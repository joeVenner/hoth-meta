import HoTHCore
import SwiftUI
import UIKit

/// Bundled demo photos for demo mode and the simulator (clearly labelled "Demo photo" in the UI).
///
/// Each sample carries its own coordinate inside the seeded Khalifa City area (at least 200 m from every
/// seeded report, except the flagged duplicate demo) and a canned
/// `VisionAnalysis` used only when there is no API key, or the vision call fails in demo mode, so the
/// golden path still completes offline. With a key the real analysis runs on the demo photo.
/// Missing image assets are replaced by a drawn placeholder.
struct DemoSample: Identifiable, Sendable {
    let id: String
    /// Asset names tried in order (`demo_*` first, then `seed_*`).
    let assetNames: [String]
    let titleEN: String
    let titleAR: String
    let symbol: String
    let coordinate: Coordinate
    let cannedAnalysis: VisionAnalysis
    /// Short "what this demonstrates" label shown in the picker grid.
    var demoLabelEN: String = ""
    var demoLabelAR: String = ""
    /// The one sample meant to show the duplicate merge (it sits ~30 m from seeded pothole r10).
    /// Every other demo sample never merges, whatever the judge or the distance says.
    var isDuplicateDemo = false

    /// The bundled asset, if any is present.
    var assetImage: UIImage? {
        assetNames.lazy.compactMap { UIImage(named: $0) }.first
    }

    /// The asset image, or a drawn placeholder so the flow never dead-ends on a missing asset.
    func loadImage() -> UIImage {
        assetImage ?? Self.placeholder(symbol: symbol, title: titleEN)
    }

    var gpsFix: GPSFix {
        GPSFix(latitude: coordinate.latitude, longitude: coordinate.longitude, accuracyMeters: 8)
    }

    func title(arabic: Bool) -> String { arabic ? titleAR : titleEN }
    func demoLabel(arabic: Bool) -> String { arabic ? demoLabelAR : demoLabelEN }

    private static func placeholder(symbol: String, title: String) -> UIImage {
        let size = CGSize(width: 1024, height: 768)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.93, green: 0.89, blue: 0.83, alpha: 1).cgColor,
                          UIColor(red: 0.80, green: 0.72, blue: 0.62, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                     end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: 260, weight: .light)
            if let icon = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(UIColor(red: 0.12, green: 0.43, blue: 0.42, alpha: 0.85), renderingMode: .alwaysOriginal) {
                let rect = CGRect(x: (size.width - icon.size.width) / 2, y: (size.height - icon.size.height) / 2 - 40,
                                  width: icon.size.width, height: icon.size.height)
                icon.draw(in: rect)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .semibold),
                .foregroundColor: UIColor(white: 0.15, alpha: 0.8),
            ]
            let label = "Demo photo · \(title)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: (size.width - labelSize.width) / 2, y: size.height - 110), withAttributes: attributes)
        }
    }
}

enum DemoSamples {
    /// Default location used when no fix exists in demo mode (seed area centre).
    static let areaCentre = Coordinate(latitude: 24.4200, longitude: 54.5750)

    static let all: [DemoSample] = [springRider, exposedWire, openManhole, pothole, waste, waterLeak,
                                    blockedPath, fitness, fakeScreen]

    /// The seeded report the duplicate demo merges into (r10: open pothole, bundled photo `seed_10`).
    static let duplicateDemoSeedPhoto = "seed_10"

