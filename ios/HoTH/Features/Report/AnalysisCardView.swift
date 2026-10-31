import HoTHCore
import SwiftUI

/// The AI's read of the photo: highlighted hazards, category, priority and why (P0-13).
struct AnalysisCardView: View {
    let image: UIImage
    let analysis: VisionAnalysis
    let priority: PriorityDecision
    let plausibility: PlausibilityResult?
    let isArabic: Bool
    let isDemoAnalysis: Bool
    let source: CaptureSource
    let onContinue: () -> Void
    let onRetake: () -> Void

    @State private var displayedLevel: Severity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                HazardPhotoView(image: image, hazards: analysis.hazards)
                    .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)

                if !analysis.hazards.isEmpty {
                    HazardLegend(hazards: analysis.hazards)
                }

                trustChips

                HoTHCard {
                    VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                        HStack(spacing: HoTHSpacing.s) {
                            CategoryChip(categoryRaw: analysis.category.rawValue)
                            Spacer()
                            PriorityBadge(levelRaw: (displayedLevel ?? analysis.severityProposal).rawValue)
                                .id(displayedLevel)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(isArabic ? analysis.titleAR : analysis.titleEN)
                            .font(.hothTitle)
                            .foregroundStyle(Color.hothInk)
                        Text(isArabic ? analysis.descriptionAR : analysis.descriptionEN)
                            .font(.hothBody)
                            .foregroundStyle(Color.hothInkSecondary)
                        if isDemoAnalysis {
                            Label("Demo analysis (offline)", systemImage: "wifi.slash")
                                .font(.hothCaption)
                                .foregroundStyle(Color.hothTeal)
                        }
                    }
                }

                PriorityReasonCard(priority: priority, isArabic: isArabic)

                VStack(spacing: HoTHSpacing.s) {
                    Button(action: onContinue) {
                        Label("Continue", systemImage: "arrow.forward")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("analysisContinueButton")
                    Button("Retake photo", action: onRetake)
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, HoTHSpacing.s)
            }
            .padding(HoTHSpacing.m)
            .padding(.bottom, HoTHSpacing.l)
        }
        .background(Color.hothBackground.ignoresSafeArea())
        .task {
            // Animate from the model's proposal up to the final (floored) level.
            displayedLevel = analysis.severityProposal
            guard priority.level != analysis.severityProposal else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { displayedLevel = priority.level }
            if priority.level == .critical {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private var trustChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoTHSpacing.s) {
                trustChip(symbol: source == .liveCamera ? "camera.fill" : "photo.stack",
                          text: source == .liveCamera ? "Live camera" : "Demo photo")
                // Capture-time claims only hold for live shots; demo photos carry neither.
                if source == .liveCamera {
                    trustChip(symbol: "clock.fill", text: "Fresh capture")
                    trustChip(symbol: "location.fill", text: "Location stamped")
                }
                if plausibility?.status == .accepted {
                    trustChip(symbol: "checkmark.seal.fill", text: "Checks passed")
                }
            }
        }
    }

    private func trustChip(symbol: String, text: LocalizedStringKey) -> some View {
        Label(text, systemImage: symbol)
            .font(.hothCaption)
            .foregroundStyle(Color.hothTeal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.hothTeal.opacity(0.1)))
    }
}

// MARK: - Priority reason

/// "Why this priority": the AI reason plus the deterministic signal chips.
struct PriorityReasonCard: View {
    let priority: PriorityDecision
    let isArabic: Bool

    var body: some View {
        HoTHCard {
            VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                SectionHeader(title: "Why this priority")
                if let floor = priority.floorApplied {
                    Text(floor)
                        .font(.hothHeadline)
                        .foregroundStyle(priority.level == .critical ? Color.hothCritical : Color.hothHigh)
                }
                Text(isArabic ? priority.reasonAR : priority.reasonEN)
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInk)
                if !priority.signals.isEmpty {
                    ReportSignalChips(items: priority.signals.map { isArabic ? $0.labelAR : $0.labelEN })
                }
            }
        }
    }
}

/// Wrapping chips without iOS 16 Layout boilerplate in every caller.
struct ReportSignalChips: View {
    let items: [String]

    var body: some View {
        ReportWrapLayout(spacing: HoTHSpacing.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInk.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.hothSand))
            }
        }
    }
}

