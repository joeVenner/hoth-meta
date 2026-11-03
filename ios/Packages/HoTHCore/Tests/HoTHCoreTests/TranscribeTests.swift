import XCTest
@testable import HoTHCore

/// Muse Voice Transcribe file mode. Fixtures are doc-derived (`*_doc.json`, dev.meta.ai/docs/speech-to-text),
/// not recorded from the live API.
final class TranscribeTests: XCTestCase {
    private let testKey = "LLM_000000_test-secret-123456789"
    private let wav = Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt fake-pcm".utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func makeClient(key: APIKeyProvider? = nil) -> MetaModelClient {
        MetaModelClient(keyProvider: key ?? StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                        baseURL: URL(string: "https://stub.invalid/v1")!)
    }

    func testSendsMultipartRequestAndAudioParts() async throws {
        let response = try Fixtures.data("transcribe_ptt_doc")
        StubURLProtocol.handler = { _ in (200, response) }

        let transcript = try await makeClient().transcribe(
            wav: wav, model: "muse-voice-transcribe-1.0", languageHint: "ar-khaleeji", keywords: ["Al Reem", " ", "زحليقة"])
        XCTAssertEqual(transcript.text, "في زحليقة مكسورة في الحديقة")
        XCTAssertEqual(transcript.sessionId, "ptt-doc-1")
        XCTAssertEqual(transcript.audioDurationMs, 2400)
        XCTAssertTrue(transcript.turns.isEmpty)

        let captured = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(captured.request.url?.path, "/v1/asr/transcribe")
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(testKey)")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Accept"), "application/json")
        let contentType = try XCTUnwrap(captured.request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

        let parts = try Self.splitMultipart(captured.body, boundary: boundary)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].headers.contains("Content-Disposition: form-data; name=\"request\""))
        XCTAssertTrue(parts[0].headers.contains("Content-Type: application/json"))
        let request = try JSONDecoder().decode(JSONValue.self, from: parts[0].body)
        XCTAssertEqual(request["model"], .string("muse-voice-transcribe-1.0"))
        XCTAssertEqual(request["mode"], .string("PUSH_TO_TALK"))
        XCTAssertEqual(request["audioEncoding"], .string("WAV"))
        XCTAssertEqual(request["languageBias"], .array([.string("Arabic"), .string("English")]))
        XCTAssertEqual(request["keywords"], .array([.string("Al Reem"), .string("زحليقة")]))
        XCTAssertNil(request["authorization"], "file mode authenticates with the header only")

        XCTAssertTrue(parts[1].headers.contains("name=\"audio\"; filename=\"audio.wav\""))
        XCTAssertTrue(parts[1].headers.contains("Content-Type: audio/wav"))
        XCTAssertEqual(parts[1].body, wav)
    }

    func testOmitsBiasAndKeywordsWhenUnknown() throws {
        let data = try MetaModelClient.transcribeRequestJSON(model: "m", languageHint: "fr", keywords: [])
        let request = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertNil(request["languageBias"])
        XCTAssertNil(request["keywords"])
        XCTAssertEqual(MetaModelClient.languageBias(for: "en"), ["English"])
        XCTAssertEqual(MetaModelClient.languageBias(for: "AR"), ["Arabic", "English"])
        XCTAssertEqual(MetaModelClient.languageBias(for: nil), [])
    }

    func testParsesDiarizationTurns() throws {
        let transcript = try MetaModelClient.parseTranscript(Fixtures.data("transcribe_diarization_doc"))
        XCTAssertEqual(transcript.text, "How is the weather? It is raining.")
        XCTAssertEqual(transcript.turns.count, 2)
        XCTAssertEqual(transcript.turns[1], TranscriptTurn(turnId: 2, startMs: 5900, endMs: 8240,
                                                            transcript: "It is raining.", speaker: "B"))
    }

    func testMissingTranscriptIsDecodingError() {
        XCTAssertThrowsError(try MetaModelClient.parseTranscript(Data(#"{"sessionId":"x"}"#.utf8))) { error in
            guard case .decoding? = error as? ModelAPIError else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertThrowsError(try MetaModelClient.parseTranscript(Data("A:Hello".utf8)))
    }

    func testEmptyTranscriptIsValid() throws {
        let transcript = try MetaModelClient.parseTranscript(Data(#"{"transcript":"  "}"#.utf8))
        XCTAssertTrue(transcript.isEmpty)
    }

    func testErrorsMapLikeResponses() async throws {
        StubURLProtocol.handler = { _ in
            (400, Data(#"{"error":{"message":"Audio is not a supported WAV file"}}"#.utf8))
        }
        do {
            _ = try await makeClient().transcribe(wav: wav, model: "m")
            XCTFail("expected error")
        } catch let error as ModelAPIError {
            XCTAssertEqual(error, .http(400, "Audio is not a supported WAV file"))
        }

        StubURLProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await makeClient().transcribe(wav: wav, model: "m")
            XCTFail("expected error")
        } catch let error as ModelAPIError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testMissingKeyFailsBeforeNetwork() async {
        do {
            _ = try await makeClient(key: FailingKey()).transcribe(wav: wav, model: "m")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ModelAPIError, .missingKey)
            XCTAssertTrue(StubURLProtocol.captured.isEmpty)
        }
    }

    // MARK: Helpers

    private struct Part {
        let headers: String
        let body: Data
    }

    /// Minimal multipart reader for assertions: splits on the boundary, then on the blank header line.
    private static func splitMultipart(_ data: Data, boundary: String) throws -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var parts: [Part] = []
        var searchStart = data.startIndex
        var chunks: [Range<Data.Index>] = []
        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            chunks.append(range)
            searchStart = range.upperBound
        }
        XCTAssertEqual(data.suffix(delimiter.count + 4), delimiter + Data("--\r\n".utf8), "closing boundary")
        for (index, delimiterRange) in chunks.dropLast().enumerated() {
            let partStart = delimiterRange.upperBound + crlf.count
            let partEnd = chunks[index + 1].lowerBound - crlf.count
            let part = data[partStart..<partEnd]
            let split = try XCTUnwrap(part.range(of: headerEnd))
            parts.append(Part(headers: String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self),
                              body: Data(part[split.upperBound..<part.endIndex])))
        }
        return parts
    }
}
