import Foundation
import HoTHCore
import OSLog
import SwiftUI

// MARK: - Seams (real AVFoundation types in PushToTalkAudio.swift; stubs in tests)

/// Records one push-to-talk turn to a temporary WAV.
@MainActor
protocol VoiceRecording: AnyObject {
    func start() throws
    /// Stops and hands over the file (the caller deletes it); nil when nothing was recording.
    func stop() -> URL?
    /// Stops and deletes the file.
    func cancel()
    /// 0...1 input level for the orb.
    var level: Float { get }
}

/// Turns one recorded turn into text.
protocol SpeechTranscribing: Sendable {
    func transcribe(wav: Data) async throws -> String
}

/// Speaks an assistant reply; returns when it finished or was stopped.
@MainActor
protocol SpeechSpeaking: AnyObject {
    func speak(_ text: String, languageCode: String) async
    func stop()
}

/// Why voice could not be used for a turn. Hard failures send the resident to typing.
enum PushToTalkNotice: Equatable {
    case micDenied
    case recordingFailed
    case transcriptionFailed
    /// Too short or silent: stay in voice and try again.
    case didNotCatch

    var fallsBackToTyping: Bool { self != .didNotCatch }

    var message: LocalizedStringKey {
        switch self {
        case .micDenied: return "Microphone access is off. Turn it on in Settings, or type your answer."
        case .recordingFailed: return "Couldn't record audio. Please type your answer."
        case .transcriptionFailed: return "Couldn't turn your voice into text right now. Please type your answer."
        case .didNotCatch: return "I didn't catch that. Hold the button and speak."
        }
    }
}

// MARK: - Model