    static func sample(id: String?) -> DemoSample? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Spring rider with a snapped seat: far from seeded playground reports, so it becomes a new ticket.
    static let springRider = DemoSample(
        id: "spring_rider",
        assetNames: ["demo_springrider", "demo_spring_rider", "seed_1"],
        titleEN: "Broken spring rider",
        titleAR: "لعبة نابض مكسورة",
        symbol: "figure.play",
        coordinate: Coordinate(latitude: 24.4262, longitude: 54.5668),
        cannedAnalysis: VisionAnalysis(
            category: .playgroundEquipment,
            titleEN: "Broken spring rider with exposed metal",
            titleAR: "لعبة نابض مكسورة وحديد بارز",
            descriptionEN: "The seat of a playground spring rider has snapped off, leaving sharp metal sticking out at child height.",
            descriptionAR: "انكسر مقعد لعبة النابض في الملعب وبقي حديد حاد بارز على مستوى الأطفال.",
            hazards: [
                Hazard(label: "Sharp exposed metal", kind: .sharpEdge, box: NormalizedBox(x: 0.38, y: 0.30, w: 0.24, h: 0.22)),
                Hazard(label: "Missing seat", kind: .fall, box: NormalizedBox(x: 0.30, y: 0.50, w: 0.36, h: 0.26)),
            ],
            childUseEquipment: true,
            childPresent: false,
            sceneType: .playground,
            severityProposal: .high,
            severityReasonEN: "Sharp metal on equipment young children use.",
            severityReasonAR: "حديد حاد في لعبة يستخدمها الأطفال الصغار.",
            suggestedQuestions: ["Are children using it right now?"],
            confidence: .high
        ),
        demoLabelEN: "Critical · child safety",
        demoLabelAR: "حرج · سلامة الأطفال"
    )

    /// The duplicate demo: placed ~30 m from seeded open pothole r10 and flagged, so it always merges there.
    static let pothole = DemoSample(
        id: "pothole",
        assetNames: ["demo_pothole", "seed_10", "seed_2"],
        titleEN: "Deep pothole",
        titleAR: "حفرة عميقة",
        symbol: "road.lanes",
        coordinate: Coordinate(latitude: 24.4185, longitude: 54.5801),
        cannedAnalysis: VisionAnalysis(
            category: .potholePavement,
            titleEN: "Deep pothole in the road",
            titleAR: "حفرة عميقة في الشارع",
            descriptionEN: "A deep pothole with broken asphalt edges in a residential street lane.",
            descriptionAR: "حفرة عميقة بحواف إسفلت مكسورة في مسار شارع سكني.",
            hazards: [
                Hazard(label: "Pothole", kind: .trip, box: NormalizedBox(x: 0.28, y: 0.52, w: 0.42, h: 0.28)),
            ],
            sceneType: .street,
            severityProposal: .medium,
            severityReasonEN: "A trip and traffic hazard in a lane cars use.",
            severityReasonAR: "خطر تعثر ومرور في مسار تستخدمه السيارات.",
            suggestedQuestions: ["Which lane is it in?"],
            confidence: .high
        ),
        demoLabelEN: "Duplicate demo",
        demoLabelAR: "تجربة البلاغ المكرر",
        isDuplicateDemo: true
    )

    /// Open electrical cabinet on a school route; offline it triggers the safety sheet before the interview.
    static let exposedWire = DemoSample(
        id: "exposed_wire",
        assetNames: ["demo_electrical", "demo_exposed_wire", "seed_3", "seed_12"],
        titleEN: "Open electrical cabinet",
        titleAR: "خزانة كهرباء مفتوحة",
        symbol: "bolt.trianglebadge.exclamationmark.fill",
        coordinate: Coordinate(latitude: 24.4285, longitude: 54.5700),
        cannedAnalysis: VisionAnalysis(
            category: .electricalHazard,
            titleEN: "Open electrical cabinet with exposed wires",
            titleAR: "خزانة كهرباء مفتوحة وأسلاك مكشوفة",
            descriptionEN: "A street-side electrical cabinet on the footpath to a school is hanging open, bare wires within a child's reach.",
            descriptionAR: "خزانة كهرباء على ممر المشاة المؤدي إلى مدرسة مفتوحة، وأسلاكها العارية في متناول الأطفال.",
            hazards: [
                Hazard(label: "Bare wires", kind: .electrical, box: NormalizedBox(x: 0.22, y: 0.25, w: 0.30, h: 0.30)),
            ],
            childPresent: false,
            // School route: a child zone, so the offline read is CRITICAL and shows the safety sheet.
            sceneType: .schoolArea,
            severityProposal: .high,
            severityReasonEN: "Bare wires within reach on a public pavement.",
            severityReasonAR: "أسلاك عارية في متناول اليد على رصيف عام.",
            suggestedQuestions: ["Is it sparking?"],
            confidence: .high
        ),
        demoLabelEN: "Critical · safety sheet",
        demoLabelAR: "حرج · تنبيه السلامة"
    )

