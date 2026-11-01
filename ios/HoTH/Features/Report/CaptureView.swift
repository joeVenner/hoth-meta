import AVFoundation
import HoTHCore
import SwiftUI
import UIKit

/// Full-screen live camera with a big shutter, GPS/time stamp and the live-only trust note (P0-12).
/// In demo mode (or on a simulator without a camera) a clearly labelled "Demo photo" picker appears.
struct CaptureView: View {
    let isDemoMode: Bool
    var onClose: (() -> Void)?
    let onCaptured: (CapturedPhoto) -> Void

    @StateObject private var capture = CaptureService()
    @State private var isCapturing = false
    @State private var showDemoPicker = false
    @State private var errorText: LocalizedStringKey?
    @State private var flash = false

    private var showsDemoOption: Bool { isDemoMode || capture.cameraState != .running }

    /// Live shots need a usable fix, otherwise plausibility would reject them after the fact.
    private var hasUsableFix: Bool {
        guard let fix = capture.latestFix else { return false }
        return fix.accuracyMeters >= 0 && fix.accuracyMeters <= Plausibility.maxGPSAccuracyMeters
    }

    private var canShoot: Bool { capture.cameraState == .running && hasUsableFix && !isCapturing }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraLayer.ignoresSafeArea()
            if flash { Color.white.ignoresSafeArea().transition(.opacity) }

            VStack(spacing: HoTHSpacing.m) {
                topBar
                Spacer()
                if let errorText {
                    Text(errorText)
                        .font(.hothCaption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, HoTHSpacing.m)
                        .padding(.vertical, HoTHSpacing.s)
                        .background(Capsule().fill(Color.hothCritical.opacity(0.85)))
                }
                trustNote
                controls
            }
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.bottom, HoTHSpacing.m)
        }
        .task { await capture.start() }
        .onDisappear { capture.stop() }
        .sheet(isPresented: $showDemoPicker) {
            DemoPhotoPicker { sample in
                showDemoPicker = false
                pickDemo(sample)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Layers

    @ViewBuilder
    private var cameraLayer: some View {
        switch capture.cameraState {
        case .running:
            CameraPreview(session: capture.session)
        case .denied:
            unavailableView(symbol: "video.slash.fill",
                            title: "Camera access is off",
                            detail: "Turn on camera access for HoTH in Settings to report a hazard.")
        case .unavailable:
            unavailableView(symbol: "camera.metering.unknown",
                            title: "No live camera here",
                            detail: "This device has no camera. Use a demo photo to try the flow.")
        case .idle:
            ProgressView().tint(.white)
        }
    }

    private func unavailableView(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: HoTHSpacing.m) {
            Image(systemName: symbol).font(.system(size: 52, weight: .light))
            Text(title).font(.hothTitle)
            Text(detail).font(.hothBody).multilineTextAlignment(.center).opacity(0.75)
        }
        .foregroundStyle(.white)
        .padding(HoTHSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color.hothTeal.opacity(0.9), Color.black], startPoint: .top, endPoint: .bottom)
        )
    }

    private var topBar: some View {
        HStack(spacing: HoTHSpacing.s) {
            if let onClose { CloseButton(action: onClose) }
            stampChip
            Spacer()
            if isDemoMode {
                Text("Demo mode")
                    .font(.hothCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.hothTeal.opacity(0.85)))
            }
        }
        .padding(.top, HoTHSpacing.s)
    }

    /// GPS accuracy + live clock, stamped on the device at capture time.
    private var stampChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: HoTHSpacing.s) {
                Image(systemName: capture.latestFix == nil ? "location.slash" : "location.fill")
                if let fix = capture.latestFix {
                    Text(String(format: "%.4f, %.4f · ±%.0f m", fix.latitude, fix.longitude, fix.accuracyMeters))
                } else {
                    Text(capture.locationDenied ? LocalizedStringKey("Location off") : LocalizedStringKey("Finding GPS…"))
                }
                Text(verbatim: "·")
                Text(timeline.date, format: .dateTime.hour().minute().second())
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.45)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .accessibilityElement(children: .combine)
    }

    private var trustNote: some View {
        VStack(spacing: 6) {
            Label("Live camera only — no gallery uploads", systemImage: "checkmark.shield.fill")
                .font(.hothCaption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial.opacity(0.9)))
                .environment(\.colorScheme, .dark)
            // Disclosure: the unblurred photo and location leave the phone for analysis.
            Text("Your photo and location are sent to Meta's Muse Spark model to analyse the hazard.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("captureDisclosure")
        }
    }

    private var controls: some View {
        HStack {
            Group {
                if showsDemoOption {
                    Button {
                        showDemoPicker = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.stack").font(.system(size: 20, weight: .semibold))
                            Text("Demo photo").font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 64)
                        .background(RoundedRectangle(cornerRadius: HoTHRadius.inner).fill(Color.hothTeal.opacity(0.85)))
                    }
                    .accessibilityIdentifier("demoPhotoButton")
                } else {
                    Color.clear.frame(width: 76, height: 64)
                }
            }
            Spacer()
            shutter
            Spacer()
            Color.clear.frame(width: 76, height: 64)
        }
    }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 5).frame(width: 84, height: 84)
                Circle().fill(.white).frame(width: 68, height: 68).scaleEffect(isCapturing ? 0.85 : 1)
            }
        }
        .disabled(!canShoot)
        .opacity(canShoot || isCapturing ? 1 : 0.35)
        .accessibilityLabel(Text("Take photo"))
        .accessibilityIdentifier("shutterButton")
    }

    // MARK: Actions

    private func shoot() {
        guard !isCapturing else { return }
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        Task {
            defer { isCapturing = false }
            try? await Task.sleep(nanoseconds: 90_000_000)
            withAnimation(.easeIn(duration: 0.2)) { flash = false }
            do {
                let photo = try await capture.capturePhoto()
                errorText = nil
                onCaptured(photo)
            } catch {
                errorText = CaptureError.userMessage(for: error)
            }
        }
    }

    private func pickDemo(_ sample: DemoSample) {
        let image = sample.loadImage()
        do {
            let photo = try CaptureService.makeCapturedPhoto(
                from: image, capturedAt: Date(), gps: sample.gpsFix, // demo samples carry their own seeded-area location
                source: .demoLibrary, demoSampleID: sample.id)
            onCaptured(photo)
        } catch {
            errorText = CaptureError.userMessage(for: error)
        }
    }
}

