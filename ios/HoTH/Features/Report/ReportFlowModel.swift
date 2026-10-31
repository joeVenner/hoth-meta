import Foundation
import HoTHCore
import OSLog
import SwiftData
import UIKit

/// The report golden path as a state machine:
/// capture → analyzing → plausibility → dedup → priority → interview → ticket → posted.
@MainActor
final class ReportFlowModel: ObservableObject {
    enum Step: Equatable {
        case capture
        case analyzing
        case needsRetake(message: String, reasons: [String])
        case failed(message: String)
        case duplicate(DuplicateOutcome)
        case analysis
        case interview
        case ticket
        case posted(ticketNumber: String, isPosted: Bool)
    }

    struct DuplicateOutcome: Equatable {
        let reportID: UUID
        let titleEN: String
        let titleAR: String
        let neighbourCount: Int
        let priorityRaw: String
        let distanceMeters: Int
        /// True once the resident added an optional voice note to the merged report.
        var hasVoiceNote = false
    }

    /// How a photo may merge into an existing report.
    enum MergePolicy: Equatable {
        /// A demo sample that is not the duplicate demo: always a new ticket.
        case never
        /// The flagged duplicate demo: merge straight into seeded r10 (no judge call, no category check).
        case intoDuplicateDemoSeed
        /// A live photo: needs a DuplicateJudge "same issue" verdict; no verdict means a new report.
        case judged
    }

    struct SafetyAlert: Identifiable, Equatable {
        let id = UUID()
        let reason: String
        /// True when raised mid voice call: the sheet sits over the live interview and dismissing it
        /// returns to the call instead of jumping to the ticket (tearing down WebRTC would drop the call).
        var keepsInterview = false
        /// True when raised from the analysis card: "Continue report" then starts the interview.
        var resumesInterview = false
    }

    // MARK: Published state

    @Published private(set) var step: Step = .capture
    @Published private(set) var photo: CapturedPhoto?
    @Published private(set) var analysis: VisionAnalysis?
    @Published private(set) var priority: PriorityDecision?
    @Published private(set) var plausibility: PlausibilityResult?
    @Published private(set) var submitArgs: SubmitReportArgs?
    @Published private(set) var isDemoAnalysis = false
    @Published private(set) var blurredImage: UIImage?
    @Published var safetyAlert: SafetyAlert?
    @Published private(set) var reportID = UUID()
    /// MapKit place within 100 m (P2-02); nil means the vision scene decides the location type.
    @Published private(set) var nearbyPlace: LocationType?
    /// Set while the interview records an optional voice note for a merged duplicate.
    @Published private(set) var voiceNoteTarget: DuplicateOutcome?

    // MARK: Dependencies

