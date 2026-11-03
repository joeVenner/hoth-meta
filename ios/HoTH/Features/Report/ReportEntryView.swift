import HoTHCore
import SwiftData
import SwiftUI

/// Report flow: hosts the golden path (capture → analysis → interview → ticket → posted).
/// Presented full screen from the tab bar's Report button, so the floating tab bar is hidden.
struct ReportEntryView: View {
    @ObservedObject private var services = AppServices.shared
    @Environment(\.modelContext) private var modelContext
    @StateObject private var flow: ReportFlowModel
    private let onClose: () -> Void

    /// - Parameter onClose: dismisses the flow (close button, or "Done" after posting).
    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
        let services = AppServices.shared
        _flow = StateObject(wrappedValue: ReportFlowModel(
            client: services.modelClient,
            prompts: services.prompts,
            language: { AppServices.shared.isArabic ? "ar" : "en" },
            isDemoMode: { AppServices.shared.demoMode },
            hasAPIKey: { AppServices.shared.hasAPIKey() },
            visionModel: { AppServices.shared.visionModel }))
    }

    var body: some View {
        ZStack {
            Color.hothBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                if flow.step != .capture { closeBar }
                content
                    .id(stepKey)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .animation(HoTHMotion.spring, value: stepKey)
        // A sheet (not a full-screen cover or a step swap) so a voice call underneath keeps running.
        .sheet(item: $flow.safetyAlert, onDismiss: { flow.safetySheetDismissed() }) { alert in
            SafetySheet(reason: alert.reason) { flow.continueAfterSafety() }
        }
    }

    private var closeBar: some View {
        HStack {
            Spacer()
            CloseButton(action: close, onDark: false)
        }
        .padding(.horizontal, HoTHSpacing.m)
        .padding(.top, HoTHSpacing.xs)
    }

    private func close() {
        flow.retake()
        onClose()
    }

    /// Identity for transitions; associated values don't need to animate.
    private var stepKey: String {
        switch flow.step {
        case .capture: return "capture"
        case .analyzing: return "analyzing"
        case .needsRetake: return "retake"
        case .failed: return "failed"
        case .duplicate: return "duplicate"
        case .analysis: return "analysis"
        case .interview: return "interview"
        case .ticket: return "ticket"
        case .posted: return "posted"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .capture:
            CaptureView(isDemoMode: services.demoMode, onClose: close) { photo in
                Task { await flow.submit(photo, context: modelContext) }
            }
        case .analyzing:
            AnalyzingView(image: flow.photo?.image)
        case .needsRetake(let message, let reasons):
            NoticeView(symbol: "camera.badge.ellipsis", tint: .hothHigh, title: message, details: reasons,
                       primaryTitle: "Take a live photo", onPrimary: flow.retake)
        case .failed(let message):
            NoticeView(symbol: "wifi.exclamationmark", tint: .hothCritical, title: message, details: [],
                       primaryTitle: "Try again", onPrimary: flow.retake)
        case .duplicate(let outcome):
            DuplicateMergedView(outcome: outcome, isArabic: flow.isArabic,
                                onAddVoiceNote: { flow.addVoiceNote(to: outcome) }, onDone: flow.retake)
        case .analysis:
            if let photo = flow.photo, let analysis = flow.analysis, let priority = flow.priority {
                AnalysisCardView(image: photo.image, analysis: analysis, priority: priority,
                                 plausibility: flow.plausibility, isArabic: flow.isArabic,
                                 isDemoAnalysis: flow.isDemoAnalysis, source: photo.source,
                                 onContinue: flow.continueFromAnalysis, onRetake: flow.retake)
            }
        case .interview:
            if let context = flow.interviewContext {
                InterviewStepView(
                    context: context,
                    slots: flow.slots,
                    // UI tests use the local chat so the golden path costs one live call (vision).
                    client: services.hasAPIKey() && !AppServices.isUITestRun ? services.modelClient : nil,
                    prompts: services.prompts,
                    textModel: services.textModel,
                    // No voice builder yet: Talk is hidden and the interview runs as text until the
                    // push-to-talk interview (Muse Voice Transcribe + on-device speech) lands.
                    voiceBuilder: nil,
                    initialMode: InterviewStepView.initialMode(prefersVoice: services.voiceFirstInterview,
                                                               isUITestRun: AppServices.isUITestRun),
                    onComplete: { flow.interviewCompleted($0, context: modelContext) },
                    onUrgent: { flow.interviewFlaggedUrgent($0) })
            }
        case .ticket:
            if let analysis = flow.analysis, let priority = flow.priority, let team = flow.team {
                TicketView(ticketNumber: flow.ticketNumber, analysis: analysis, priority: priority, team: team,
                           args: flow.submitArgs, slots: flow.slots, photo: flow.photo?.image,
                           isArabic: flow.isArabic) { post, anonymous in
                    await flow.post(toNeighbourhood: post, anonymous: anonymous, context: modelContext)
                }
            }
        case .posted(let ticketNumber, let isPosted):
            PostedView(ticketNumber: ticketNumber, isPosted: isPosted, onDone: close)
        }
    }

}

