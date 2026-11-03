import CoreGraphics
import Foundation
import HoTHCore
import SwiftData

// MARK: - Verdict

/// App-local fix-check verdict, decoupled from `HoTHCore.FixVerification` (which has no public init)
/// so the workflow and its tests can build verdicts directly.
struct FixVerdict: Equatable, Sendable {
    struct Region: Equatable, Sendable {
        let label: String
        /// Arabic name from the verifier (`label_ar`); nil for SAM regions and older responses.
        let labelAR: String?
        /// Normalised 0...1 rect on the AFTER image (top-left origin).
        let box: CGRect

        init(label: String, labelAR: String? = nil, box: CGRect) {
            self.label = label
            self.labelAR = labelAR
            self.box = box
        }

        /// The name to show: Arabic when asked for and present, else English.
        func label(arabic: Bool) -> String {
            guard arabic, let labelAR else { return label }
            let trimmed = labelAR.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? label : trimmed
        }
    }

    let resolved: Bool
    let reasonEN: String
    let reasonAR: String
    let remaining: [Region]
    /// True when produced offline from a bundled demo photo (labelled in the UI).
    let isCanned: Bool

    func reason(arabic: Bool) -> String {
        let preferred = arabic ? reasonAR : reasonEN
        return preferred.isEmpty ? (arabic ? reasonEN : reasonAR) : preferred
    }
}

// MARK: - Verifier abstraction

/// Compares before/after photos. Stubbed in tests; live calls go through `LiveFixVerifier`.
protocol FixVerifying: Sendable {
    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict
}

/// Wraps `HoTHCore.FixVerifier` (one Responses API call per `verify`).
struct LiveFixVerifier: FixVerifying {
    let verifier: FixVerifier

    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict {
        let result = try await verifier.verify(
            before: before,
            after: after,
            reportTitle: reportTitle,
            category: ReportCategory(rawValue: categoryRaw) ?? .other,
            beforeCapturedAt: beforeCapturedAt,
            afterCapturedAt: .now
        )
        return FixVerdict(
            resolved: result.resolved,
            reasonEN: result.reasonEN,
            reasonAR: result.reasonAR,
            remaining: result.remainingIssues.map {
                FixVerdict.Region(label: $0.label, labelAR: $0.labelAR,
                                  box: CGRect(x: $0.box.x, y: $0.box.y, width: $0.box.w, height: $0.box.h))
            },
            isCanned: false
        )
    }
}

/// Bundled demo repair photos and their offline verdicts (used when no API key is configured).
enum DemoFixPhoto: String, CaseIterable, Identifiable, Sendable {
    case bad = "demo_fix_after_bad"
    case good = "demo_fix_after_good_pothole"

    var id: String { rawValue }
    static let beforeAssetName = "demo_fix_before"

    var cannedVerdict: FixVerdict {
        switch self {
        case .bad:
            return FixVerdict(
                resolved: false,
                reasonEN: "Only half of the pothole was filled. Loose gravel is still exposed on the left side.",
                reasonAR: "تم ردم نصف الحفرة فقط. لا يزال الحصى المفكك ظاهراً في الجهة اليسرى.",
                remaining: [Region(label: "Unfilled gravel", labelAR: "حصى غير مردوم", box: CGRect(x: 0.25, y: 0.55, width: 0.22, height: 0.20))],
                isCanned: true
            )
        case .good:
            return FixVerdict(
                resolved: true,
                reasonEN: "The pothole is fully patched with fresh asphalt, level with the road.",
                reasonAR: "تم ترقيع الحفرة بالكامل بأسفلت جديد ومستوٍ مع الطريق.",
                remaining: [],
                isCanned: true
            )
        }
    }

    private typealias Region = FixVerdict.Region
}

// MARK: - Workflow

/// Errors raised when a crew action is not allowed in the report's current state.
enum CrewWorkflowError: Error, Equatable, CustomStringConvertible {
    case notActionable(ReportStatus)

    var description: String {
        switch self {
        case .notActionable(let status): return "Report is \(status.rawValue); crew actions need open or in progress"
        }
    }
}

/// Result of applying a fix verdict to a report.
struct FixOutcome: Equatable {
    let verdictResolved: Bool
    let newStatus: ReportStatus
    /// Points granted to the reporter by this call (0 when already awarded or not resolved).
    let reporterPointsAwarded: Int
    /// Points the current user received by this call (as reporter or confirmer).
    let currentUserPointsAwarded: Int
    /// True when the current user reported or confirmed this report (drives the Fixed moment).
    let isCurrentUserInvolved: Bool
    let currentUserWasReporter: Bool
    /// Points before/after for the current user, for level-up detection.
    let currentUserPointsBefore: Int
    let currentUserPointsAfter: Int

    var didLevelUp: Bool {
        Rewards.level(forPoints: currentUserPointsAfter) != Rewards.level(forPoints: currentUserPointsBefore)
    }
}

