import HoTHCore
import SwiftUI
import UIKit

/// The "Fixed ✨" moment (P1-05): before/after slider, points earned, and the new badge on level-up.
struct FixedCelebrationView: View {
    let celebration: FixCheckModel.Celebration
    let isArabic: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isRevealed = false

    private var title: String {
        let preferred = isArabic ? celebration.titleAR : celebration.titleEN
        return preferred.isEmpty ? celebration.titleEN : preferred
    }

    private var badgeName: String {
        switch Rewards.level(forPoints: celebration.newPoints) {
        case .neighbour: return "badge_neighbour"
        case .guardian: return "badge_guardian"
        case .heroOfTheHay: return "badge_hero"
        }
    }

    private var levelTitle: String {
        let level = Rewards.level(forPoints: celebration.newPoints)
        return isArabic ? level.titleAR : level.titleEN
    }

    var body: some View {
        ScrollView {
            VStack(spacing: HoTHSpacing.m) {
                Text("Fixed ✨")
                    .font(.hothDisplay(40))
                    .foregroundStyle(Color.hothInk)
                    .padding(.top, HoTHSpacing.l)
                Text(FixedMomentNotifier.message(titleEN: celebration.titleEN, titleAR: celebration.titleAR,
                                                 points: celebration.pointsAwarded,
                                                 wasReporter: celebration.wasReporter, arabic: isArabic))
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothInkSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("celebrationMessage")

                BeforeAfterSlider(before: celebration.before, after: celebration.after)
                    .frame(height: 300)
                    // Image geometry: before always on the physical left.
                    .environment(\.layoutDirection, .leftToRight)

                if celebration.didLevelUp {
                    VStack(spacing: HoTHSpacing.xs) {
                        Image(badgeName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 110, height: 110)
                            .scaleEffect(isRevealed ? 1 : 0.4)
                            .rotationEffect(.degrees(isRevealed ? 0 : -20))
                        Text("Level up!")
                            .font(.hothCaption.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(Color.hothAccent)
                        Text(levelTitle)
                            .font(.hothTitle)
                            .foregroundStyle(Color.hothInk)
                    }
                    .accessibilityIdentifier("celebrationLevelUp")
                }

                HStack(spacing: HoTHSpacing.xs) {
                    Text("+\(celebration.pointsAwarded)")
                        .font(.hothDisplay(30))
                        .foregroundStyle(Color.hothAccent)
                    Text("points · \(celebration.newPoints) total")
                        .font(.hothBody)
                        .foregroundStyle(Color.hothInkSecondary)
                }

                Button("Back to work") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("celebrationDoneButton")
            }
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.bottom, HoTHSpacing.l)
        }
        .background(Color.hothBackground.ignoresSafeArea())
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.2)) { isRevealed = true }
        }
        .presentationDragIndicator(.visible)
    }
}

/// Drag the handle to compare BEFORE (left) and AFTER (right).
struct BeforeAfterSlider: View {
    let before: UIImage?
    let after: UIImage?
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        GeometryReader { proxy in
            SliderLayers(before: before, after: after, size: proxy.size, fraction: fraction)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    fraction = min(max(value.location.x / max(proxy.size.width, 1), 0.02), 0.98)
                })
        }
        .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous))
    }
}

private struct SliderLayers: View {
    let before: UIImage?
    let after: UIImage?
    let size: CGSize
    let fraction: CGFloat

    var body: some View {
        let handleX = size.width * fraction
        ZStack(alignment: .topLeading) {
            SliderPhoto(image: after, size: size)
            SliderPhoto(image: before, size: size)
                .frame(width: handleX, height: size.height, alignment: .topLeading)
                .clipped()
            Rectangle()
                .fill(Color.white)
                .frame(width: 3, height: size.height)
                .offset(x: handleX - 1.5)
            SliderHandle()
                .offset(x: handleX - 20, y: size.height / 2 - 20)
            SliderTag(text: "Before").padding(10)
            SliderTag(text: "After")
                .padding(10)
                .frame(width: size.width, alignment: .topTrailing)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct SliderPhoto: View {
    let image: UIImage?
    let size: CGSize

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.hothSand
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private struct SliderHandle: View {
    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 40, height: 40)
            .shadow(radius: 6)
            .overlay(
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.hothInk)
            )
            .accessibilityIdentifier("beforeAfterHandle")
    }
}

private struct SliderTag: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
