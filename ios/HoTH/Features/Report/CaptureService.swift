@preconcurrency import AVFoundation
import CoreLocation
import HoTHCore
import OSLog
import SwiftUI
import UIKit

private let captureLogger = Logger(subsystem: "io.fomy.hoth", category: "Capture")

/// One captured photo plus the on-device trust stamps (time, GPS, source).
struct CapturedPhoto: Sendable {
    /// Orientation-normalized image, downsized to <= 1024 px on the long edge.
    let image: UIImage
    /// JPEG bytes of `image`, sent to the vision model.
    let jpegData: Data
    let capturedAt: Date
    let gps: GPSFix?
    let source: CaptureSource
    /// Bundled demo sample this photo came from (demo mode only).
    let demoSampleID: String?
}

/// Errors surfaced by the live camera.
enum CaptureError: Error, CustomStringConvertible {
    case cameraUnavailable
    case permissionDenied
    case captureFailed(String)

    var description: String {
        switch self {
        case .cameraUnavailable: return "No camera is available on this device."
        case .permissionDenied: return "Camera access is turned off for HoTH."
        case .captureFailed(let reason): return "The photo could not be taken: \(reason)"
        }
    }

    /// User-facing, localized message (technical detail stays in `description` for logs).
    static func userMessage(for error: Error) -> LocalizedStringKey {
        switch error as? CaptureError {
        case .cameraUnavailable: return "No camera is available on this device."
        case .permissionDenied: return "Camera access is turned off for HoTH."
        case .captureFailed, .none: return "The photo could not be taken. Please try again."
        }
    }
}

/// Live camera session, photo capture and a one-shot location fix (P0-12).
///
/// There is deliberately no photo-library path here: real reports come from the live camera only.
@MainActor
final class CaptureService: NSObject, ObservableObject {
    enum CameraState: Equatable {
        case idle
        case unavailable
        case denied
        case running
    }

    @Published private(set) var cameraState: CameraState = .idle
    @Published private(set) var latestFix: GPSFix?
    @Published private(set) var locationDenied = false

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "io.fomy.hoth.capture.session")
    private let locationManager = CLLocationManager()
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var isConfigured = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// True when the device has a back camera (false on the simulator).
    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    // MARK: Lifecycle

    /// Asks for permissions in context and starts the preview plus location updates.
    func start() async {
        startLocation()
        guard Self.hasCamera else {
            cameraState = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                cameraState = .denied
                return
            }
        default:
            cameraState = .denied
            return
        }
        do {
            try configureIfNeeded()
        } catch {
            captureLogger.error("Camera configuration failed: \(String(describing: error))")
            cameraState = .unavailable
            return
        }
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
        cameraState = .running
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        if cameraState == .running { cameraState = .idle }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CaptureError.captureFailed("session rejected input/output")
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        isConfigured = true
    }

    private func startLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationDenied = true
            return
        default:
            break
        }
        locationManager.startUpdatingLocation()
    }

    // MARK: Capture

    /// Takes a live photo and stamps it with the current time and the latest GPS fix.
    func capturePhoto() async throws -> CapturedPhoto {
        guard cameraState == .running else { throw CaptureError.cameraUnavailable }
        let capturedAt = Date()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        guard let raw = UIImage(data: data) else { throw CaptureError.captureFailed("unreadable image data") }
        return try Self.makeCapturedPhoto(from: raw, capturedAt: capturedAt, gps: latestFix,
                                          source: .liveCamera, demoSampleID: nil)
    }

    /// Normalizes orientation, downsizes and encodes a photo.
    /// JPEG quality for report photos (the local original and the redacted upload alike).
    nonisolated static let jpegQuality: CGFloat = 0.82

    nonisolated static func makeCapturedPhoto(
        from image: UIImage,
        capturedAt: Date,
        gps: GPSFix?,
        source: CaptureSource,
        demoSampleID: String?
    ) throws -> CapturedPhoto {
        let prepared = ImageResizing.normalizedAndDownsized(image, maxEdge: ImageResizing.maxPixelEdge)
        guard let jpeg = prepared.jpegData(compressionQuality: jpegQuality) else {
            throw CaptureError.captureFailed("JPEG encoding failed")
        }
        return CapturedPhoto(image: prepared, jpegData: jpeg, capturedAt: capturedAt, gps: gps,
                             source: source, demoSampleID: demoSampleID)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CaptureService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let result: Result<Data, Error>
        if let error {
            result = .failure(CaptureError.captureFailed(error.localizedDescription))
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(CaptureError.captureFailed("no image data"))
        }
        Task { @MainActor in
            self.photoContinuation?.resume(with: result)
            self.photoContinuation = nil
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension CaptureService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = GPSFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                         accuracyMeters: location.horizontalAccuracy)
        Task { @MainActor in self.latestFix = fix }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        captureLogger.error("Location update failed: \(error.localizedDescription)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationDenied = status == .denied || status == .restricted
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.locationManager.startUpdatingLocation()
            }
        }
    }
}

// MARK: - Image helpers

/// Pure image helpers shared by capture and privacy blurring.
enum ImageResizing {
    /// Longest edge sent to the vision model.
    static let maxPixelEdge: CGFloat = 1024

    /// Redraws the image upright (orientation `.up`) and scales it so the long edge is <= `maxEdge`.
    static func normalizedAndDownsized(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        let scale = longEdge > maxEdge ? maxEdge / longEdge : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
