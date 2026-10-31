import Foundation
import HoTHCore
import OSLog
import SwiftUI

/// Why a voice session could not run. Messages are user-facing and never contain secrets.
enum RealtimeSessionError: Error, Equatable {
    case microphoneDenied
    case promptsUnavailable
    case missingKey
    case invalidKey
    case network
    case connectionFailed(String)
    case timedOut
    /// The resident hung up before a report was submitted.
    case endedEarly

    /// Localized via the string catalog; `Text` resolves it with the in-app language override.
    var userMessage: LocalizedStringKey {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off for HoTH. Turn it on in Settings to talk, or type instead."
        case .promptsUnavailable:
            return "The voice assistant isn't set up on this phone yet. Let's type instead."
        case .missingKey:
            return "Voice needs an OpenAI key. Add one in Settings, or type instead."
        case .invalidKey:
            return "The OpenAI key was rejected. Check it in Settings, or type instead."
        case .network:
            return "I can't reach the voice assistant on this connection. Try again, or type instead."
        case .connectionFailed, .timedOut:
            return "Couldn't connect to the voice assistant. Try again, or type instead."
        case .endedEarly:
            return "Call ended before the report was finished. You can type it instead, or try voice again."
        }
    }
}

enum RealtimeSessionState: Equatable {
    case idle
    case connecting
    case listening
    case assistantSpeaking
    case done
    case failed(RealtimeSessionError)
}

/// One caption line. Text direction is decided per line from its script (residents code-switch).
struct VoiceCaption: Identifiable, Equatable {
    enum Speaker: Equatable { case assistant, resident }

    let id: String
    let speaker: Speaker
    var text: String
    var isFinal: Bool

    var isRightToLeft: Bool { RealtimeText.containsArabic(text) }
}

/// Drives one OpenAI Realtime voice interview over WebRTC.
///
/// Flow: mic permission → ephemeral client secret (instructions + tools) → peer connection + SDP exchange →
/// data channel open → enable input transcription → `response.create` so the assistant greets first.
@MainActor
final class RealtimeSession: ObservableObject {
    static let voice = "marin"
    /// Unverified against the live API (see docs/DISCOVERIES). Only affects user captions if wrong.
    static let transcriptionModel = "gpt-4o-transcribe"
    static let channelOpenTimeout: TimeInterval = 15
    /// Max wait for the spoken thank-you after `submit_report` before handing the report back.
    static let completionGrace: TimeInterval = 8

    @Published private(set) var state: RealtimeSessionState = .idle
    @Published private(set) var captions: [VoiceCaption] = []
    @Published private(set) var assistantLevel: Float = 0
    @Published private(set) var residentLevel: Float = 0
    @Published var isMuted = false {
        didSet { peer?.setMicEnabled(!isMuted) }
    }

    var onComplete: ((SubmitReportArgs) -> Void)?
    var onUrgent: ((String) -> Void)?

    private let context: InterviewContext
    private let keyProvider: APIKeyProvider
    private let parser = RealtimeEventParser()
    private let logger = Logger(subsystem: "io.fomy.hoth", category: "RealtimeSession")

    private var peer: RealtimePeer?
    private var levelTimer: Timer?
    private var openTimeoutTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var hasGreeted = false
    /// Set while `start()` awaits permission / the client secret, so a double tap cannot open two calls.
    private var isStarting = false

    /// Calls seen (from `function_call_arguments.done`) but not yet answered; answered on `response.done`.
    private var pendingCalls: [String: RealtimeFunctionCall] = [:]
    private var answeredCallIds: Set<String> = []
    private var urgentCallIds: Set<String> = []
    private var submittedReport: SubmitReportArgs?
    private var thankYouStarted = false
    private var thankYouAudioStarted = false

    init(context: InterviewContext, keyProvider: APIKeyProvider) {
        self.context = context
        self.keyProvider = keyProvider
    }

    // MARK: Lifecycle

