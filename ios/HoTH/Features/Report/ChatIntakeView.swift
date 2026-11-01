import HoTHCore
import SwiftUI

/// Interview step host: the chat, with push-to-talk voice when the Meta client is available.
struct InterviewStepView: View {
    let context: InterviewContext
    let slots: [SlotQuestion]
    let client: MetaModelClient?
    let prompts: Prompts
    let textModel: String?
    let startsWithVoice: Bool
    let toolbox: IntakeToolbox?
    let onComplete: (SubmitReportArgs) -> Void
    let onUrgent: (String) -> Void
    let onConfirmExisting: ((UUID, SubmitReportArgs) -> Void)?

    /// - Parameter startsWithVoice: see `startsWithVoice(prefersVoice:isUITestRun:)`. Without a client
    ///   (no key, UI tests) there is no transcription, so the interview is text only either way.
    init(context: InterviewContext, slots: [SlotQuestion], client: MetaModelClient?, prompts: Prompts,
         textModel: String? = nil, startsWithVoice: Bool = true, toolbox: IntakeToolbox? = nil,
         onComplete: @escaping (SubmitReportArgs) -> Void, onUrgent: @escaping (String) -> Void,
         onConfirmExisting: ((UUID, SubmitReportArgs) -> Void)? = nil) {
        self.context = context
        self.slots = slots
        self.client = client
        self.prompts = prompts
        self.textModel = textModel
        self.startsWithVoice = startsWithVoice
        self.toolbox = toolbox
        self.onComplete = onComplete
        self.onUrgent = onUrgent
        self.onConfirmExisting = onConfirmExisting
    }

    /// Voice unless the resident turned off "Start interview with voice". UI tests always start typing
    /// (no mic prompt, no speech).
    static func startsWithVoice(prefersVoice: Bool, isUITestRun: Bool) -> Bool {
        prefersVoice && !isUITestRun
    }

    var body: some View {
        ChatIntakeView(context: context, slots: slots, client: client, prompts: prompts, textModel: textModel,
                       transcriber: client.map {
                           MetaSpeechTranscriber(client: $0, model: prompts.models.transcribe,
                                                 languageHint: context.language)
                       },
                       startsWithVoice: startsWithVoice, toolbox: toolbox,
                       onComplete: onComplete, onUrgent: onUrgent, onConfirmExisting: onConfirmExisting)
            .background(Color.hothBackground.ignoresSafeArea())
    }
}

/// Quick-chat interview (P0-15): bubbles, quick replies, read-back + confirm. With a transcriber the
/// resident can answer by push-to-talk instead of typing, and replies are read aloud.
struct ChatIntakeView: View {
    @StateObject private var model: ChatIntakeModel
    @StateObject private var voice: PushToTalkModel
    @State private var draft = ""
    @State private var isPressingMic = false
    @FocusState private var isFocused: Bool