// MARK: - Camera preview

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Demo picker

/// Clearly labelled demo samples; real reports never come from a library.
/// A grid: photo, title, and a short label of what each sample demonstrates.
private struct DemoPhotoPicker: View {
    let onPick: (DemoSample) -> Void
    @ObservedObject private var services = AppServices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.m) {
            Text("Demo photo").font(.hothTitle).foregroundStyle(Color.hothInk)
            Text("Sample photos for the demo only. Real reports use the live camera.")
                .font(.hothBody)
                .foregroundStyle(Color.hothInkSecondary)
            ScrollView {
                // Eager grid (9 items): every cell stays in the accessibility tree for UI tests.
                Grid(horizontalSpacing: HoTHSpacing.s, verticalSpacing: HoTHSpacing.s) {
                    ForEach(Array(stride(from: 0, to: DemoSamples.all.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(DemoSamples.all[start..<min(start + 2, DemoSamples.all.count)]) { sample in
                                Button { onPick(sample) } label: { cell(sample) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("demoSample_\(sample.id)")
                            }
                        }
                    }
                }
            }
        }
        .padding(HoTHSpacing.l)
        .background(Color.hothBackground.ignoresSafeArea())
    }

    private func cell(_ sample: DemoSample) -> some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
            Color.hothSand
                .frame(height: 110)
                .overlay {
                    if let image = sample.assetImage {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: sample.symbol).font(.system(size: 28)).foregroundStyle(Color.hothTeal)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous))
            Text(sample.title(arabic: services.isArabic))
                .font(.hothHeadline)
                .foregroundStyle(Color.hothInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sample.demoLabel(arabic: services.isArabic))
                .font(.hothCaption.weight(.semibold))
                .foregroundStyle(sample.isDuplicateDemo ? Color.hothAccent : Color.hothTeal)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(HoTHSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous).fill(Color.hothSurface))
        .contentShape(Rectangle())
    }
}