    func start() async {
        guard !isStarting, state == .idle || isFailed else { return }
        isStarting = true
        defer { isStarting = false }
        resetConversation()
        state = .connecting

        // Key first: without one, asking for the microphone would only lead to a dead end.
        let key = try? await keyProvider.apiKey()
        guard let key, !key.isEmpty else { return fail(.missingKey) }
        guard await VoiceMicPermission.request() else { return fail(.microphoneDenied) }

        let prompts: Prompts
        do {
            prompts = try Prompts(bundle: .main)
        } catch {
            logger.error("prompts.json failed to load: \(String(describing: error), privacy: .public)")
            return fail(.promptsUnavailable)
        }
        let instructions = RealtimeInstructions.build(personaTemplate: prompts.voicePersona, context: context)

        do {
            // Same key source as every other OpenAI call (AppServices.shared.keyProvider by default).
            let client = OpenAIClient(keyProvider: keyProvider)
            let secret = try await client.createRealtimeClientSecret(
                model: AppServices.shared.realtimeModel,
                instructions: instructions,
                tools: prompts.realtimeTools,
                voice: Self.voice)
            guard state == .connecting else { return }  // ended while waiting

            try RealtimePeer.configureAudioSession()
            let peer = RealtimePeer()
            wire(peer)
            self.peer = peer
            try await peer.connect(ephemeralKey: secret.value)
            guard state == .connecting else { return }
            peer.setMicEnabled(!isMuted)
            startOpenTimeout()
            if peer.isChannelOpen { channelDidOpen() }
        } catch let error as OpenAIError {
            logger.error("Realtime client secret failed: \(error.description, privacy: .public)")
            fail(Self.map(error))
        } catch let error as RealtimePeerError {
            logger.error("Realtime transport failed: \(String(describing: error), privacy: .public)")
            fail(.connectionFailed(String(describing: error)))
        } catch {
            logger.error("Realtime start failed: \(error.localizedDescription, privacy: .public)")
            fail(.connectionFailed(error.localizedDescription))
        }
    }

    /// Ends the call (user tapped End, or the view disappeared). Safe to call repeatedly.
    func end() {
        guard state != .done, !isFailed else { return teardown() }
        teardown()
        // Without a submitted report "done" would be misleading: offer typing or a retry instead.
        state = submittedReport == nil ? .failed(.endedEarly) : .done
        if let report = submittedReport { onComplete?(report) }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(_ error: RealtimeSessionError) {
        teardown()
        state = .failed(error)
    }

    private func teardown() {
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        completionTask?.cancel()
        completionTask = nil
        levelTimer?.invalidate()
        levelTimer = nil
        if let peer {
            peer.close()
            RealtimePeer.deactivateAudioSession()
        }
        peer = nil
        assistantLevel = 0
        residentLevel = 0
    }

    private func resetConversation() {
        captions = []
        pendingCalls = [:]
        answeredCallIds = []
        urgentCallIds = []
        submittedReport = nil
        thankYouStarted = false
        thankYouAudioStarted = false
        hasGreeted = false
    }

    private static func map(_ error: OpenAIError) -> RealtimeSessionError {
        switch error {
        case .missingKey: return .missingKey
        case .invalidKey: return .invalidKey
        case .network: return .network
        default: return .connectionFailed(error.description)
        }
    }

    // MARK: Transport wiring

    private func wire(_ peer: RealtimePeer) {
        peer.onMessage = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        peer.onChannelOpen = { [weak self] in
            Task { @MainActor in self?.channelDidOpen() }
        }
        peer.onDisconnected = { [weak self] reason in
            Task { @MainActor in self?.transportDropped(reason) }
        }
    }

    private func startOpenTimeout() {
        openTimeoutTask?.cancel()
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.channelOpenTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            self.fail(.timedOut)
        }
    }

    private func channelDidOpen() {
        guard !hasGreeted, let peer, state == .connecting else { return }
        hasGreeted = true
        openTimeoutTask?.cancel()
        // Separate update so a bad transcription model id cannot break the instructions or tools.
        peer.send(RealtimeEventParser.enableInputTranscription(model: Self.transcriptionModel))
        // The assistant speaks first and references what the photo analysis found.
        peer.send(RealtimeEventParser.responseCreate())
        state = .listening
        startLevelMetering()
    }

    private func transportDropped(_ reason: String) {
        switch state {
        case .done, .failed, .idle:
            return
        case .connecting:
            fail(.connectionFailed(reason))
        case .listening, .assistantSpeaking:
            // If the report is already in hand, deliver it rather than losing it.
            if let report = submittedReport { return finish(with: report) }
            fail(.connectionFailed(reason))
        }
    }

