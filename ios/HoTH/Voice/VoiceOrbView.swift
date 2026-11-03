import SwiftUI

/// What the voice interview is doing, as far as the orb cares.
enum VoiceOrbState: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case assistantSpeaking
    case done
    case failed
}

/// Living voice orb: slow breathing when idle, swells with the audio level, hue follows who is talking.
struct VoiceOrbView: View {
    let state: VoiceOrbState
    /// 0...1, assistant output level when it speaks, resident mic level otherwise.
    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: (core: Color, glow: Color, rim: Color) {
        switch state {
        case .assistantSpeaking: return (.hothAccent, .hothHigh, .hothSand)
        case .listening: return (.hothTeal, .hothLow, .hothSand)
        case .transcribing, .thinking, .idle: return (.hothSand, .hothTeal.opacity(0.5), .hothInkSecondary.opacity(0.3))
        case .done: return (.hothSuccess, .hothLow, .hothSand)
        case .failed: return (.hothInkSecondary.opacity(0.5), .hothSand, .hothInkSecondary.opacity(0.2))
        }
    }

    /// Transcribing or waiting for the reply: faster breathing and a spinner.
    private var isWorking: Bool { state == .transcribing || state == .thinking }

    /// Perceptual boost: mic and speech levels are small, so lift quiet speech into visible motion.
    private var amplitude: CGFloat {
        let clamped = max(0, min(1, CGFloat(level)))
        return min(1, sqrt(clamped) * 1.4)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breathing = reduceMotion ? 0 : (sin(time * (isWorking ? 2.4 : 1.2)) + 1) / 2
            let scale = 0.92 + 0.04 * breathing + 0.22 * amplitude

            ZStack {
                // Outer halo.
                Circle()
                    .fill(RadialGradient(colors: [palette.glow.opacity(0.35), .clear],
                                         center: .center, startRadius: 40, endRadius: 170))
                    .scaleEffect(1.0 + 0.3 * amplitude + 0.05 * breathing)
                    .blur(radius: 18)

                // Drifting colour blobs inside the orb.
                ZStack {
                    blob(color: palette.core, time: time, speed: 0.35, phase: 0)
                    blob(color: palette.glow, time: time, speed: 0.27, phase: 2.1)
                    blob(color: palette.rim, time: time, speed: 0.19, phase: 4.2)
                }
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .blur(radius: 10)
                .overlay(
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear],
                                                 startPoint: .topLeading, endPoint: .center))
                        .blendMode(.softLight)
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: palette.core.opacity(0.35), radius: 24, x: 0, y: 12)
                .scaleEffect(scale)

                if isWorking {
                    ProgressView().tint(Color.hothInk.opacity(0.6))
                }
            }
            .frame(width: 280, height: 280)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: amplitude)
        .animation(.easeInOut(duration: 0.6), value: state)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityText))
    }

    private func blob(color: Color, time: TimeInterval, speed: Double, phase: Double) -> some View {
        let angle = reduceMotion ? phase : time * speed + phase
        let radius = 34 + 18 * Double(amplitude)
        return Circle()
            .fill(color)
            .frame(width: 150, height: 150)
            .offset(x: cos(angle) * radius, y: sin(angle * 1.3) * radius)
    }

    private var accessibilityText: LocalizedStringKey {
        switch state {
        case .idle: return "Hold to talk"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .assistantSpeaking: return "The assistant is speaking"
        case .done: return "Interview finished"
        case .failed: return "Voice unavailable"
        }
    }
}
