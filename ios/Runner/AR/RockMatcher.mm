// RockMatcher.mm
// Obj-C++ implementation of the OpenCV ORB + BFMatcher + RANSAC registration
// bridge (see RockMatcher.h). Pure OpenCV -- NO ARKit / Vision dependency.
//
// OpenCV is included FIRST, before any Apple headers, to dodge macro/type
// clashes between opencv2's C headers and the Apple SDK (the well-known
// iOS+OpenCV integration gotcha).
//
// `opencv2/geometry.hpp` (cv::findHomography, cv::RANSAC -- moved out of
// calib3d into the new `geometry` module in OpenCV 5.0) is included
// EXPLICITLY: this xcframework's `opencv2/opencv.hpp` umbrella guards the
// geometry module behind `#ifdef HAVE_OPENCV_3D`, but `opencv_modules.hpp`
// actually defines `HAVE_OPENCV_GEOMETRY` -- a header/module naming mismatch
// in this particular prebuilt xcframework -- so the umbrella silently never
// pulls it in.
#import <opencv2/opencv.hpp>
#import <opencv2/geometry.hpp>

#import "RockMatcher.h"

#include <algorithm>
#include <cmath>
#include <vector>

@interface RockMatcher () {
    std::vector<cv::KeyPoint> _refKeypoints;
    cv::Mat _refDescriptors;
    int _refWidth;
    int _refHeight;
}
@end

@implementation RockMatcher

- (instancetype)init {
    self = [super init];
    if (self) {
        [self reset];
    }
    return self;
}

#pragma mark - Conversion helpers

/// Converts a CGImage to a single-channel grayscale `cv::Mat` at the image's
/// full (un-cropped) pixel dimensions. Returns an empty Mat on failure.
static cv::Mat GrayMatFromCGImage(CGImageRef image) {
    if (image == NULL) {
        return cv::Mat();
    }
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) {
        return cv::Mat();
    }

    cv::Mat rgba(static_cast<int>(height), static_cast<int>(width), CV_8UC4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        rgba.data,
        width,
        height,
        8,
        rgba.step[0],
        colorSpace,
        kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault
    );
    CGColorSpaceRelease(colorSpace);
    if (ctx == NULL) {
        return cv::Mat();
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    CGContextRelease(ctx);

    cv::Mat gray;
    cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY);
    return gray;
}

/// Converts a live `CVPixelBufferRef` to a single-channel grayscale
/// `cv::Mat`, copied out of the buffer's memory before the caller unlocks
/// it. Handles both the planar YCbCr format ARKit's `capturedImage` actually
/// uses (plane 0 IS luma -- already grayscale, no color conversion needed)
/// and a single-plane 32BGRA buffer (e.g. a synthetic test pixel buffer).
/// Returns an empty Mat on any failure; the buffer must already be locked by
/// the caller (this function never locks/unlocks).
static cv::Mat GrayMatFromLockedPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == NULL) {
        return cv::Mat();
    }

    const size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
    if (planeCount > 0) {
        // Planar (e.g. kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) --
        // plane 0 is the Y (luma) plane, already grayscale.
        void *base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        if (base == NULL) {
            return cv::Mat();
        }
        const size_t w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        const size_t h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        if (w == 0 || h == 0) {
            return cv::Mat();
        }
        cv::Mat y(static_cast<int>(h), static_cast<int>(w), CV_8UC1, base, stride);
        return y.clone(); // copy out before the caller unlocks the buffer
    }

    // Single-plane (e.g. 32BGRA synthetic buffers).
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    if (base == NULL) {
        return cv::Mat();
    }
    const size_t w = CVPixelBufferGetWidth(pixelBuffer);
    const size_t h = CVPixelBufferGetHeight(pixelBuffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (w == 0 || h == 0) {
        return cv::Mat();
    }
    cv::Mat bgra(static_cast<int>(h), static_cast<int>(w), CV_8UC4, base, stride);
    cv::Mat gray;
    // ORB only needs consistent contrast, not colorimetrically-correct luma,
    // so a non-BGRA 32-bit layout (e.g. RGBA) still produces a usable (if
    // slightly mis-weighted) grayscale image via the same conversion.
    cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY);
    return gray;
}

#pragma mark - Public API