/// Status transitions and fix rewards. Pure model mutation; the caller saves the context.
@MainActor
enum CrewWorkflow {
    /// Statuses the crew can still act on.
    nonisolated static func isActionable(_ status: ReportStatus) -> Bool { status == .open || status == .inProgress }

    /// open → inProgress. No-op when already in progress.
    static func startWork(on report: Report) throws {
        guard isActionable(report.status) else { throw CrewWorkflowError.notActionable(report.status) }
        report.status = .inProgress
    }

    /// Applies a verdict. Not resolved → status unchanged. Resolved → fixed, `fixedAt`, fix photo,
    /// +50 to the reporter and +10 to each confirmer, each at most once per report.
    @discardableResult
    static func apply(
        _ verdict: FixVerdict,
        to report: Report,
        fixPhotoFileName: String?,
        context: ModelContext,
        now: Date = .now
    ) throws -> FixOutcome {
        guard isActionable(report.status) else { throw CrewWorkflowError.notActionable(report.status) }
        let currentUser = try fetchCurrentUser(context: context)
        let pointsBefore = currentUser?.points ?? 0
        let isReporter = currentUser != nil && report.reporter?.id == currentUser?.id
        let isConfirmer = currentUser.map { report.hasVote(from: $0) } ?? false

        guard verdict.resolved else {
            return FixOutcome(verdictResolved: false, newStatus: report.status, reporterPointsAwarded: 0,
                              currentUserPointsAwarded: 0, isCurrentUserInvolved: isReporter || isConfirmer,
                              currentUserWasReporter: isReporter,
                              currentUserPointsBefore: pointsBefore, currentUserPointsAfter: pointsBefore)
        }

        report.status = .fixed
        report.fixedAt = now
        if let fixPhotoFileName { report.fixPhotoFileName = fixPhotoFileName }

        var reporterAward = 0
        if let reporter = report.reporter,
           try award(Rewards.verifiedFixPoints, to: reporter, for: report, context: context, now: now) {
            reporterAward = Rewards.verifiedFixPoints
            reporter.trust = min(max(reporter.trust + Rewards.trustDelta(for: .verifiedFix), 0), 100)
        }
        for voter in report.votes.compactMap(\.voter) where voter.id != report.reporter?.id {
            try award(Rewards.confirmationPoints, to: voter, for: report, context: context, now: now)
        }

        let pointsAfter = currentUser?.points ?? 0
        return FixOutcome(verdictResolved: true, newStatus: .fixed, reporterPointsAwarded: reporterAward,
                          currentUserPointsAwarded: pointsAfter - pointsBefore,
                          isCurrentUserInvolved: isReporter || isConfirmer, currentUserWasReporter: isReporter,
                          currentUserPointsBefore: pointsBefore, currentUserPointsAfter: pointsAfter)
    }

    /// Grants `delta` for a verified fix unless this user already has a fix award for this report.
    /// - Returns: true when points were granted.
    @discardableResult
    static func award(_ delta: Int, to neighbour: Neighbour, for report: Report,
                      context: ModelContext, now: Date = .now) throws -> Bool {
        let reportID = report.id
        let fixedRaw = PointsReason.reportFixed.rawValue
        let existing = try context.fetch(FetchDescriptor<PointsEvent>(
            predicate: #Predicate { $0.reportID == reportID && $0.reasonRaw == fixedRaw }
        ))
        guard !existing.contains(where: { $0.user?.id == neighbour.id }) else { return false }
        let event = PointsEvent(user: neighbour, delta: delta, reason: .reportFixed, createdAt: now, reportID: reportID)
        context.insert(event)
        neighbour.points += delta
        return true
    }

    static func fetchCurrentUser(context: ModelContext) throws -> Neighbour? {
        var descriptor = FetchDescriptor<Neighbour>(predicate: #Predicate { $0.isCurrentUser })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// MARK: - Queue

/// Ranking and filtering for the crew queue (pure).
enum CrewQueue {
    /// Open and in-progress reports: priority level → score → oldest first.
    static func ranked(_ reports: [Report], teamNameEN: String? = nil) -> [Report] {
        reports
            .filter { CrewWorkflow.isActionable($0.status) }
            .filter { teamNameEN == nil || team(for: $0).nameEN == teamNameEN }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                if lhs.priorityScore != rhs.priorityScore { return lhs.priorityScore > rhs.priorityScore }
                return lhs.createdAt < rhs.createdAt
            }
    }

    static func team(for report: Report) -> ReportRouting.Team {
        ReportRouting.team(for: ReportCategory(rawValue: report.categoryRaw) ?? .other)
    }

    static let allTeams: [ReportRouting.Team] = [
        ReportRouting.parks, ReportRouting.roads, ReportRouting.electrical, ReportRouting.waste, ReportRouting.safety,
    ]
}
