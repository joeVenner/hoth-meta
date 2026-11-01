import SwiftData
import SwiftUI
import UIKit

/// Crew case (P1-02/P1-03): details, "Start work", "Upload repair photo", and the AI fix verdict.
struct CrewCaseView: View {
    @Bindable var report: Report
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var services = AppServices.shared
    @StateObject private var fixCheck = FixCheckModel()
    @State private var isPickingDemo = false
    @State private var isShowingCamera = false
    @State private var actionError: String?

    private var isArabic: Bool { services.isArabic }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                ReportPhotoView(fileName: report.displayPhotoFileName, category: report.category, priority: report.priority)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous))

                HStack(spacing: 6) {
                    PriorityBadge(levelRaw: report.priorityRaw)
                    CategoryChip(categoryRaw: report.categoryRaw)
                    Spacer(minLength: 0)
                    StatusPill(status: report.status)
                }
                Text(report.title(arabic: isArabic))
                    .font(.hothTitle)
                    .foregroundStyle(Color.hothInk)
                Text(report.priorityReason(arabic: isArabic))
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInkSecondary)
                let team = CrewQueue.team(for: report)
                Label {
                    Text("Routed to \(team.name(arabic: isArabic))")
                } icon: { Image(systemName: team.symbol) }
                    .font(.hothCaption.weight(.semibold))
                    .foregroundStyle(Color.hothTeal)

                actions
                verdictSection.id("verdict")
            }
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.bottom, 140)
        }
        .onChange(of: fixCheck.phase) { _, phase in
            guard phase == .verdict || phase == .checking else { return }
            withAnimation(HoTHMotion.spring) { scroller.scrollTo("verdict", anchor: .top) }
        }
        }
        .background(Color.hothBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.hothBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $isPickingDemo) { demoPicker }
        .fullScreenCover(isPresented: $isShowingCamera) {
            RepairPhotoPicker { image in
                isShowingCamera = false
                if let image { runCheck(after: image, demo: nil) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $fixCheck.celebration) { celebration in
            FixedCelebrationView(celebration: celebration, isArabic: isArabic)
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        if CrewWorkflow.isActionable(report.status) {
            VStack(spacing: HoTHSpacing.s) {
                if report.status == .open {
                    Button {
                        do {
                            try CrewWorkflow.startWork(on: report)
                            try modelContext.save()
                            Haptics.tap()
                        } catch {
                            actionError = String(describing: error)
                        }
                    } label: {
                        Label("Start work", systemImage: "wrench.and.screwdriver.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("crewStartWorkButton")
                }
                Button {
                    if services.demoMode { isPickingDemo = true } else { isShowingCamera = true }
                } label: {
                    Label("Upload repair photo", systemImage: "camera.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(fixCheck.phase == .checking)
                .accessibilityIdentifier("crewUploadRepairButton")
                if let actionError {
                    Text(actionError).font(.hothCaption).foregroundStyle(Color.hothCritical)
                }
            }
            .padding(.top, HoTHSpacing.s)
        } else if report.status == .fixed {
            Label {
                if let fixedAt = report.fixedAt {
                    Text("Fixed \(fixedAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Fixed")
                }
            } icon: { Image(systemName: "checkmark.seal.fill") }
                .font(.hothHeadline)
                .foregroundStyle(Color.hothSuccess)
        }
    }

    private func runCheck(after: UIImage, demo: DemoFixPhoto?) {
        Task { await fixCheck.check(report: report, after: after, demo: demo, context: modelContext) }
    }

    private var demoPicker: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                Text("Pick a bundled repair photo. It is clearly a demo photo, not a live capture.")
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInkSecondary)
                HStack(spacing: HoTHSpacing.m) {
                    ForEach(DemoFixPhoto.allCases) { photo in
                        Button {
                            isPickingDemo = false
                            if let image = UIImage(named: photo.rawValue) { runCheck(after: image, demo: photo) }
                        } label: {
                            VStack(spacing: HoTHSpacing.xs) {
                                Image(photo.rawValue)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous))
                                    .overlay(alignment: .topLeading) { DemoPhotoTag().padding(6) }
                                Text(photo == .bad ? "Partial repair" : "Full repair")
                                    .font(.hothCaption.weight(.semibold))
                                    .foregroundStyle(Color.hothInk)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("demoFix_\(photo == .bad ? "bad" : "good")")
                    }
                }
                Button {
                    isPickingDemo = false
                    isShowingCamera = true
                } label: {
                    Label("Use the camera instead", systemImage: "camera")
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(HoTHSpacing.m)
            .navigationTitle(Text("Repair photo"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    // MARK: Verdict

    @ViewBuilder private var verdictSection: some View {
        switch fixCheck.phase {
        case .idle:
            EmptyView()
        case .checking:
            HoTHCard {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking the repair against the original photo…")
                        .font(.hothBody)
                        .foregroundStyle(Color.hothInk)
                }
            }
            .accessibilityIdentifier("fixChecking")
        case .failed(let message):
            HoTHCard {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.hothBody)
                    .foregroundStyle(Color.hothCritical)
            }
        case .verdict:
            if let verdict = fixCheck.verdict { verdictCard(verdict) }
        }
    }

    private func verdictCard(_ verdict: FixVerdict) -> some View {
        HoTHCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: HoTHSpacing.s) {
                    Image(systemName: verdict.resolved ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text(verdict.resolved ? "Fixed — verified" : "Not fixed yet")
                        .font(.hothTitle)
                }
                .foregroundStyle(verdict.resolved ? Color.hothSuccess : Color.hothCritical)
                .accessibilityIdentifier(verdict.resolved ? "fixVerdictResolved" : "fixVerdictRejected")

                if let after = fixCheck.afterImage {
                    let remaining = FixCheckModel.remainingRegions(verdict: verdict, sam: fixCheck.samRemaining)
                    // SAM regions carry the English concept; show its Arabic name in the Arabic UI.
                    RemainingIssuesImage(image: after, regions: remaining.regions.map {
                        FixVerdict.Region(label: services.prompts.segmentConceptDisplayName($0.label, arabic: isArabic), box: $0.box)
                    })
                        .overlay(alignment: .topLeading) {
                            if fixCheck.isDemoPhoto { DemoPhotoTag().padding(8) }
                        }
                        .animation(.easeOut(duration: 0.35), value: remaining.isFromSAM)
                    if remaining.isFromSAM, let concept = fixCheck.samRemaining?.concept {
                        SAMOutlineChip(concept: services.prompts.segmentConceptDisplayName(concept, arabic: isArabic))
                    }
                }
                Text(verdict.reasonEN)
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInk)
                if !verdict.reasonAR.isEmpty {
                    Text(verdict.reasonAR)
                        .font(.hothBody)
                        .foregroundStyle(Color.hothInkSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                Text(verdict.resolved
                     ? "Status set to Fixed. The reporter gets +50 points."
                     : "Status stays open. Upload a new photo once the work is done.")
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
                if verdict.isCanned {
                    Text("Demo verdict (offline)")
                        .font(.hothCaption.weight(.semibold))
                        .foregroundStyle(Color.hothTeal)
                }
            }
        }
    }
}

/// After photo with red boxes on the remaining issues (normalised, top-left origin). Aspect-fit so
/// boxes line up with the pixels.
struct RemainingIssuesImage: View {
    let image: UIImage
    let regions: [FixVerdict.Region]

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                        let rect = CGRect(x: region.box.minX * proxy.size.width,
                                          y: region.box.minY * proxy.size.height,
                                          width: region.box.width * proxy.size.width,
                                          height: region.box.height * proxy.size.height)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.hothCritical, lineWidth: 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.hothCritical.opacity(0.15)))
                            .frame(width: rect.width, height: rect.height)
                            .overlay(alignment: .topLeading) {
                                Text(region.label)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.hothCritical))
                                    .fixedSize()
                                    .offset(y: -20)
                            }
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                // Boxes are image coordinates: never mirror them in RTL.
                .environment(\.layoutDirection, .leftToRight)
            }
            .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous))
            .accessibilityIdentifier("fixAfterPhoto")
    }
}

struct DemoPhotoTag: View {
    var body: some View {
        Label("Demo photo", systemImage: "photo")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.6)))
    }
}

/// Camera (or photo library on the simulator) for the repair photo.
struct RepairPhotoPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
