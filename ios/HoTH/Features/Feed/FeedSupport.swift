import CoreLocation
import HoTHCore
import SwiftUI
import UIKit

// MARK: - Report presentation helpers

extension Report {
    func title(arabic: Bool) -> String {
        let preferred = arabic ? titleAR : titleEN
        return preferred.isEmpty ? (arabic ? titleEN : titleAR) : preferred
    }

    func summary(arabic: Bool) -> String {
        let preferred = arabic ? summaryAR : summaryEN
        return preferred.isEmpty ? (arabic ? summaryEN : summaryAR) : preferred
    }

    func priorityReason(arabic: Bool) -> String {
        let preferred = arabic ? priorityReasonAR : priorityReasonEN
        return preferred.isEmpty ? (arabic ? priorityReasonEN : priorityReasonAR) : preferred
    }

    /// Every comment in order, blocked ones included (rendered as "Removed by community guidelines").
    var threadComments: [Comment] {
        comments.sorted { $0.createdAt < $1.createdAt }
    }

    /// Comments that passed moderation (or are still pending, shown optimistically to their author).
    var visibleComments: [Comment] {
        comments
            .filter { $0.moderationStatus != .blocked }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Distance in metres from the demo neighbourhood centre.
    var distanceFromHome: CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: FeedGeography.home)
    }
}

enum FeedGeography {
    /// Demo "current location": the seeded Khalifa City centre.
    static let home = CLLocation(latitude: 24.4200, longitude: 54.5750)
    static let nearMeRadius: CLLocationDistance = 1500

    /// - Parameter locale: pass the SwiftUI environment locale so the in-app language override applies.
    static func formattedDistance(_ metres: CLLocationDistance, locale: Locale = .autoupdatingCurrent) -> String {
        let measurement = Measurement(value: metres, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = metres < 1000 ? 0 : 1
        return formatter.string(from: measurement)
    }
}

// MARK: - Signal labels

/// Bilingual labels for priority signal ids stored on reports.
enum SignalLabel {
    private static let table: [String: (en: String, ar: String)] = [
        "accessibility": ("Accessibility", "إمكانية الوصول"),
        "child_equipment": ("Children's equipment", "معدات أطفال"),
        "electrical": ("Electrical hazard", "خطر كهربائي"),
        "fall": ("Fall risk", "خطر السقوط"),
        "park": ("In a park", "في حديقة"),
        "playground": ("Playground", "ملعب أطفال"),
        "location_playground": ("In a playground", "في ملعب أطفال"),
        "location_school": ("Near a school", "قرب مدرسة"),
        "location_park": ("In a park", "في حديقة"),
        "private_property": ("Private property", "ملكية خاصة"),
        "residential": ("Residential area", "منطقة سكنية"),
        "sanitation": ("Sanitation", "النظافة العامة"),
        "school_area": ("School area", "منطقة مدرسية"),
        "school_route": ("School route", "طريق المدرسة"),
        "sharp_edge": ("Sharp edge", "حافة حادة"),
        "sidewalk": ("Sidewalk", "رصيف"),
        "slip": ("Slip risk", "خطر الانزلاق"),
        "street": ("Street", "شارع"),
        "traffic": ("Traffic risk", "خطر مروري"),
        "trip": ("Trip hazard", "خطر التعثر"),
        "water": ("Water", "مياه"),
        "near_water": ("Water nearby", "يوجد ماء قريب"),
        "sparking": ("Sparking reported", "تم الإبلاغ عن شرارة"),
        "open_manhole": ("Open manhole", "فتحة صرف مكشوفة"),
        "not_an_issue": ("Not a neighbourhood issue", "ليست مشكلة في الحي"),
        // Ids emitted by HoTHCore.PriorityAgent (labels there are per-decision; these are the stored-id fallbacks).
        "child_equipment_hazard": ("Hazard on equipment children use", "خطر في لعبة يستخدمها الأطفال"),
        "children_using_now": ("Children using it now", "أطفال يستخدمونها الآن"),
        "child_present": ("A child is in the photo", "يظهر طفل في الصورة"),
        "confirmations": ("Confirmed by neighbours", "أكّده الجيران"),
        "long_duration": ("Ongoing for over a week", "مستمرة منذ أكثر من أسبوع"),
        "report_age": ("Open for days", "مفتوحة منذ أيام"),
    ]