    /// Uncovered manhole on a footpath: critical, triggers the safety sheet before the interview.
    static let openManhole = DemoSample(
        id: "open_manhole",
        assetNames: ["demo_open_manhole", "seed_5"],
        titleEN: "Open manhole",
        titleAR: "فتحة صرف مكشوفة",
        symbol: "exclamationmark.triangle.fill",
        coordinate: Coordinate(latitude: 24.4130, longitude: 54.5700),
        cannedAnalysis: VisionAnalysis(
            category: .openManhole,
            titleEN: "Open manhole without a cover",
            titleAR: "فتحة صرف بدون غطاء",
            descriptionEN: "A manhole on the street edge has no cover, leaving a deep open shaft where people walk.",
            descriptionAR: "فتحة صرف على طرف الشارع بدون غطاء، وتركت فتحة عميقة في ممر المشاة.",
            hazards: [
                Hazard(label: "Open shaft", kind: .fall, box: NormalizedBox(x: 0.32, y: 0.45, w: 0.36, h: 0.30)),
            ],
            sceneType: .street,
            severityProposal: .critical,
            severityReasonEN: "Someone could fall into the open shaft.",
            severityReasonAR: "ممكن حد يطيح في الفتحة المكشوفة.",
            suggestedQuestions: ["Is anything marking it off?"],
            confidence: .high
        ),
        demoLabelEN: "Critical · fall risk",
        demoLabelAR: "حرج · خطر السقوط"
    )

    /// Overflowing litter bin with rubbish dumped around it.
    static let waste = DemoSample(
        id: "waste",
        assetNames: ["demo_waste", "seed_4"],
        titleEN: "Overflowing bin",
        titleAR: "حاوية نفايات ممتلئة",
        symbol: "trash.fill",
        coordinate: Coordinate(latitude: 24.4125, longitude: 54.5800),
        cannedAnalysis: VisionAnalysis(
            category: .wasteOverflowDumping,
            titleEN: "Overflowing bin with rubbish dumped around it",
            titleAR: "حاوية ممتلئة ونفايات مرمية حولها",
            descriptionEN: "A public litter bin is full and bags of rubbish are piled on the pavement next to it.",
            descriptionAR: "حاوية نفايات عامة ممتلئة وأكياس القمامة مكدسة على الرصيف بجانبها.",
            hazards: [
                Hazard(label: "Piled rubbish", kind: .sanitation, box: NormalizedBox(x: 0.25, y: 0.40, w: 0.50, h: 0.45)),
            ],
            sceneType: .sidewalk,
            severityProposal: .medium,
            severityReasonEN: "Attracts pests and blocks part of the pavement.",
            severityReasonAR: "تجذب الحشرات وتسد جزء من الرصيف.",
            suggestedQuestions: ["Does it smell or attract pests?"],
            confidence: .high
        ),
        demoLabelEN: "Routine · sanitation",
        demoLabelAR: "عادي · نظافة"
    )

    /// Water main break flooding the street.
    static let waterLeak = DemoSample(
        id: "water_leak",
        assetNames: ["demo_water_leak", "seed_7"],
        titleEN: "Water main leak",
        titleAR: "تسرب ماء من الخط الرئيسي",
        symbol: "drop.fill",
        coordinate: Coordinate(latitude: 24.4290, longitude: 54.5800),
        cannedAnalysis: VisionAnalysis(
            category: .waterLeak,
            titleEN: "Water gushing from a broken main",
            titleAR: "ماء يتدفق من خط رئيسي مكسور",
            descriptionEN: "Water is bubbling up through the road surface and running along the street.",
            descriptionAR: "الماء يطلع من سطح الشارع ويجري على طول الطريق.",
            hazards: [
                Hazard(label: "Running water", kind: .trip, box: NormalizedBox(x: 0.20, y: 0.50, w: 0.60, h: 0.35)),
            ],
            sceneType: .street,
            severityProposal: .high,
            severityReasonEN: "Wastes water and can undermine the road.",
            severityReasonAR: "يهدر الماء وممكن يضعف الشارع.",
            suggestedQuestions: ["Is the water still flowing?"],
            confidence: .high
        ),
        demoLabelEN: "High · utilities",
        demoLabelAR: "عالي · خدمات المياه"
    )

