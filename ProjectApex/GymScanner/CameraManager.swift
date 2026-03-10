// CameraManager.swift
// ProjectApex — GymScanner Feature
//
// Owns the AVCaptureSession lifecycle and exposes two async interfaces:
//
//   1. `previewLayer` — an AVCaptureVideoPreviewLayer for live camera preview.
//      Used by CameraPreviewView (UIViewRepresentable) to render the feed in SwiftUI.
//
//   2. `frames(interval:)` — an AsyncStream<CapturedFrame> that fires at the
//      configured interval, yielding Base64-encoded JPEG frames for the Vision API.
//
// Threading model:
//   • All AVFoundation configuration runs on a dedicated serial background queue
//     (`sessionQueue`) to avoid blocking the main thread (per Apple guidance).
//   • The CameraManager class itself is NOT an actor, but its mutable state is
//     protected by the `sessionQueue` via dispatch. Public methods that mutate
//     state are `@MainActor`-safe because they dispatch internally.
//   • The AsyncStream continuation is called from `sessionQueue` context; consumers
//     should process frames on a non-main actor.
//
// FR coverage: FR-001-A (permissions), FR-001-B (interval capture), FR-001-C (JPEG/Base64)

import AVFoundation
import UIKit

// MARK: - CapturedFrame

/// A single still frame captured from the live camera feed, ready for Vision API submission.
struct CapturedFrame: Sendable {
    /// Base64-encoded JPEG data at 80% quality (FR-001-C).
    let base64JPEG: String
    /// Monotonic capture index — used to correlate API responses with frames.
    let index: Int
    /// Wall-clock time of capture.
    let capturedAt: Date
}

// MARK: - CameraManager

/// Manages the AVCaptureSession and frame-capture pipeline for the gym scanner.
///
/// Usage pattern in ScannerViewModel:
/// ```swift
/// for await frame in cameraManager.frames(interval: 2.0) {
///     Task { await visionService.analyse(frame) }
/// }
/// ```
/// Not `Sendable`: wraps AVFoundation reference types (AVCaptureSession,
/// AVCaptureVideoPreviewLayer) which are not safe to pass freely across
/// concurrency domains. Access is serialised via `sessionQueue` internally.
final class CameraManager: NSObject {

    // ---------------------------------------------------------------------------
    // MARK: Public Interfaces
    // ---------------------------------------------------------------------------

    /// The preview layer wired to the active AVCaptureSession.
    /// Expose this to `CameraPreviewView` for live feed rendering.
    let previewLayer: AVCaptureVideoPreviewLayer

    // ---------------------------------------------------------------------------
    // MARK: Private State
    // ---------------------------------------------------------------------------

    /// The central AVFoundation pipeline object.
    /// All mutations happen on `sessionQueue`.
    private let captureSession = AVCaptureSession()

    /// Dedicated serial background queue for all AVFoundation configuration
    /// and sample buffer callbacks. Never blocked by UI work.
    private let sessionQueue = DispatchQueue(
        label: "com.projectapex.scanner.sessionQueue",
        qos: .userInitiated
    )

    /// Photo output for high-quality still frame capture at intervals.
    /// Lower overhead than processing every video frame continuously.
    private let photoOutput = AVCapturePhotoOutput()

    /// Tracks the monotonic frame index across the scanning session.
    /// Marked nonisolated(unsafe) because it is exclusively mutated on `sessionQueue`
    /// (including from the nonisolated delegate callback), satisfying the no-data-race contract.
    private nonisolated(unsafe) var frameIndex: Int = 0

    /// The continuation for the currently active frame stream.
    /// Nil when no scan is in progress. Stored as nonisolated(unsafe)
    /// because it is only written once (at stream creation) and read on
    /// sessionQueue, satisfying the no-data-race contract.
    private nonisolated(unsafe) var frameContinuation: AsyncStream<CapturedFrame>.Continuation?

    /// Timer driving periodic frame capture. Lives on `sessionQueue`.
    private nonisolated(unsafe) var captureTimer: Timer?

    // ---------------------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------------------

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    // ---------------------------------------------------------------------------
    // MARK: Permission & Session Setup (FR-001-A)
    // ---------------------------------------------------------------------------

