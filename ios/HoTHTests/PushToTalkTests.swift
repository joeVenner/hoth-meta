import AVFoundation
import HoTHCore
import XCTest
@testable import HoTH

/// Push-to-talk state machine with stubbed recorder, transcriber and speaker (no mic, no network, no audio).
@MainActor
final class PushToTalkTests: XCTestCase {
    // MARK: Stubs

    private final class StubRecorder: VoiceRecording {
        var durationMs = 1_000
        var startError: Error?
        var level: Float = 0.4
        private(set) var startCount = 0
        private(set) var cancelCount = 0
        private(set) var lastURL: URL?

        func start() throws {
            if let startError { throw startError }
            startCount += 1
        }

        func stop() -> URL? {
            guard startCount > 0 else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoth-ptt-test-\(UUID().uuidString).wav")
            let pcm = Data(count: durationMs * 48)  // 24 kHz, 2 bytes per sample
            try? (WAVAudio.header(sampleRate: 24_000, dataSize: pcm.count) + pcm).write(to: url)
            lastURL = url
            return url
        }

        func cancel() { cancelCount += 1 }
    }

    private struct StubTranscriber: SpeechTranscribing {
        var result: Result<String, Error>
        func transcribe(wav: Data) async throws -> String {
            XCTAssertEqual(wav.count, 44 + 48_000, "Uploads the canonical WAV")
            return try result.get()
        }
    }