    /// Car parked across the footpath, blocking wheelchairs and prams.
    static let blockedPath = DemoSample(
        id: "blocked_path",
        assetNames: ["demo_blocked_path", "seed_6"],
        titleEN: "Blocked footpath",
        titleAR: "ممر مشاة مسدود",
        symbol: "figure.roll",
        coordinate: Coordinate(latitude: 24.4275, longitude: 54.5860),
        cannedAnalysis: VisionAnalysis(
            category: .blockedAccessibility,
            titleEN: "Car blocking the footpath",
            titleAR: "سيارة تسد ممر المشاة",
            descriptionEN: "A car is parked on the footpath, leaving no room for a wheelchair or pram to pass.",
            descriptionAR: "سيارة واقفة على ممر المشاة وما تخلي مجال للكرسي المتحرك أو عربة الأطفال.",
            hazards: [
                Hazard(label: "Blocked path", kind: .traffic, box: NormalizedBox(x: 0.25, y: 0.40, w: 0.30, h: 0.30)),
            ],
            sceneType: .sidewalk,
            severityProposal: .medium,
            severityReasonEN: "Wheelchair users have to go into the road.",
            severityReasonAR: "مستخدمو الكراسي المتحركة يضطرون ينزلون للشارع.",
            suggestedQuestions: ["Is there another way around?"],
            confidence: .high
        ),
        demoLabelEN: "Accessibility",
        demoLabelAR: "سهولة الوصول"
    )

    /// Outdoor fitness walker with a snapped footplate.
    static let fitness = DemoSample(
        id: "fitness",
        assetNames: ["demo_fitness", "seed_8"],
        titleEN: "Broken fitness machine",
        titleAR: "جهاز رياضي مكسور",
        symbol: "figure.walk",
        coordinate: Coordinate(latitude: 24.4180, longitude: 54.5880),
        cannedAnalysis: VisionAnalysis(
            category: .fitnessEquipment,
            titleEN: "Outdoor walker with a broken footplate",
            titleAR: "جهاز مشي خارجي بدواسة مكسورة",
            descriptionEN: "One footplate of an outdoor fitness walker has snapped off and lies on the ground.",
            descriptionAR: "انكسرت إحدى دواسات جهاز المشي الخارجي وطاحت على الأرض.",
            hazards: [
                Hazard(label: "Broken footplate", kind: .sharpEdge, box: NormalizedBox(x: 0.55, y: 0.70, w: 0.30, h: 0.20)),
            ],
            sceneType: .park,
            severityProposal: .medium,
            severityReasonEN: "Someone could slip using the broken side.",
            severityReasonAR: "ممكن حد يتزحلق وهو يستخدم الجهة المكسورة.",
            suggestedQuestions: ["Is anyone still using it?"],
            confidence: .high
        ),
        demoLabelEN: "Park equipment",
        demoLabelAR: "معدات الحديقة"
    )

    /// A pothole shown on a laptop screen: the plausibility check asks for a live photo instead.
    static let fakeScreen = DemoSample(
        id: "fake_screen",
        assetNames: ["demo_fake_screen"],
        titleEN: "Photo of a screen",
        titleAR: "صورة لشاشة",
        symbol: "display",
        coordinate: Coordinate(latitude: 24.4150, longitude: 54.5620),
        cannedAnalysis: VisionAnalysis(
            category: .potholePavement,
            titleEN: "Pothole shown on a laptop screen",
            titleAR: "حفرة معروضة على شاشة لابتوب",
            descriptionEN: "The photo shows a laptop screen displaying a picture of a pothole, not the street itself.",
            descriptionAR: "الصورة لشاشة لابتوب تعرض صورة حفرة، وليست للشارع نفسه.",
            sceneType: .other,
            severityProposal: .low,
            severityReasonEN: "Not a live photo of the spot.",
            severityReasonAR: "ليست صورة مباشرة من المكان.",
            plausibility: PlausibilitySignals(showsReportedIssue: true, looksLikeScreenOrPrint: true,
                                              looksLikeStockOrWatermarked: false,
                                              notes: "Photo of a laptop screen."),
            confidence: .high
        ),
        demoLabelEN: "Fake photo · rejected",
        demoLabelAR: "صورة مزيفة · مرفوضة"
    )
}