    /// Requests camera permission and, if granted, configures the capture session.
    /// Returns `true` if the session is ready to run, `false` on denial.
    ///
    /// - Throws: `ScannerError.cameraSetupFailed` if AVFoundation configuration fails.
    func requestAccessAndConfigure() async throws -> Bool {
        // Check / request authorisation asynchronously (modern AVFoundation API)
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            break // Already good
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw ScannerError.cameraPermissionDenied }
        case .denied, .restricted:
            throw ScannerError.cameraPermissionDenied
        @unknown default:
            throw ScannerError.cameraPermissionDenied
        }

        // Run the potentially blocking session configuration on sessionQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.configureSession()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ScannerError.cameraSetupFailed(underlying: error))
                }
            }
        }

        return true
    }

    /// Configures AVCaptureSession with a wide-angle back camera and photo output.
    /// Must be called on `sessionQueue`.
    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Target medium-quality preset — adequate for Vision API analysis,
        // keeps frame sizes manageable for JPEG encoding and network transfer.
        captureSession.sessionPreset = .medium

        // Select the best available back camera
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw ScannerError.cameraSetupFailed(
                underlying: NSError(
                    domain: "CameraManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No back camera available"]
                )
            )
        }

        // Create and add the video input
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(deviceInput) else {
            throw ScannerError.cameraSetupFailed(
                underlying: NSError(
                    domain: "CameraManager",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input to session"]
                )
            )
        }
        captureSession.addInput(deviceInput)

        // Add photo output for interval-based still capture
        // isDeferredStartEnabled is automatically true for photo outputs on iOS 26+,
        // which improves session startup performance.
        guard captureSession.canAddOutput(photoOutput) else {
            throw ScannerError.cameraSetupFailed(
                underlying: NSError(
                    domain: "CameraManager",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add photo output to session"]
                )
            )
        }
        captureSession.addOutput(photoOutput)
    }

    // ---------------------------------------------------------------------------
    // MARK: Session Lifecycle
    // ---------------------------------------------------------------------------

    /// Starts the capture session. Non-blocking: dispatches to `sessionQueue`.
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    /// Stops the capture session and tears down any active frame stream.
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureTimer?.invalidate()
            self.captureTimer = nil
            self.frameContinuation?.finish()
            self.frameContinuation = nil
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Frame Stream (FR-001-B, FR-001-C)
    // ---------------------------------------------------------------------------

    /// Returns an `AsyncStream` that emits a `CapturedFrame` every `interval` seconds
    /// for as long as the scan is active. The stream finishes when `stopSession()` is
    /// called or the `CameraManager` is deallocated.
    ///
    /// Frames are JPEG-compressed at 80% quality and Base64-encoded (FR-001-C).
    ///
    /// - Parameter interval: Seconds between successive frame captures. Default: 2.0s.
    func frames(interval: TimeInterval = 2.0) -> AsyncStream<CapturedFrame> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            // Store continuation so photo delegate callbacks can yield frames
            self.frameContinuation = continuation

            // Register termination handler so the stream cleans up properly
            continuation.onTermination = { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    self?.captureTimer?.invalidate()
                    self?.captureTimer = nil
                    self?.frameContinuation = nil
                }
            }

            // Schedule a repeating timer on sessionQueue's RunLoop.
            // Using a RunLoop timer on the queue keeps scheduling tight and avoids
            // Timer's default main-thread requirement.
            self.sessionQueue.async { [weak self] in
                guard let self else { return }

                // Trigger the first capture immediately, then repeat
                self.triggerPhotoCapture()

                let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    self?.triggerPhotoCapture()
                }
                RunLoop.current.add(timer, forMode: .common)
                self.captureTimer = timer
                RunLoop.current.run() // Keep the runloop alive for the timer
            }
        }
    }

    /// Requests a single still frame capture from `photoOutput`.
    /// Must be called from `sessionQueue`.
    private func triggerPhotoCapture() {
        guard captureSession.isRunning else { return }

        // Use a high-quality JPEG capture setting.
        // AVCapturePhotoSettings is created fresh each capture (Apple requirement).
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = .off

        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {

    /// Called on `sessionQueue` after a photo capture completes.
    /// Extracts the JPEG data, Base64-encodes it, and yields to the frame stream.
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Silently skip failed frames — we rely on interval retries.
        guard error == nil, let jpegData = photo.fileDataRepresentation() else { return }

        // Recompress to exactly 80% quality (FR-001-C).
        // `fileDataRepresentation()` gives the camera's native JPEG, but we
        // re-encode via UIImage to enforce the 80% quality target consistently.
        guard
            let image = UIImage(data: jpegData),
            let compressedData = image.jpegData(compressionQuality: 0.8)
        else { return }

        let base64String = compressedData.base64EncodedString()

        // Increment the frame counter and yield the captured frame.
        // frameContinuation access is safe here: only written once at stream
        // creation and only read/used on sessionQueue.
        let index = frameIndex
        frameIndex += 1

        let frame = CapturedFrame(
            base64JPEG: base64String,
            index: index,
            capturedAt: Date()
        )

        frameContinuation?.yield(frame)
    }
}
