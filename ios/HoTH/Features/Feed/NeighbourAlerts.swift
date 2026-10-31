import CoreLocation
import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - Policy

/// Pure rules for neighbour hazard alerts (P1-01): only high/critical, only nearby, and rate-limited
/// so a busy street never spams the neighbourhood.
enum NeighbourAlertPolicy {
    static let radius: CLLocationDistance = 1000
    static let minimumInterval: TimeInterval = 10 * 60

    static func shouldAlert(priority: PriorityLevel, distance: CLLocationDistance,
                            lastAlertAt: Date?, now: Date = .now) -> Bool {
        guard priority == .high || priority == .critical else { return false }
        guard distance <= radius else { return false }
        guard let lastAlertAt else { return true }
        return now.timeIntervalSince(lastAlertAt) >= minimumInterval
    }

    /// Notification / banner line: "⚠️ Hazard near you: <title> · <place>".
    static func message(title: String, place: String, arabic: Bool) -> String {
        arabic ? "⚠️ خطر بالقرب منك: \(title) · \(place)" : "⚠️ Hazard near you: \(title) · \(place)"
    }
}

// MARK: - Banner model

struct NeighbourAlertBanner: Equatable, Identifiable {
    let id = UUID()
    let reportID: UUID
    let message: String
    let isDemo: Bool
}

// MARK: - Alert centre

/// Raises neighbour alerts (in-app banner + local notification) and, in demo mode, simulates a
/// neighbour's critical report arriving.
@MainActor
final class NeighbourAlertCenter: ObservableObject {
    static let shared = NeighbourAlertCenter()

    enum StorageKey {
        static let lastAlertAt = "hoth.alerts.lastAlertAt"
        static let demoSimulated = "hoth.alerts.demoNeighbourSimulated"
    }

    /// Fixed id so repeated demo triggers update one row instead of stacking duplicates.
    static let demoReportID = UUID(uuidString: "6E1B0A11-7D3C-4C55-9E21-0000000000A1")!
    static let launchDelay: Duration = .seconds(20)
    static let bannerDuration: Duration = .seconds(6)

    @Published private(set) var banner: NeighbourAlertBanner?

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "NeighbourAlerts")
    private let defaults: UserDefaults
    private var dismissTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastAlertAt: Date? {
        let stamp = defaults.double(forKey: StorageKey.lastAlertAt)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Hook for a freshly posted report. Skipped in UI-test runs so the golden path never
    /// rate-limits (or covers) later screenshots.
    func reportPosted(_ report: Report) {
        guard report.isPosted, !AppServices.isUITestRun else { return }
        alert(for: report, isDemo: false, bypassRateLimit: false)
    }

    /// Demo: one simulated neighbour report per install, `launchDelay` after the feed appears.
    func runLaunchSimulationIfNeeded(context: ModelContext) async {
        guard AppServices.shared.demoMode, !AppServices.isUITestRun,
              !defaults.bool(forKey: StorageKey.demoSimulated) else { return }
        do {
            try await Task.sleep(for: Self.launchDelay)
            // Never fire underneath the first-run onboarding cover.
            while !defaults.bool(forKey: OnboardingView.storageKey) {
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            return  // Feed went away; try again next time it appears.
        }
        guard AppServices.shared.demoMode, !defaults.bool(forKey: StorageKey.demoSimulated) else { return }
        defaults.set(true, forKey: StorageKey.demoSimulated)
        simulateNeighbourReport(context: context, bypassRateLimit: false)
    }

    /// Inserts (or refreshes) the seeded neighbour report and alerts. The wordmark long-press passes
    /// `bypassRateLimit: true` so presenters can replay it on stage.
    func simulateNeighbourReport(context: ModelContext, bypassRateLimit: Bool) {
        let report = upsertDemoReport(context: context)
        do {
            try context.save()
        } catch {
            Self.logger.error("Saving demo neighbour report failed: \(String(describing: error))")
        }
        alert(for: report, isDemo: true, bypassRateLimit: bypassRateLimit)
    }

    func dismissBanner() {
        dismissTask?.cancel()
        withAnimation(HoTHMotion.spring) { banner = nil }
    }

    // MARK: Private

    private func alert(for report: Report, isDemo: Bool, bypassRateLimit: Bool) {
        let now = Date.now
        let allowed = NeighbourAlertPolicy.shouldAlert(
            priority: report.priority,
            distance: report.distanceFromHome,
            lastAlertAt: bypassRateLimit ? nil : lastAlertAt,
            now: now
        )
        guard allowed else { return }
        defaults.set(now.timeIntervalSince1970, forKey: StorageKey.lastAlertAt)

        let arabic = AppServices.shared.isArabic
        let message = NeighbourAlertPolicy.message(title: report.title(arabic: arabic), place: report.placeName, arabic: arabic)
        withAnimation(HoTHMotion.spring) {
            banner = NeighbourAlertBanner(reportID: report.id, message: message, isDemo: isDemo)
        }
        FixedMomentNotifier.shared.schedule(title: arabic ? "تنبيه الجيران" : "Neighbour alert", body: message)

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.bannerDuration)
            } catch {
                return
            }
            self?.dismissBanner()
        }
    }

    private func upsertDemoReport(context: ModelContext) -> Report {
        let id = Self.demoReportID
        if let existing = try? context.fetch(FetchDescriptor<Report>(predicate: #Predicate { $0.id == id })).first {
            existing.createdAt = .now
            return existing
        }
        let neighbour = try? context.fetch(
            FetchDescriptor<Neighbour>(predicate: #Predicate { !$0.isCurrentUser })
        ).first
        let report = Report(
            id: id,
            category: .electricalHazard,
            titleEN: "Open power cabinet with exposed wires",
            titleAR: "خزانة كهرباء مفتوحة وأسلاك مكشوفة",
            summaryEN: "A street-side power cabinet is hanging open with bare wires at child height, next to the footpath to the school.",
            summaryAR: "خزانة كهرباء على جانب الشارع مفتوحة وأسلاكها عارية بارتفاع الأطفال بجانب ممر المشاة المؤدي إلى المدرسة.",
            // ~400 m from the demo home location.
            latitude: 24.4234,
            longitude: 54.5762,
            placeName: "Al Sidr Street",
            photoFileName: "demo_exposed_wire",
            priority: .critical,
            priorityScore: 98,
            priorityReasonEN: "Exposed live wires at child height on a school route: electrocution risk.",
            priorityReasonAR: "أسلاك مكشوفة بارتفاع الأطفال على طريق المدرسة: خطر صعق كهربائي.",
            signals: ["electrical", "school_route", "child_equipment_hazard"],
            isPosted: true,
            isDemoSeed: true,
            reporter: neighbour
        )
        context.insert(report)
        return report
    }
}

// MARK: - Banner view

struct NeighbourAlertBannerView: View {
    let banner: NeighbourAlertBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HoTHSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: HoTHSpacing.xs) {
                    Text("Neighbour alert")
                        .font(.hothCaption.weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.9))
                    if banner.isDemo {
                        Text("Demo")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.hothCritical)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white))
                    }
                }
                Text(verbatim: banner.message)
                    .font(.hothBody.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss alert"))
        }
        .padding(HoTHSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous).fill(Color.hothCritical)
        )
        .shadow(color: Color.hothCritical.opacity(0.35), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("neighbourAlertBanner")
    }
}
