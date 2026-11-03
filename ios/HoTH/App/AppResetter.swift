import Foundation
import OSLog
import SwiftData
import UserNotifications

/// Settings "Reset app": puts the device back to first-launch state. Deletes every SwiftData record and
/// re-seeds the demo community, removes all `hoth.` UserDefaults (settings, onboarding flag, alert and
/// confirmation state), deletes report and fix photos plus voice temp files, cancels local notifications
/// and, only when asked, removes the Meta API key. Dependencies are injected so tests stay hermetic.
@MainActor
struct AppResetter {
    struct Outcome: Equatable {
        let removedFileCount: Int
        let removedAPIKey: Bool
        /// Key removal was requested but the Keychain refused; everything else was still reset.
        let failedToRemoveAPIKey: Bool
    }

    /// Every app setting and flag uses this prefix (see `AppServices.SettingsKey`, `OnboardingView`,
    /// `ConfirmedReports`, `NeighbourAlertCenter`, `SeedLoader`).
    static let defaultsPrefix = "hoth."
    /// Photos the app writes to Documents (`ReportPhotoFiles`, fix-check `fix_<id>.jpg`).
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    /// Push-to-talk recordings in tmp (`hoth-ptt-<uuid>.wav`).
    static let tempFilePrefix = "hoth-"

    var defaults: UserDefaults = .standard
    var bundle: Bundle = .main
    var documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    var cancelNotifications: () -> Void = {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    var deleteAPIKey: () throws -> Void = { try AppServices.shared.deleteAPIKey() }

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "AppResetter")

    /// - Parameter removingAPIKey: also delete the stored Meta API key (default keeps it).
    /// - Throws: a SwiftData error when the store cannot be cleared or re-seeded. File clean-up and key
    ///   removal failures are logged and reported in the outcome, not thrown, so one never blocks the rest.
    @discardableResult
    func reset(context: ModelContext, removingAPIKey: Bool = false, now: Date = .now) throws -> Outcome {
        // Store first, and check the seed decodes before deleting anything: a failure then leaves the
        // store, settings and files as they were (unsaved deletes are rolled back).
        _ = try SeedLoader.loadSeed(bundle: bundle)
        do {
            try SeedLoader.reset(context: context, defaults: defaults, bundle: bundle, now: now)
        } catch {
            context.rollback()
            throw error
        }
        clearDefaults()
        // The store holds the fresh seed again; keep the flag that records it (cleared with the rest).
        defaults.set(true, forKey: SeedLoader.seededFlagKey)
        let removedFiles = removeFiles(in: documentsDirectory) { Self.photoExtensions.contains($0.pathExtension.lowercased()) }
            + removeFiles(in: temporaryDirectory) { $0.lastPathComponent.hasPrefix(Self.tempFilePrefix) }
        cancelNotifications()
        var removedKey = false
        if removingAPIKey {
            do {
                try deleteAPIKey()
                removedKey = true
            } catch {
                Self.logger.error("Removing the API key failed: \(String(describing: error))")
            }
        }
        Self.logger.info("App reset: \(removedFiles) files removed, key removed: \(removedKey)")
        return Outcome(removedFileCount: removedFiles, removedAPIKey: removedKey,
                       failedToRemoveAPIKey: removingAPIKey && !removedKey)
    }

    private func clearDefaults() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.defaultsPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Deletes the regular files directly in `directory` that match; returns how many were removed.
    private func removeFiles(in directory: URL?, matching isMatch: (URL) -> Bool) -> Int {
        guard let directory else { return 0 }
        let fileManager = FileManager.default
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles])
        } catch {
            Self.logger.error("Listing \(directory.lastPathComponent, privacy: .public) failed: \(error.localizedDescription)")
            return 0
        }
        var removed = 0
        for url in urls where isMatch(url) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                Self.logger.error("Removing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription)")
            }
        }
        return removed
    }
}
