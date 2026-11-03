import Combine
import UIKit
import XCTest
@testable import HoTH

/// The floating tab bar hides while the keyboard is up (it covered the comment composer's send button).
@MainActor
final class KeyboardVisibilityTests: XCTestCase {
    func testFollowsKeyboardShowAndHide() {
        let center = NotificationCenter()
        let keyboard = KeyboardVisibility(center: center)
        XCTAssertFalse(keyboard.isVisible)

        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        waitUntil(keyboard, isVisible: true)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        waitUntil(keyboard, isVisible: false)
    }


    private func waitUntil(_ keyboard: KeyboardVisibility, isVisible expected: Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let reached = expectation(description: "isVisible == \(expected)")
        let watch = keyboard.$isVisible.filter { $0 == expected }.first().sink { _ in reached.fulfill() }
        wait(for: [reached], timeout: 2)
        watch.cancel()
        XCTAssertEqual(keyboard.isVisible, expected, file: file, line: line)
    }
}