    init(context: InterviewContext, slots: [SlotQuestion], client: MetaModelClient?, prompts: Prompts,
         textModel: String? = nil, transcriber: SpeechTranscribing? = nil, startsWithVoice: Bool = false,
         toolbox: IntakeToolbox? = nil,
         onComplete: @escaping (SubmitReportArgs) -> Void, onUrgent: @escaping (String) -> Void,
         onConfirmExisting: ((UUID, SubmitReportArgs) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ChatIntakeModel(
            context: context, slots: slots, client: client, prompts: prompts, model: textModel, toolbox: toolbox,
            onComplete: onComplete, onUrgent: onUrgent, onConfirmExisting: onConfirmExisting))
        _voice = StateObject(wrappedValue: PushToTalkModel(
            transcriber: transcriber, recorder: WAVVoiceRecorder(), speaker: SystemSpeechSpeaker(),
            startsInVoice: startsWithVoice))
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
        .onAppear {
            // Wired here (not in init) so both closures reach the StateObjects SwiftUI actually keeps.
            model.onAssistantMessage = { [weak voice] text in voice?.assistantSaid(text) }
            voice.onTranscript = { [weak model] text in model?.send(text) }
            model.start()
        }
        .onDisappear { voice.shutDown() }
        .onChange(of: model.isThinking) { _, isThinking in
            if !isThinking { voice.chatSettled() }
        }
        .onChange(of: model.isFinished) { _, isFinished in
            if isFinished { voice.conversationFinished() }
        }
        .onChange(of: voice.notice) { _, notice in
            if notice?.fallsBackToTyping == true { isFocused = true }
        }
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
            Text(activityText).font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
                .accessibilityIdentifier("chatActivity")
            Spacer()
        }
        .padding(.leading, 36)
    }

    /// What the agent is doing, so its tool calls are visible while it thinks.
    private var activityText: LocalizedStringKey {
        switch model.toolActivity {
        case .nearbyReports: return "Checking reports nearby…"
        case .segmenting: return "Outlining with SAM 3.1…"
        case .placeContext: return "Checking places nearby…"
        case nil: return "Thinking…"
        }
    }

    private var inputArea: some View {
        VStack(spacing: HoTHSpacing.s) {
            if let notice = voice.notice {
                Label(notice.message, systemImage: notice.fallsBackToTyping ? "mic.slash" : "ear")
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
                    .padding(.horizontal, HoTHSpacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voiceNotice")
            }
            if !model.quickReplies.isEmpty && !model.isFinished {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoTHSpacing.s) {
                        ForEach(model.quickReplies, id: \.self) { reply in
                            Button(reply) {
                                voice.stopSpeaking()
                                model.send(reply)
                            }
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
            if voice.isVoiceMode {
                voiceControls
            } else {
                textRow
            }
        }
        .padding(.vertical, HoTHSpacing.s)
        .disabled(model.isFinished)
        .opacity(model.isFinished ? 0.5 : 1)
    }

    private var textRow: some View {
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
                if voice.isAvailable {
                    Button {
                        voice.switchToVoice()
                        isFocused = false
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.hothTeal)
                            .frame(width: 42, height: 42)
                            .background(Circle().strokeBorder(Color.hothTeal, lineWidth: 1.5))
                    }
                    .accessibilityLabel(Text("Answer by voice"))
                    .accessibilityIdentifier("chatMicButton")
                }
            }
            .padding(.horizontal, HoTHSpacing.m)
    }

    /// Hold the orb to talk (or tap, then tap again to send); the status line says what happens next.
    private var voiceControls: some View {
        let isMicEnabled = voice.canRecord && !model.isThinking && !model.isFinished
        return VStack(spacing: HoTHSpacing.xs) {
            ZStack {
                VoiceOrbView(state: voice.phase.orbState, level: voice.phase == .speaking ? 0.3 : voice.level)
                    .scaleEffect(0.5)
                    .frame(width: 140, height: 140)
                Image(systemName: voice.phase == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 4)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressingMic else { return }
                        isPressingMic = true
                        voice.pressBegan()
                    }
                    .onEnded { _ in
                        isPressingMic = false
                        voice.pressEnded()
                    }
            )
            .allowsHitTesting(isMicEnabled)
            .opacity(isMicEnabled || voice.phase != .idle ? 1 : 0.6)
            .accessibilityElement()
            .accessibilityLabel(Text("Talk"))
            .accessibilityValue(Text(voice.phase.statusText(isLatched: voice.isLatched)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isMicEnabled { voice.toggleRecording() } }
            .accessibilityIdentifier("pushToTalkButton")

            Text(voice.phase.statusText(isLatched: voice.isLatched))
                .font(.hothCaption)
                .foregroundStyle(Color.hothInkSecondary)
                .accessibilityHidden(true)

            Button {
                voice.switchToTyping()
                isFocused = true
            } label: {
                Label("Type instead", systemImage: "keyboard")
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothTeal)
            }
            .accessibilityIdentifier("typeInsteadButton")
        }
        .frame(maxWidth: .infinity)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.send(text)
    }
}