- (BOOL)loadReferenceCGImage:(CGImageRef)image rockQuad:(NSArray<NSNumber *> *)rockQuad {
    [self reset];

    cv::Mat gray = GrayMatFromCGImage(image);
    if (gray.empty()) {
        return NO;
    }

    // ORB is run at a downscaled "working resolution" (~1000px longest side)
    // -- the full 4032x3024 reference is 10x+ slower for no matching-quality
    // benefit, and (more importantly) puts the reference features at a much
    // coarser scale than the live-frame features (which are already
    // downscaled below), which was hurting match rate. Detection coordinates
    // are then scaled back UP into full-reference-pixel space so the stored
    // keypoints -- and therefore the homography this class returns -- stay in
    // the full-reference-pixel -> full-live-pixel contract the Swift side
    // (OpenCvRegistrationEngine) expects.
    const int refW = gray.cols;
    const int refH = gray.rows;
    const double refScale = std::min(1.0, 1000.0 / (double)std::max(refW, refH));

    cv::Mat detectGray;
    if (refScale < 1.0) {
        cv::resize(gray, detectGray, cv::Size(), refScale, refScale, cv::INTER_AREA);
    } else {
        detectGray = gray;
    }
    const int refWs = detectGray.cols;
    const int refHs = detectGray.rows;

    // Build an ORB detection mask restricted to the rock quad (if given), at
    // the SAME downscaled resolution as `detectGray`; detection still runs
    // on the full gray image's content otherwise -- the mask only restricts
    // WHERE keypoints are found. Keypoint coordinates are rescaled back to
    // full-reference-pixel space below (never cropped), matching the
    // coordinate contract in RockRegistrationEngine.swift.
    cv::Mat mask;
    if (rockQuad.count == 8) {
        mask = cv::Mat::zeros(detectGray.size(), CV_8UC1);
        std::vector<cv::Point> pts;
        pts.reserve(4);
        for (int i = 0; i < 4; i++) {
            const double nx = rockQuad[(NSUInteger)(i * 2)].doubleValue;
            const double ny = rockQuad[(NSUInteger)(i * 2 + 1)].doubleValue;
            int px = static_cast<int>(std::lround(nx * refWs));
            int py = static_cast<int>(std::lround(ny * refHs));
            px = std::max(0, std::min(refWs - 1, px));
            py = std::max(0, std::min(refHs - 1, py));
            pts.push_back(cv::Point(px, py));
        }
        cv::fillConvexPoly(mask, pts, cv::Scalar(255));
    }

    cv::Ptr<cv::ORB> orb = cv::ORB::create(1500);
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    orb->detectAndCompute(detectGray, mask.empty() ? cv::noArray() : mask, keypoints, descriptors);

    if (keypoints.size() < 20 || descriptors.empty()) {
        [self reset];
        return NO;
    }

    // Scale detected keypoints back up from downscaled-detection space to
    // full-reference-pixel space. Descriptor values are unaffected by
    // coordinate scale, so `descriptors` is stored as-is.
    if (refScale < 1.0) {
        const float invScaleX = (float)refW / (float)refWs;
        const float invScaleY = (float)refH / (float)refHs;
        for (auto &kp : keypoints) {
            kp.pt.x *= invScaleX;
            kp.pt.y *= invScaleY;
        }
    }

    _refKeypoints = keypoints;
    _refDescriptors = descriptors;
    _refWidth = refW;
    _refHeight = refH;
    return YES;
}

- (nullable NSArray<NSNumber *> *)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (_refDescriptors.empty() || _refKeypoints.size() < 20) {
        return nil;
    }
    if (pixelBuffer == NULL) {
        return nil;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    cv::Mat gray = GrayMatFromLockedPixelBuffer(pixelBuffer);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    if (gray.empty()) {
        return nil;
    }

    // Same working-resolution downscale as the reference (~1000px longest
    // side): this is the main per-frame cost, so shrinking the live frame is
    // what actually buys the ~10x speedup. Detected keypoints are rescaled
    // back to full-live-pixel space below so `cv::findHomography` -- and the
    // homography this method returns -- stays full-ref-pixel ->
    // full-live-pixel, per the class contract.
    const int liveW = gray.cols;
    const int liveH = gray.rows;
    const double liveScale = std::min(1.0, 1000.0 / (double)std::max(liveW, liveH));

    cv::Mat liveDetectGray;
    if (liveScale < 1.0) {
        cv::resize(gray, liveDetectGray, cv::Size(), liveScale, liveScale, cv::INTER_AREA);
    } else {
        liveDetectGray = gray;
    }
    const int liveWs = liveDetectGray.cols;
    const int liveHs = liveDetectGray.rows;

    cv::Ptr<cv::ORB> orb = cv::ORB::create(1500);
    std::vector<cv::KeyPoint> liveKeypoints;
    cv::Mat liveDescriptors;
    orb->detectAndCompute(liveDetectGray, cv::noArray(), liveKeypoints, liveDescriptors);

    if (liveDescriptors.empty() || liveKeypoints.size() < 20) {
        return nil;
    }

    if (liveScale < 1.0) {
        const float invScaleX = (float)liveW / (float)liveWs;
        const float invScaleY = (float)liveH / (float)liveHs;
        for (auto &kp : liveKeypoints) {
            kp.pt.x *= invScaleX;
            kp.pt.y *= invScaleY;
        }
    }

    cv::BFMatcher matcher(cv::NORM_HAMMING);
    std::vector<std::vector<cv::DMatch>> knnMatches;
    matcher.knnMatch(_refDescriptors, liveDescriptors, knnMatches, 2);

    std::vector<cv::DMatch> good;
    good.reserve(knnMatches.size());
    for (const auto &pair : knnMatches) {
        if (pair.size() == 2 && pair[0].distance < 0.75f * pair[1].distance) {
            good.push_back(pair[0]);
        }
    }
    if (good.size() < 12) {
        return nil;
    }

    std::vector<cv::Point2f> refPts;
    std::vector<cv::Point2f> livePts;
    refPts.reserve(good.size());
    livePts.reserve(good.size());
    for (const auto &m : good) {
        refPts.push_back(_refKeypoints[(size_t)m.queryIdx].pt);
        livePts.push_back(liveKeypoints[(size_t)m.trainIdx].pt);
    }

    cv::Mat inlierMask;
    cv::Mat H = cv::findHomography(refPts, livePts, cv::RANSAC, 5.0, inlierMask);
    if (H.empty() || H.rows != 3 || H.cols != 3) {
        return nil;
    }

    const int inliers = cv::countNonZero(inlierMask);
    const double inlierRatio = good.empty() ? 0.0 : (double)inliers / (double)good.size();
    if (inliers < 12 || inlierRatio < 0.25) {
        return nil;
    }

    cv::Mat h64;
    H.convertTo(h64, CV_64F);

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:10];
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            const double v = h64.at<double>(r, c);
            if (!std::isfinite(v)) {
                return nil;
            }
            [result addObject:@(v)];
        }
    }
    [result addObject:@(inlierRatio)];
    return result;
}

- (void)reset {
    _refKeypoints.clear();
    _refDescriptors.release();
    _refWidth = 0;
    _refHeight = 0;
}

@end
