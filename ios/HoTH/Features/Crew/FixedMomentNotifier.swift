import Foundation
import OSLog
import UserNotifications

/// Posts the local "Fixed ✨" notification. Permission is requested lazily on first use, and the
/// notifier presents banners while the app is in the foreground.
final class FixedMomentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FixedMomentNotifier()

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "FixedMoment")
    private var isDelegateInstalled = false

    /// Notification body for a fixed report; pure so it can be unit-tested.
    static func message(titleEN: String, titleAR: String, points: Int, wasReporter: Bool, arabic: Bool) -> String {
        let title = arabic ? (titleAR.isEmpty ? titleEN : titleAR) : (titleEN.isEmpty ? titleAR : titleEN)
        if arabic {
            let verb = wasReporter ? "التي أبلغت عنها" : "التي أكدتها"
            return "«\(title)» \(verb) تم إصلاحها ✨ +\(points) نقطة"
        }
        let verb = wasReporter ? "you reported" : "you confirmed"
        return "The \(title.prefix(1).lowercased() + title.dropFirst()) \(verb) is fixed ✨ +\(points) points"
    }

    @MainActor
    func post(titleEN: String, titleAR: String, points: Int, wasReporter: Bool) {
        let arabic = AppServices.shared.isArabic
        let body = Self.message(titleEN: titleEN, titleAR: titleAR, points: points, wasReporter: wasReporter, arabic: arabic)
        schedule(title: arabic ? "تم الإصلاح ✅" : "Fixed ✅", body: body)
    }

    /// Shared local-notification helper (Fixed moment, neighbour alerts): lazy permission request,
    /// foreground banners via this delegate, immediate delivery.
    @MainActor
    func schedule(title: String, body: String) {
        // UI-test runs skip the permission prompt so it never covers the screenshots.
        guard !AppServices.isUITestRun else { return }
        let center = UNUserNotificationCenter.current()
        if !isDelegateInstalled {
            center.delegate = self
            isDelegateInstalled = true
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    Self.logger.error("Notification not scheduled: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
