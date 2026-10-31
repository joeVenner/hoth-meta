import SwiftUI

/// The HoTH app-icon mark as a reusable view (app icons can't be loaded by name, so the
/// `hoth_logo` imageset carries a copy). Masked to the iOS icon squircle with a soft warm shadow.
struct HoTHLogo: View {
    /// Side length in points.
    let size: CGFloat
    var hasShadow: Bool = true

    /// iOS icon corner radius is ~22.37% of the side.
    static let cornerRatio: CGFloat = 0.2237

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
        Image("hoth_logo")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 0.5))
            .shadow(color: hasShadow ? Color(red: 0.55, green: 0.32, blue: 0.18).opacity(0.10) : .clear,
                    radius: size * 0.04, x: 0, y: size * 0.02)
            .shadow(color: hasShadow ? Color(red: 0.55, green: 0.32, blue: 0.18).opacity(0.14) : .clear,
                    radius: size * 0.22, x: 0, y: size * 0.12)
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 24) {
        HoTHLogo(size: 44)
        HoTHLogo(size: 128)
    }
    .padding(40)
    .background(Color.hothBackground)
}
