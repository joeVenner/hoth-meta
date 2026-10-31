import XCTest
@testable import HoTH

final class HoTHTests: XCTestCase {
    @MainActor
    func testRootTabsCanBeConstructed() {
        let tabs = RootTabs()
        XCTAssertNotNil(tabs.body)
    }
}
