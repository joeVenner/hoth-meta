import XCTest
@testable import HoTH

final class RealtimeEventParserTests: XCTestCase {
    private let parser = RealtimeEventParser()

    // MARK: Function calls

    func testResponseDoneExtractsFunctionCalls() throws {
        let json = """
        {"type":"response.done","response":{"id":"resp_1","status":"completed","output":[
          {"type":"message","id":"item_0","role":"assistant","content":[]},
          {"type":"function_call","id":"item_1","call_id":"call_abc","name":"submit_report",
           "arguments":"{\\"summary_en\\":\\"Broken swing\\",\\"summary_ar\\":\\"مرجيحة مكسورة\\",\\"answers\\":{\\"children_using_now\\":\\"yes\\"},\\"user_language\\":\\"ar-khaleeji\\",\\"wants_to_post\\":true,\\"anonymous\\":false}"}
        ]}}
        """
        let event = try parser.parse(json)
        guard case .responseDone(let calls) = event else { return XCTFail("Expected responseDone, got \(event)") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.callId, "call_abc")
        XCTAssertEqual(calls.first?.name, "submit_report")
        XCTAssertTrue(calls.first?.arguments.contains("children_using_now") ?? false)
    }

    func testResponseDoneWithoutCallsHasEmptyList() throws {
        let event = try parser.parse(#"{"type":"response.done","response":{"output":[{"type":"message"}]}}"#)
        XCTAssertEqual(event, .responseDone(functionCalls: []))
    }

    func testResponseDoneSkipsFunctionCallWithoutCallId() throws {
        let event = try parser.parse(#"{"type":"response.done","response":{"output":[{"type":"function_call","name":"flag_urgent","arguments":"{}"}]}}"#)
        XCTAssertEqual(event, .responseDone(functionCalls: []))
    }

    func testFunctionCallArgumentsDone() throws {
        let json = #"{"type":"response.function_call_arguments.done","call_id":"call_9","name":"flag_urgent","arguments":"{\"reason\":\"sparking wire near water\"}"}"#
        let event = try parser.parse(json)
        let expected = RealtimeFunctionCall(callId: "call_9", name: "flag_urgent",
                                            arguments: #"{"reason":"sparking wire near water"}"#)
        XCTAssertEqual(event, .functionCallArgumentsDone(expected))
        XCTAssertEqual(RealtimeEventParser.urgentReason(fromArguments: expected.arguments), "sparking wire near water")
    }

    func testUrgentReasonFallsBackOnBadArguments() {
        XCTAssertEqual(RealtimeEventParser.urgentReason(fromArguments: "not json"), "Immediate danger reported")
        XCTAssertEqual(RealtimeEventParser.urgentReason(fromArguments: #"{"reason":"  "}"#), "Immediate danger reported")
    }

    // MARK: Transcripts

    func testAssistantTranscriptDeltaGAAndBetaNames() throws {
        let ga = try parser.parse(#"{"type":"response.output_audio_transcript.delta","item_id":"it_1","delta":"شكراً "}"#)
        XCTAssertEqual(ga, .assistantTranscriptDelta(itemId: "it_1", delta: "شكراً "))
        let beta = try parser.parse(#"{"type":"response.audio_transcript.delta","item_id":"it_1","delta":"Hi"}"#)
        XCTAssertEqual(beta, .assistantTranscriptDelta(itemId: "it_1", delta: "Hi"))
    }

    func testAssistantTranscriptDone() throws {
        let event = try parser.parse(#"{"type":"response.output_audio_transcript.done","item_id":"it_1","transcript":"Are children using it?"}"#)
        XCTAssertEqual(event, .assistantTranscriptDone(itemId: "it_1", transcript: "Are children using it?"))
    }

    func testUserTranscriptionDeltaAndCompleted() throws {
        let delta = try parser.parse(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u_1","delta":"إي"}"#)
        XCTAssertEqual(delta, .userTranscriptDelta(itemId: "u_1", delta: "إي"))
        let done = try parser.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u_1","transcript":"إي، في عيال"}"#)
        XCTAssertEqual(done, .userTranscriptDone(itemId: "u_1", transcript: "إي، في عيال"))
    }

    // MARK: State events and errors

    func testStateEvents() throws {
        XCTAssertEqual(try parser.parse(#"{"type":"input_audio_buffer.speech_started","item_id":"u_2"}"#),
                       .userSpeechStarted(itemId: "u_2"))
        XCTAssertEqual(try parser.parse(#"{"type":"output_audio_buffer.started"}"#), .assistantAudioStarted)
        XCTAssertEqual(try parser.parse(#"{"type":"output_audio_buffer.stopped"}"#), .assistantAudioStopped)
        XCTAssertEqual(try parser.parse(#"{"type":"session.created","session":{}}"#), .sessionReady)
    }

    func testErrorAndUnknownEvents() throws {
        XCTAssertEqual(try parser.parse(#"{"type":"error","error":{"message":"bad model"}}"#),
                       .serverError(message: "bad model"))
        XCTAssertEqual(try parser.parse(#"{"type":"rate_limits.updated"}"#), .ignored(type: "rate_limits.updated"))
    }

    func testMalformedMessagesThrow() {
        XCTAssertThrowsError(try parser.parse("not json"))
        XCTAssertThrowsError(try parser.parse(#"["array"]"#))
        XCTAssertThrowsError(try parser.parse(#"{"no_type":true}"#))
    }

    // MARK: Client events

    func testFunctionCallOutputShape() throws {
        let data = RealtimeEventParser.functionCallOutput(callId: "call_abc", output: ["ok": true])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_abc")
        XCTAssertEqual(item["output"] as? String, #"{"ok":true}"#)
    }

    func testResponseCreateAndTranscriptionUpdate() throws {
        let create = try XCTUnwrap(try JSONSerialization.jsonObject(with: RealtimeEventParser.responseCreate()) as? [String: Any])
        XCTAssertEqual(create["type"] as? String, "response.create")
        let update = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: RealtimeEventParser.enableInputTranscription(model: "gpt-4o-transcribe")) as? [String: Any])
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = update["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["model"] as? String, "gpt-4o-transcribe")
    }

    // MARK: Text direction

    func testArabicDetection() {
        XCTAssertTrue(RealtimeText.containsArabic("في أطفال يلعبون؟"))
        XCTAssertTrue(RealtimeText.containsArabic("yes يعني"))
        XCTAssertFalse(RealtimeText.containsArabic("Are children using it?"))
    }
}
