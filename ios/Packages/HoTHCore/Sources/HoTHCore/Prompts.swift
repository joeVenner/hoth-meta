import Foundation

/// A strict JSON schema block from prompts.json (`{name, strict, schema}`), forwarded verbatim.
public struct JSONSchemaSpec: Codable, Equatable, Sendable {
    public let name: String
    public let strict: Bool
    public let schema: JSONValue
}

/// A prompt with a system message, user template and optional strict output schema.
public struct PromptSpec: Codable, Equatable, Sendable {
    public let system: String
    public let userTemplate: String
    public let jsonSchema: JSONSchemaSpec?

    enum CodingKeys: String, CodingKey {
        case system
        case userTemplate = "user_template"
        case jsonSchema = "json_schema"
    }
}

/// Voice/chat interview question for one category.
public struct SlotQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let en: String
    public let ar: String
    /// "yes" or "always" when the answer signals immediate danger.
    public let urgentIf: String?

    enum CodingKeys: String, CodingKey {
        case id, en, ar
        case urgentIf = "urgent_if"
    }
}

/// Meta model ids (`models` in prompts.json).
public struct ModelIDs: Codable, Equatable, Sendable {
    /// Muse Spark: photo analysis, duplicate judge, fix check.
    public let vision: String
    /// Muse Spark: chat intake and comment moderation.
    public let text: String
    /// Muse Voice Transcribe: speech to text.
    public let transcribe: String
    /// SAM 3.1: concept segmentation.
    public let segment: String
}

public enum PromptsError: Error, Equatable {
    case resourceNotFound(String)
    case decoding(String)
}

/// Decoded `prompts.json`. The app passes `Bundle.main`; tests pass raw data.
public struct Prompts: Codable, Sendable {
    public let version: Int
    public let models: ModelIDs
    public let categories: [ReportCategory]
    public let severityLevels: [Severity]
    public let sharedRules: String
    public let visionAnalyze: PromptSpec
    public let fixVerify: PromptSpec
    public let sameIssue: PromptSpec
    public let slots: [String: [SlotQuestion]]
    public let chatIntake: PromptSpec
    public let moderation: PromptSpec
    /// SAM 3.1 noun phrase per category raw value (`segment_concepts`); absent in older files.
    public let segmentConcepts: [String: String]?

    enum CodingKeys: String, CodingKey {
        case version, models, categories
        case severityLevels = "severity_levels"
        case sharedRules = "shared_rules"
        case visionAnalyze = "vision_analyze"
        case fixVerify = "fix_verify"
        case sameIssue = "same_issue"
        case slots
        case chatIntake = "chat_intake"
        case moderation
        case segmentConcepts = "segment_concepts"
    }

    public init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(Prompts.self, from: data)
        } catch {
            throw PromptsError.decoding(String(describing: error))
        }
    }

    /// Loads `prompts.json` from the given bundle (the app passes `Bundle.main`).
    public init(bundle: Bundle, resource: String = "prompts") throws {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw PromptsError.resourceNotFound("\(resource).json")
        }
        try self.init(data: try Data(contentsOf: url))
    }

    public func slots(for category: ReportCategory) -> [SlotQuestion] {
        slots[category.rawValue] ?? []
    }

    /// The SAM concept for a category, or nil when it has none (`other`, `not_an_issue`): no SAM call then.
    public func segmentConcept(for category: ReportCategory) -> String? {
        let phrase = segmentConcepts?[category.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return phrase.isEmpty ? nil : phrase
    }

    /// The vision model to call: a non-blank override (Settings) wins, else `models.vision`.
    public static func resolveVisionModel(override: String?, prompts: Prompts) -> String {
        resolve(override: override, default: prompts.models.vision)
    }

    /// The text model to call: a non-blank override (Settings) wins, else `models.text`.
    public static func resolveTextModel(override: String?, prompts: Prompts) -> String {
        resolve(override: override, default: prompts.models.text)
    }

    private static func resolve(override: String?, default fallback: String) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Replaces every `{{name}}` placeholder; unknown placeholders are left untouched.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { partial, entry in
            partial.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}
