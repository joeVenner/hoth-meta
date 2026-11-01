import HoTHCore
import SwiftUI

/// SAM 3.1 outline of the analysed photo. A seam so flow and crew tests stay hermetic.
protocol HazardOutlining: Sendable {
    /// - Returns: nil when the category has no SAM concept; throws on timeout or API errors.
    func outline(jpegData: Data, category: ReportCategory) async throws -> SegmentOutline?
    /// A free-form concept (the intake agent's `segment_hazard`); nil when the concept is refused.
    func outline(jpegData: Data, concept: String) async throws -> SegmentOutline?
}

extension HazardOutlining {
    /// Fakes that only outline categories find nothing for free-form concepts.
    func outline(jpegData: Data, concept: String) async throws -> SegmentOutline? { nil }
}

extension HazardSegmenter: HazardOutlining {}

extension AppServices {
    /// Live SAM only with a key and outside UI tests (the golden path stays at one live call).
    func hazardOutliner() -> HazardOutlining? {
        guard hasAPIKey(), !AppServices.isUITestRun else { return nil }
        return HazardSegmenter(client: modelClient, prompts: prompts)
    }
}

/// SAM's boxes drawn over a photo, styled apart from Muse Spark's numbered hazard outlines: dashed
/// white edge with a teal glow. Boxes are 0...1 on the image; `mode` must match how the image is shown.
struct SAMOutlineOverlay: View {
    let boxes: [NormalizedBox]
    let imageSize: CGSize
    var mode: OverlayGeometry.ContentMode = .fit
    var lineWidth: CGFloat = 2.5

    @State private var isShown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(boxes.enumerated()), id: \.offset) { index, box in
                    let rect = OverlayGeometry.viewRect(for: box, imageSize: imageSize, in: proxy.size, mode: mode)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [7, 4]))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.hothTeal.opacity(0.18)))
                        .shadow(color: Color.hothTeal.opacity(0.9), radius: 4)
                        .frame(width: max(rect.width, 6), height: max(rect.height, 6))
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(isShown ? 1 : 0)
                        .scaleEffect(isShown ? 1 : 1.08)
                        .animation(.easeOut(duration: 0.5).delay(Double(index) * 0.15), value: isShown)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        // Boxes are image coordinates: never mirror them in RTL.
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isShown = true }
    }
}

/// "Outlined by SAM 3.1 · pothole": says which boxes came from SAM and what it looked for.
struct SAMOutlineChip: View {
    /// Display name of the concept (already localized by the caller; SAM itself got English).
    let concept: String

    var body: some View {
        Label {
            Text("Outlined by SAM 3.1") + Text(verbatim: " · \(concept)")
        } icon: {
            Image(systemName: "viewfinder")
        }
        .font(.hothCaption)
        .foregroundStyle(Color.hothTeal)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.hothTeal.opacity(0.1)))
        .accessibilityIdentifier("samOutlineChip")
    }
}
