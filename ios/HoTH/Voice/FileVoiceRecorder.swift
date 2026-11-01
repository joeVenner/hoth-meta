import Foundation
import HoTHCore
import OSLog

/// Picks the push-to-talk recorder. Release builds always get the microphone (`WAVVoiceRecorder`).
enum VoiceRecorderFactory {
    @MainActor
    static func make() -> VoiceRecording {
        #if DEBUG
        if AppServices.isDemoCaptureRun, let recorder = FileVoiceRecorder.fromEnvironment() {
            return recorder
        }
        #endif
        return WAVVoiceRecorder()
    }

    /// The mic permission check for `recorder`: a WAV playlist needs no microphone.
    @MainActor
    static func micStatus(for recorder: VoiceRecording) -> () -> VoiceMicPermission.Status {
        #if DEBUG
        if recorder is FileVoiceRecorder { return { .granted } }
        #endif
        return { VoiceMicPermission.status }
    }
}

#if DEBUG

// MARK: - Playlist

/// One validated push-to-talk clip and its loudness envelope (for the orb).
struct FileVoiceClip: Equatable {
    let url: URL
    let durationMs: Int
    /// 0...1 level per `FileVoicePlaylist.envelopeWindow` of audio.
    let envelope: [Float]
}

/// DEBUG-only: loads the capture WAV playlist from a host directory (`HOTH_PTT_WAV_DIR`).
///
/// The directory is untrusted input: it must be an absolute path to an existing directory, and every
/// `.wav` in it must be a regular file (no symlinks), inside the directory once symlinks in the
/// directory path are resolved, under the size cap, and a canonical mono 16-bit 16/24 kHz WAV of at
/// least 400 ms. One bad clip rejects the whole playlist, so a broken file can never shift the order
/// of the answers. Other files (`.DS_Store`, a `README`) are ignored.
enum FileVoicePlaylist {
    enum LoadError: Error, Equatable, CustomStringConvertible {
        case notAbsolute(String)
        case notADirectory(String)
        case unreadable(String)
        case empty(String)
        case notRegularFile(String)
        case outsideDirectory(String)
        case tooLarge(String, bytes: Int)
        case invalidAudio(String, detail: String)
        case tooShort(String, durationMs: Int)

        var description: String {
            switch self {
            case .notAbsolute(let path): return "WAV directory must be an absolute path: \(path)"
            case .notADirectory(let path): return "WAV directory does not exist or is not a directory: \(path)"
            case .unreadable(let path): return "WAV directory could not be listed: \(path)"
            case .empty(let path): return "WAV directory has no .wav clips: \(path)"
            case .notRegularFile(let name): return "Clip is not a regular file (symlink?): \(name)"
            case .outsideDirectory(let name): return "Clip resolves outside the WAV directory: \(name)"
            case .tooLarge(let name, let bytes): return "Clip is too large (\(bytes) bytes): \(name)"
            case .invalidAudio(let name, let detail): return "Clip is not mono 16-bit 16/24 kHz WAV (\(detail)): \(name)"
            case .tooShort(let name, let durationMs): return "Clip is shorter than 400 ms (\(durationMs) ms): \(name)"
            }
        }
    }

    /// 60 s of 24 kHz mono 16-bit audio is about 2.9 MB; anything far bigger is not a push-to-talk turn.
    static let defaultMaxBytes = 8 * 1024 * 1024
    /// Same floor as `PushToTalkModel.minimumDurationMs`: shorter reads as "didn't catch that".
    static let minimumDurationMs = 400
    static let envelopeWindow: TimeInterval = 0.05

    /// Clips sorted by file name (`01_….wav`, `02_….wav`, …).
    static func load(directory path: String, maxBytes: Int = defaultMaxBytes,
                     fileManager: FileManager = .default) -> Result<[FileVoiceClip], LoadError> {
        guard path.hasPrefix("/") else { return .failure(.notAbsolute(path)) }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.notADirectory(path))
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])
        } catch {
            return .failure(.unreadable(path))
        }
        let wavs = entries
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !wavs.isEmpty else { return .failure(.empty(path)) }

        var clips: [FileVoiceClip] = []
        for url in wavs {
            switch clip(at: url, in: directory, maxBytes: maxBytes, keys: Set(keys)) {
            case .success(let clip): clips.append(clip)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(clips)
    }

    private static func clip(at url: URL, in directory: URL, maxBytes: Int,
                             keys: Set<URLResourceKey>) -> Result<FileVoiceClip, LoadError> {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true, values.isRegularFile == true else {
            return .failure(.notRegularFile(name))
        }
        // Belt and braces: the directory itself was resolved, so a plain child must stay under it.
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(directory.path + "/") else { return .failure(.outsideDirectory(name)) }
        let size = values.fileSize ?? 0
        guard size <= maxBytes else { return .failure(.tooLarge(name, bytes: size)) }

        let wav: PCMWAV
        do {
            wav = try WAVAudio.canonicalPCM16(Data(contentsOf: url))
        } catch {
            return .failure(.invalidAudio(name, detail: String(describing: error)))
        }
        guard wav.durationMs >= minimumDurationMs else {
            return .failure(.tooShort(name, durationMs: wav.durationMs))
        }
        return .success(FileVoiceClip(url: url, durationMs: wav.durationMs,
                                      envelope: envelope(of: wav, window: envelopeWindow)))
    }

    /// RMS per window, mapped to 0...1 with the same dB curve as the live mic meter.
    static func envelope(of wav: PCMWAV, window: TimeInterval) -> [Float] {
        let headerBytes = 44
        let bytes = [UInt8](wav.data)
        guard bytes.count > headerBytes, window > 0 else { return [] }
        let sampleCount = (bytes.count - headerBytes) / 2
        let samplesPerWindow = max(1, Int(Double(wav.sampleRate) * window))
        var levels: [Float] = []
        levels.reserveCapacity(sampleCount / samplesPerWindow + 1)
        var start = 0
        while start < sampleCount {
            let end = min(start + samplesPerWindow, sampleCount)
            var sumOfSquares: Double = 0
            for index in start..<end {
                let offset = headerBytes + index * 2
                let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let normalized = Double(sample) / Double(Int16.max)
                sumOfSquares += normalized * normalized
            }
            let rms = (sumOfSquares / Double(end - start)).squareRoot()
            let decibels = rms > 0 ? Float(20 * log10(rms)) : -160
            levels.append(PushToTalkAudio.normalizedLevel(decibels: decibels))
            start = end
        }
        return levels
    }
}

