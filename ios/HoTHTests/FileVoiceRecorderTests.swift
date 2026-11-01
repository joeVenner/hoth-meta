#if DEBUG
import HoTHCore
import XCTest
@testable import HoTH

/// Capture WAV playlist (H2): validation of the host directory, playlist order, the temp copy handed to
/// PushToTalkModel, and cancel / re-queue. Temp directories only; no mic, no network.
@MainActor
final class FileVoiceRecorderTests: XCTestCase {
    private var root: URL!
    private var clipsDirectory: URL!
    private var copiesDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() async throws {
        // Resolved, so `/var` vs `/private/var` never decides a containment check.
        root = fileManager.temporaryDirectory.appendingPathComponent("FileVoiceRecorderTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        clipsDirectory = root.appendingPathComponent("ptt", isDirectory: true)
        copiesDirectory = root.appendingPathComponent("copies", isDirectory: true)
        try fileManager.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: copiesDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fileManager.removeItem(at: root)
    }

    // MARK: Fixtures

    /// Canonical mono 16-bit WAV: `loudMs` of a full-scale-ish square wave, then silence.
    private func wavData(durationMs: Int, sampleRate: Int = 24_000, loudMs: Int = 0) -> Data {
        let sampleCount = durationMs * sampleRate / 1000
        let loudCount = loudMs * sampleRate / 1000
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let sample: Int16 = index < loudCount ? (index.isMultiple(of: 2) ? 16_000 : -16_000) : 0
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return WAVAudio.header(sampleRate: sampleRate, dataSize: pcm.count) + pcm
    }

    @discardableResult
    private func writeClip(_ name: String, durationMs: Int = 1_000, loudMs: Int = 0, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? clipsDirectory).appendingPathComponent(name)
        try wavData(durationMs: durationMs, loudMs: loudMs).write(to: url)
        return url
    }

    private func loadClips(maxBytes: Int = FileVoicePlaylist.defaultMaxBytes) -> Result<[FileVoiceClip], FileVoicePlaylist.LoadError> {
        FileVoicePlaylist.load(directory: clipsDirectory.path, maxBytes: maxBytes)
    }

    private func makeRecorder(clips: [FileVoiceClip], now: @escaping () -> Date = Date.init) -> FileVoiceRecorder {
        FileVoiceRecorder(clips: clips, now: now, makeTemporaryURL: { [copiesDirectory] in
            copiesDirectory!.appendingPathComponent("copy-\(UUID().uuidString).wav")
        })
    }

    // MARK: Playlist

    func testPlaylistIsSortedByNameAndIgnoresOtherFiles() throws {
        try writeClip("02_confirm.wav")
        try writeClip("01_children.wav")
        try writeClip("10_spare.WAV")
        try Data("notes".utf8).write(to: clipsDirectory.appendingPathComponent("README.txt"))
        try Data().write(to: clipsDirectory.appendingPathComponent(".DS_Store"))

        let clips = try loadClips().get()
        XCTAssertEqual(clips.map(\.url.lastPathComponent), ["01_children.wav", "02_confirm.wav", "10_spare.WAV"])
        XCTAssertEqual(clips.first?.durationMs, 1_000)
    }

    func testRelativeMissingAndFileDirectoriesAreRejected() throws {
        XCTAssertEqual(FileVoicePlaylist.load(directory: "assets/vo/ptt"), .failure(.notAbsolute("assets/vo/ptt")))
        let missing = root.appendingPathComponent("nope").path
        XCTAssertEqual(FileVoicePlaylist.load(directory: missing), .failure(.notADirectory(missing)))
        let file = try writeClip("01.wav")
        XCTAssertEqual(FileVoicePlaylist.load(directory: file.path), .failure(.notADirectory(file.path)))
    }

    func testDirectoryWithoutClipsIsRejected() {
        XCTAssertEqual(loadClips(), .failure(.empty(clipsDirectory.path)))
    }

    func testSymlinkedClipIsRejectedEvenWhenItPointsAtAValidWAV() throws {
        let outside = try writeClip("outside.wav", in: root)
        try fileManager.createSymbolicLink(at: clipsDirectory.appendingPathComponent("01_link.wav"),
                                           withDestinationURL: outside)
        XCTAssertEqual(loadClips(), .failure(.notRegularFile("01_link.wav")))
    }

