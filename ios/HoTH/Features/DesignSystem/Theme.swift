import SwiftUI
import UIKit

// MARK: - HoTH Design System
// Social-network palette: one blue accent on cool neutrals, system sans throughout,
// flat white cards with hairlines, subtle spring motion. RTL-safe: only leading/trailing.

// MARK: Colors

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func hothDynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }
}

extension Color {
    /// Cool grey page background.
    static let hothBackground = Color(uiColor: .hothDynamic(light: 0xF0F2F5, dark: 0x18191A))
    /// Card surface (white in light mode).
    static let hothSurface = Color(uiColor: .hothDynamic(light: 0xFFFFFF, dark: 0x242526))
    /// Primary text (near-black, never pure black).
    static let hothInk = Color(uiColor: .hothDynamic(light: 0x1C1E21, dark: 0xE4E6EB))
    /// Secondary text.
    static let hothInkSecondary = Color(uiColor: .hothDynamic(light: 0x65676B, dark: 0xB0B3B8))
    /// Blue accent (primary action, links, selection).
    static let hothAccent = Color(uiColor: .hothDynamic(light: 0x0866FF, dark: 0x2D88FF))
    /// Deep civic blue (trust, info, demo labels). Name kept from the earlier teal palette.
    static let hothTeal = Color(uiColor: .hothDynamic(light: 0x0A5DC2, dark: 0x5AA7FF))
    /// Neutral grey fill (chips, secondary buttons). Name kept from the earlier sand palette.
    static let hothSand = Color(uiColor: .hothDynamic(light: 0xE4E6EB, dark: 0x3A3B3C))
    static let hothCritical = Color(uiColor: .hothDynamic(light: 0xC62E2E, dark: 0xF0605A))
    static let hothHigh = Color(uiColor: .hothDynamic(light: 0xD9711C, dark: 0xF39A4A))
    static let hothMedium = Color(uiColor: .hothDynamic(light: 0xB8901A, dark: 0xE2C04F))
    static let hothLow = Color(uiColor: .hothDynamic(light: 0x5B7F6A, dark: 0x8DBB9E))
    static let hothSuccess = Color(uiColor: .hothDynamic(light: 0x2F8A57, dark: 0x5CCB8A))
}

// MARK: Typography

extension Font {
    /// Bold system sans for hero numbers and wordmarks.
    static func hothDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold)
    }
    static let hothTitle = Font.system(size: 24, weight: .bold)
    static let hothHeadline = Font.system(size: 17, weight: .semibold)
    static let hothBody = Font.system(size: 16, weight: .regular)
    static let hothCaption = Font.system(size: 13, weight: .medium)
}

// MARK: Spacing & Radius

enum HoTHSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 36
}

enum HoTHRadius {
    static let card: CGFloat = 14
    static let chip: CGFloat = 999
    static let inner: CGFloat = 10
}

enum HoTHMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

// MARK: Card

/// Flat card: surface fill, hairline border, one faint shadow.
struct HoTHCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = HoTHSpacing.m, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                    .fill(Color.hothSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                    .strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

// MARK: Priority badge

struct PriorityBadge: View {
    let levelRaw: String
    @State private var isPulsing = false

    private var level: PriorityLevel { PriorityLevel(rawValue: levelRaw.lowercased()) ?? .low }

    private var color: Color {
        switch level {
        case .critical: return .hothCritical
        case .high: return .hothHigh
        case .medium: return .hothMedium
        case .low: return .hothLow
        }
    }

    private var symbol: String {
        switch level {
        case .critical: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "leaf.fill"
        }
    }

    private var label: LocalizedStringKey {
        switch level {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    var body: some View {
        HStack(spacing: HoTHSpacing.xs) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(label).font(.hothCaption.weight(.bold)).textCase(.uppercase)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("priorityBadge_\(level.rawValue)")
        .shadow(color: level == .critical ? color.opacity(isPulsing ? 0.55 : 0.0) : .clear,
                radius: isPulsing ? 10 : 2)
        .scaleEffect(level == .critical && isPulsing ? 1.04 : 1)
        .onAppear {
            guard level == .critical else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Category chip

struct CategoryChip: View {
    let categoryRaw: String

    private var category: IssueCategory { IssueCategory(rawValue: categoryRaw) ?? .other }

    var body: some View {
        HStack(spacing: HoTHSpacing.xs) {
            Image(systemName: category.fallbackSymbol).font(.system(size: 11, weight: .semibold))
            Text(category.localizedName).font(.hothCaption)
        }
        .foregroundStyle(Color.hothInk.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.hothSand))
    }
}

extension IssueCategory {
    /// Human, localized name for UI.
    var localizedName: LocalizedStringKey {
        switch self {
        case .playgroundEquipment: return "Playground"
        case .fitnessEquipment: return "Fitness equipment"
        case .potholePavement: return "Pothole / pavement"
        case .electricalHazard: return "Electrical hazard"
        case .openManhole: return "Open manhole"
        case .wasteOverflowDumping: return "Waste / dumping"
        case .blockedAccessibility: return "Blocked access"
        case .waterLeak: return "Water leak"
        case .other: return "Other"
        case .notAnIssue: return "Not an issue"
        }
    }
}

// MARK: Button styles

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hothHeadline)
            .foregroundStyle(Color.white)
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous)
                    .fill(Color.hothAccent.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(HoTHMotion.spring, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hothHeadline)
            .foregroundStyle(Color.hothInk)
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous)
                    .fill(Color.hothSand.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(HoTHMotion.spring, value: configuration.isPressed)
    }
}

// MARK: Demo badge

struct DemoBadge: View {
    var body: some View {
        HStack(spacing: HoTHSpacing.xs) {
            Circle().fill(Color.hothTeal).frame(width: 6, height: 6)
            Text("Demo community").font(.hothCaption.weight(.semibold))
        }
        .foregroundStyle(Color.hothTeal)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.hothTeal.opacity(0.12)))
        .accessibilityLabel(Text("Demo community"))
    }
}

// MARK: Section header

struct SectionHeader: View {
    let title: LocalizedStringKey

    init(title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.hothCaption.weight(.bold))
            .textCase(.uppercase)
            .hothTracking(1.2)
            .foregroundStyle(Color.hothInkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HoTHSpacing.m)
    }
}

// MARK: Status bar backdrop

extension View {
    /// Page colour behind the status bar so scrolled content does not run under the clock
    /// (screens that hide the navigation bar).
    func hothStatusBarBackdrop() -> some View {
        // A zero-height inset sits on the safe-area edge; its background extends up under the status bar.
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background(Color.hothBackground, ignoresSafeAreaEdges: .top)
                .allowsHitTesting(false)
        }
    }
}

// MARK: RTL-safe tracking

private struct HoTHTrackingModifier: ViewModifier {
    let value: CGFloat
    @Environment(\.layoutDirection) private var layoutDirection

    // Arabic is a connected script: any letter-spacing breaks the glyph joins.
    func body(content: Content) -> some View {
        content.tracking(layoutDirection == .rightToLeft ? 0 : value)
    }
}

extension View {
    /// Letter-spacing that is disabled in right-to-left (Arabic) layouts.
    func hothTracking(_ value: CGFloat) -> some View {
        modifier(HoTHTrackingModifier(value: value))
    }
}
