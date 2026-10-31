import Foundation

/// Supplies the OpenAI API key at call time. The package never stores the key;
/// the app implements this on top of the Keychain.
public protocol APIKeyProvider: Sendable {
    func apiKey() async throws -> String
}

/// Typed errors. No case ever carries the API key or image bytes.
public enum OpenAIError: Error, Equatable, CustomStringConvertible {
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
        case .missingKey: return "OpenAI API key is missing."
        case .invalidKey: return "OpenAI API key is invalid (401)."
        case .rateLimited: return "OpenAI rate limit reached (429)."
        case .http(let code, let message): return "OpenAI HTTP \(code): \(message)"
        case .network(let message): return "Network error: \(message)"
        case .refused(let message): return "Model refused: \(message)"
        case .incomplete(let reason): return "Response incomplete: \(reason)"
        case .decoding(let message): return "Decoding error: \(message)"
        }
    }
}

/// One image attached to a Responses request.
public struct ImageInput: Sendable {
    public enum Detail: String, Sendable { case low, high, original, auto }

    public let jpegData: Data
    public let detail: Detail

    public init(jpegData: Data, detail: Detail = .auto) {
        self.jpegData = jpegData
        self.detail = detail
    }

    var dataURL: String { "data:image/jpeg;base64," + jpegData.base64EncodedString() }
}

/// Ephemeral Realtime secret for the WebRTC SDP exchange.
public struct RealtimeClientSecret: Equatable, Sendable {
    public let value: String
    public let expiresAt: Date
}

/// Thin async client for the OpenAI Responses and Realtime client-secret endpoints.
public final class OpenAIClient: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    private let keyProvider: APIKeyProvider
    private let session: URLSession

    public init(
        keyProvider: APIKeyProvider,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        timeout: TimeInterval = 30
    ) {
        self.keyProvider = keyProvider
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
    }

    // MARK: Responses API

    /// POST /v1/responses with optional images and a strict json_schema output, decoded into `T`.
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
                "image_url": .string(image.dataURL),
                "detail": .string(image.detail.rawValue)
            ]))
        }
        let body: JSONValue = .object([
            "model": .string(model),
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
        ])

        let data = try await post(path: "responses", body: body)
        let text = try Self.extractOutputText(from: data)
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw OpenAIError.decoding("Output did not match \(T.self): \(error)")
        }
    }

    /// Walks `output[] -> message -> content[] -> output_text` (the raw API has no `output_text` shortcut).
    static func extractOutputText(from data: Data) throws -> String {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OpenAIError.decoding("Response is not JSON")
        }
        if root["status"]?.stringValue == "incomplete" {
            let reason = root["incomplete_details"]?["reason"]?.stringValue ?? "unknown"
            throw OpenAIError.incomplete(reason)
        }
        guard case .array(let output)? = root["output"] else {
            throw OpenAIError.decoding("Response has no output array")
        }
        for item in output where item["type"]?.stringValue == "message" {
            guard case .array(let content)? = item["content"] else { continue }
            for part in content {
                switch part["type"]?.stringValue {
                case "output_text":
                    if let text = part["text"]?.stringValue { return text }
                case "refusal":
                    throw OpenAIError.refused(part["refusal"]?.stringValue ?? "")
                default:
                    continue
                }
            }
        }
        throw OpenAIError.decoding("No output_text in response")
    }

    // MARK: Realtime

    /// POST /v1/realtime/client_secrets → ephemeral key for the phone's WebRTC session.
    public func createRealtimeClientSecret(
        model: String,
        instructions: String,
        tools: [JSONValue],
        voice: String = "marin"
    ) async throws -> RealtimeClientSecret {
        let body: JSONValue = .object([
            "session": .object([
                "type": .string("realtime"),
                "model": .string(model),
                "instructions": .string(instructions),
                "audio": .object([
                    "output": .object(["voice": .string(voice)]),
                    "input": .object(["turn_detection": .object(["type": .string("semantic_vad")])])
                ]),
                "tools": .array(tools),
                "tool_choice": .string("auto")
            ])
        ])
        let data = try await post(path: "realtime/client_secrets", body: body)
        return try Self.parseClientSecret(data)
    }

    /// Accepts both `{value, expires_at}` and `{client_secret: {value, expires_at}}`.
    static func parseClientSecret(_ data: Data) throws -> RealtimeClientSecret {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OpenAIError.decoding("Client secret response is not JSON")
        }
        let node = root["value"] != nil ? root : (root["client_secret"] ?? .null)
        guard let value = node["value"]?.stringValue,
              case .number(let expires)? = node["expires_at"] else {
            throw OpenAIError.decoding("Client secret response missing value/expires_at")
        }
        return RealtimeClientSecret(value: value, expiresAt: Date(timeIntervalSince1970: expires))
    }

    // MARK: Transport

    private func post(path: String, body: JSONValue) async throws -> Data {
        let key: String
        do {
            key = try await keyProvider.apiKey()
        } catch {
            throw OpenAIError.missingKey
        }
        guard !key.isEmpty else { throw OpenAIError.missingKey }

        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIError.network((error as? URLError)?.code.rawValue.description ?? "request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw OpenAIError.invalidKey
        case 429:
            throw OpenAIError.rateLimited
        default:
            throw OpenAIError.http(http.statusCode, Self.sanitizedErrorMessage(data))
        }
    }

    /// Short, key-free error message. OpenAI error bodies can echo a masked key, so strip `sk-…` tokens.
    static func sanitizedErrorMessage(_ data: Data) -> String {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        let raw = decoded?["error"]?["message"]?.stringValue ?? String(decoding: data, as: UTF8.self)
        let scrubbed = raw.replacingOccurrences(
            of: "sk-[A-Za-z0-9_\\-\\*\\.]+", with: "sk-***", options: .regularExpression)
        return String(scrubbed.prefix(200))
    }
}
