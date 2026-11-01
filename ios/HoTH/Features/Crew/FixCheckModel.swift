import Foundation
import HoTHCore
import OSLog
import SwiftData
import SwiftUI
import UIKit

/// Drives one crew fix check: before photo → verifier → verdict → (resolved) blur, save, rewards, Fixed moment.
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
    @Published var celebration: Celebration?

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "FixCheck")
    private let verifierFactory: (DemoFixPhoto?) -> FixVerifying?

    /// - Parameter verifierFactory: returns the verifier for a pick (nil → no verifier available).
    init(verifierFactory: ((DemoFixPhoto?) -> FixVerifying?)? = nil) {
        self.verifierFactory = verifierFactory ?? FixCheckModel.defaultVerifier
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
        afterImage = after
        isDemoPhoto = demo != nil
        verdict = nil
        guard let before = Self.beforeImage(for: report), let beforeData = before.jpegData(compressionQuality: 0.7),
              let afterData = after.jpegData(compressionQuality: 0.7) else {
            phase = .failed(String(localized: "crew.error.noBefore", defaultValue: "The original photo is not available on this device."))
            return
        }
        guard let verifier = verifierFactory(demo) else {
            phase = .failed(String(localized: "crew.error.noKey", defaultValue: "Add an OpenAI key in Settings to check repairs."))
            return
        }

        phase = .checking
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

        do {
            // Public fix photo is always the redacted one; nothing is saved if blurring fails.
            var fixFileName: String?
            if result.resolved {
                fixFileName = await Self.saveBlurred(after, reportID: report.id)
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
        phase = .idle
        verdict = nil
        afterImage = nil
        isDemoPhoto = false
    }

    /// Blurs faces/plates and writes `fix_<id>.jpg` to Documents. Nil when blurring or writing fails.
    private static func saveBlurred(_ image: UIImage, reportID: UUID) async -> String? {
        let blurred = await FaceAndPlateBlur.blur(image)
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
