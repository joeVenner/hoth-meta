import Foundation

/// Evidence that every photo sent to Meta passed the on-device blur first (`FaceAndPlateBlur`).
///
/// Upload paths call `redacted` when a redaction finishes and `request` right before the Meta call
/// that carries those redacted bytes, naming the redactions by `uploadID`. A photo blurred once and sent
/// to several models (vision, then SAM and `segment_hazard` on the same JPEG) has one `redacted` and
/// several `request`s. Nothing is recorded for paths that send no photo (canned demo analyses).
///
/// DEBUG builds write both to the demo-capture log (`CaptureLog`, only when `HOTH_DEMO_CAPTURE=1`);
/// release builds record nothing. Only counts, timings and ids are passed: never image bytes or keys.
struct UploadAudit: Sendable {
    enum Path: String, Sendable {
        case vision
        case sam
        case dedup
        case segmentHazard = "segment_hazard"
        case fixcheck
    }

    /// One finished redaction: what it blurred and how long it took.
    struct Redaction: Equatable, Sendable {
        let path: Path
        let uploadID: String
        let faces: Int
        let plates: Int
        let durationMs: Int
    }

    /// A redaction finished (its bytes may now be sent).
    let redacted: @Sendable (Redaction) -> Void
    /// A Meta request carrying the redactions `uploadIDs` is about to be sent.
    let request: @Sendable (_ path: Path, _ uploadIDs: [String]) -> Void

    static let none = UploadAudit(redacted: { _ in }, request: { _, _ in })

    /// The app's audit: the capture log in DEBUG, nothing in release.
    static var live: UploadAudit {
        #if DEBUG
        UploadAudit(redacted: { CaptureLog.recordRedaction($0) },
                    request: { CaptureLog.recordMetaRequest(path: $0, uploadIDs: $1) })
        #else
        .none
        #endif
    }

    /// A short random id linking a redaction to the requests that send it (not derived from the photo).
    static func newUploadID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// Runs `redactor` on `image` and records the redaction when it succeeds. Nil (nothing recorded,
    /// nothing may be sent) when it fails.
    func redact<Input>(_ image: Input, path: Path,
                       with redactor: (Input) async -> FaceAndPlateBlur.Upload?) async -> AuditedUpload? {
        let clock = ContinuousClock()
        let start = clock.now
        guard let upload = await redactor(image) else { return nil }
        let milliseconds = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
        let id = Self.newUploadID()
        redacted(Redaction(path: path, uploadID: id, faces: upload.result.faceCount,
                           plates: upload.result.plateCount, durationMs: milliseconds))
        return AuditedUpload(upload: upload, uploadID: id)
    }
}

/// A redacted upload and the audit id of its redaction.
struct AuditedUpload: Sendable {
    let upload: FaceAndPlateBlur.Upload
    let uploadID: String

    var jpegData: Data { upload.jpegData }
}
