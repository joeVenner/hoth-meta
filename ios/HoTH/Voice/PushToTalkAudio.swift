import AVFoundation
import Foundation
import HoTHCore
import OSLog

// MARK: - Audio session

/// `.playAndRecord` + `.defaultToSpeaker`, set once on first voice use (not at launch, so other apps'
/// audio is left alone until the resident picks voice).
@MainActor
enum VoiceAudioSession {
    private static var isConfigured = false

    static func configureIfNeeded() throws {
        guard !isConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        isConfigured = true
    }
}

// MARK: - Recorder

/// What Muse Voice Transcribe file mode accepts: mono 16-bit little-endian PCM at 24 kHz, WAV container.
enum PushToTalkAudio {
    static let sampleRate = 24_000

    static var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// A fresh temp file per turn; `.wav` makes AVAudioRecorder write a RIFF/WAVE container.
    static func temporaryRecordingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hoth-ptt-\(UUID().uuidString).wav")
    }

    /// Average power in dBFS (-160...0) to 0...1; below -50 dB is silence.
    static func normalizedLevel(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let floor: Float = -50
        return max(0, min(1, (decibels - floor) / -floor))
    }
}

enum VoiceRecorderError: Error {
    case couldNotStart
}

/// `AVAudioRecorder` with metering, one temp WAV per turn.
@MainActor
final class WAVVoiceRecorder: VoiceRecording {
    private var recorder: AVAudioRecorder?

    func start() throws {
        cancel()
        let url = PushToTalkAudio.temporaryRecordingURL()
        let recorder = try AVAudioRecorder(url: url, settings: PushToTalkAudio.recorderSettings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            PushToTalkModel.removeTemporaryFile(url)
            throw VoiceRecorderError.couldNotStart
        }
        self.recorder = recorder
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        self.recorder = nil
        recorder.stop()
        return recorder.url
    }

    func cancel() {
        guard let recorder else { return }
        self.recorder = nil
        recorder.stop()
        PushToTalkModel.removeTemporaryFile(recorder.url)
    }

    var level: Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return PushToTalkAudio.normalizedLevel(decibels: recorder.averagePower(forChannel: 0))
    }
}

// MARK: - Speaker

/// Spoken replies in the reply's own language (Meta has no TTS, so this is on device).
enum SpeechVoice {
    static let arabic = "ar-SA"
    static let english = "en-US"

    /// Arabic voice when the reply is mostly Arabic script, so a code-switching resident hears each
    /// reply in the language it was written in.
    static func languageCode(for text: String) -> String {
        var arabicLetters = 0
        var latinLetters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                arabicLetters += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                latinLetters += 1
            default:
                break
            }
        }
        return arabicLetters > latinLetters ? arabic : english
    }

    /// Drops emoji (the synthesizer reads them out by name) and tidies the spacing they leave.
    static func speakable(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            let properties = scalar.properties
            if properties.isEmojiPresentation { return false }
            // Text-default emoji such as ❤ (digits, # and * are emoji too and must stay).
            if properties.isEmoji && scalar.value > 0x238C { return false }
            return scalar.value != 0x200D && scalar.value != 0xFE0F
        }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// nil (the system default voice) when the simulator or device has no voice for the language.
    static func voice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: languageCode)
    }
}

/// `AVSpeechSynthesizer` behind an async `speak` that returns on finish or stop.
@MainActor
final class SystemSpeechSpeaker: NSObject, SpeechSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoice.voice(for: languageCode)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.current = utterance
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        // Unconditional: right after `speak` the synthesizer may not report `isSpeaking` yet, and the
        // queued utterance would then play into the resident's recording.
        synthesizer.stopSpeaking(at: .immediate)
        resume(for: current)
    }

    /// Resumes only for the utterance being awaited: a late `didCancel` from a stopped utterance must
    /// not end the next one early.
    private func resume(for utterance: AVSpeechUtterance?) {
        guard let utterance, utterance === current else { return }
        current = nil
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume(for: utterance) }
    }

    // `stopSpeaking` ends with didCancel, not didFinish.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume(for: utterance) }
    }
}

// MARK: - Transcriber

/// Muse Voice Transcribe through `MetaModelClient.transcribe` (PUSH_TO_TALK, language bias from the hint).
struct MetaSpeechTranscriber: SpeechTranscribing {
    let client: MetaModelClient
    let model: String
    let languageHint: String

    func transcribe(wav: Data) async throws -> String {
        try await client.transcribe(wav: wav, model: model, languageHint: languageHint).text
    }
}