    /// Holds every transcription until the test resumes it, like a slow network.
    private final class GatedTranscriber: SpeechTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CheckedContinuation<String, Error>] = []

        var waitingCount: Int { lock.withLock { pending.count } }

        func transcribe(wav: Data) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending.append(continuation) }
            }
        }

        func resumeOldest(with result: Result<String, Error>) {
            let continuation = lock.withLock { pending.removeFirst() }
            continuation.resume(with: result)
        }
    }

    private final class StubSpeaker: SpeechSpeaking {
        private(set) var spoken: [(text: String, language: String)] = []
        private(set) var stopCount = 0
        func speak(_ text: String, languageCode: String) async { spoken.append((text, languageCode)) }
        func stop() { stopCount += 1 }
    }

    private struct Boom: Error {}

    private var clock = Date(timeIntervalSince1970: 0)
    private var micStatus: VoiceMicPermission.Status = .granted
    private var recorder: StubRecorder!
    private var speaker: StubSpeaker!
    private var prepareCount = 0

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 0)
        micStatus = .granted
        recorder = StubRecorder()
        speaker = StubSpeaker()
        prepareCount = 0
    }

    private func makeModel(transcript: Result<String, Error> = .success("The swing chain is broken"),
                           hasTranscriber: Bool = true, startsInVoice: Bool = true,
                           grantOnRequest: Bool = true, transcriber: SpeechTranscribing? = nil) -> PushToTalkModel {
        PushToTalkModel(
            transcriber: hasTranscriber ? (transcriber ?? StubTranscriber(result: transcript)) : nil,
            recorder: recorder, speaker: speaker, startsInVoice: startsInVoice,
            micStatus: { [unowned self] in self.micStatus },
            requestMic: { grantOnRequest },
            prepareAudio: { [unowned self] in self.prepareCount += 1 },
            now: { [unowned self] in self.clock })
    }

    /// Press, wait for recording to start, hold for `seconds`, release, wait for the turn to finish.
    private func hold(_ model: PushToTalkModel, for seconds: TimeInterval) async {
        model.pressBegan()
        await model.work?.value
        clock.addTimeInterval(seconds)
        model.pressEnded()
        await model.work?.value
    }

    // MARK: State machine

    func testHoldSendsTranscriptAndDeletesTheRecording() async throws {
        let model = makeModel()
        var sent: [String] = []
        model.onTranscript = { sent.append($0) }

        model.pressBegan()
        await model.work?.value
        XCTAssertEqual(model.phase, .listening)
        clock.addTimeInterval(1.2)
        model.pressEnded()
        XCTAssertEqual(model.phase, .transcribing)
        await model.work?.value

        XCTAssertEqual(sent, ["The swing chain is broken"])
        XCTAssertEqual(model.phase, .thinking)
        let url = try XCTUnwrap(recorder.lastURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Temp WAV must be deleted after upload")
    }

    func testReplyIsSpokenThenReturnsToIdle() async {
        let model = makeModel()
        model.onTranscript = { _ in }
        await hold(model, for: 1)

        model.assistantSaid("Thanks 🙏 Is anyone hurt?")
        XCTAssertEqual(model.phase, .speaking)
        await model.speechTask?.value

        XCTAssertEqual(speaker.spoken.map(\.text), ["Thanks Is anyone hurt?"])
        XCTAssertEqual(speaker.spoken.map(\.language), ["en-US"])
        XCTAssertEqual(model.phase, .idle)
    }

    func testBackToBackRepliesAreSpokenInOrderAndInTheirLanguage() async {
        let model = makeModel()
        model.assistantSaid("أنا المساعد الذكي في HoTH.")
        model.assistantSaid("Is it near a school?")
        await model.speechTask?.value
        XCTAssertEqual(speaker.spoken.map(\.language), ["ar-SA", "en-US"])
    }

    func testQuickTapLatchesAndSecondTapSends() async {
        let model = makeModel()
        var sent: [String] = []
        model.onTranscript = { sent.append($0) }

        model.pressBegan()
        await model.work?.value
        clock.addTimeInterval(0.1)
        model.pressEnded()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertTrue(model.isLatched)

        clock.addTimeInterval(2)
        model.pressBegan()  // second tap
        await model.work?.value
        model.pressEnded()
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(model.isLatched)
    }

    func testReleaseBeforeRecordingStartsLatches() async {
        let model = makeModel()
        model.pressBegan()
        model.pressEnded()  // before the start task ran
        await model.work?.value
        XCTAssertEqual(model.phase, .listening)
        XCTAssertTrue(model.isLatched)
    }

    func testToggleForAccessibilityStartsAndSends() async {
        let model = makeModel()
        var sent: [String] = []
        model.onTranscript = { sent.append($0) }
        model.toggleRecording()
        await model.work?.value
        XCTAssertEqual(model.phase, .listening)
        clock.addTimeInterval(1)
        model.toggleRecording()
        await model.work?.value
        XCTAssertEqual(sent.count, 1)
    }

    func testPressWhileSpeakingInterruptsTheSpeaker() async {
        let model = makeModel()
        model.assistantSaid("A long question")
        model.pressBegan()
        XCTAssertEqual(speaker.stopCount, 1, "Barge-in stops the reply before the mic opens")
        await model.work?.value
        await model.speechTask?.value
        XCTAssertEqual(model.phase, .listening)
    }

    func testTooShortRecordingAsksAgainWithoutTranscribing() async {
        recorder.durationMs = 200
        let model = makeModel()
        var sent: [String] = []
        model.onTranscript = { sent.append($0) }
        await hold(model, for: 1)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.notice, .didNotCatch)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.isVoiceMode, "A missed turn stays in voice")
    }

    func testEmptyTranscriptAsksAgain() async {
        let model = makeModel(transcript: .success("  \n"))
        await hold(model, for: 1)
        XCTAssertEqual(model.notice, .didNotCatch)
        XCTAssertTrue(model.isVoiceMode)
    }

    func testTranscriptionErrorFallsBackToTyping() async throws {
        let model = makeModel(transcript: .failure(ModelAPIError.http(500, "server error")))
        await hold(model, for: 1)
        XCTAssertEqual(model.notice, .transcriptionFailed)
        XCTAssertFalse(model.isVoiceMode)
        XCTAssertEqual(model.phase, .idle)
        let url = try XCTUnwrap(recorder.lastURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Deleted on the error path too")
    }

    func testRecorderErrorFallsBackToTyping() async {
        recorder.startError = Boom()
        let model = makeModel()
        model.pressBegan()
        await model.work?.value
        XCTAssertEqual(model.notice, .recordingFailed)
        XCTAssertFalse(model.isVoiceMode)
    }

    func testDeniedMicFallsBackToTyping() async {
        micStatus = .denied
        let model = makeModel()
        model.pressBegan()
        await model.work?.value
        XCTAssertEqual(model.notice, .micDenied)
        XCTAssertFalse(model.isVoiceMode)
        XCTAssertEqual(recorder.startCount, 0)
    }

    func testFirstPermissionPromptDoesNotStartRecording() async {
        micStatus = .undetermined
        let model = makeModel()
        model.pressBegan()
        await model.work?.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertNil(model.notice)

        let declined = makeModel(grantOnRequest: false)
        declined.pressBegan()
        await declined.work?.value
        XCTAssertEqual(declined.notice, .micDenied)
    }

    func testWithoutTranscriberVoiceIsUnavailable() {
        let model = makeModel(hasTranscriber: false)
        XCTAssertFalse(model.isAvailable)
        XCTAssertFalse(model.isVoiceMode)
        model.switchToVoice()
        XCTAssertFalse(model.isVoiceMode)
        model.pressBegan()
        XCTAssertNil(model.work)
    }

    func testTypingModeDoesNotSpeakAndVoiceFirstOffStartsTyping() async {
        let model = makeModel(startsInVoice: false)
        XCTAssertFalse(model.isVoiceMode)
        model.assistantSaid("Hello")
        XCTAssertNil(model.speechTask)
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertEqual(prepareCount, 0, "Typing leaves the audio session alone")

        model.switchToVoice()
        model.assistantSaid("Hello")
        await model.speechTask?.value
        XCTAssertEqual(speaker.spoken.count, 1)
    }

    func testSpokenReplySetsUpTheAudioSessionBeforeAnyPress() async {
        let model = makeModel()
        model.assistantSaid("I'm HoTH's AI assistant.")
        XCTAssertEqual(prepareCount, 1, "The opening reply must not play under the muted default category")
        await model.speechTask?.value
        XCTAssertEqual(speaker.spoken.count, 1)
    }

    func testAppleWAVWriterOutputPassesTheUploadCheck() throws {
        let url = PushToTalkAudio.temporaryRecordingURL()
        defer { PushToTalkModel.removeTemporaryFile(url) }
        try {
            // Scoped so the file is closed (header finalized) before it is read back.
            let file = try AVAudioFile(forWriting: url, settings: PushToTalkAudio.recorderSettings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            let frames = AVAudioFrameCount(PushToTalkAudio.sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            try file.write(from: buffer)
        }()
        let wav = try WAVAudio.canonicalPCM16(Data(contentsOf: url))
        XCTAssertEqual(wav.sampleRate, 24_000)
        XCTAssertEqual(wav.durationMs, 1000)
        XCTAssertEqual(wav.data.count, 44 + 48_000)
    }

    func testSwitchingToTypingCancelsRecording() async {
        let model = makeModel()
        model.pressBegan()
        await model.work?.value
        model.switchToTyping()
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isVoiceMode)
    }

    /// Records one turn and returns once the gated transcriber holds its request.
    private func startTranscribing(_ model: PushToTalkModel, gate: GatedTranscriber) async {
        let waitingBefore = gate.waitingCount
        model.pressBegan()
        await model.work?.value
        clock.addTimeInterval(1)
        model.pressEnded()
        XCTAssertEqual(model.phase, .transcribing)
        for _ in 0..<1_000 where gate.waitingCount == waitingBefore { await Task.yield() }
        XCTAssertEqual(gate.waitingCount, waitingBefore + 1, "Transcription request never started")
    }

    func testSwitchingToTypingDuringTranscriptionIsNotAFailure() async {
        for late in [Result<String, Error>.success("late words"), .failure(ModelAPIError.network("-999"))] {
            let gate = GatedTranscriber()
            let model = makeModel(transcriber: gate)
            var sent: [String] = []
            model.onTranscript = { sent.append($0) }
            await startTranscribing(model, gate: gate)
            let inFlight = model.work
            let stopsBefore = speaker.stopCount

            model.switchToTyping()
            gate.resumeOldest(with: late)
            await inFlight?.value

            XCTAssertNil(model.notice, "Typing on purpose must not show a voice error")
            XCTAssertEqual(sent, [])
            XCTAssertFalse(model.isVoiceMode)
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(speaker.stopCount, stopsBefore + 1, "Only the switch itself stops the speaker")
        }
    }

    func testStaleTranscriptFromAnAbandonedTurnIsDropped() async {
        let gate = GatedTranscriber()
        let model = makeModel(transcriber: gate)
        var sent: [String] = []
        model.onTranscript = { sent.append($0) }
        await startTranscribing(model, gate: gate)
        let firstTurn = model.work

        model.switchToTyping()
        model.switchToVoice()
        await startTranscribing(model, gate: gate)
        let secondTurn = model.work

        gate.resumeOldest(with: .success("old turn"))
        await firstTurn?.value
        XCTAssertEqual(sent, [])
        XCTAssertEqual(model.phase, .transcribing, "The new turn is still waiting")

        gate.resumeOldest(with: .success("new turn"))
        await secondTurn?.value
        XCTAssertEqual(sent, ["new turn"])
        XCTAssertEqual(model.phase, .thinking)
    }

    func testFinishedConversationEndsAfterLastReply() async {
        let model = makeModel()
        model.assistantSaid("Done — your ticket is ready. Thank you 💛")
        model.conversationFinished()
        await model.speechTask?.value
        XCTAssertEqual(model.phase, .finished)
        XCTAssertFalse(model.canRecord)
    }

    func testChatSettledWithoutReplyLeavesThinking() async {
        let model = makeModel()
        model.onTranscript = { _ in }
        await hold(model, for: 1)
        XCTAssertEqual(model.phase, .thinking)
        model.chatSettled()
        XCTAssertEqual(model.phase, .idle)
    }

    func testPhasesMapToOrbStates() {
        XCTAssertEqual(PushToTalkModel.Phase.listening.orbState, .listening)
        XCTAssertEqual(PushToTalkModel.Phase.transcribing.orbState, .transcribing)
        XCTAssertEqual(PushToTalkModel.Phase.thinking.orbState, .thinking)
        XCTAssertEqual(PushToTalkModel.Phase.speaking.orbState, .assistantSpeaking)
        XCTAssertEqual(PushToTalkModel.Phase.finished.orbState, .done)
    }

    // MARK: Chat wiring

    func testChatIntakeReportsEveryAssistantMessage() throws {
        let analysis = DemoSamples.waste.cannedAnalysis
        let context = InterviewContext(
            analysis: analysis,
            priority: PriorityAgent.decide(PriorityInput(vision: analysis, answers: [:], nearbyPlace: nil)),
            language: "ar", slotQuestions: [])
        let chat = ChatIntakeModel(context: context, slots: [], client: nil, prompts: try Prompts(bundle: .main),
                                   onComplete: { _ in }, onUrgent: { _ in })
        var heard: [String] = []
        chat.onAssistantMessage = { heard.append($0) }
        chat.start()
        XCTAssertEqual(heard, chat.bubbles.filter { $0.role == .assistant }.map(\.text))
        XCTAssertFalse(heard.isEmpty)
        XCTAssertEqual(SpeechVoice.languageCode(for: heard[0]), "ar-SA")
    }

    // MARK: Audio settings and voices

    func testRecorderSettingsAreMono16BitPCMAt24kHz() {
        let settings = PushToTalkAudio.recorderSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 24_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
        XCTAssertTrue(WAVAudio.supportedSampleRates.contains(PushToTalkAudio.sampleRate))
        XCTAssertEqual(PushToTalkAudio.temporaryRecordingURL().pathExtension, "wav")
    }

    func testMeterLevelIsNormalized() {
        XCTAssertEqual(PushToTalkAudio.normalizedLevel(decibels: 0), 1)
        XCTAssertEqual(PushToTalkAudio.normalizedLevel(decibels: -25), 0.5)
        XCTAssertEqual(PushToTalkAudio.normalizedLevel(decibels: -160), 0)
        XCTAssertEqual(PushToTalkAudio.normalizedLevel(decibels: -.infinity), 0)
    }

    func testReplyLanguagePicksTheVoice() {
        XCTAssertEqual(SpeechVoice.languageCode(for: "سلامتكم أهم شي. لا تلمسها."), "ar-SA")
        XCTAssertEqual(SpeechVoice.languageCode(for: "Your safety comes first."), "en-US")
        // Mostly Arabic with an English brand name, and the other way round.
        XCTAssertEqual(SpeechVoice.languageCode(for: "أنا المساعد الذكي في HoTH"), "ar-SA")
        XCTAssertEqual(SpeechVoice.languageCode(for: "I can see a broken زحليقة in the park"), "en-US")
        XCTAssertEqual(SpeechVoice.languageCode(for: "🙏 💛"), "en-US")
        XCTAssertEqual(SpeechVoice.languageCode(for: ""), "en-US")
    }

    func testSpeakableDropsEmojiButKeepsDigits() {
        XCTAssertEqual(SpeechVoice.speakable("Done — your ticket is ready. Thank you 💛"),
                       "Done — your ticket is ready. Thank you")
        XCTAssertEqual(SpeechVoice.speakable("شكراً إنك انتبهت 🙏 أشوف"), "شكراً إنك انتبهت أشوف")
        XCTAssertEqual(SpeechVoice.speakable("Call 999 ❤️ #1"), "Call 999 #1")
        XCTAssertEqual(SpeechVoice.speakable("👍🏽"), "")
    }
}