    static func label(for id: String, arabic: Bool) -> String {
        if id.hasPrefix("confirmed_x"), let count = Int(id.dropFirst("confirmed_x".count)) {
            return arabic ? "أكده \(count) من الجيران" : "Confirmed by \(count)"
        }
        if let entry = table[id] { return arabic ? entry.ar : entry.en }
        return id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Photo

/// Report photo: bundled asset (`seed_<n>`), then a Documents file, else the category symbol
/// on a tinted gradient.
struct ReportPhotoView: View {
    let fileName: String?
    let category: IssueCategory
    let priority: PriorityLevel
    var symbolSize: CGFloat = 44

    var body: some View {
        if let image = Self.loadImage(fileName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [priority.tint.opacity(0.22), Color.hothSand],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: category.fallbackSymbol)
                    .font(.system(size: symbolSize, weight: .light))
                    .foregroundStyle(priority.tint.opacity(0.85))
            }
        }
    }

    static func loadImage(_ fileName: String?) -> UIImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let asset = UIImage(named: fileName) { return asset }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return UIImage(contentsOfFile: documents.appendingPathComponent(fileName).path)
    }
}

extension PriorityLevel {
    var tint: Color {
        switch self {
        case .critical: return .hothCritical
        case .high: return .hothHigh
        case .medium: return .hothMedium
        case .low: return .hothLow
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let status: ReportStatus

    private var label: LocalizedStringKey {
        switch status {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .fixed: return "Fixed"
        case .rejected: return "Not accepted"
        }
    }

    private var color: Color {
        switch status {
        case .open: return .hothInkSecondary
        case .inProgress: return .hothTeal
        case .fixed: return .hothSuccess
        case .rejected: return .hothInkSecondary
        }
    }

    private var symbol: String {
        switch status {
        case .open: return "circle.dotted"
        case .inProgress: return "wrench.and.screwdriver.fill"
        case .fixed: return "checkmark.seal.fill"
        case .rejected: return "xmark.circle"
        }
    }

    var body: some View {
        Label { Text(label) } icon: { Image(systemName: symbol) }
            .font(.hothCaption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Comment moderation hook

/// Moderation hook for new comments (P1-06: `ModelCommentModerator`, `LocalCommentModerator`).
protocol CommentModerator {
    func moderate(_ text: String, reportTitle: String) async -> ModerationStatus
}

/// Allows everything (previews / tests).
struct AllowAllCommentModerator: CommentModerator {
    func moderate(_ text: String, reportTitle: String) async -> ModerationStatus { .allowed }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// MARK: - Priority recompute

extension Report {
    /// Recomputes priority after a new confirmation (feed "I saw it too" and report-flow merges share this,
    /// so scores, reasons and signals always match). Uses the PriorityAgent when the original vision
    /// analysis is stored, else the agent's fixed confirmation bump. Never lowers the level.
    func recomputePriority(now: Date = .now) {
        if let data = analysisJSON,
           let vision = try? JSONDecoder().decode(VisionAnalysis.self, from: data) {
            // Keep the MapKit place found at capture (stored as its `location_*` chip id).
            let place = signals.lazy.compactMap { id -> LocationType? in
                guard id.hasPrefix("location_") else { return nil }
                return LocationType(rawValue: String(id.dropFirst("location_".count)))
            }.first
            let decision = PriorityAgent.decide(PriorityInput(
                vision: vision,
                nearbyPlace: place,
                confirmations: confirmations,
                reportAgeHours: now.timeIntervalSince(createdAt) / 3600
            ))
            // Never lower a level that neighbours have already pushed up.
            let newScore = max(decision.score, priorityScore)
            priorityScore = newScore
            priorityRaw = max(PriorityLevel(rawValue: decision.level.rawValue) ?? priority, priority).rawValue
            priorityReasonEN = decision.reasonEN
            priorityReasonAR = decision.reasonAR
            signals = decision.signals.map(\.id)
        } else {
            priorityScore = min(priorityScore + PriorityAgent.confirmationPoints, 100)
            let bumped = PriorityLevel(rawValue: PriorityAgent.level(forScore: priorityScore).rawValue) ?? priority
            priority = max(bumped, priority)
            let confirmationSignal = "confirmed_x\(confirmations)"
            signals = signals.filter { !$0.hasPrefix("confirmed_x") } + [confirmationSignal]
        }
    }
}