/// Push-to-talk interview voice: hold (or tap, then tap again) to record, Muse Voice Transcribe turns the
/// turn into text for `ChatIntakeModel`, and each assistant reply is read aloud on device.
///
/// The chat model still drives the conversation; this type only owns the mic, the speaker and the
/// listening → transcribing → thinking → speaking cycle.
@MainActor
final class PushToTalkModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var notice: PushToTalkNotice?
    /// True after a quick tap started recording: the next tap stops it.
    @Published private(set) var isLatched = false
    /// Voice layout and spoken replies; off means the resident types.
    @Published private(set) var isVoiceMode: Bool

    /// False without a transcriber (no key, UI tests): the mic is hidden.
    let isAvailable: Bool
    /// The transcript of a finished turn, sent as the resident's chat message.
    var onTranscript: ((String) -> Void)?

    private let transcriber: SpeechTranscribing?
    private let recorder: VoiceRecording
    private let speaker: SpeechSpeaking
    private let micStatus: () -> VoiceMicPermission.Status
    private let requestMic: () async -> Bool
    private let prepareAudio: @MainActor () throws -> Void
    private let now: () -> Date

    /// A release sooner than this after the press counts as a tap (recording stays on).
    let tapThreshold: TimeInterval
    /// Shorter turns are treated as an accidental press.
    let minimumDurationMs: Int
    /// Recording stops on its own after this long.
    let maximumDuration: TimeInterval

    private var recordingStartedAt: Date?
    /// The finger is still down; a release before recording actually starts latches it on.
    private var isPressed = false
    private var isConversationFinished = false
    private var speechQueue: [String] = []
    private var meterTask: Task<Void, Never>?
    /// Exposed so tests can await the press / release work.
    private(set) var work: Task<Void, Never>?
    private(set) var speechTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "PushToTalk")

    init(transcriber: SpeechTranscribing?, recorder: VoiceRecording, speaker: SpeechSpeaking,
         startsInVoice: Bool,
         micStatus: @escaping () -> VoiceMicPermission.Status = { VoiceMicPermission.status },
         requestMic: @escaping () async -> Bool = { await VoiceMicPermission.request() },
         prepareAudio: @escaping @MainActor () throws -> Void = { try VoiceAudioSession.configureIfNeeded() },
         now: @escaping () -> Date = Date.init,
         tapThreshold: TimeInterval = 0.35, minimumDurationMs: Int = 400, maximumDuration: TimeInterval = 60) {
        self.transcriber = transcriber
        self.isAvailable = transcriber != nil
        self.recorder = recorder
        self.speaker = speaker
        self.micStatus = micStatus
        self.requestMic = requestMic
        self.prepareAudio = prepareAudio
        self.now = now
        self.tapThreshold = tapThreshold
        self.minimumDurationMs = minimumDurationMs
        self.maximumDuration = maximumDuration
        self.isVoiceMode = startsInVoice && transcriber != nil
    }

    /// The mic button can start a turn.
    var canRecord: Bool {
        isAvailable && isVoiceMode && (phase == .idle || phase == .speaking || phase == .listening)
    }

    // MARK: Mode

    func switchToVoice() {
        guard isAvailable else { return }
        notice = nil
        isVoiceMode = true
    }

    func switchToTyping() {
        cancelTurn()
        isVoiceMode = false
        if phase != .finished { phase = .idle }
    }

    // MARK: Press / release

    /// Finger down on the mic (or the first tap).
    func pressBegan() {
        guard canRecord, !isPressed else { return }
        if phase == .listening {
            if isLatched { finishRecording() }
            return
        }
        isPressed = true
        stopSpeaking()
        notice = nil
        work = Task { await beginRecording() }
    }

    /// Finger up. A quick release latches recording on; a hold ends the turn.
    func pressEnded() {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, phase == .listening, !isLatched else { return }
        if let start = recordingStartedAt, now().timeIntervalSince(start) < tapThreshold {
            isLatched = true
            return
        }
        finishRecording()
    }

    /// One activation for VoiceOver and Switch Control: start latched, or send the turn.
    func toggleRecording() {
        if phase == .listening {
            isPressed = false
            finishRecording()
            return
        }
        pressBegan()
        isPressed = false
    }

    private func beginRecording() async {
        switch micStatus() {
        case .granted:
            break
        case .denied:
            return fail(.micDenied, detail: "microphone permission denied")
        case .undetermined:
            // The system prompt took the press; start on the next one so recording never begins unasked.
            let granted = await requestMic()
            isPressed = false
            if granted { phase = .idle } else { fail(.micDenied, detail: "microphone permission declined") }
            return
        }
        do {
            try prepareAudio()
            try recorder.start()
        } catch {
            return fail(.recordingFailed, detail: String(describing: error))
        }
        recordingStartedAt = now()
        isLatched = !isPressed
        phase = .listening
        startMetering()
    }

    private func finishRecording() {
        stopMetering()
        isLatched = false
        recordingStartedAt = nil
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        phase = .transcribing
        work = Task { await transcribe(fileAt: url) }
    }

    private func transcribe(fileAt url: URL) async {
        defer { Self.removeTemporaryFile(url) }
        let wav: PCMWAV
        do {
            wav = try WAVAudio.canonicalPCM16(Data(contentsOf: url))
        } catch {
            return fail(.recordingFailed, detail: String(describing: error))
        }
        guard wav.durationMs >= minimumDurationMs else {
            notice = .didNotCatch
            phase = .idle
            return
        }
        guard let transcriber else { return fail(.transcriptionFailed, detail: "no transcriber") }
        do {
            let text = try await transcriber.transcribe(wav: wav.data).trimmingCharacters(in: .whitespacesAndNewlines)
            guard phase == .transcribing else { return }  // the resident switched to typing meanwhile
            guard !text.isEmpty else {
                notice = .didNotCatch
                phase = .idle
                return
            }
            phase = .thinking
            onTranscript?(text)
        } catch {
            fail(.transcriptionFailed, detail: String(describing: error))
        }
    }

    // MARK: Assistant side

    /// Each new assistant message. Spoken in voice mode, queued so back-to-back messages play in order.
    func assistantSaid(_ text: String) {
        guard isVoiceMode else { return }
        let speakable = SpeechVoice.speakable(text)
        guard !speakable.isEmpty else { return }
        speechQueue.append(speakable)
        guard speechTask == nil else { return }
        // Before the first press the session is still `.soloAmbient`, which the silent switch mutes.
        do {
            try prepareAudio()
        } catch {
            Self.logger.error("Audio session setup failed, speaking anyway: \(String(describing: error))")
        }
        if phase != .listening { phase = .speaking }
        speechTask = Task { await drainSpeech() }
    }

    /// The chat finished thinking; an empty answer must not leave the orb on "thinking".
    func chatSettled() {
        if phase == .thinking { phase = isConversationFinished ? .finished : .idle }
    }

    /// The interview is over: no more turns once the last reply was spoken.
    func conversationFinished() {
        isConversationFinished = true
        cancelRecording()
        if speechTask == nil { phase = .finished }
    }

    /// Barge-in, a quick reply tap, or leaving the screen.
    func stopSpeaking() {
        speechQueue.removeAll()
        speaker.stop()
    }

    /// The screen went away: release the mic and the speaker.
    func shutDown() {
        cancelTurn()
        speechTask?.cancel()
        speechTask = nil
    }

    private func drainSpeech() async {
        while !speechQueue.isEmpty, !Task.isCancelled {
            let text = speechQueue.removeFirst()
            await speaker.speak(text, languageCode: SpeechVoice.languageCode(for: text))
        }
        speechTask = nil
        if phase == .speaking { phase = isConversationFinished ? .finished : .idle }
    }

    // MARK: Helpers

    private func cancelTurn() {
        stopSpeaking()
        cancelRecording()
        work?.cancel()
        if phase == .transcribing || phase == .thinking { phase = .idle }
    }

    private func cancelRecording() {
        guard phase == .listening else { return }
        stopMetering()
        recorder.cancel()
        isLatched = false
        recordingStartedAt = nil
        phase = .idle
    }

    private func fail(_ reason: PushToTalkNotice, detail: String) {
        Self.logger.error("Push-to-talk failed (\(String(describing: reason))): \(detail)")
        stopMetering()
        recorder.cancel()
        isLatched = false
        isPressed = false
        recordingStartedAt = nil
        notice = reason
        phase = isConversationFinished ? .finished : .idle
        if reason.fallsBackToTyping {
            stopSpeaking()
            isVoiceMode = false
        }
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .listening else { return }
                self.level = self.recorder.level
                if let start = self.recordingStartedAt, self.now().timeIntervalSince(start) >= self.maximumDuration {
                    self.finishRecording()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        level = 0
    }

    static func removeTemporaryFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("Could not delete recording: \(String(describing: error))")
        }
    }
}

extension PushToTalkModel.Phase {
    var orbState: VoiceOrbState {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .speaking: return .assistantSpeaking
        case .finished: return .done
        }
    }

    /// Status line under the orb.
    func statusText(isLatched: Bool) -> LocalizedStringKey {
        switch self {
        case .idle: return "Hold to talk"
        case .listening: return isLatched ? "Listening… tap to send" : "Listening… release to send"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking… hold to interrupt"
        case .finished: return "Interview finished"
        }
    }
}
