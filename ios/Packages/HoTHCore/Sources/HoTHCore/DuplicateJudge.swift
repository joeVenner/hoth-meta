import Foundation

/// Summary of one report passed to the duplicate judge.
public struct ReportSnapshot: Sendable {
    public let summary: String
    public let category: ReportCategory
    public let capturedAt: Date
    public let jpegData: Data

    public init(summary: String, category: ReportCategory, capturedAt: Date, jpegData: Data) {
        self.summary = summary
        self.category = category
        self.capturedAt = capturedAt
        self.jpegData = jpegData
    }
}

/// Asks the model whether two nearby reports show the same physical issue (`same_issue` prompt).
public struct DuplicateJudge: Sendable {
    private let client: OpenAIClient
    private let prompts: Prompts
    private let modelOverride: String?

    /// - Parameter model: optional model id (e.g. the Settings override); blank or nil falls back to
    ///   `prompts.models.vision`.
    public init(client: OpenAIClient, prompts: Prompts, model: String? = nil) {
        self.client = client
        self.prompts = prompts
        self.modelOverride = model
    }

    /// The model actually sent to the API.
    public var model: String { Prompts.resolveVisionModel(override: modelOverride, prompts: prompts) }

    public func judge(new: ReportSnapshot, existing: ReportSnapshot, distanceMeters: Double) async throws -> SameIssueVerdict {
        let spec = prompts.sameIssue
        guard let schema = spec.jsonSchema else { throw OpenAIError.decoding("same_issue has no json_schema") }
        let formatter = ISO8601DateFormatter()
        let values = [
            "new_summary": new.summary,
            "new_category": new.category.rawValue,
            "new_captured_at": formatter.string(from: new.capturedAt),
            "existing_summary": existing.summary,
            "existing_category": existing.category.rawValue,
            "existing_captured_at": formatter.string(from: existing.capturedAt),
            "distance_m": String(Int(distanceMeters.rounded()))
        ]
        return try await client.structured(
            model: model,
            system: Prompts.fill(spec.system, values),
            user: Prompts.fill(spec.userTemplate, values),
            images: [ImageInput(jpegData: new.jpegData), ImageInput(jpegData: existing.jpegData)],
            schema: schema,
            as: SameIssueVerdict.self
        )
    }
}
