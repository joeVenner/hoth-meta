import Foundation
import HoTHCore
import OSLog
import SwiftData
import SwiftUI
import UIKit

/// Drives one crew fix check: before photo → verifier → verdict → (resolved) blur, save, rewards, Fixed moment;
/// (rejected) SAM 3.1 "what's left" boxes on the after photo.
@MainActor
final class FixCheckModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case verdict
        case failed(String)
    }

    /// Data for the in-app "Fixed ✨" celebration.
    struct Celebration: Identifiable {
        let id = UUID()
        let titleEN: String
        let titleAR: String
        let before: UIImage?
        let after: UIImage?
        let pointsAwarded: Int
        let wasReporter: Bool
        let newPoints: Int
        let didLevelUp: Bool
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var verdict: FixVerdict?
    @Published private(set) var afterImage: UIImage?
    @Published private(set) var isDemoPhoto = false
    /// SAM 3.1 boxes for what is still broken on a rejected live verdict; nil while pending or unavailable.
    @Published private(set) var samRemaining: SegmentOutline?
    @Published var celebration: Celebration?

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "FixCheck")
    private let verifierFactory: (DemoFixPhoto?) -> FixVerifying?
    private let outlinerFactory: () -> HazardOutlining?
    /// On-device face/plate blur for both photos before the verifier or SAM sees them.
    private let redactor: @Sendable (UIImage) async -> FaceAndPlateBlur.Upload?
    private var outlineTask: Task<Void, Never>?
    /// Identifies the current check so a late SAM answer for an earlier photo is dropped.
    private var checkID = UUID()

    /// - Parameters:
    ///   - verifierFactory: returns the verifier for a pick (nil → no verifier available).
    ///   - outlinerFactory: SAM for rejected verdicts (nil → Muse Spark's boxes only).
    ///   - redactor: blurs faces and plates before any upload (tests inject a fake).
    init(verifierFactory: ((DemoFixPhoto?) -> FixVerifying?)? = nil,
         outlinerFactory: (() -> HazardOutlining?)? = nil,
         redactor: @escaping @Sendable (UIImage) async -> FaceAndPlateBlur.Upload? = { await FixCheckModel.redactForUpload($0) }) {
        self.verifierFactory = verifierFactory ?? FixCheckModel.defaultVerifier
        self.outlinerFactory = outlinerFactory ?? { AppServices.shared.hazardOutliner() }
        self.redactor = redactor
    }

    /// Production redactor at the fix check's JPEG quality.
    nonisolated static func redactForUpload(_ image: UIImage) async -> FaceAndPlateBlur.Upload? {
        await FaceAndPlateBlur.redactForUpload(image, quality: 0.7)
    }

    /// The "what's left" boxes to draw: SAM's when it found something, else the verifier's own.
    static func remainingRegions(verdict: FixVerdict, sam: SegmentOutline?) -> (regions: [FixVerdict.Region], isFromSAM: Bool) {
        guard !verdict.resolved else { return ([], false) }
        guard let sam, !sam.boxes.isEmpty else { return (verdict.remaining, false) }
        let regions = sam.boxes.map {
            FixVerdict.Region(label: sam.concept, box: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h))
        }
        return (regions, true)
    }

    /// Live verifier when a key exists; otherwise the labelled canned verdict for bundled demo photos.
    private static func defaultVerifier(for demo: DemoFixPhoto?) -> FixVerifying? {
        let services = AppServices.shared
        if services.hasAPIKey() {
            return LiveFixVerifier(verifier: FixVerifier(client: services.modelClient, prompts: services.prompts,
                                                         model: services.visionModel))
        }
        if let demo, services.demoMode { return CannedFixVerifier(photo: demo) }
        return nil
    }

    /// BEFORE photo: the original local photo; demo seeds use the bundled pair that matches the demo fixes.
    static func beforeImage(for report: Report) -> UIImage? {
        if report.isDemoSeed {
            if report.category == .potholePavement, let pair = UIImage(named: DemoFixPhoto.beforeAssetName) {
                return pair
            }
            return report.photoFileName.flatMap { UIImage(named: $0) }
        }
        return ReportPhotoView.loadImage(report.photoFileName) ?? ReportPhotoView.loadImage(report.blurredPhotoFileName)
    }

    /// Runs exactly one verification for this after photo. Never retries.
    func check(report: Report, after: UIImage, demo: DemoFixPhoto?, context: ModelContext) async {
        guard phase != .checking else { return }
        guard CrewWorkflow.isActionable(report.status) else {
            phase = .failed(String(localized: "crew.error.notActionable", defaultValue: "This case is already closed."))
            return
        }
        cancelOutline()
        // Upright and <= 1024 px, like report photos: a camera shot is often `.right` with raw sensor
        // pixels, and boxes from either model must land on the image that is shown.
        let after = ImageResizing.normalizedAndDownsized(after, maxEdge: ImageResizing.maxPixelEdge)
        afterImage = after
        isDemoPhoto = demo != nil
        verdict = nil
        guard let before = Self.beforeImage(for: report) else {
            phase = .failed(String(localized: "crew.error.noBefore", defaultValue: "The original photo is not available on this device."))
            return
        }
        guard let verifier = verifierFactory(demo) else {
            phase = .failed(String(localized: "crew.error.noKey", defaultValue: "Add a Meta Model API key in Settings to check repairs."))
            return
        }

        phase = .checking
        // Privacy: both photos are blurred on the phone before either leaves it. If either cannot be
        // redacted (or times out), nothing is sent.
        async let redactedBefore = redactor(before)
        async let redactedAfter = redactor(after)
        guard let beforeUpload = await redactedBefore, let afterUpload = await redactedAfter else {
            phase = .failed(String(localized: "crew.error.redaction",
                                   defaultValue: "Couldn't blur faces and number plates on these photos, so nothing was sent. Please try again."))
            return
        }
        let beforeData = beforeUpload.jpegData
        let afterData = afterUpload.jpegData
        let result: FixVerdict
        do {
            result = try await verifier.verify(before: beforeData, after: afterData, reportTitle: report.titleEN,
                                               categoryRaw: report.categoryRaw, beforeCapturedAt: report.createdAt)
        } catch {
            Self.logger.error("Fix check failed: \(String(describing: error), privacy: .public)")
            phase = .failed(String(localized: "crew.error.verify", defaultValue: "Couldn't check the repair. Please try again."))
            return
        }
        verdict = result
        if !result.resolved, !result.isCanned, let category = ReportCategory(rawValue: report.categoryRaw) {
            startOutline(afterData: afterData, category: category)
        }

        do {
            // Public fix photo is always the redacted one; nothing is saved if blurring fails.
            var fixFileName: String?
            if result.resolved {
                fixFileName = Self.saveBlurred(afterUpload.result, reportID: report.id)
            }
            let outcome = try CrewWorkflow.apply(result, to: report, fixPhotoFileName: fixFileName, context: context)
            try context.save()
            phase = .verdict
            if outcome.verdictResolved {
                Haptics.success()
                if outcome.isCurrentUserInvolved {
                    let fixedDisplay = fixFileName.flatMap { ReportPhotoView.loadImage($0) } ?? after
                    celebration = Celebration(
                        titleEN: report.titleEN, titleAR: report.titleAR, before: before, after: fixedDisplay,
                        pointsAwarded: outcome.currentUserPointsAwarded, wasReporter: outcome.currentUserWasReporter,
                        newPoints: outcome.currentUserPointsAfter, didLevelUp: outcome.didLevelUp
                    )
                    FixedMomentNotifier.shared.post(titleEN: report.titleEN, titleAR: report.titleAR,
                                                    points: outcome.currentUserPointsAwarded,
                                                    wasReporter: outcome.currentUserWasReporter)
                }
            }
        } catch {
            Self.logger.error("Applying fix verdict failed: \(String(describing: error), privacy: .public)")
            phase = .failed(String(localized: "crew.error.save", defaultValue: "Couldn't save the result."))
        }
    }

    func reset() {
        cancelOutline()
        phase = .idle
        verdict = nil
        afterImage = nil
        isDemoPhoto = false
    }

    // MARK: SAM

    /// SAM on the exact after JPEG the verifier saw. Failure or timeout keeps Muse Spark's boxes.
    private func startOutline(afterData: Data, category: ReportCategory) {
        guard let outliner = outlinerFactory() else { return }
        let check = checkID
        outlineTask = Task { [weak self] in
            do {
                let result = try await outliner.outline(jpegData: afterData, category: category)
                guard let self, check == self.checkID, !Task.isCancelled else { return }
                self.samRemaining = result
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                Self.logger.error("SAM what's-left unavailable: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func cancelOutline() {
        outlineTask?.cancel()
        outlineTask = nil
        samRemaining = nil
        checkID = UUID()
    }

    /// Waits for the in-flight SAM call (tests only; the view observes `samRemaining`).
    func waitForOutline() async {
        await outlineTask?.value
    }

    /// Writes the already-blurred after photo (the one the verifier saw) as `fix_<id>.jpg` to Documents.
    /// Nil when there is no redacted image or writing fails.
    private static func saveBlurred(_ blurred: FaceAndPlateBlur.Result, reportID: UUID) -> String? {
        guard let redacted = blurred.image, let data = redacted.jpegData(compressionQuality: 0.8),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Fix photo not saved: blur produced no image")
            return nil
        }
        let name = "fix_\(reportID.uuidString).jpg"
        do {
            try data.write(to: documents.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            logger.error("Fix photo write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Offline verdict for a bundled demo repair photo (no network).
struct CannedFixVerifier: FixVerifying {
    let photo: DemoFixPhoto

    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict {
        try await Task.sleep(nanoseconds: 900_000_000)  // lets the "checking" state read on screen
        return photo.cannedVerdict
    }
}
