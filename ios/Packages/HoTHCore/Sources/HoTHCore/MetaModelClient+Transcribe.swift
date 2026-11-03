import Foundation

/// One detected speech turn (ENDPOINTING / DIARIZATION modes; empty in PUSH_TO_TALK).
public struct TranscriptTurn: Codable, Equatable, Sendable {
    public let turnId: Int
    public let startMs: Int
    public let endMs: Int
    public let transcript: String
    /// DIARIZATION only, e.g. "A".
    public let speaker: String?
}

/// Muse Voice Transcribe file-mode result.
public struct Transcript: Equatable, Sendable {
    /// The complete transcript, in every mode.
    public let text: String
    public let sessionId: String?
    public let audioDurationMs: Int?
    public let turns: [TranscriptTurn]

    public init(text: String, sessionId: String? = nil, audioDurationMs: Int? = nil, turns: [TranscriptTurn] = []) {
        self.text = text
        self.sessionId = sessionId
        self.audioDurationMs = audioDurationMs
        self.turns = turns
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension MetaModelClient {
    /// POST /v1/asr/transcribe (multipart: a `request` JSON part and an `audio` WAV part).
    ///
    /// - Parameters:
    ///   - wav: RIFF/WAVE, mono 16-bit PCM at 16 or 24 kHz (the endpoint rejects anything else with 400).
    ///   - model: e.g. `prompts.models.transcribe`.
    ///   - languageHint: the app's language hint ("en", "ar", "ar-khaleeji"); mapped to `languageBias`.
    ///   - keywords: vocabulary biasing (place names, category words). Omitted when empty.
    public func transcribe(
        wav: Data,
        model: String,
        languageHint: String? = nil,
        keywords: [String] = []
    ) async throws -> Transcript {
        let key = try await loadKey()
        let boundary = "hoth-\(UUID().uuidString)"
        let requestPart = try Self.transcribeRequestJSON(model: model, languageHint: languageHint, keywords: keywords)

        var request = URLRequest(url: baseURL.appendingPathComponent("asr/transcribe"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.multipartBody(requestJSON: requestPart, wav: wav, boundary: boundary)

        let data = try await send(request, key: key)
        return try Self.parseTranscript(data)
    }

    /// The `request` part: PUSH_TO_TALK (the user delimits the turn), WAV container.
    static func transcribeRequestJSON(model: String, languageHint: String?, keywords: [String]) throws -> Data {
        var fields: [String: JSONValue] = [
            "model": .string(model),
            "mode": .string("PUSH_TO_TALK"),
            "audioEncoding": .string("WAV")
        ]
        let bias = languageBias(for: languageHint)
        if !bias.isEmpty { fields["languageBias"] = .array(bias.map(JSONValue.string)) }
        let cleanKeywords = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !cleanKeywords.isEmpty { fields["keywords"] = .array(cleanKeywords.map(JSONValue.string)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(fields))
    }

    /// `languageBias` takes language names, not codes. Arabic residents often code-switch, so an
    /// Arabic hint also lists English. Unknown or empty hints omit the field (auto-detect).
    static func languageBias(for hint: String?) -> [String] {
        let normalized = hint?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.hasPrefix("ar") { return ["Arabic", "English"] }
        if normalized.hasPrefix("en") { return ["English"] }
        return []
    }

    static func multipartBody(requestJSON: Data, wav: Data, boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"request\"")
        line("Content-Type: application/json")
        line("")
        body.append(requestJSON)
        line("")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"")
        line("Content-Type: audio/wav")
        line("")
        body.append(wav)
        line("")
        line("--\(boundary)--")
        return body
    }

    /// Decodes `{sessionId, transcript, audioDurationMs, turns[]}`; only `transcript` is required.
    static func parseTranscript(_ data: Data) throws -> Transcript {
        struct Wire: Decodable {
            let sessionId: String?
            let transcript: String?
            let audioDurationMs: Int?
            let turns: [TranscriptTurn]?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw ModelAPIError.decoding("Transcription response is not the expected JSON")
        }
        guard let text = wire.transcript else {
            throw ModelAPIError.decoding("Transcription response has no transcript")
        }
        return Transcript(text: text, sessionId: wire.sessionId, audioDurationMs: wire.audioDurationMs,
                          turns: wire.turns ?? [])
    }
}
