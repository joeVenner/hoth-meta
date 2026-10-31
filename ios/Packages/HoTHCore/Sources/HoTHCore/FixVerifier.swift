import Foundation

/// Compares BEFORE/AFTER photos with the `fix_verify` prompt from prompts.json.
public struct FixVerifier: Sendable {
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

    public func verify(
        before: Data,
        after: Data,
        reportTitle: String,
        category: ReportCategory,
        beforeCapturedAt: Date,
        afterCapturedAt: Date
    ) async throws -> FixVerification {
        let spec = prompts.fixVerify
        guard let schema = spec.jsonSchema else { throw OpenAIError.decoding("fix_verify has no json_schema") }
        let formatter = ISO8601DateFormatter()
        let values = [
            "report_title": reportTitle,
            "category": category.rawValue,
            "before_captured_at": formatter.string(from: beforeCapturedAt),
            "after_captured_at": formatter.string(from: afterCapturedAt)
        ]
        return try await client.structured(
            model: model,
            system: Prompts.fill(spec.system, values),
            user: Prompts.fill(spec.userTemplate, values),
            images: [ImageInput(jpegData: before), ImageInput(jpegData: after)],
            schema: schema,
            as: FixVerification.self
        )
    }
}