    func testSymlinkedDirectoryPathIsResolvedAndAccepted() throws {
        try writeClip("01.wav")
        let alias = root.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: clipsDirectory)
        let clips = try FileVoicePlaylist.load(directory: alias.path).get()
        XCTAssertEqual(clips.map(\.url.lastPathComponent), ["01.wav"])
    }

    func testOversizedClipIsRejected() throws {
        try writeClip("01.wav", durationMs: 1_000)  // 48 044 bytes
        XCTAssertEqual(loadClips(maxBytes: 10_000), .failure(.tooLarge("01.wav", bytes: 48_044)))
    }

    func testNonWAVAndTooShortClipsRejectTheWholePlaylist() throws {
        try writeClip("01.wav")
        try Data("not audio".utf8).write(to: clipsDirectory.appendingPathComponent("02.wav"))
        guard case .failure(.invalidAudio("02.wav", _)) = loadClips() else {
            return XCTFail("A broken clip must reject the playlist so answers never shift order")
        }
        try fileManager.removeItem(at: clipsDirectory.appendingPathComponent("02.wav"))
        try writeClip("02.wav", durationMs: 300)
        XCTAssertEqual(loadClips(), .failure(.tooShort("02.wav", durationMs: 300)))
    }

    func testEnvelopeFollowsTheVoice() throws {
        let clip = try { () throws -> FileVoiceClip in
            try writeClip("01.wav", durationMs: 1_000, loudMs: 500)
            return try loadClips().get()[0]
        }()
        XCTAssertEqual(clip.envelope.count, 20, "1 s in 50 ms windows")
        XCTAssertGreaterThan(clip.envelope[0], 0.8)
        XCTAssertEqual(clip.envelope[19], 0)
    }

    func testPlaylistDirectoryComesFromTheEnvironment() {
        XCTAssertEqual(FileVoiceRecorder.playlistDirectory(environment: ["HOTH_PTT_WAV_DIR": "/abs/ptt"]), "/abs/ptt")
    }

    func testInvalidNamedPlaylistGivesAnEmptyRecorderNotTheMicrophone() throws {
        let recorder = FileVoiceRecorder.fromEnvironment(["HOTH_PTT_WAV_DIR": root.appendingPathComponent("nope").path])
        XCTAssertNotNil(recorder)
        XCTAssertEqual(recorder?.remainingClipCount, 0)
        XCTAssertThrowsError(try recorder?.start())
    }

    // MARK: Recorder

    func testStopHandsOverACopyAndLeavesTheOriginal() throws {
        try writeClip("01.wav")
        try writeClip("02.wav", durationMs: 2_000)
        let recorder = makeRecorder(clips: try loadClips().get())

        try recorder.start()
        let first = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "copies")
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: clipsDirectory.appendingPathComponent("01.wav")))
        // PushToTalkModel deletes what it receives; the playlist file must survive that.
        try fileManager.removeItem(at: first)
        XCTAssertTrue(fileManager.fileExists(atPath: clipsDirectory.appendingPathComponent("01.wav").path))

        try recorder.start()
        let second = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(try WAVAudio.canonicalPCM16(Data(contentsOf: second)).durationMs, 2_000)
        XCTAssertNil(recorder.stop(), "Nothing is recording after stop")
        XCTAssertThrowsError(try recorder.start(), "An exhausted playlist cannot start") { error in
            XCTAssertEqual(error as? VoiceRecorderError, .couldNotStart)
        }
    }

    func testCancelBeforeStopRequeuesTheClip() throws {
        try writeClip("01.wav")
        try writeClip("02.wav", durationMs: 2_000)
        let recorder = makeRecorder(clips: try loadClips().get())

        try recorder.start()
        recorder.cancel()
        XCTAssertEqual(recorder.remainingClipCount, 2)
        try recorder.start()
        let url = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(try WAVAudio.canonicalPCM16(Data(contentsOf: url)).durationMs, 1_000, "Clip 01 again")
    }

    func testCancelAfterStopKeepsTheClipUsedAndTheCopy() throws {
        try writeClip("01.wav")
        try writeClip("02.wav")
        let recorder = makeRecorder(clips: try loadClips().get())

        try recorder.start()
        let url = try XCTUnwrap(recorder.stop())
        recorder.cancel()  // PushToTalkModel.fail() does this after a stopped turn
        XCTAssertEqual(recorder.remainingClipCount, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path), "The copy belongs to the caller")
    }

    func testCopyFailureReturnsNil() throws {
        try writeClip("01.wav")
        let clips = try loadClips().get()
        try fileManager.removeItem(at: clips[0].url)
        let recorder = makeRecorder(clips: clips)
        try recorder.start()
        XCTAssertNil(recorder.stop())
    }

    func testLevelPlaysTheEnvelopeOverTime() throws {
        try writeClip("01.wav", durationMs: 1_000, loudMs: 500)
        var clock = Date(timeIntervalSince1970: 0)
        let recorder = makeRecorder(clips: try loadClips().get(), now: { clock })

        XCTAssertEqual(recorder.level, 0, "Silent before start")
        try recorder.start()
        clock = clock.addingTimeInterval(0.1)
        XCTAssertGreaterThan(recorder.level, 0.8)
        clock = clock.addingTimeInterval(0.7)
        XCTAssertEqual(recorder.level, 0)
        clock = clock.addingTimeInterval(5)
        XCTAssertEqual(recorder.level, 0, "Past the end of the clip")
    }

    func testPushToTalkTurnTranscribesTheClipAndDeletesOnlyTheCopy() async throws {
        try writeClip("01.wav", durationMs: 1_000, loudMs: 1_000)
        let recorder = makeRecorder(clips: try loadClips().get())
        let transcriber = RecordingTranscriber()
        let model = PushToTalkModel(transcriber: transcriber, recorder: recorder, speaker: SilentSpeaker(),
                                    startsInVoice: true,
                                    micStatus: VoiceRecorderFactory.micStatus(for: recorder),
                                    prepareAudio: {}, tapThreshold: 0)
        var transcripts: [String] = []
        model.onTranscript = { transcripts.append($0) }

        model.pressBegan()
        await model.work?.value
        XCTAssertEqual(model.phase, .listening)
        model.pressEnded()
        await model.work?.value

        XCTAssertEqual(transcripts, ["clip"])
        XCTAssertEqual(transcriber.uploadedBytes, 44 + 48_000)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: copiesDirectory.path), [], "Copy deleted")
        XCTAssertTrue(fileManager.fileExists(atPath: clipsDirectory.appendingPathComponent("01.wav").path))
    }

    func testFileRecorderSkipsTheMicPermission() throws {
        let fileRecorder = makeRecorder(clips: [])
        XCTAssertEqual(VoiceRecorderFactory.micStatus(for: fileRecorder)(), .granted)
    }
}

private final class RecordingTranscriber: SpeechTranscribing, @unchecked Sendable {
    private(set) var uploadedBytes = 0
    func transcribe(wav: Data) async throws -> String {
        uploadedBytes = wav.count
        return "clip"
    }
}

@MainActor
private final class SilentSpeaker: SpeechSpeaking {
    func speak(_ text: String, languageCode: String) async {}
    func stop() {}
}
#endif
