import Foundation
import HoTHCore

/// Everything an interview (voice or chat) needs to know about the report so far.
///
/// Shared contract between the report flow (`ReportFlowModel`) and the interview (`ChatIntakeModel`,
/// typed or push-to-talk).
struct InterviewContext: Sendable {
    /// What the vision model found in the live photo.
    let analysis: VisionAnalysis
    /// The hybrid priority decision made before the interview.
    let priority: PriorityDecision
    /// Resident language hint, e.g. "en", "ar", "ar-khaleeji".
    let language: String
    /// Slot questions to ask (1-2), already in the resident's language.
    let slotQuestions: [String]

    init(analysis: VisionAnalysis, priority: PriorityDecision, language: String, slotQuestions: [String]) {
        self.analysis = analysis
        self.priority = priority
        self.language = language
        self.slotQuestions = slotQuestions
    }

    /// True when the resident language hint is any Arabic variant.
    var isArabic: Bool { language.lowercased().hasPrefix("ar") }
}
