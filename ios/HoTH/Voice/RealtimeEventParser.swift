import Foundation

/// A function call the Realtime model asked the app to run.
struct RealtimeFunctionCall: Equatable, Sendable {
    let callId: String
    let name: String
    /// Raw JSON arguments string, exactly as sent by the model.
    let arguments: String
}

/// Server events the voice interview cares about. Everything else maps to `.ignored`.
enum RealtimeServerEvent: Equatable, Sendable {
    case sessionReady
    case assistantTranscriptDelta(itemId: String, delta: String)
    case assistantTranscriptDone(itemId: String, transcript: String)
    case userTranscriptDelta(itemId: String, delta: String)
    case userTranscriptDone(itemId: String, transcript: String)
    /// Server VAD heard the resident start talking; `itemId` is the user item that will be transcribed.
    case userSpeechStarted(itemId: String)
    case userSpeechStopped
    case assistantAudioStarted
    case assistantAudioStopped
    case responseStarted
    /// `response.done`, with any function calls found in `response.output[]`.
    case responseDone(functionCalls: [RealtimeFunctionCall])
    /// `response.function_call_arguments.done` (some servers only send this, some only `response.done`).
    case functionCallArgumentsDone(RealtimeFunctionCall)
    case serverError(message: String)
    case ignored(type: String)
}

/// Pure, side-effect-free parsing of Realtime data-channel messages and building of client events.
///
/// Tolerant by design: the beta and GA APIs use slightly different event names
/// (`response.audio_transcript.*` vs `response.output_audio_transcript.*`), so both are accepted.
struct RealtimeEventParser {

    enum ParseError: Error, Equatable {
        case notJSONObject
        case missingType
    }

    // MARK: Server events

    func parse(_ text: String) throws -> RealtimeServerEvent {
        try parse(Data(text.utf8))
    }

    func parse(_ data: Data) throws -> RealtimeServerEvent {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.notJSONObject
        }
        guard let type = object["type"] as? String else { throw ParseError.missingType }
        let itemId = object["item_id"] as? String ?? ""

        switch type {
        case "session.created", "session.updated":
            return .sessionReady

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta",
             "response.output_text.delta", "response.text.delta":
            return .assistantTranscriptDelta(itemId: itemId, delta: object["delta"] as? String ?? "")

        case "response.output_audio_transcript.done", "response.audio_transcript.done",
             "response.output_text.done", "response.text.done":
            let transcript = object["transcript"] as? String ?? object["text"] as? String ?? ""
            return .assistantTranscriptDone(itemId: itemId, transcript: transcript)

        case "conversation.item.input_audio_transcription.delta":
            return .userTranscriptDelta(itemId: itemId, delta: object["delta"] as? String ?? "")

        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.done":
            return .userTranscriptDone(itemId: itemId, transcript: object["transcript"] as? String ?? "")

        case "input_audio_buffer.speech_started":
            return .userSpeechStarted(itemId: itemId)
        case "input_audio_buffer.speech_stopped":
            return .userSpeechStopped
        case "output_audio_buffer.started":
            return .assistantAudioStarted
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            return .assistantAudioStopped
        case "response.created":
            return .responseStarted

        case "response.function_call_arguments.done":
            guard let call = Self.functionCall(from: object) else { return .ignored(type: type) }
            return .functionCallArgumentsDone(call)

        case "response.done":
            let response = object["response"] as? [String: Any] ?? [:]
            let output = response["output"] as? [[String: Any]] ?? []
            let calls = output
                .filter { ($0["type"] as? String) == "function_call" }
                .compactMap(Self.functionCall(from:))
            return .responseDone(functionCalls: calls)

        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? object["message"] as? String ?? "Unknown realtime error"
            return .serverError(message: message)

        default:
            return .ignored(type: type)
        }
    }

    /// Reads `{call_id, name, arguments}` from either a `function_call` item or an arguments-done event.
    private static func functionCall(from object: [String: Any]) -> RealtimeFunctionCall? {
        guard let callId = object["call_id"] as? String, !callId.isEmpty,
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        let arguments: String
        if let raw = object["arguments"] as? String {
            arguments = raw
        } else if let dict = object["arguments"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let raw = String(data: data, encoding: .utf8) {
            arguments = raw
        } else {
            arguments = "{}"
        }
        return RealtimeFunctionCall(callId: callId, name: name, arguments: arguments)
    }

    /// Extracts `reason` from `flag_urgent` arguments; falls back to a generic reason.
    static func urgentReason(fromArguments arguments: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        let reason = (object?["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Immediate danger reported" : reason
    }

    // MARK: Client events

    /// `response.create` with no overrides (uses the session instructions).
    static func responseCreate() -> Data {
        encode(["type": "response.create"])
    }

    /// `conversation.item.create` carrying a `function_call_output` for `callId`.
    static func functionCallOutput(callId: String, output: [String: Any]) -> Data {
        let outputData = (try? JSONSerialization.data(withJSONObject: output)) ?? Data("{}".utf8)
        let outputString = String(data: outputData, encoding: .utf8) ?? "{}"
        return encode([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": outputString
            ] as [String: Any]
        ])
    }

    /// `session.update` enabling input-audio transcription so the user's own words can be captioned.
    static func enableInputTranscription(model: String) -> Data {
        encode([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "audio": ["input": ["transcription": ["model": model]]]
            ] as [String: Any]
        ])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// Text helpers for captions.
enum RealtimeText {
    /// True when the string contains Arabic-script characters (decides RTL per line, since residents code-switch).
    static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value)
                || (0xFB50...0xFDFF).contains(scalar.value) || (0xFE70...0xFEFF).contains(scalar.value)
        }
    }
}
