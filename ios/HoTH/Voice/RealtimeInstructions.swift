import Foundation
import HoTHCore

/// Builds the Realtime session instructions from the `voice_persona` template (pure).
enum RealtimeInstructions {

    /// Fills `{{findings}}`, `{{slot_questions}}` and `{{user_language}}` in the persona template.
    static func build(personaTemplate: String, context: InterviewContext) -> String {
        let persona = Prompts.fill(personaTemplate, [
            "findings": findings(analysis: context.analysis, priority: context.priority),
            "slot_questions": slotQuestions(context.slotQuestions),
            "user_language": context.language.isEmpty ? "unknown, detect from speech" : context.language
        ])
        return persona + "\n\n" + firstTurnDirective
    }

    /// The session opens with our own `response.create`, so tell the model exactly how to greet.
    static let firstTurnDirective = """
        First turn (you speak first, the resident has not said anything yet): say you are HoTH's AI assistant, \
        name in a few words what the photo shows (from the findings), give one short empathy line, then ask your \
        first question. If the findings show immediate danger, skip the question and follow the safety steps instead. \
        Use the resident language hint for this first turn.
        """

    /// Short, factual bullet list of what the vision step saw. No numbers or confidence scores.
    static func findings(analysis: VisionAnalysis, priority: PriorityDecision) -> String {
        var lines: [String] = [
            "- Category: \(analysis.category.rawValue)",
            "- Title: \(analysis.titleEN)" + (analysis.titleAR.isEmpty ? "" : " / \(analysis.titleAR)"),
            "- Scene: \(analysis.sceneType.rawValue)"
        ]
        if !analysis.descriptionEN.isEmpty {
            lines.append("- What is visible: \(analysis.descriptionEN)")
        }
        if !analysis.hazards.isEmpty {
            let hazards = analysis.hazards.map { "\($0.label) (\($0.kind.rawValue))" }.joined(separator: "; ")
            lines.append("- Hazards seen: \(hazards)")
        }
        if analysis.childUseEquipment { lines.append("- This is equipment used by children.") }
        if analysis.childPresent { lines.append("- A child appears to be present in the photo.") }
        lines.append("- Proposed priority: \(priority.level.rawValue). \(priority.reasonEN)")
        if let floor = priority.floorApplied { lines.append("- Safety floor: \(floor)") }
        lines.append("- Location is already known from GPS.")
        return lines.joined(separator: "\n")
    }

    static func slotQuestions(_ questions: [String]) -> String {
        let cleaned = questions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "- (none: just confirm the read-back)" }
        return cleaned.prefix(2).map { "- \($0)" }.joined(separator: "\n")
    }
}