// MARK: - Recorder

/// DEBUG-only push-to-talk recorder that plays back a WAV playlist instead of the microphone, so the
/// demo film's interview uses real recorded voice through the real Muse Voice Transcribe call.
///
/// Each `start()` takes the next clip; `stop()` hands over a temp **copy** (PushToTalkModel deletes
/// the file it receives) of the clip as-is, so Meta transcribes exactly the recorded audio.
@MainActor
final class FileVoiceRecorder: VoiceRecording {
    private struct Turn {
        let clip: FileVoiceClip
        let startedAt: Date
    }

    private var queue: [FileVoiceClip]
    private var turn: Turn?
    private let now: () -> Date
    private let makeTemporaryURL: () -> URL
    private let fileManager: FileManager
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "FileVoiceRecorder")

    init(clips: [FileVoiceClip], now: @escaping () -> Date = Date.init,
         makeTemporaryURL: @escaping () -> URL = PushToTalkAudio.temporaryRecordingURL,
         fileManager: FileManager = .default) {
        self.queue = clips
        self.now = now
        self.makeTemporaryURL = makeTemporaryURL
        self.fileManager = fileManager
    }

    /// Clips not yet used.
    var remainingClipCount: Int { queue.count }

    /// The capture-run recorder, or nil when no playlist was named (the microphone is used then).
    /// A named but invalid playlist yields an empty recorder: the turn fails visibly ("Couldn't record
    /// audio") instead of silently recording the host Mac's microphone into the film.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                fileManager: FileManager = .default) -> FileVoiceRecorder? {
        guard let path = playlistDirectory(environment: environment, fileManager: fileManager) else { return nil }
        switch FileVoicePlaylist.load(directory: path, fileManager: fileManager) {
        case .success(let clips):
            logger.info("Capture playlist: \(clips.count, privacy: .public) clip(s)")
            return FileVoiceRecorder(clips: clips)
        case .failure(let error):
            logger.error("Capture playlist rejected: \(error.description, privacy: .public)")
            return FileVoiceRecorder(clips: [])
        }
    }

    /// `HOTH_PTT_WAV_DIR`, else `<Documents>/ptt` when it exists (fill it with
    /// `xcrun simctl get_app_container booted io.fomy.hoth data`), else nil.
    nonisolated static func playlistDirectory(environment: [String: String], fileManager: FileManager = .default) -> String? {
        if let path = environment[DemoCapture.EnvironmentKey.wavDirectory], !path.isEmpty { return path }
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let fallback = documents.appendingPathComponent("ptt", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fallback.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return fallback.path
    }

    func start() throws {
        cancel()
        guard !queue.isEmpty else {
            Self.logger.error("Capture playlist is empty")
            throw VoiceRecorderError.couldNotStart
        }
        turn = Turn(clip: queue.removeFirst(), startedAt: now())
    }

    func stop() -> URL? {
        guard let turn else { return nil }
        self.turn = nil
        let copy = makeTemporaryURL()
        do {
            try fileManager.copyItem(at: turn.clip.url, to: copy)
        } catch {
            Self.logger.error("Could not copy clip \(turn.clip.url.lastPathComponent, privacy: .public): \(String(describing: error))")
            return nil
        }
        return copy
    }

    /// Before `stop()`: the clip goes back to the front of the playlist (the turn never happened).
    /// After `stop()` there is nothing to undo: the clip is used, and the copy belongs to the caller.
    func cancel() {
        guard let turn else { return }
        self.turn = nil
        queue.insert(turn.clip, at: 0)
    }

    var level: Float {
        guard let turn else { return 0 }
        let elapsed = now().timeIntervalSince(turn.startedAt)
        guard elapsed >= 0 else { return 0 }
        let index = Int(elapsed / FileVoicePlaylist.envelopeWindow)
        return index < turn.clip.envelope.count ? turn.clip.envelope[index] : 0
    }
}
#endif
