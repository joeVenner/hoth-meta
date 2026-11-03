import Combine
import UIKit

/// Whether the software keyboard is on screen, from UIKit's will-show / will-hide notifications.
///
/// The floating tab bar sits in a bottom safe-area inset, so with the keyboard up it rides on top of
/// the keyboard and covers whatever text field the keyboard pushed into view (the case comment
/// composer: a send tap landed on Settings). `RootTabs` hides the bar while this is true.
@MainActor
final class KeyboardVisibility: ObservableObject {
    @Published private(set) var isVisible = false

    private var subscriptions: Set<AnyCancellable> = []

    /// - Parameter center: the notification centre to observe (tests post to their own).
    init(center: NotificationCenter = .default) {
        let shown = center.publisher(for: UIResponder.keyboardWillShowNotification).map { _ in true }
        let hidden = center.publisher(for: UIResponder.keyboardWillHideNotification).map { _ in false }
        // UIKit posts these on the main thread, so no hop (a RunLoop hop would wait out a scroll).
        shown.merge(with: hidden)
            .removeDuplicates()
            .sink { [weak self] visible in self?.isVisible = visible }
            .store(in: &subscriptions)
    }
}
