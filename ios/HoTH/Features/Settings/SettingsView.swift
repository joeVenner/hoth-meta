import OSLog
import SwiftData
import SwiftUI

/// Settings (P0-22): API key (Keychain), demo mode, role, language, model overrides, privacy, reset.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var services = AppServices.shared
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var keyError: LocalizedStringKey?
    @State private var isConfirmingReset = false
    @State private var resetMessage: LocalizedStringKey?
    @State private var isConfirmingAppReset = false
    @State private var isResettingApp = false

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "Settings")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                    header
                    apiKeySection
                    communitySection
                    languageSection
                    modelsSection
                    aboutSection
                    resetAppSection
                }
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.bottom, 120)
            }
            .background(Color.hothBackground.ignoresSafeArea())
            .hothStatusBarBackdrop()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { keyStatus = services.keyProvider.maskedStatus() }
            .confirmationDialog(
                Text("Reset demo community?"),
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button(role: .destructive, action: resetDemo) { Text("Reset everything") }
                    .accessibilityIdentifier("resetConfirmButton")
                Button(role: .cancel) {} label: { Text("Cancel") }
            } message: {
                Text("This deletes all reports, comments and points on this device and reloads the demo community.")
            }
            .confirmationDialog(
                Text("Reset HoTH?"),
                isPresented: $isConfirmingAppReset,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) { resetApp(removingAPIKey: false) } label: { Text("Reset app") }
                    .accessibilityIdentifier("confirmResetAppButton")
                if services.hasAPIKey() && !services.keyProvider.isUsingEnvironmentFallback {
                    Button(role: .destructive) { resetApp(removingAPIKey: true) } label: {
                        Text("Reset app and remove Meta API key")
                    }
                    .accessibilityIdentifier("confirmResetAppRemoveKeyButton")
                }
                Button(role: .cancel) {} label: { Text("Cancel") }
            } message: {
                Text("Deletes all reports, comments, points, photos and settings on this device, reloads the demo community and shows the welcome screens again. Your Meta API key is kept unless you remove it.")
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
            Text("Settings")
                .font(.hothDisplay(38))
                .hothTracking(-1)
                .foregroundStyle(Color.hothInk)
            Text("Everything stays on this device.")
                .font(.hothBody)
                .foregroundStyle(Color.hothInkSecondary)
        }
        .padding(.top, HoTHSpacing.l)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "Meta Model API key")
            HoTHCard {
                VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                    Text("Powers Meta's Muse Spark: photo analysis, chat and repair checks.")
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                    HStack(spacing: HoTHSpacing.s) {
                        Image(systemName: keyStatus == nil ? "key" : "key.fill")
                            .foregroundStyle(keyStatus == nil ? Color.hothInkSecondary : Color.hothSuccess)
                        if let keyStatus {
                            Text("Key saved \(keyStatus)")
                                .font(.hothHeadline)
                                .foregroundStyle(Color.hothInk)
                        } else {
                            Text("No key saved")
                                .font(.hothHeadline)
                                .foregroundStyle(Color.hothInk)
                        }
                        Spacer()
                        if keyStatus != nil && !services.keyProvider.isUsingEnvironmentFallback {
                            Button(role: .destructive, action: deleteKey) { Text("Remove") }
                                .font(.hothCaption.weight(.semibold))
                        }
                    }
                    if services.keyProvider.isUsingEnvironmentFallback {
                        Text("Using the developer environment key (simulator debug only).")
                            .font(.hothCaption)
                            .foregroundStyle(Color.hothInkSecondary)
                    }
                    SecureField(text: $keyDraft) { Text(verbatim: "LLM_…") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.hothBackground))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hothInk.opacity(0.08)))
                    if let keyError {
                        Text(keyError).font(.hothCaption).foregroundStyle(Color.hothCritical)
                    }
                    Button(action: saveKey) { Text("Save to Keychain") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
                    Text("Stored in the iOS Keychain on this device only. Never logged or shared.")
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                }
            }
        }
    }

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "Community")
            HoTHCard {
                VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                    Toggle(isOn: $services.demoMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo mode").font(.hothHeadline).foregroundStyle(Color.hothInk)
                            Text("Shows a fictional demo community.")
                                .font(.hothCaption)
                                .foregroundStyle(Color.hothInkSecondary)
                        }
                    }
                    .tint(Color.hothTeal)

                    Divider()

                    Toggle(isOn: $services.voiceFirstInterview) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start interview with voice").font(.hothHeadline).foregroundStyle(Color.hothInk)
                            Text("Replies are read aloud and you hold the mic to answer. You can always switch to typing.")
                                .font(.hothCaption)
                                .foregroundStyle(Color.hothInkSecondary)
                        }
                    }
                    .tint(Color.hothTeal)
                    .accessibilityIdentifier("voiceFirstToggle")

                    Divider()

                    Toggle(isOn: $services.agentIntake) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Interview agent tools").font(.hothHeadline).foregroundStyle(Color.hothInk)
                            Text("Muse Spark can check reports and places nearby on your phone and outline the photo with SAM 3.1 while it interviews you.")
                                .font(.hothCaption)
                                .foregroundStyle(Color.hothInkSecondary)
                        }
                    }
                    .tint(Color.hothTeal)
                    .accessibilityIdentifier("agentIntakeToggle")

                    Divider()

                    VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                        Text("Role").font(.hothHeadline).foregroundStyle(Color.hothInk)
                        Picker(selection: $services.role) {
                            Text("Resident").tag(AppServices.Role.resident.rawValue)
                            Text("City Crew").tag(AppServices.Role.crew.rawValue)
                        } label: {
                            Text("Role")
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

                    Button { isConfirmingReset = true } label: {
                        Label { Text("Reset demo community") } icon: { Image(systemName: "arrow.counterclockwise") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("resetDemoButton")
                    if let resetMessage {
                        Text(resetMessage).font(.hothCaption).foregroundStyle(Color.hothSuccess)
                    }
                }
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "Language")
            HoTHCard {
                Picker(selection: $services.preferredLanguage) {
                    Text("System").tag(AppServices.Language.system.rawValue)
                    Text(verbatim: "English").tag(AppServices.Language.en.rawValue)
                    Text(verbatim: "العربية").tag(AppServices.Language.ar.rawValue)
                } label: {
                    Text("Language")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "AI models")
            HoTHCard {
                VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                    modelField(title: "Vision model", text: $services.visionModelOverride,
                               placeholder: services.prompts.models.vision)
                    modelField(title: "Text model", text: $services.textModelOverride,
                               placeholder: services.prompts.models.text)
                    Text("Leave empty to use the defaults.")
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                    Divider()
                    VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
                        Label { Text("Powered by Meta AI") } icon: { Image(systemName: "sparkles") }
                            .font(.hothHeadline)
                            .foregroundStyle(Color.hothInk)
                        // Model names stay in Latin script in every language.
                        Text(verbatim: "Muse Spark 1.3 · Muse Voice Transcribe · SAM 3.1")
                            .font(.hothCaption.weight(.semibold))
                            .foregroundStyle(Color.hothAccent)
                        Text("Photo understanding, the interview agent, fix checks and comment moderation; voice to text; hazard outlines.")
                            .font(.hothCaption)
                            .foregroundStyle(Color.hothInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settingsPoweredByMeta")
                }
            }
        }
    }

    private func modelField(title: LocalizedStringKey, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
            Text(title).font(.hothCaption.weight(.semibold)).foregroundStyle(Color.hothInkSecondary)
            TextField(text: text) { Text(verbatim: placeholder) }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.hothBackground))
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "About & privacy")
            HoTHCard {
                VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                    privacyRow(symbol: "iphone", text: "Reports, comments and points live on this device. There is no HoTH server.")
                    privacyRow(symbol: "eye.slash", text: "Faces and number plates are blurred on your phone before anything is posted to the neighbourhood. To analyse the hazard, the photo is sent to Meta's Muse Spark model.")
                    privacyRow(symbol: "network", text: "Photos and voice go directly to the Meta Model API with your own key, only when you report.")
                    privacyRow(symbol: "person.2", text: "The demo community is fictional.")
                    HStack {
                        Text(verbatim: "HoTH · Heroes of the Hay")
                        Spacer()
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    }
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
                }
            }
        }
    }

    private var resetAppSection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "Reset")
            HoTHCard {
                VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                    Button(role: .destructive) {
                        services.appResetNotice = nil
                        isConfirmingAppReset = true
                    } label: {
                        Label { Text("Reset app") } icon: { Image(systemName: "trash") }
                            .font(.hothHeadline)
                            .foregroundStyle(Color.hothCritical)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isResettingApp)
                    .accessibilityIdentifier("resetAppButton")
                    Text("Start over as on first launch. Your Meta API key stays unless you choose to remove it.")
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice = services.appResetNotice {
                        Text(notice).font(.hothCaption).foregroundStyle(Color.hothCritical)
                    }
                }
            }
        }
    }

    private func privacyRow(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HoTHSpacing.m) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(Color.hothTeal)
            Text(text)
                .font(.hothBody)
                .foregroundStyle(Color.hothInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func saveKey() {
        do {
            try services.saveAPIKey(keyDraft)
            keyDraft = ""
            keyError = nil
            keyStatus = services.keyProvider.maskedStatus()
            Haptics.success()
        } catch {
            Self.logger.error("Saving API key failed: \(String(describing: error))")
            keyError = "Could not save the key. Please try again."
        }
    }

    private func deleteKey() {
        do {
            try services.deleteAPIKey()
            keyStatus = services.keyProvider.maskedStatus()
        } catch {
            Self.logger.error("Removing API key failed: \(String(describing: error))")
            keyError = "Could not remove the key."
        }
    }

    /// Runs after the dialog has gone, so the onboarding cover it brings back does not collide with it.
    private func resetApp(removingAPIKey: Bool) {
        guard !isResettingApp else { return }
        isResettingApp = true
        Task { @MainActor in
            defer { isResettingApp = false }
            try? await Task.sleep(for: .milliseconds(400))
            do {
                let outcome = try AppResetter().reset(context: modelContext, removingAPIKey: removingAPIKey)
                NeighbourAlertCenter.shared.dismissBanner()
                Haptics.success()
                // Rebuilds the whole tab tree (this view included) on the fresh state.
                services.didResetApp(notice: outcome.failedToRemoveAPIKey
                    ? "App reset, but the Meta API key could not be removed." : nil)
            } catch {
                Self.logger.error("App reset failed: \(String(describing: error))")
                services.didResetApp(notice: "Reset failed. Please try again.")
            }
        }
    }

    private func resetDemo() {
        do {
            try SeedLoader.reset(context: modelContext)
            UserDefaults.standard.removeObject(forKey: "hoth.confirmedReportIDs")
            resetMessage = "Demo community restored."
            Haptics.success()
        } catch {
            Self.logger.error("Demo reset failed: \(String(describing: error))")
            resetMessage = "Reset failed."
        }
    }
}
