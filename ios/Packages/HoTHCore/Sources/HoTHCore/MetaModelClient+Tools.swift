import Foundation

/// A developer-defined function tool in the Responses API's flat shape
/// (dev.meta.ai/docs/tool-calling: `type`, `name`, `description`, `parameters` at the top level).
public struct FunctionTool: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments. Sent without `strict`: the server only validates the schema then,
    /// and the model's arguments are never guaranteed to match, so callers clamp them anyway.
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var requestValue: JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "parameters": parameters
        ])
    }
}

/// One `function_call` output item.
public struct FunctionCall: Equatable, Sendable {
    public let callID: String
    public let name: String
    /// The raw JSON string the model produced; may be malformed.
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }

    /// The arguments as a JSON object, or nil when they do not parse as one.
    public var argumentsObject: [String: JSONValue]? {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)) else {
            return nil
        }
        return object
    }
}

/// One Responses call made with tools: what the model asked for, or its final text.
public struct ToolRoundResponse: Sendable {
    /// Every `output` item as returned (reasoning with `encrypted_content`, commentary, function calls),
    /// replayed verbatim on the next round so ordering and `phase` stay exactly as the server sent them.
    public let outputItems: [JSONValue]
    public let functionCalls: [FunctionCall]
    /// The final message text; nil while the model is still calling tools.
    public let outputText: String?
}

/// A tool call and the result the app returned for it, kept for logging and for the single-turn fallback.
public struct ToolCallRecord: Equatable, Sendable {
    public let name: String
    public let arguments: String
    public let output: String

    public init(name: String, arguments: String, output: String) {
        self.name = name
        self.arguments = arguments
        self.output = output
    }
}

extension MetaModelClient {
    /// One POST /v1/responses with function tools and (optionally) a json_schema final answer.
    ///
    /// Stateless encrypted replay (`store: false` + `include: ["reasoning.encrypted_content"]`, the path the
    /// docs recommend for agents): the server keeps no copy of the conversation, and the caller resends the
    /// whole `input` each round. Never combined with `previous_response_id` (HTTP 400). `tool_choice` is left
    /// out: only "auto" (the default) is accepted.
    ///
    /// - Parameter input: Responses input items (messages, replayed output items, `function_call_output`s).
    public func respond(
        model: String,
        input: [JSONValue],
        tools: [FunctionTool],
        schema: JSONSchemaSpec?
    ) async throws -> ToolRoundResponse {
        var fields: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input),
            "store": .bool(false),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if !tools.isEmpty {
            fields["tools"] = .array(tools.map(\.requestValue))
        }
        if let schema {
            fields["text"] = .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(schema.name),
                    "strict": .bool(schema.strict),
                    "schema": schema.schema
                ])
            ])
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            fields["reasoning"] = .object(["effort": .string(reasoningEffort)])
        }
        let data = try await postJSON(path: "responses", body: .object(fields))
        return try Self.parseToolRound(data)
    }

    static func parseToolRound(_ data: Data) throws -> ToolRoundResponse {
        // Throws on incomplete/refused/non-JSON before we look at function calls.
        let text = try extractOutputText(from: data)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let output)? = root["output"] else {
            throw ModelAPIError.decoding("Response has no output array")
        }
        var calls: [FunctionCall] = []
        for item in output where item["type"]?.stringValue == "function_call" {
            guard let callID = item["call_id"]?.stringValue, !callID.isEmpty,
                  let name = item["name"]?.stringValue else {
                throw ModelAPIError.decoding("function_call without call_id or name")
            }
            calls.append(FunctionCall(callID: callID, name: name, arguments: item["arguments"]?.stringValue ?? "{}"))
        }
        // Commentary before a tool call is not the answer; only a call-free round has final text.
        return ToolRoundResponse(outputItems: output, functionCalls: calls, outputText: calls.isEmpty ? text : nil)
    }

    /// A Responses message input item.
    public static func messageItem(role: String, text: String) -> JSONValue {
        .object([
            "role": .string(role),
            "content": .array([.object(["type": .string("input_text"), "text": .string(text)])])
        ])
    }

    /// The `function_call_output` answering `callID`.
    public static func functionCallOutput(callID: String, output: String) -> JSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(output)
        ])
    }
}

/// A bounded tool-calling loop on top of `MetaModelClient.respond`.
///
/// Every function call in a round gets exactly one `function_call_output` before the next request (an unpaired
/// call is HTTP 400), including unknown names and bad arguments: the executor returns an error JSON for those.
public enum ToolLoop {
    public enum Outcome<T> {
        /// The model answered; `rounds` counts tool rounds (0 = answered straight away).
        case final(T, rounds: Int, calls: [ToolCallRecord])
        /// Still calling tools after `maxRounds`; the caller decides how to finish without tools.
        case roundLimit(calls: [ToolCallRecord])
    }

    /// - Parameters:
    ///   - maxRounds: tool rounds allowed before giving up; at most `maxRounds + 1` requests.
    ///   - execute: runs one call and returns its result text (JSON). Called in order, on the caller's actor.
    /// - Throws: the client's `ModelAPIError`, or `.decoding` when the final text does not match `T`.
    public static func run<T: Decodable>(
        client: MetaModelClient,
        model: String,
        system: String,
        user: String,
        tools: [FunctionTool],
        schema: JSONSchemaSpec,
        maxRounds: Int = 4,
        as type: T.Type = T.self,
        isolation: isolated (any Actor)? = #isolation,
        execute: (FunctionCall) async -> String
    ) async throws -> Outcome<T> {
        var input: [JSONValue] = [
            MetaModelClient.messageItem(role: "system", text: system),
            MetaModelClient.messageItem(role: "user", text: user)
        ]
        var records: [ToolCallRecord] = []
        for round in 0...max(maxRounds, 0) {
            let response = try await client.respond(model: model, input: input, tools: tools, schema: schema)
            if response.functionCalls.isEmpty {
                guard let text = response.outputText else {
                    throw ModelAPIError.decoding("No output_text and no function_call in response")
                }
                do {
                    let value = try JSONDecoder().decode(T.self, from: Data(text.utf8))
                    return .final(value, rounds: round, calls: records)
                } catch {
                    throw ModelAPIError.decoding("Output did not match \(T.self): \(error)")
                }
            }
            guard round < maxRounds else { break }
            input += response.outputItems
            for call in response.functionCalls {
                let output = await execute(call)
                records.append(ToolCallRecord(name: call.name, arguments: call.arguments, output: output))
                input.append(MetaModelClient.functionCallOutput(callID: call.callID, output: output))
            }
            // Tools do not throw; stop here instead of paying for another round nobody will read.
            try Task.checkCancellation()
        }
        return .roundLimit(calls: records)
    }
}