    private let client: OpenAIClient
    private let prompts: Prompts
    private let isDemoModeProvider: () -> Bool
    private let hasAPIKeyProvider: () -> Bool
    private let languageProvider: () -> String
    private let visionModelProvider: () -> String?
    private var blurTask: Task<FaceAndPlateBlur.Result, Never>?
    private var nearbyPlaceTask: Task<LocationType?, Never>?
    private var hasShownSafety = false
    /// Answers recovered from a voice `flag_urgent` reason, merged into the final priority.
    private var urgentAnswers: [String: String] = [:]
    /// Identifies the current submit run; regenerated on every reset so results from an abandoned run
    /// (retake / close while an OpenAI call is in flight) are dropped instead of overwriting the new one.
    private var runID = UUID()
    /// Re-entrancy guard for `post`: `step` only changes after the blur await, so a double tap needs this.
    private var isPosting = false
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "ReportFlow")

    /// - Parameters:
    ///   - language: resident language hint ("en" / "ar"), read live so a Settings change applies.
    ///   - isDemoMode: read live; demo mode allows bundled photos and the offline canned analysis.
    ///   - hasAPIKey: read live; without a key a demo photo uses its canned analysis (no doomed call).
    ///   - visionModel: read live; the Settings override (nil/blank → prompts.json `models.vision`).
    init(client: OpenAIClient, prompts: Prompts, language: @escaping () -> String,
         isDemoMode: @escaping () -> Bool, hasAPIKey: @escaping () -> Bool = { true },
         visionModel: @escaping () -> String? = { nil }) {
        self.visionModelProvider = visionModel
        self.client = client
        self.prompts = prompts
        self.languageProvider = language
        self.isDemoModeProvider = isDemoMode
        self.hasAPIKeyProvider = hasAPIKey
    }

    var language: String { languageProvider() }
    var isArabic: Bool { language.hasPrefix("ar") }
    var isDemoMode: Bool { isDemoModeProvider() }
    var ticketNumber: String { TicketNumber.make(for: reportID) }

    var team: ReportRouting.Team? {
        analysis.map { ReportRouting.team(for: $0.category) }
    }

    /// Slot questions for the analysed category (1-2).
    var slots: [SlotQuestion] {
        guard let analysis else { return [] }
        return Array(prompts.slots(for: analysis.category).prefix(2))
    }

    var interviewContext: InterviewContext? {
        guard let analysis, let priority else { return nil }
        return InterviewContext(analysis: analysis, priority: priority, language: language,
                                slotQuestions: slots.map { isArabic ? $0.ar : $0.en })
    }

    // MARK: Flow

    /// Entry point after the shutter (or a demo pick): analyse, check, dedup, prioritise.
    func submit(_ captured: CapturedPhoto, context: ModelContext) async {
        reset(keepingStep: true)
        let run = runID  // after reset(), which regenerates it
        photo = captured
        step = .analyzing
        let image = captured.image
        blurTask = Task.detached(priority: .utility) { await FaceAndPlateBlur.blur(image) }
        // P2-02: runs alongside vision; bounded by NearbyPlaces.timeout so it never holds the flow.
        if NearbyPlaces.shouldLookUp(isDemoMode: isDemoMode, hasGPS: captured.gps != nil), let gps = captured.gps {
            nearbyPlaceTask = Task { await NearbyPlaces.lookUp(latitude: gps.latitude, longitude: gps.longitude) }
        }

        // 1. Vision.
        let vision: VisionAnalysis
        if let sample = DemoSamples.sample(id: captured.demoSampleID),
           sample.assetImage == nil || !hasAPIKeyProvider() {
            // No key (offline demo), or a drawn placeholder that would only confuse the model: canned read.
            // With a key, the real photo gets the real analysis (still labelled "Demo photo").
            vision = sample.cannedAnalysis
            isDemoAnalysis = true
        } else {
            do {
                vision = try await VisionAnalyzer(client: client, prompts: prompts, model: visionModelProvider())
                    .analyze(imageData: captured.jpegData, language: language, capturedAt: captured.capturedAt,
                             placeHint: placeHint(for: captured))
                guard run == runID else { return }
                isDemoAnalysis = false
            } catch {
                guard run == runID else { return }
                Self.logger.error("Vision analysis failed: \(String(describing: error))")
                guard isDemoMode else {
                    step = .failed(message: Self.friendlyMessage(for: error, arabic: isArabic))
                    return
                }
                vision = (DemoSamples.sample(id: captured.demoSampleID) ?? DemoSamples.springRider).cannedAnalysis
                isDemoAnalysis = true
            }
        }
        analysis = vision

        // 2. Plausibility, right after analysis so the 2-minute capture window is checked fairly.
        let allowsDemoPhotos = isDemoMode || !CaptureService.hasCamera
        let check = Plausibility.evaluate(PlausibilityInput(
            captureSource: captured.source, capturedAt: captured.capturedAt, now: Date(), gps: captured.gps,
            vision: vision, isDemoMode: allowsDemoPhotos))
        plausibility = check
        if check.status != .accepted {
            let message = isArabic
                ? "ما قدرت أتأكد إن الصورة انأخذت هني الحين — تقدر تصوّر صورة مباشرة من المكان؟"
                : String(localized: "report.retake.message",
                         defaultValue: "I couldn't verify this was taken here just now — could you take a live photo from the spot?")
            step = .needsRetake(message: message, reasons: isArabic ? check.reasonsAR : check.reasonsEN)
            return
        }

        // 3. Priority (before the interview; refined with the answers afterwards). Computed before the
        // duplicate check so a merged duplicate can still record an optional voice note.
        let place = await nearbyPlaceTask?.value
        guard run == runID else { return }
        nearbyPlace = place
        priority = PriorityAgent.decide(PriorityInput(vision: vision, nearbyPlace: place))

        // 4. Duplicate check against open reports nearby.
        let outcome = await mergeIfDuplicate(vision: vision, captured: captured, run: run, context: context)
        guard run == runID else { return }
        if let outcome {
            step = .duplicate(outcome)
            return
        }
        step = .analysis
    }

    /// Called from the analysis card's "Continue". Danger shows the safety sheet first; its
    /// "Continue report" (or a swipe down) then starts the interview. The step stays `.analysis` while
    /// the sheet is up so the voice call does not start talking behind it.
    func continueFromAnalysis() {
        if !hasShownSafety, let reason = preInterviewSafetyReason() {
            hasShownSafety = true
            safetyAlert = SafetyAlert(reason: reason, resumesInterview: true)
            return
        }
        step = .interview
    }

    /// The safety sheet went away without its button (swipe down): never strand the resident on the card.
    func safetySheetDismissed() {
        if step == .analysis, hasShownSafety { step = .interview }
    }

    /// "Add a voice note" on a merged duplicate: the interview runs, and its summary becomes a comment.
    func addVoiceNote(to outcome: DuplicateOutcome) {
        guard case .duplicate = step, interviewContext != nil else { return }
        voiceNoteTarget = outcome
        hasShownSafety = true  // the note never opens the safety sheet or a new ticket
        step = .interview
    }

    func interviewCompleted(_ args: SubmitReportArgs, context: ModelContext? = nil) {
        if let target = voiceNoteTarget {
            voiceNoteTarget = nil
            if let context { attachVoiceNote(args, to: target.reportID, context: context) }
            var updated = target
            updated.hasVoiceNote = true
            step = .duplicate(updated)
            return
        }
        submitArgs = args
        guard let analysis else { return }
        let answers = args.answers.merging(urgentAnswers) { spoken, _ in spoken }
        let refined = PriorityAgent.decide(PriorityInput(vision: analysis, answers: answers, nearbyPlace: nearbyPlace))
        priority = refined
        if !hasShownSafety, let reason = postInterviewSafetyReason(answers: answers, decision: refined) {
            presentSafety(reason: reason, answers: answers)
            return
        }
        step = .ticket
    }

    /// Chat urgency (the chat has already finished): keep what was said, show safety, ticket behind it.
    func interviewFlaggedUrgent(_ reason: String) {
        guard voiceNoteTarget == nil else { return }  // a note on a merged report never files a new ticket
        presentSafety(reason: reason, answers: Self.answers(fromUrgentReason: reason))
    }

    /// Voice `flag_urgent`: show the safety sheet over the live call. The step stays `.interview` so the
    /// WebRTC session keeps running and the assistant can calm the resident and still submit the report.
    func voiceFlaggedUrgent(_ reason: String) {
        guard step == .interview, let analysis else { return interviewFlaggedUrgent(reason) }
        guard voiceNoteTarget == nil else { return }
        let alreadyShown = hasShownSafety
        hasShownSafety = true
        urgentAnswers.merge(Self.answers(fromUrgentReason: reason)) { existing, _ in existing }
        priority = PriorityAgent.decide(PriorityInput(vision: analysis, answers: urgentAnswers, nearbyPlace: nearbyPlace))
        // Already shown before the interview: keep the call going instead of covering it again.
        guard !alreadyShown else { return }
        safetyAlert = SafetyAlert(reason: reason, keepsInterview: true)
    }

    /// "Continue report" on the safety sheet: back to the call, or to the ticket already behind the sheet.
    func continueAfterSafety() {
        let alert = safetyAlert
        safetyAlert = nil
        if alert?.keepsInterview == true, step == .interview { return }
        if alert?.resumesInterview == true || (alert == nil && step == .analysis && hasShownSafety) {
            step = .interview
            return
        }
        if step != .ticket { step = .ticket }
    }

    func retake() {
        reset(keepingStep: false)
    }

    /// Saves the ticket to SwiftData. The posted photo is always the blurred one.
    func post(toNeighbourhood: Bool, anonymous: Bool, context: ModelContext) async {
        guard case .ticket = step, !isPosting, let analysis, let priority, let photo else { return }
        isPosting = true
        defer { isPosting = false }
        let run = runID
        let blur = await finishedBlur(fallback: photo.image)
        guard run == runID else { return }
        let id = reportID
        let originalName = ReportPhotoFiles.save(photo.jpegData, named: "report_\(id.uuidString).jpg")
        // Only a successfully redacted image is ever written as the public file.
        let blurredName = blur.image.flatMap {
            ReportPhotoFiles.save($0, named: "report_\(id.uuidString)_public.jpg")
        }
        let coordinate = coordinate(for: photo)
        let reporter = currentUser(in: context)
        let args = submitArgs

        let report = Report(
            id: id,
            createdAt: photo.capturedAt,
            category: IssueCategory(rawValue: analysis.category.rawValue) ?? .other,
            titleEN: analysis.titleEN,
            titleAR: analysis.titleAR,
            summaryEN: args?.summaryEN ?? analysis.descriptionEN,
            summaryAR: args?.summaryAR ?? analysis.descriptionAR,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeName: isArabic ? "بالقرب منك" : "Near you",
            photoFileName: originalName,
            // Never fall back to the original: if the blurred save failed, nothing is shown publicly.
            blurredPhotoFileName: blurredName,
            analysisJSON: try? JSONEncoder().encode(analysis),
            priority: PriorityLevel(rawValue: priority.level.rawValue) ?? .medium,
            priorityScore: priority.score,
            priorityReasonEN: priority.reasonEN,
            priorityReasonAR: priority.reasonAR,
            signals: priority.signals.map(\.id),
            // Privacy invariant: no blurred file, no public post (the feed would fall back to the original).
            isPosted: Self.canPostPublicly(wantsToPost: toNeighbourhood, blur: blur, blurredFileName: blurredName),
            isAnonymous: anonymous,
            reporter: reporter
        )
        context.insert(report)
        if report.isPosted, let reporter {
            award(Rewards.firstReporterPoints, reason: .reportPosted, to: reporter, reportID: id, context: context)
        }
        do {
            try context.save()
        } catch {
            Self.logger.error("Saving report failed: \(String(describing: error))")
        }
        NeighbourAlertCenter.shared.reportPosted(report)
        step = .posted(ticketNumber: ticketNumber, isPosted: report.isPosted)
    }

    // MARK: Safety

    /// Shows the safety cover and moves the flow to the ticket behind it, so the interview unmounts
    /// (no more questions) and the priority reflects what the resident already said.
    private func presentSafety(reason: String, answers: [String: String]) {
        hasShownSafety = true
        if let analysis {
            let merged = (submitArgs?.answers ?? [:]).merging(answers) { existing, _ in existing }
            priority = PriorityAgent.decide(PriorityInput(vision: analysis, answers: merged, nearbyPlace: nearbyPlace))
            if submitArgs == nil {
                let details = merged.map { "\($0.key.replacingOccurrences(of: "_", with: " ")): \($0.value)" }
                    .sorted().joined(separator: "; ")
                submitArgs = SubmitReportArgsFactory.make(
                    summaryEN: details.isEmpty ? analysis.titleEN : "\(analysis.titleEN) — \(details)",
                    summaryAR: analysis.titleAR, answers: merged,
                    userLanguage: language, wantsToPost: true, anonymous: false)
            }
        }
        step = .ticket
        safetyAlert = SafetyAlert(reason: reason)
    }

    /// Recovers slot answers from an urgency reason: chat sends "slot_id: answer" pairs; voice sends
    /// free text, mapped by keyword so the priority floors still see the danger.
    static func answers(fromUrgentReason reason: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in reason.split(separator: ";") {
            let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2, !pieces[0].contains(" "), !pieces[0].isEmpty {
                result[pieces[0]] = pieces[1]
            }
        }
        let lowered = reason.lowercased()
        if lowered.contains("spark") || lowered.contains("buzz") || lowered.contains("شرار") {
            result["sparking"] = result["sparking"] ?? "yes"
        }
        if lowered.contains("water") || lowered.contains("ماي") || lowered.contains("ماء") {
            result["near_water"] = result["near_water"] ?? "yes"
        }
        if lowered.contains("child") || lowered.contains("kid") || lowered.contains("أطفال") || lowered.contains("عيال") {
            result["children_using_now"] = result["children_using_now"] ?? "yes"
        }
        return result
    }

    /// Electrical / open manhole at critical, or a child visibly on broken equipment.
    private func preInterviewSafetyReason() -> String? {
        guard let analysis, let priority, priority.level == .critical else { return nil }
        if analysis.category == .openManhole { return "open_manhole" }
        if analysis.category == .electricalHazard || analysis.hasHazard(.electrical) { return "electrical" }
        if analysis.childUseEquipment && analysis.childPresent { return "child_on_equipment" }
        return nil
    }

    private func postInterviewSafetyReason(answers: [String: String], decision: PriorityDecision) -> String? {
        guard decision.level == .critical, let analysis else { return nil }
        if AnswerParsing.isAffirmative(answers["sparking"]) || AnswerParsing.isAffirmative(answers["near_water"]) {
            return "electrical"
        }
        if analysis.childUseEquipment && AnswerParsing.isAffirmative(answers["children_using_now"]) {
            return "child_on_equipment"
        }
        return preInterviewSafetyReason()
    }

    // MARK: Dedup

    private func mergeIfDuplicate(vision: VisionAnalysis, captured: CapturedPhoto, run: UUID,
                                  context: ModelContext) async -> DuplicateOutcome? {
        let here = coordinate(for: captured)
        let reports: [Report]
        do {
            reports = try context.fetch(FetchDescriptor<Report>())
        } catch {
            Self.logger.error("Dedup fetch failed: \(String(describing: error))")
            return nil
        }
        switch Self.mergePolicy(demoSampleID: captured.demoSampleID) {
        case .never:
            return nil
        case .intoDuplicateDemoSeed:
            guard let seed = Self.duplicateDemoSeed(in: reports) else { return nil }
            let distance = Dedup.haversineMeters(here, Coordinate(latitude: seed.latitude, longitude: seed.longitude))
            return merge(into: seed, distance: distance, context: context)
        case .judged:
            break
        }
        let existing = reports.compactMap { report -> ExistingReport? in
            guard let category = ReportCategory(rawValue: report.categoryRaw) else { return nil }
            let isOpen = report.status == .open || report.status == .inProgress
            return ExistingReport(id: report.id.uuidString, category: category,
                                  coordinate: Coordinate(latitude: report.latitude, longitude: report.longitude),
                                  isOpen: isOpen)
        }
        guard let nearest = Dedup.candidates(for: vision.category, at: here, among: existing).first,
              let match = reports.first(where: { $0.id.uuidString == nearest.report.id }) else {
            return nil
        }

        var verdict: SameIssueVerdict?
        if !isDemoAnalysis, let existingJPEG = ReportPhotoFiles.loadJPEG(match.photoFileName) {
            do {
                verdict = try await DuplicateJudge(client: client, prompts: prompts, model: visionModelProvider()).judge(
                    new: ReportSnapshot(summary: vision.descriptionEN, category: vision.category,
                                        capturedAt: captured.capturedAt, jpegData: captured.jpegData),
                    existing: ReportSnapshot(summary: match.summaryEN, category: vision.category,
                                             capturedAt: match.createdAt, jpegData: existingJPEG),
                    distanceMeters: nearest.distanceMeters)
            } catch {
                Self.logger.error("Duplicate judge unavailable: \(String(describing: error))")
            }
            guard run == runID else { return nil }
        }

        switch Dedup.decide(nearest: nearest, verdict: verdict) {
        case .duplicate:
            break
        case .candidate, .newReport, .distinct:
            // No verdict (offline, no photo to compare): file a new report rather than guess, in every mode.
            return nil
        }
        guard run == runID else { return nil }
        return merge(into: match, distance: nearest.distanceMeters, context: context)
    }

    /// Demo samples decide by flag, never by distance or judge: only the duplicate demo merges.
    /// Live photos (no sample id) go through the judge. An unknown sample id never merges.
    nonisolated static func mergePolicy(demoSampleID: String?) -> MergePolicy {
        guard let demoSampleID else { return .judged }
        return DemoSamples.sample(id: demoSampleID)?.isDuplicateDemo == true ? .intoDuplicateDemoSeed : .never
    }

    /// Seeded r10 (open or in progress), the duplicate demo's fixed target.
    static func duplicateDemoSeed(in reports: [Report]) -> Report? {
        reports.first {
            $0.isDemoSeed && $0.photoFileName == DemoSamples.duplicateDemoSeedPhoto
                && ($0.status == .open || $0.status == .inProgress)
        }
    }

    /// Stores the voice note's summary as an approved comment from the resident on the merged report.
    private func attachVoiceNote(_ args: SubmitReportArgs, to reportID: UUID, context: ModelContext) {
        let text = (isArabic ? args.summaryAR : args.summaryEN).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (isArabic ? args.summaryEN : args.summaryAR).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = text.isEmpty ? fallback : text
        guard !note.isEmpty else { return }
        var descriptor = FetchDescriptor<Report>(predicate: #Predicate { $0.id == reportID })
        descriptor.fetchLimit = 1
        guard let report = (try? context.fetch(descriptor))?.first else { return }
        let comment = Comment(author: currentUser(in: context), text: note, moderationStatus: .allowed)
        context.insert(comment)
        comment.report = report
        do {
            try context.save()
        } catch {
            Self.logger.error("Saving voice note failed: \(String(describing: error))")
        }
    }

    private func merge(into report: Report, distance: Double, context: ModelContext) -> DuplicateOutcome {
        report.confirmations += 1
        report.mergedReportIDs.append(reportID)
        // Same recompute as the feed's "I saw it too", so score, reason and signals match. Never lowers.
        report.recomputePriority()
        // +10 once per report: the feed's "I saw it too" reads the same confirmed-ids key, so a merge
        // followed by a manual confirm (or a second merge) never pays twice. No points on your own report.
        if let user = currentUser(in: context), report.reporter?.id != user.id,
           ConfirmedReports.insert(report.id) {
            award(Rewards.confirmationPoints, reason: .confirmation, to: user, reportID: report.id, context: context)
        }
        do {
            try context.save()
        } catch {
            Self.logger.error("Saving merge failed: \(String(describing: error))")
        }
        return DuplicateOutcome(reportID: report.id, titleEN: report.titleEN, titleAR: report.titleAR,
                                neighbourCount: report.confirmations, priorityRaw: report.priorityRaw,
                                distanceMeters: Int(distance.rounded()))
    }

    // MARK: Helpers

    private func reset(keepingStep: Bool) {
        blurTask?.cancel()
        blurTask = nil
        nearbyPlaceTask?.cancel()
        nearbyPlaceTask = nil
        nearbyPlace = nil
        photo = nil
        analysis = nil
        priority = nil
        plausibility = nil
        submitArgs = nil
        isDemoAnalysis = false
        blurredImage = nil
        blurResult = nil
        safetyAlert = nil
        hasShownSafety = false
        voiceNoteTarget = nil
        urgentAnswers = [:]
        reportID = UUID()
        runID = UUID()
        if !keepingStep { step = .capture }
    }

    private var blurResult: FaceAndPlateBlur.Result?

    private func finishedBlur(fallback: UIImage) async -> FaceAndPlateBlur.Result {
        if let blurResult { return blurResult }
        let run = runID
        let result: FaceAndPlateBlur.Result
        if let blurTask {
            result = await blurTask.value
        } else {
            result = await FaceAndPlateBlur.blur(fallback)
        }
        // A stale run's blur must never be cached (it would be posted with the next report).
        guard run == runID else { return result }
        blurResult = result
        // Previews only ever show a redacted image.
        blurredImage = result.image
        return result
    }

    /// Blurred photo for previews once ready (kicks off nothing new).
    func loadBlurPreview() async {
        guard blurredImage == nil, let blurTask else { return }
        let run = runID
        let result = await blurTask.value
        guard run == runID else { return }
        blurResult = result
        blurredImage = result.image
    }

    /// Privacy invariant: a report goes public only when the resident asked for it, redaction
    /// succeeded, and the redacted file was saved (otherwise the feed has nothing safe to show).
    nonisolated static func canPostPublicly(wantsToPost: Bool, blur: FaceAndPlateBlur.Result,
                                            blurredFileName: String?) -> Bool {
        wantsToPost && blur.isSafeToPost && blurredFileName != nil
    }

    private func coordinate(for photo: CapturedPhoto) -> Coordinate {
        if let gps = photo.gps { return Coordinate(latitude: gps.latitude, longitude: gps.longitude) }
        return DemoSamples.sample(id: photo.demoSampleID)?.coordinate ?? DemoSamples.areaCentre
    }

    /// Coordinates rounded to 3 decimals (~100 m): enough for "where is this", without the precise spot.
    private func placeHint(for photo: CapturedPhoto) -> String {
        guard let gps = photo.gps else { return "unknown" }
        return String(format: "lat %.3f, lon %.3f (±%.0f m)", gps.latitude, gps.longitude, gps.accuracyMeters)
    }

    private func currentUser(in context: ModelContext) -> Neighbour? {
        var descriptor = FetchDescriptor<Neighbour>(predicate: #Predicate { $0.isCurrentUser })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func award(_ points: Int, reason: PointsReason, to user: Neighbour, reportID: UUID, context: ModelContext) {
        user.points += points
        context.insert(PointsEvent(user: user, delta: points, reason: reason, reportID: reportID))
    }

    static func friendlyMessage(for error: Error, arabic: Bool) -> String {
        switch error as? OpenAIError {
        case .missingKey, .invalidKey:
            return arabic
                ? "مفتاح الذكاء الاصطناعي غير مضبوط. أضفه من الإعدادات أو فعّل الوضع التجريبي."
                : String(localized: "report.error.key",
                         defaultValue: "The AI key isn't set up. Add it in Settings, or turn on Demo mode.")
        case .network:
            return arabic
                ? "ما في اتصال بالإنترنت. جرّب مرة ثانية."
                : String(localized: "report.error.offline", defaultValue: "You seem to be offline. Please try again.")
        case .rateLimited:
            return arabic
                ? "الخدمة مشغولة الحين. جرّب بعد شوي."
                : String(localized: "report.error.busy", defaultValue: "The AI is busy right now. Please try again in a moment.")
        default:
            return arabic
                ? "ما قدرت أحلل الصورة. جرّب مرة ثانية."
                : String(localized: "report.error.generic", defaultValue: "I couldn't analyse this photo. Please try again.")
        }
    }
}
