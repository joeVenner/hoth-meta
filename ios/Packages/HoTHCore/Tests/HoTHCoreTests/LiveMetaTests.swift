import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HoTHCore

/// Opt-in live checks against the real Meta Model API, through the same client code the app uses.
///
/// Skipped unless `META_API_KEY` is set, so the default `swift test` stays hermetic. Run with:
///     META_API_KEY=... swift test --filter LiveMetaTests
/// Each call prints `LIVE <name> <ms> ms` so latency can be read from the log. The key is never printed:
/// it only reaches the client through `StaticKey`, and client errors are already scrubbed.
/// A missing billing setup (HTTP 402) fails these tests on purpose: a skip would read as green.
final class LiveMetaTests: XCTestCase {
    private var client: MetaModelClient!
    private var prompts: Prompts!
    private var key = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        key = ProcessInfo.processInfo.environment["META_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(key.isEmpty, "META_API_KEY not set; live Meta tests are opt-in")
        client = MetaModelClient(keyProvider: StaticKey(key: key))
        prompts = try Fixtures.prompts()
    }

    // MARK: Models

    /// GET /v1/models lists every id prompts.json depends on.
    func testModelIDsAreListed() async throws {
        var request = URLRequest(url: MetaModelClient.defaultBaseURL.appendingPathComponent("models"),
                                 timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await timed("models") { try await URLSession.shared.data(for: request) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let models)? = root["data"] else { return XCTFail("No data array in /v1/models") }
        let ids = Set(models.compactMap { $0["id"]?.stringValue })
        for id in [prompts.models.vision, prompts.models.text, prompts.models.transcribe, prompts.models.segment] {
            XCTAssertTrue(ids.contains(id), "\(id) missing from /v1/models")
        }
    }

    // MARK: Muse Spark

    func testVisionAnalyzeDecodesCategoryAndSeverity() async throws {
        let analyzer = VisionAnalyzer(client: client, prompts: prompts)
        let cases: [(String, ReportCategory)] = [
            ("real/real_pothole_pavement_1.jpg", .potholePavement),
            ("generated/syn_playground_springrider.jpg", .playgroundEquipment)
        ]
        for (file, expected) in cases {
            let jpeg = try LiveData.jpeg(file)
            let analysis = try await timed("vision \(file)") {
                try await analyzer.analyze(imageData: jpeg, language: "en")
            }
            XCTAssertEqual(analysis.category, expected, file)
            XCTAssertTrue(Severity.allCases.contains(analysis.severityProposal), file)
            XCTAssertFalse(analysis.titleEN.isEmpty, file)
            XCTAssertTrue(LiveData.hasArabicScript(analysis.titleAR), "title_ar not Arabic: \(file)")
            for box in analysis.hazards.map(\.box) {
                XCTAssertTrue(box.x >= 0 && box.y >= 0 && box.x + box.w <= 1.0001 && box.y + box.h <= 1.0001,
                              "box out of bounds in \(file): \(box)")
            }
        }
    }

    /// syn_pair2: the pothole is still there after the "repair" (labels.json fixed=false).
    func testFixVerifyRejectsUnfixedPair() async throws {
        let verdict = try await verify(pair: "pair2", category: .potholePavement, title: "Pothole on the road")
        XCTAssertFalse(verdict.resolved, verdict.reasonEN)
    }

    /// syn_pair3: the playground equipment was repaired (labels.json fixed=true).
    func testFixVerifyAcceptsResolvedPair() async throws {
        let verdict = try await verify(pair: "pair3", category: .playgroundEquipment,
                                       title: "Broken playground equipment")
        XCTAssertTrue(verdict.resolved, verdict.reasonEN)
    }

    func testDuplicateJudge() async throws {
        let judge = DuplicateJudge(client: client, prompts: prompts)
        let first = try LiveData.jpeg("real/real_pothole_pavement_1.jpg")
        let second = try LiveData.jpeg("real/real_pothole_pavement_2.jpg")
        let now = Date()
        func snapshot(_ jpeg: Data) -> ReportSnapshot {
            ReportSnapshot(summary: "Pothole in the road", category: .potholePavement,
                           capturedAt: now.addingTimeInterval(-3600), jpegData: jpeg)
        }
        let same = try await timed("duplicate same photo") {
            try await judge.judge(new: snapshot(first), existing: snapshot(first), distanceMeters: 8)
        }
        XCTAssertTrue(same.sameIssue, same.reason)
        let different = try await timed("duplicate different potholes") {
            try await judge.judge(new: snapshot(second), existing: snapshot(first), distanceMeters: 40)
        }
        XCTAssertFalse(different.sameIssue, different.reason)
    }

    /// The prompts.json `moderation` spec, called the way `ModelCommentModerator` calls it.
    func testModerationAllowsAndBlocks() async throws {
        struct Verdict: Decodable { let decision: String; let reason: String }
        let spec = prompts.moderation
        let schema = try XCTUnwrap(spec.jsonSchema)
        let title = "Pothole on Al Falah Street"
        let cases: [(String, String)] = [
            ("I saw this too this morning, it is getting bigger.", "allow"),
            ("The guy in villa 12 did this on purpose, he is a criminal and everyone should go after him.", "block")
        ]
        for (comment, expected) in cases {
            let values = ["report_title": title, "comment": comment]
            let verdict = try await timed("moderation \(expected)") {
                try await client.structured(model: prompts.models.text,
                                            system: Prompts.fill(spec.system, values),
                                            user: Prompts.fill(spec.userTemplate, values),
                                            schema: schema, as: Verdict.self)
            }
            XCTAssertEqual(verdict.decision.lowercased(), expected, verdict.reason)
        }
    }

    // MARK: Muse Voice Transcribe

    func testTranscribeEnglish() async throws {
        let wav = try LiveData.spokenWAV("There is a big pothole next to the school gate.", voice: nil)
        let transcript = try await timed("transcribe en") {
            try await client.transcribe(wav: wav, model: prompts.models.transcribe, languageHint: "en")
        }
        XCTAssertFalse(transcript.isEmpty)
        XCTAssertTrue(transcript.text.lowercased().contains("pothole") || transcript.text.lowercased().contains("school"),
                      transcript.text)
    }

    func testTranscribeArabic() async throws {
        let voice = try XCTUnwrap(LiveData.arabicVoice(), "No Arabic `say` voice installed")
        let wav = try LiveData.spokenWAV("في حفرة كبيرة جنب باب المدرسة", voice: voice)
        let transcript = try await timed("transcribe ar") {
            try await client.transcribe(wav: wav, model: prompts.models.transcribe, languageHint: "ar-khaleeji")
        }
        XCTAssertFalse(transcript.isEmpty)
        XCTAssertTrue(LiveData.hasArabicScript(transcript.text), transcript.text)
    }

    // MARK: SAM 3.1

    func testSegmentPotholeReturnsBoxesInBounds() async throws {
        let jpeg = try LiveData.jpeg("real/real_pothole_pavement_1.jpg")
        let size = try XCTUnwrap(JPEGSize.pixelSize(of: jpeg))
        let instances = try await timed("segment pothole") {
            try await client.segment(image: ImageInput(jpegData: jpeg), concept: "pothole",
                                     model: prompts.models.segment)
        }
        XCTAssertGreaterThanOrEqual(instances.count, 1)
        for instance in instances {
            let box = instance.box
            print("LIVE sam box \(box.x1),\(box.y1)-\(box.x2),\(box.y2) of \(box.sourceWidth)x\(box.sourceHeight) "
                  + "sent \(size.width)x\(size.height) score \(instance.score.map { String($0) } ?? "nil")")
            XCTAssertTrue(box.x1 >= 0 && box.y1 >= 0 && box.x2 <= size.width && box.y2 <= size.height,
                          "SAM box outside the \(size.width)x\(size.height) image")
            XCTAssertLessThan(box.x1, box.x2)
            XCTAssertLessThan(box.y1, box.y2)
        }
        // The same call through the app's selection rules (score floor, shape check, top 3).
        let outline = try await timed("segment outline") {
            try await HazardSegmenter(client: client, prompts: prompts)
                .outline(jpegData: jpeg, category: .potholePavement)
        }
        XCTAssertFalse(outline?.boxes.isEmpty ?? true, "every SAM box was dropped by SegmentSelection")
    }

    // MARK: Tool calling

    /// One real tool round: Spark calls the tool, gets the result, then answers in the strict schema.
    func testAgentToolRoundTrip() async throws {
        struct Turn: Decodable { let reply: String }
        let agent = try XCTUnwrap(prompts.intakeAgent)
        let tool = try XCTUnwrap(agent.tools.first { $0.name == "find_nearby_reports" })
        let schema = try JSONDecoder().decode(JSONSchemaSpec.self, from: Data("""
        {"name":"chat_turn","strict":true,"schema":{"type":"object","additionalProperties":false,
        "required":["reply"],"properties":{"reply":{"type":"string"}}}}
        """.utf8))
        let toolOutput = #"{"reports":[{"id":"r-1","category":"pothole_pavement","title_en":"Pothole by the school gate","distance_m":12,"confirmations":3,"status":"open"}]}"#
        let outcome = try await timed("agent tool round trip") {
            try await ToolLoop.run(
                client: client, model: prompts.models.text,
                system: "You help a resident report a pothole. On your first turn you MUST call find_nearby_reports "
                    + "with radius_m 100 before replying. Then reply in one sentence that names any report found.",
                user: "Resident: There is a pothole near the school gate.",
                tools: [tool], schema: schema, maxRounds: 2, as: Turn.self
            ) { call in
                XCTAssertEqual(call.name, "find_nearby_reports")
                return toolOutput
            }
        }
        switch outcome {
        case .final(let turn, let rounds, let calls):
            print("LIVE agent rounds \(rounds) calls \(calls.map(\.name))")
            XCTAssertGreaterThanOrEqual(rounds, 1, "Spark answered without calling the tool")
            XCTAssertFalse(turn.reply.isEmpty)
        case .roundLimit(let calls):
            XCTFail("Hit the round limit after \(calls.count) call(s)")
        }
    }

    // MARK: Helpers

    private func verify(pair: String, category: ReportCategory, title: String) async throws -> FixVerification {
        let before = try LiveData.jpeg("generated/syn_\(pair)_before.jpg")
        let after = try LiveData.jpeg("generated/syn_\(pair)_after.jpg")
        let now = Date()
        return try await timed("fix verify \(pair)") {
            try await FixVerifier(client: client, prompts: prompts).verify(
                before: before, after: after, reportTitle: title, category: category,
                beforeCapturedAt: now.addingTimeInterval(-3 * 86_400), afterCapturedAt: now)
        }
    }

    private func timed<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let start = Date()
        defer { print("LIVE \(name) \(Int(Date().timeIntervalSince(start) * 1000)) ms") }
        return try await body()
    }
}

/// Eval images and generated speech for the live tests.
private enum LiveData {
    static let datasetURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HoTHCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // HoTHCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repo
        .appendingPathComponent("tools/eval/dataset")

    /// An eval image re-encoded the way CaptureService does it: <= 1024 px long edge, upright, JPEG 0.82.
    static func jpeg(_ relativePath: String) throws -> Data {
        let url = datasetURL.appendingPathComponent(relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }

    /// Speaks `text` with macOS `say` into 16 kHz mono 16-bit WAV, then runs the app's canonical rewrite.
    static func spokenWAV(_ text: String, voice: String?) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoth-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000"]
        if let voice { arguments += ["-v", voice] }
        arguments.append(text)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "say exited \(process.terminationStatus)"])
        }
        return try WAVAudio.canonicalPCM16(Data(contentsOf: url)).data
    }

    /// The first installed `say` voice for an Arabic locale (e.g. "Majed  ar_001"), or nil.
    static func arabicVoice() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = output.split(separator: "\n").first { $0.contains(" ar_") }
        return line.flatMap { $0.components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces) }
    }

    static func hasArabicScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }
}