    private func startLevelMetering() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLevels() }
        }
    }

    private func sampleLevels() {
        guard let peer else { return }
        peer.audioLevels { [weak self] assistant, resident in
            Task { @MainActor in
                guard let self else { return }
                self.assistantLevel = assistant
                self.residentLevel = self.isMuted ? 0 : resident
            }
        }
    }

    // MARK: Server events

    func handle(_ text: String) {
        let event: RealtimeServerEvent
        do {
            event = try parser.parse(text)
        } catch {
            logger.debug("Ignoring non-event data channel message")
            return
        }
        apply(event)
    }

    private func apply(_ event: RealtimeServerEvent) {
        guard state != .done, !isFailed else { return }
        switch event {
        case .assistantTranscriptDelta(let itemId, let delta):
            appendCaption(id: itemId, speaker: .assistant, delta: delta)
            state = .assistantSpeaking
        case .assistantTranscriptDone(let itemId, let transcript):
            finalizeCaption(id: itemId, speaker: .assistant, text: transcript)
        case .userSpeechStarted(let itemId):
            placeholderCaption(id: itemId)
            state = .listening
        case .userTranscriptDelta(let itemId, let delta):
            appendCaption(id: itemId, speaker: .resident, delta: delta)
        case .userTranscriptDone(let itemId, let transcript):
            finalizeCaption(id: itemId, speaker: .resident, text: transcript)
        case .assistantAudioStarted:
            state = .assistantSpeaking
            if thankYouStarted { thankYouAudioStarted = true }
        case .assistantAudioStopped:
            state = .listening
            if thankYouAudioStarted, let report = submittedReport { finish(with: report) }
        case .responseStarted:
            if submittedReport != nil { thankYouStarted = true }
        case .functionCallArgumentsDone(let call):
            noteCall(call)
        case .responseDone(let calls):
            calls.forEach(noteCall)
            answerPendingCalls()
        case .serverError(let message):
            // Non-fatal (e.g. an unsupported transcription model); the call keeps going.
            logger.error("Realtime server error: \(message, privacy: .public)")
        case .sessionReady, .userSpeechStopped, .ignored:
            break
        }
    }

    // MARK: Tool calls

    /// Records a call once; `flag_urgent` surfaces immediately so the safety sheet is not delayed.
    private func noteCall(_ call: RealtimeFunctionCall) {
        guard !answeredCallIds.contains(call.callId) else { return }
        pendingCalls[call.callId] = call
        if call.name == "flag_urgent", urgentCallIds.insert(call.callId).inserted {
            onUrgent?(RealtimeEventParser.urgentReason(fromArguments: call.arguments))
        }
    }

    /// Replies to every pending call with `function_call_output`, then one `response.create`.
    private func answerPendingCalls() {
        guard !pendingCalls.isEmpty, let peer else { return }
        let calls = pendingCalls.values.sorted { $0.callId < $1.callId }
        pendingCalls = [:]
        for call in calls {
            answeredCallIds.insert(call.callId)
            peer.send(RealtimeEventParser.functionCallOutput(callId: call.callId, output: output(for: call)))
        }
        peer.send(RealtimeEventParser.responseCreate())
    }

    private func output(for call: RealtimeFunctionCall) -> [String: Any] {
        switch call.name {
        case "submit_report":
            do {
                let report = try JSONDecoder().decode(SubmitReportArgs.self, from: Data(call.arguments.utf8))
                submittedReport = report
                thankYouStarted = false
                thankYouAudioStarted = false
                scheduleCompletionFallback(report)
                return ["ok": true, "status": "submitted",
                        "next": "Thank the resident in one short line in their language. Do not ask anything else."]
            } catch {
                logger.error("submit_report arguments did not decode: \(String(describing: error), privacy: .public)")
                return ["ok": false,
                        "error": "Arguments invalid. Call submit_report again with all required fields: summary_en, summary_ar, answers, user_language, wants_to_post, anonymous."]
            }
        case "flag_urgent":
            return ["ok": true, "status": "flagged_urgent",
                    "next": "Calmly tell the resident not to touch it, keep people and children away, and call 999 now if anyone is at risk. No more questions until they say they are safe."]
        default:
            return ["ok": false, "error": "Unknown tool \(call.name)."]
        }
    }

    /// Hands the report back after the spoken thank-you, or after a grace period if audio events never arrive.
    private func scheduleCompletionFallback(_ report: SubmitReportArgs) {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.completionGrace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.finish(with: report)
        }
    }

    private func finish(with report: SubmitReportArgs) {
        guard state != .done, !isFailed else { return }
        state = .done
        teardown()
        onComplete?(report)
    }

    // MARK: Captions

    private func placeholderCaption(id: String) {
        guard !id.isEmpty, !captions.contains(where: { $0.id == id }) else { return }
        captions.append(VoiceCaption(id: id, speaker: .resident, text: "", isFinal: false))
    }

    private func appendCaption(id: String, speaker: VoiceCaption.Speaker, delta: String) {
        if id.isEmpty {
            // No item id: keep growing the last open line of the same speaker.
            if let last = captions.indices.last, captions[last].speaker == speaker, !captions[last].isFinal {
                captions[last].text += delta
            } else {
                captions.append(VoiceCaption(id: UUID().uuidString, speaker: speaker, text: delta, isFinal: false))
            }
            return
        }
        if let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].text += delta
        } else {
            captions.append(VoiceCaption(id: id, speaker: speaker, text: delta, isFinal: false))
        }
    }

    private func finalizeCaption(id: String, speaker: VoiceCaption.Speaker, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = captions.firstIndex(where: { $0.id == id && !id.isEmpty }) {
            if !trimmed.isEmpty { captions[index].text = trimmed }
            captions[index].isFinal = true
        } else if !trimmed.isEmpty {
            captions.append(VoiceCaption(id: id.isEmpty ? UUID().uuidString : id,
                                         speaker: speaker, text: trimmed, isFinal: true))
        }
    }
}
