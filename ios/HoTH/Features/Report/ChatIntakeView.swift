import HoTHCore
import SwiftUI

/// Builds the voice interview screen. Supplied by the parent so this file never names the voice type.
typealias VoiceInterviewBuilder = (
    _ context: InterviewContext,
    _ onComplete: @escaping (SubmitReportArgs) -> Void,
    _ onUrgent: @escaping (String) -> Void,
    _ onSwitchToText: @escaping () -> Void
) -> AnyView

/// Interview step host: "Talk" (voice, when available) or "Type" (chat fallback).
struct InterviewStepView: View {
    let context: InterviewContext
    let slots: [SlotQuestion]
    let client: MetaModelClient?
    let prompts: Prompts
    let voiceBuilder: VoiceInterviewBuilder?
    let onComplete: (SubmitReportArgs) -> Void
    let onUrgent: (String) -> Void

    enum Mode: Hashable { case talk, type }

    @State private var mode: Mode

    /// - Parameter initialMode: the segment selected on entry (see `initialMode(prefersVoice:isUITestRun:)`).
    ///   Talk is used even without a key: the voice screen then explains why it can't start instead of
    ///   silently switching to Type.
    init(context: InterviewContext, slots: [SlotQuestion], client: MetaModelClient?, prompts: Prompts,
         voiceBuilder: VoiceInterviewBuilder?, initialMode: Mode = .talk,
         onComplete: @escaping (SubmitReportArgs) -> Void, onUrgent: @escaping (String) -> Void) {
        self.context = context
        self.slots = slots
        self.client = client
        self.prompts = prompts
        self.voiceBuilder = voiceBuilder
        self.onComplete = onComplete
        self.onUrgent = onUrgent
        _mode = State(initialValue: voiceBuilder == nil ? .type : initialMode)
    }

    /// Talk unless the resident turned off "Start interview with voice". UI tests always start in Type
    /// (no mic prompt, no Realtime call).
    static func initialMode(prefersVoice: Bool, isUITestRun: Bool) -> Mode {
        prefersVoice && !isUITestRun ? .talk : .type
    }

    var body: some View {
        VStack(spacing: 0) {
            if voiceBuilder != nil {
                Picker("Interview mode", selection: $mode) {
                    Label("Talk", systemImage: "waveform").tag(Mode.talk)
                    Label("Type", systemImage: "keyboard").tag(Mode.type)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.vertical, HoTHSpacing.s)
                .accessibilityIdentifier("interviewModePicker")
            }
            Group {
                if mode == .talk, let voiceBuilder {
                    voiceBuilder(context, onComplete, onUrgent, { mode = .type })
                } else {
                    ChatIntakeView(context: context, slots: slots, client: client, prompts: prompts,
                                   onComplete: onComplete, onUrgent: onUrgent)
                }
            }
            .transition(.opacity)
        }
        .animation(HoTHMotion.spring, value: mode)
        .background(Color.hothBackground.ignoresSafeArea())
    }
}

/// Text quick-chat fallback (P0-15): bubbles, quick replies, read-back + confirm.
struct ChatIntakeView: View {
    @StateObject private var model: ChatIntakeModel
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(context: InterviewContext, slots: [SlotQuestion], client: MetaModelClient?, prompts: Prompts,
         onComplete: @escaping (SubmitReportArgs) -> Void, onUrgent: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: ChatIntakeModel(
            context: context, slots: slots, client: client, prompts: prompts,
            onComplete: onComplete, onUrgent: onUrgent))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: HoTHSpacing.s) {
                        if model.mode == .local {
                            Label("Quick chat (offline)", systemImage: "bolt.horizontal.circle")
                                .font(.hothCaption)
                                .foregroundStyle(Color.hothInkSecondary)
                                .padding(.vertical, HoTHSpacing.xs)
                        }
                        ForEach(model.bubbles) { bubble in
                            bubbleView(bubble).id(bubble.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if model.isThinking {
                            typingIndicator.id("typing")
                        }
                    }
                    .padding(HoTHSpacing.m)
                    .animation(HoTHMotion.spring, value: model.bubbles)
                }
                .onChange(of: model.bubbles.count) {
                    withAnimation { proxy.scrollTo(model.bubbles.last?.id, anchor: .bottom) }
                }
            }
            inputArea
        }
        .background(Color.hothBackground)
        .onAppear { model.start() }
    }

    private func bubbleView(_ bubble: ChatBubble) -> some View {
        let isAssistant = bubble.role == .assistant
        return HStack(alignment: .bottom, spacing: HoTHSpacing.s) {
            if isAssistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.hothTeal))
            } else {
                Spacer(minLength: 48)
            }
            Text(bubble.text)
                .font(.hothBody)
                .foregroundStyle(isAssistant ? Color.hothInk : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isAssistant ? Color.hothSurface : Color.hothAccent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.hothInk.opacity(isAssistant ? 0.06 : 0))
                )
            if isAssistant { Spacer(minLength: 48) }
        }
    }

    private var typingIndicator: some View {
        HStack {
            ProgressView().tint(Color.hothTeal)
            Text("Thinking…").font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
            Spacer()
        }
        .padding(.leading, 36)
    }

    private var inputArea: some View {
        VStack(spacing: HoTHSpacing.s) {
            if !model.quickReplies.isEmpty && !model.isFinished {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoTHSpacing.s) {
                        ForEach(model.quickReplies, id: \.self) { reply in
                            Button(reply) { model.send(reply) }
                                .font(.hothHeadline)
                                .foregroundStyle(Color.hothTeal)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Capsule().strokeBorder(Color.hothTeal, lineWidth: 1.5))
                                .disabled(model.isThinking)
                        }
                    }
                    .padding(.horizontal, HoTHSpacing.m)
                }
            }
            HStack(spacing: HoTHSpacing.s) {
                TextField("Type your answer…", text: $draft, axis: .vertical)
                    .font(.hothBody)
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.hothSurface))
                    .overlay(Capsule().strokeBorder(Color.hothInk.opacity(0.08)))
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .accessibilityIdentifier("chatInputField")
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.hothAccent))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("chatSendButton")
            }
            .padding(.horizontal, HoTHSpacing.m)
        }
        .padding(.vertical, HoTHSpacing.s)
        .disabled(model.isFinished)
        .opacity(model.isFinished ? 0.5 : 1)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.send(text)
    }
}