/// Minimal flow layout: places subviews left-to-right (leading-to-trailing), wrapping lines.
struct ReportWrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Hazard overlay

/// Where each hazard's box and tag go on the photo. Pure geometry so it can be unit tested.
///
/// Large boxes get a single-line capsule ("1  Jagged metal") just above the box (below it when the box
/// touches the top edge), nudged up/down to avoid earlier capsules and capped at 60% of the photo width.
/// Small boxes, or capsules that cannot be placed without overlapping, fall back to a number badge
/// on the box corner; the full list is always shown in `HazardLegend` under the photo.
struct HazardLabelLayout {
    struct Item: Equatable {
        let number: Int
        let box: CGRect
        /// Capsule frame when a full label fits; nil → number badge only.
        let labelFrame: CGRect?
        /// Centre of the number badge (used when `labelFrame` is nil).
        let badgeCenter: CGPoint
    }

    static let labelHeight: CGFloat = 24
    static let badgeSize: CGFloat = 22
    static let maxLabelWidthFraction: CGFloat = 0.6
    static let minBoxForLabel = CGSize(width: 56, height: 36)
    private static let gap: CGFloat = 4
    private static let inset: CGFloat = 6

    /// - Parameters:
    ///   - boxes: hazard boxes in view points.
    ///   - labelWidths: natural single-line capsule widths (badge + text + padding), same order.
    ///   - size: the photo's rendered size.
    static func layout(boxes: [CGRect], labelWidths: [CGFloat], in size: CGSize) -> [Item] {
        let badges = boxes.map { box in
            CGPoint(x: min(max(box.minX + badgeSize / 2 + 4, badgeSize / 2 + 2), size.width - badgeSize / 2 - 2),
                    y: min(max(box.minY + badgeSize / 2 + 4, badgeSize / 2 + 2), size.height - badgeSize / 2 - 2))
        }
        let isSmall = boxes.map { $0.width < minBoxForLabel.width || $0.height < minBoxForLabel.height }
        // Number badges of small boxes are fixed; reserve them so capsules never cover a number.
        var occupied: [CGRect] = zip(badges, isSmall).compactMap { center, small in
            small ? CGRect(x: center.x - badgeSize / 2 - 3, y: center.y - badgeSize / 2 - 3,
                           width: badgeSize + 6, height: badgeSize + 6) : nil
        }
        var items: [Item] = []
        for (index, box) in boxes.enumerated() {
            let badge = badges[index]
            var frame: CGRect?
            if !isSmall[index] {
                let natural = index < labelWidths.count ? labelWidths[index] : 0
                let width = min(natural, size.width * maxLabelWidthFraction)
                frame = place(width: width, near: box, in: size, avoiding: occupied)
            }
            if let frame {
                occupied.append(frame.insetBy(dx: -2, dy: -2))
            } else if !isSmall[index] {
                // A large box that lost its capsule shows its badge instead; keep later capsules off it.
                occupied.append(CGRect(x: badge.x - badgeSize / 2 - 3, y: badge.y - badgeSize / 2 - 3,
                                       width: badgeSize + 6, height: badgeSize + 6))
            }
            items.append(Item(number: index + 1, box: box, labelFrame: frame, badgeCenter: badge))
        }
        return items
    }

    private static func place(width: CGFloat, near box: CGRect, in size: CGSize, avoiding occupied: [CGRect]) -> CGRect? {
        guard width > 0, size.width > inset * 2 else { return nil }
        let x = min(max(box.minX, inset), max(size.width - width - inset, inset))
        let above = box.minY - gap - labelHeight
        let below = box.maxY + gap
        let step = labelHeight + 3
        // Prefer above; stack further away from the box on collisions, then try below.
        var candidates: [CGFloat] = []
        for k in 0..<3 { candidates.append(above - CGFloat(k) * step) }
        for k in 0..<3 { candidates.append(below + CGFloat(k) * step) }
        for y in candidates {
            guard y >= inset, y + labelHeight <= size.height - inset else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: labelHeight)
            if !occupied.contains(where: { $0.intersects(rect) }) { return rect }
        }
        return nil
    }
}

/// Hazard tint: red for sharp/electrical/drowning, amber otherwise.
func hazardTint(for kind: HazardKind) -> Color {
    switch kind {
    case .sharpEdge, .electrical, .drowning: return .hothCritical
    default: return .hothHigh
    }
}

