import SwiftUI
import UIKit

/// Safety interrupt (P0-19): calm, direct, no more questions. Offers Call 999 first.
struct SafetySheet: View {
    let reason: String
    let onContinue: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var pulse = false

    static let emergencyURL = URL(string: "tel://999")

    var body: some View {
        VStack(spacing: HoTHSpacing.l) {
            Capsule().fill(Color.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, HoTHSpacing.s)

            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 132, height: 132)
                    .scaleEffect(pulse ? 1.08 : 0.94)
                Circle().fill(Color.white.opacity(0.18)).frame(width: 98, height: 98)
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
            }

            VStack(spacing: HoTHSpacing.s) {
                Text("Please keep away and keep children away")
                    .font(.hothDisplay(28))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.hothBody)
                    .multilineTextAlignment(.center)
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, HoTHSpacing.m)

            Spacer(minLength: 0)

            VStack(spacing: HoTHSpacing.s) {
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    if let url = Self.emergencyURL { openURL(url) }
                } label: {
                    Label("Call 999", systemImage: "phone.fill")
                        .font(.hothDisplay(24))
                        .foregroundStyle(Color.hothCritical)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Capsule().fill(Color.white))
                        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
                }
                .accessibilityIdentifier("call999Button")

                Button(action: onContinue) {
                    Text("Continue report")
                        .font(.hothHeadline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))
                }
                .accessibilityIdentifier("safetyContinueButton")
            }
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.bottom, HoTHSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color.hothCritical, Color.hothCritical.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
        .interactiveDismissDisabled()
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    }

    private var symbol: String {
        let lowered = reason.lowercased()
        if lowered.contains("electric") || lowered.contains("spark") || lowered.contains("wire") {
            return "bolt.trianglebadge.exclamationmark.fill"
        }
        if lowered.contains("manhole") { return "exclamationmark.octagon.fill" }
        return "hand.raised.fill"
    }

    private var detail: LocalizedStringKey {
        let lowered = reason.lowercased()
        if lowered.contains("electric") || lowered.contains("spark") || lowered.contains("wire") {
            return "Don't touch it. If you see sparks or smoke, call 999 now. I've marked this as urgent."
        }
        if lowered.contains("manhole") {
            return "Stay clear of the opening and warn people nearby. I've marked this as urgent."
        }
        return "Children's safety comes first. Keep them off it if you can. I've marked this as urgent."
    }
}
