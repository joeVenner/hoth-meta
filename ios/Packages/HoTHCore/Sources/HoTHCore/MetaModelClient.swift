import Foundation

/// Supplies the Meta Model API key at call time. The package never stores the key;
/// the app implements this on top of the Keychain.
public protocol APIKeyProvider: Sendable {
    func apiKey() async throws -> String
}

/// Typed errors. No case ever carries the API key, image bytes or audio.
public enum ModelAPIError: Error, Equatable, CustomStringConvertible {
    case missingKey
    case invalidKey
    case rateLimited
    case http(Int, String)
    case network(String)
    case refused(String)
    case incomplete(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .missingKey: return "Model API key is missing."
        case .invalidKey: return "Model API key is invalid (401)."
        case .rateLimited: return "Model API rate limit reached (429)."
        case .http(let code, let message): return "Model API HTTP \(code): \(message)"
        case .network(let message): return "Network error: \(message)"
        case .refused(let message): return "Model refused: \(message)"
        case .incomplete(let reason): return "Response incomplete: \(reason)"
        case .decoding(let message): return "Decoding error: \(message)"
        }
    }
}

/// One JPEG attached to a Responses request, sent inline as a base64 data URL.
/// Meta documents no `detail` knob, so none is sent.
public struct ImageInput: Sendable {
    public let jpegData: Data

    public init(jpegData: Data) {
        self.jpegData = jpegData
    }

    var dataURL: String { "data:image/jpeg;base64," + jpegData.base64EncodedString() }
}

/// Thin async client for the Meta Model API (`https://api.meta.ai/v1`).
///
/// - `structured(...)`: Muse Spark over the Responses API (`POST /v1/responses`) with a `text.format` json_schema.
/// - `transcribe(...)`: Muse Voice Transcribe file mode (`MetaModelClient+Transcribe.swift`).
/// - `segment(...)`: SAM 3.1 concept segmentation (`MetaModelClient+Segment.swift`).
public final class MetaModelClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.meta.ai/v1")!

    public let baseURL: URL
    public let timeout: TimeInterval
    /// `reasoning.effort` sent with `structured` calls; nil omits it. Muse Spark rejects "none" (400).
    public let reasoningEffort: String?
    let keyProvider: APIKeyProvider
    let session: URLSession

    /// - Parameter timeout: 60 s by default: Muse Spark reasons before answering, and non-streaming
    ///   calls past the server budget come back as 504 anyway.
    public init(
        keyProvider: APIKeyProvider,
        session: URLSession = .shared,
        baseURL: URL = MetaModelClient.defaultBaseURL,
        timeout: TimeInterval = 60,
        reasoningEffort: String? = "low"
    ) {
        self.keyProvider = keyProvider
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
        self.reasoningEffort = reasoningEffort
    }

    // MARK: Responses API

    /// POST /v1/responses with optional images and a json_schema output, decoded into `T`.
    /// Sends `store: false`: Responses default to `store: true` (kept server-side for retrieval), and
    /// these one-shot calls carry residents' unblurred photos and never read a stored response back.
    public func structured<T: Decodable>(
        model: String,
        system: String,
        user: String,
        images: [ImageInput] = [],
        schema: JSONSchemaSpec,
        as type: T.Type = T.self
    ) async throws -> T {
        var userContent: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(user)])]
        for image in images {
            userContent.append(.object([
                "type": .string("input_image"),
                "image_url": .string(image.dataURL)
            ]))
        }
        var fields: [String: JSONValue] = [
            "model": .string(model),
            "store": .bool(false),
            "input": .array([
                .object(["role": .string("system"),
                         "content": .array([.object(["type": .string("input_text"), "text": .string(system)])])]),
                .object(["role": .string("user"), "content": .array(userContent)])
            ]),
            "text": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(schema.name),
                    "strict": .bool(schema.strict),
                    "schema": schema.schema
                ])
            ])
        ]
        if let reasoningEffort, !reasoningEffort.isEmpty {
            fields["reasoning"] = .object(["effort": .string(reasoningEffort)])
        }

        let data = try await postJSON(path: "responses", body: .object(fields))
        guard let text = try Self.extractOutputText(from: data) else {
            throw ModelAPIError.decoding("No output_text in response")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw ModelAPIError.decoding("Output did not match \(T.self): \(error)")
        }
    }

    /// Walks `output[] -> message -> content[] -> output_text` (the raw API has no `output_text` shortcut).
    /// Returns nil when the response completed without any text (SAM's "zero matches").
    static func extractOutputText(from data: Data) throws -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ModelAPIError.decoding("Response is not JSON")
        }
        if root["status"]?.stringValue == "incomplete" {
            let reason = root["incomplete_details"]?["reason"]?.stringValue ?? "unknown"
            throw ModelAPIError.incomplete(reason)
        }
        guard case .array(let output)? = root["output"] else {
            throw ModelAPIError.decoding("Response has no output array")
        }
        for item in output where item["type"]?.stringValue == "message" {
            guard case .array(let content)? = item["content"] else { continue }
            for part in content {
                switch part["type"]?.stringValue {
                case "output_text":
                    if let text = part["text"]?.stringValue { return text }
                case "refusal":
                    throw ModelAPIError.refused(part["refusal"]?.stringValue ?? "")
                default:
                    continue
                }
            }
        }
        return nil
    }

    // MARK: Transport

    func postJSON(path: String, body: JSONValue) async throws -> Data {
        let key = try await loadKey()
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, key: key)
    }

    /// Fetches the key before any network work, so a missing key never reaches the wire.
    func loadKey() async throws -> String {
        let key: String
        do {
            key = try await keyProvider.apiKey()
        } catch {
            throw ModelAPIError.missingKey
        }
        guard !key.isEmpty else { throw ModelAPIError.missingKey }
        return key
    }

    /// Adds the Bearer header, sends, and maps the status code to `ModelAPIError`.
    func send(_ request: URLRequest, key: String) async throws -> Data {
        var request = request
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error, isTaskCancelled: Task.isCancelled)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelAPIError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ModelAPIError.invalidKey
        case 429:
            throw ModelAPIError.rateLimited
        default:
            throw ModelAPIError.http(http.statusCode, Self.sanitizedErrorMessage(data, key: key))
        }
    }

    /// Cancellation stays `CancellationError` so callers can drop abandoned work silently; anything else
    /// (timeouts included) is a real `.network` failure.
    static func transportError(_ error: Error, isTaskCancelled: Bool) -> Error {
        if isTaskCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        return ModelAPIError.network((error as? URLError)?.code.rawValue.description ?? "request failed")
    }

    /// Short, key-free error message. Error bodies can echo the request, so drop the literal key and
    /// anything shaped like one: Meta `LLM_<id>_<secret>`, `sk-…` and `Bearer …` tokens.
    static func sanitizedErrorMessage(_ data: Data, key: String? = nil) -> String {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        var message = decoded?["error"]?["message"]?.stringValue ?? String(decoding: data, as: UTF8.self)
        if let key, !key.isEmpty {
            message = message.replacingOccurrences(of: key, with: "***")
        }
        let patterns = [
            ("LLM_[A-Za-z0-9_\\-\\*\\.]+", "LLM_***"),
            ("sk-[A-Za-z0-9_\\-\\*\\.]+", "sk-***"),
            ("Bearer\\s+[A-Za-z0-9_\\-\\*\\.]+", "Bearer ***")
        ]
        for (pattern, replacement) in patterns {
            message = message.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(message.prefix(200))
    }
}
