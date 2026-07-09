import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit

/// Native AR platform view behind `UiKitView(viewType: 'climbtopo/ar')`.
///
/// Shows a live back-camera preview. In `auto` mode it continuously runs
/// `ArVisionPipeline` against incoming frames and publishes alignment
/// updates over the `climbtopo/ar/alignment` EventChannel (via
/// `ArChannelHandler`). In `manual` mode it only shows the camera preview
/// -- Vision is not run, and Dart owns the manual transform entirely.
final class ArPlatformView: NSObject, FlutterPlatformView {

    private let containerView: UIView
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "climbtopo.ar.session")

    private let visionPipeline = ArVisionPipeline()
    private let channelHandler: ArChannelHandler

    private var mode: ArMode = .auto
    private var isSessionGraphConfigured = false
    private var referenceLoaded = false

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
        containerView = UIView(frame: frame)
        containerView.backgroundColor = .black

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill

        // The MethodChannel ("climbtopo/ar") and EventChannel
        // ("climbtopo/ar/alignment") are created here, against the exact
        // same FlutterBinaryMessenger the registrar handed to
        // ArViewFactory (see AppDelegate.swift), so channel names match
        // the Dart contract exactly.
        channelHandler = ArChannelHandler(messenger: messenger)

        super.init()

        channelHandler.sessionController = self
        containerView.layer.addSublayer(previewLayer)
        previewLayer.frame = containerView.bounds
    }

    func view() -> UIView {
        containerView
    }
}

// MARK: - ArSessionControlling (driven by ArChannelHandler / MethodChannel)

extension ArPlatformView: ArSessionControlling {

    func startSession(
        referenceImagePath: String,
        refWidth: Int,
        refHeight: Int,
        routesJson: String,
        completion: @escaping (Bool) -> Void
    ) {
        // `routesJson` is accepted for contract completeness -- the native
        // side does not need route geometry to compute the homography
        // (Dart applies the returned matrix to its own stored route
        // points), so it is intentionally unused here.
        _ = routesJson

        let referenceOk = visionPipeline.loadReference(path: referenceImagePath, refWidth: refWidth, refHeight: refHeight)
        referenceLoaded = referenceOk

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureCaptureIfNeeded()
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            DispatchQueue.main.async {
                self.previewLayer.frame = self.containerView.bounds
                completion(referenceOk)
            }
        }
    }

    func stopSession() {
        referenceLoaded = false
        visionPipeline.reset()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func setMode(_ newMode: ArMode) {
        mode = newMode
    }
}

// MARK: - Capture session setup

private extension ArPlatformView {

    func configureCaptureIfNeeded() {
        guard !isSessionGraphConfigured else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            buildSessionGraph()
            isSessionGraphConfigured = true

        case .notDetermined:
            // Block this session-queue call until the permission prompt is
            // answered, so `startSession`'s completion still reflects the
            // final state rather than racing ahead with an empty session.
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            if granted {
                buildSessionGraph()
                isSessionGraphConfigured = true
            } else {
                reportPermissionDenied()
            }

        default:
            // Denied or restricted: don't crash -- report a benign
            // "not tracking" state so Dart can surface a permission prompt.
            reportPermissionDenied()
        }
    }

    func buildSessionGraph() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .hd1280x720

        if
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera),
            captureSession.canAddInput(input)
        {
            captureSession.addInput(input)
        }

        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
    }

    func reportPermissionDenied() {
        DispatchQueue.main.async { [weak self] in
            self?.channelHandler.sendAlignment(homography: ArVisionPipeline.identity, confidence: 0, tracking: false)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ArPlatformView: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard mode == .auto, referenceLoaded, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        visionPipeline.processLiveFrame(pixelBuffer) { [weak self] result in
            guard let self, let result else { return }
            DispatchQueue.main.async {
                self.channelHandler.sendAlignment(
                    homography: result.homography,
                    confidence: result.confidence,
                    tracking: result.tracking
                )
            }
        }
    }
}
