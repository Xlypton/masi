// RockMatcher.h
// Obj-C++ bridge to OpenCV ORB + BFMatcher + RANSAC homography estimation --
// the `.opencv` variant of the AR placement-engine A/B (see
// `docs/superpowers/specs/2026-07-27-ar-placement-engines-design.md`).
//
// Pure OpenCV. No ARKit / Vision dependency -- this class only ever sees a
// CGImage (the reference photo) and a CVPixelBuffer (a live camera frame) and
// hands back a homography, matching the shape `RockEngineMath` already
// expects from the ORB/Vision engines (see `RockRegistrationEngine.swift`).
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface RockMatcher : NSObject

/// Detects ORB keypoints/descriptors on the reference image ONCE.
/// `rockQuad`: 8 normalized (0..1) doubles TL,TR,BR,BL of the rock region
/// within the (already-upright) reference image; an empty array means
/// "whole image". When non-empty, a detection MASK restricts ORB to the rock
/// region -- the full image is still gray-converted and stored (never
/// cropped), matching the coordinate contract in `RockRegistrationEngine`
/// (homographies map full-reference-pixel space, not a crop subset).
/// Returns NO if fewer than 20 keypoints are found (too few to ever produce
/// a reliable match) -- callers should fall back to another engine.
- (BOOL)loadReferenceCGImage:(CGImageRef)image rockQuad:(NSArray<NSNumber *> *)rockQuad;

/// Matches one live camera frame against the stored reference. Returns 10
/// NSNumbers -- `h0..h8` (row-major 3x3 homography, reference-pixel ->
/// live-frame-pixel) followed by `inlierRatio` (0..1) -- or nil when no
/// reliable homography could be recovered this frame (too few keypoints,
/// too few good matches, or RANSAC inlier count/ratio below threshold).
- (nullable NSArray<NSNumber *> *)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// Clears the stored reference keypoints/descriptors.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