/// Photo with rounded, numbered hazard outlines that draw in, plus single-line tags where they fit.
struct HazardPhotoView: View {
    let image: UIImage
    let hazards: [Hazard]

    @State private var progress: CGFloat = 0

    private static let labelFont = UIFont.systemFont(ofSize: 12, weight: .bold)

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            // The overlay matches the aspect-fit image frame, so normalized boxes map 1:1.
            .overlay {
                GeometryReader { proxy in
                    let items = layoutItems(in: proxy.size)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            outline(item, tint: hazardTint(for: hazards[index].kind), delay: Double(index) * 0.25)
                        }
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            tag(item, hazard: hazards[index], delay: Double(index) * 0.25)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.0).delay(0.3)) { progress = 1 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(hazards.map(\.label).joined(separator: ", ")))
    }

    private func layoutItems(in size: CGSize) -> [HazardLabelLayout.Item] {
        let boxes = hazards.map { hazard -> CGRect in
            let box = hazard.box
            let x = clamp(box.x), y = clamp(box.y)
            return CGRect(x: x * size.width, y: y * size.height,
                          width: max(min(clamp(box.w), 1 - x) * size.width, 8),
                          height: max(min(clamp(box.h), 1 - y) * size.height, 8))
        }
        let widths = hazards.map { hazard -> CGFloat in
            let text = (hazard.label as NSString).size(withAttributes: [.font: Self.labelFont]).width
            // badge (18) + spacing (5) + text + horizontal padding (4 + 10)
            return ceil(text) + 18 + 5 + 14 + 2
        }
        return HazardLabelLayout.layout(boxes: boxes, labelWidths: widths, in: size)
    }

    private func outline(_ item: HazardLabelLayout.Item, tint: Color, delay: Double) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .trim(from: 0, to: progress)
            .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.10 * progress)))
            .shadow(color: tint.opacity(0.6), radius: 6)
            .frame(width: item.box.width, height: item.box.height)
            .position(x: item.box.midX, y: item.box.midY)
            .animation(.easeOut(duration: 0.9).delay(delay), value: progress)
    }

    @ViewBuilder
    private func tag(_ item: HazardLabelLayout.Item, hazard: Hazard, delay: Double) -> some View {
        let tint = hazardTint(for: hazard.kind)
        Group {
            if let frame = item.labelFrame {
                HStack(spacing: 5) {
                    NumberBadge(number: item.number, tint: tint, inverted: true, size: 18)
                    Text(hazard.label)
                        .font(Font(Self.labelFont))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .frame(width: frame.width, height: frame.height, alignment: .leading)
                .background(Capsule().fill(tint))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .position(x: frame.midX, y: frame.midY)
            } else {
                NumberBadge(number: item.number, tint: tint, inverted: false, size: HazardLabelLayout.badgeSize)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .position(item.badgeCenter)
            }
        }
        .opacity(progress)
        .scaleEffect(0.85 + 0.15 * progress)
        .animation(.easeOut(duration: 0.5).delay(delay + 0.4), value: progress)
    }

    private func clamp(_ value: Double) -> CGFloat { CGFloat(min(max(value, 0), 1)) }
}

/// Circled hazard number, shared by the photo tags and the legend.
struct NumberBadge: View {
    let number: Int
    let tint: Color
    /// True: white disc with tinted digit (on a tinted capsule). False: tinted disc, white digit.
    var inverted = false
    var size: CGFloat = 20

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(inverted ? tint : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(inverted ? Color.white : tint))
            .overlay(Circle().strokeBorder(Color.white.opacity(inverted ? 0 : 0.9), lineWidth: 1.5))
    }
}

/// Numbered list of every hazard under the photo, so long labels are always readable in full.
struct HazardLegend: View {
    let hazards: [Hazard]

    var body: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
            ForEach(Array(hazards.enumerated()), id: \.offset) { index, hazard in
                let tint = hazardTint(for: hazard.kind)
                HStack(alignment: .firstTextBaseline, spacing: HoTHSpacing.s) {
                    NumberBadge(number: index + 1, tint: tint, size: 20)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(hazard.label)
                        .font(.hothCaption.weight(.semibold))
                        .foregroundStyle(Color.hothInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("hazardLegend")
    }
}
