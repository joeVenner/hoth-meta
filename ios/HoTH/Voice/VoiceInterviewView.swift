import HoTHCore
import SwiftUI
import UIKit

/// Voice interview screen: animated orb, live captions, mute / end, and a "Type instead" escape hatch.
struct VoiceInterviewView: View {
    private let context: InterviewContext
    private let onComplete: (SubmitReportArgs) -> Void
    private let onUrgent: (String) -> Void
    private let onSwitchToText: () -> Void

    @StateObject private var session: RealtimeSession
    @State private var showsAppSettings = false

    /// - Parameters:
    ///   - context: What the vision + priority steps found, and the questions to ask.
    ///   - onComplete: Called once with the confirmed report from the `submit_report` tool.
    ///   - onUrgent: Called when the assistant flags immediate danger (`flag_urgent`); the session keeps going.
    ///   - onSwitchToText: Called when the resident prefers typing (or voice is unavailable).
    ///   - keyProvider: OpenAI key source; nil means the app's single provider (`AppServices.shared.keyProvider`).
    @MainActor
    init(
        context: InterviewContext,
        onComplete: @escaping (SubmitReportArgs) -> Void,
        onUrgent: @escaping (String) -> Void,
        onSwitchToText: @escaping () -> Void = {},
        keyProvider: APIKeyProvider? = nil
    ) {
        self.context = context
        self.onComplete = onComplete
        self.onUrgent = onUrgent
        self.onSwitchToText = onSwitchToText
        _session = StateObject(wrappedValue: RealtimeSession(
            context: context, keyProvider: keyProvider ?? AppServices.shared.keyProvider))
    }

    var body: some View {
        ZStack {
            Color.hothBackground.ignoresSafeArea()

            VStack(spacing: HoTHSpacing.m) {
                header
                Spacer(minLength: 0)
                VoiceOrbView(state: session.state, level: orbLevel)
                statusLine
                if case .failed(let error) = session.state {
                    failureCard(error)
                } else {
                    captionsList
                }
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.vertical, HoTHSpacing.m)
        }
        .task {
            session.onComplete = onComplete
            session.onUrgent = onUrgent
            await session.start()
        }
        .onDisappear { session.end() }
        .sheet(isPresented: $showsAppSettings) { SettingsView() }
    }

    private var orbLevel: Float {
        session.state == .assistantSpeaking ? session.assistantLevel : session.residentLevel
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: HoTHSpacing.s) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.hothAccent)
            Text("HoTH assistant")
                .font(.hothHeadline)
                .foregroundStyle(Color.hothInk)
            Text(verbatim: "AI")
                .font(.hothCaption.weight(.bold))
                .foregroundStyle(Color.hothTeal)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.hothTeal.opacity(0.12)))
            Spacer()
            if session.isMuted {
                Label("Muted", systemImage: "mic.slash.fill")
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothCritical)
            }
        }
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.hothCaption)
            .foregroundStyle(Color.hothInkSecondary)
            .contentTransition(.opacity)
            .animation(HoTHMotion.spring, value: session.state)
    }

    private var statusText: LocalizedStringKey {
        switch session.state {
        case .idle, .connecting: return "Connecting…"
        case .listening: return session.isMuted ? "Muted. Tap the mic to talk" : "Listening, speak in any language"
        case .assistantSpeaking: return "Speaking…"
        case .done: return "All done, thank you"
        case .failed: return "Voice is unavailable"
        }
    }

    // MARK: Captions

    private var captionsList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: HoTHSpacing.s) {
                    ForEach(visibleCaptions) { caption in
                        captionRow(caption).id(caption.id)
                    }
                }
                .padding(.vertical, HoTHSpacing.s)
            }
            .frame(maxHeight: 220)
            .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .center))
            .onChange(of: session.captions) { _, captions in
                guard let last = captions.last(where: { !$0.text.isEmpty }) else { return }
                withAnimation(HoTHMotion.spring) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var visibleCaptions: [VoiceCaption] {
        session.captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func captionRow(_ caption: VoiceCaption) -> some View {
        let isAssistant = caption.speaker == .assistant
        return VStack(alignment: .leading, spacing: 2) {
            Text(isAssistant ? "Assistant" : "You")
                .font(.hothCaption.weight(.semibold))
                .foregroundStyle(isAssistant ? Color.hothAccent : Color.hothTeal)
            Text(caption.text)
                .font(.hothBody)
                .foregroundStyle(Color.hothInk.opacity(caption.isFinal ? 1 : 0.75))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(HoTHSpacing.s + 4)
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous)
                .fill(isAssistant ? Color.hothSurface : Color.hothSand)
        )
        .environment(\.layoutDirection, caption.isRightToLeft ? .rightToLeft : .leftToRight)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Failure

    private func failureCard(_ error: RealtimeSessionError) -> some View {
        HoTHCard {
            VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                Text(error.userMessage)
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInk)
                    .accessibilityIdentifier("voiceFailureMessage")
                // The remedy first, then the always-available escape hatch.
                switch error {
                case .microphoneDenied:
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(PrimaryButtonStyle())
                case .missingKey, .invalidKey:
                    Button("Go to Settings") { showsAppSettings = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Try voice again") { Task { await session.start() } }
                        .buttonStyle(SecondaryButtonStyle())
                case .promptsUnavailable:
                    EmptyView()
                default:
                    Button("Try again") { Task { await session.start() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Type instead", action: switchToText)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("voiceTypeInsteadButton")
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: HoTHSpacing.m) {
            if !isFailed {
                HStack(spacing: HoTHSpacing.xl) {
                    roundButton(
                        systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill",
                        tint: session.isMuted ? .hothCritical : .hothInk,
                        fill: Color.hothSurface,
                        label: session.isMuted ? "Unmute" : "Mute"
                    ) { session.isMuted.toggle() }
                    .disabled(session.state == .done)

                    roundButton(systemImage: "phone.down.fill", tint: .white, fill: Color.hothCritical,
                                label: "End") { session.end() }
                    .disabled(session.state == .done)
                }
                Button(action: switchToText) {
                    Label("Type instead", systemImage: "keyboard")
                        .font(.hothCaption.weight(.semibold))
                        .foregroundStyle(Color.hothInkSecondary)
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    private func roundButton(systemImage: String, tint: Color, fill: Color, label: LocalizedStringKey,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(Color.hothInk.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
        }
        .accessibilityLabel(Text(label))
    }

    private func switchToText() {
        session.end()
        onSwitchToText()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