// MARK: - Analyzing

private struct AnalyzingView: View {
    let image: UIImage?
    @State private var sweep = false

    var body: some View {
        VStack(spacing: HoTHSpacing.l) {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.hothSand
                }
                LinearGradient(colors: [.clear, Color.hothTeal.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .offset(y: sweep ? 160 : -160)
            }
            .frame(height: 340)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous))
            .padding(.horizontal, HoTHSpacing.m)

            VStack(spacing: HoTHSpacing.s) {
                ProgressView().tint(Color.hothTeal)
                Text("Looking closely…").font(.hothTitle).foregroundStyle(Color.hothInk)
                Text("Checking what's broken, how risky it is, and whether neighbours already reported it.")
                    .font(.hothBody)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.hothInkSecondary)
                    .padding(.horizontal, HoTHSpacing.l)
            }
            // Skeleton lines hint at the card that is coming.
            VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                ForEach([0.9, 0.7, 0.5], id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 6).fill(Color.hothSand)
                        .frame(height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: fraction, y: 1, anchor: .leading)
                }
            }
            .padding(.horizontal, HoTHSpacing.xl)
            .redacted(reason: .placeholder)
            Spacer()
        }
        .padding(.top, HoTHSpacing.l)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { sweep = true }
        }
    }
}

// MARK: - Notice (retake / error)

private struct NoticeView: View {
    let symbol: String
    let tint: Color
    let title: String
    let details: [String]
    let primaryTitle: LocalizedStringKey
    let onPrimary: () -> Void

    var body: some View {
        VStack(spacing: HoTHSpacing.l) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 110, height: 110)
                .background(Circle().fill(tint.opacity(0.12)))
            Text(title)
                .font(.hothTitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.hothInk)
            if !details.isEmpty {
                VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
                    ForEach(details, id: \.self) { detail in
                        Label(detail, systemImage: "info.circle")
                            .font(.hothCaption)
                            .foregroundStyle(Color.hothInkSecondary)
                    }
                }
            }
            Spacer()
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("noticePrimaryButton")
        }
        .padding(.horizontal, HoTHSpacing.l)
        .padding(.bottom, HoTHSpacing.l)
    }
}

// MARK: - Duplicate merged

private struct DuplicateMergedView: View {
    let outcome: ReportFlowModel.DuplicateOutcome
    let isArabic: Bool
    let onAddVoiceNote: () -> Void
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var appeared = false
    @State private var mergedReport: Report?

    var body: some View {
        VStack(spacing: HoTHSpacing.l) {
            Spacer()
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.hothTeal.opacity(1 - Double(index) * 0.25))
                        .offset(x: CGFloat(index - 1) * (appeared ? 40 : 0))
                }
            }
            .frame(height: 70)
            Text(message)
                .font(.hothTitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.hothInk)
            HoTHCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isArabic ? outcome.titleAR : outcome.titleEN).font(.hothHeadline)
                            .foregroundStyle(Color.hothInk)
                        Text(verbatim: isArabic ? "على بعد \(outcome.distanceMeters) م" : "\(outcome.distanceMeters) m away")
                            .font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
                    }
                    Spacer()
                    PriorityBadge(levelRaw: outcome.priorityRaw)
                }
            }
            Button(action: openMergedReport) {
                Label("View report", systemImage: "arrow.up.right.square")
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothTeal)
            }
            .accessibilityIdentifier("duplicateViewReportButton")
            Spacer()
            if outcome.hasVoiceNote {
                Label("Voice note added to the report", systemImage: "checkmark.circle.fill")
                    .font(.hothCaption.weight(.semibold))
                    .foregroundStyle(Color.hothSuccess)
            } else {
                Button(action: onAddVoiceNote) {
                    Label("Add a voice note", systemImage: "waveform")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("duplicateVoiceNoteButton")
            }
            Button("Done", action: onDone)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("duplicateDoneButton")
        }
        .sheet(item: $mergedReport) { report in
            NavigationStack { CaseDetailView(report: report) }
        }
        .padding(.horizontal, HoTHSpacing.l)
        .padding(.bottom, HoTHSpacing.l)
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { appeared = true }
        }
    }

    private func openMergedReport() {
        let id = outcome.reportID
        var descriptor = FetchDescriptor<Report>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        mergedReport = (try? modelContext.fetch(descriptor))?.first
    }

    private var message: String {
        let count = outcome.neighbourCount
        return isArabic
            ? "مب بروحك — \(count) من الجيران بلّغوا عن هذا. أضفت صورتك ورفعت الأولوية."
            : "You're not alone — \(count) neighbours already reported this. I've added your photo; priority raised."
    }
}

// MARK: - Close button

/// Round "×" that leaves the report flow.
struct CloseButton: View {
    let action: () -> Void
    var onDark = true

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(onDark ? Color.white : Color.hothInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(onDark ? Color.black.opacity(0.45) : Color.hothSurface))
                .overlay(Circle().strokeBorder((onDark ? Color.white : Color.hothInk).opacity(0.12)))
        }
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier("reportCloseButton")
    }
}
