import XCTest

/// Drives SpringBoard on the simulator to add QuotaPulse widgets to the home screen and lock screen,
/// then leaves them there so `xcrun simctl io <udid> screenshot` can capture the real thing.
/// Run: xcodebuild test -scheme QuotaPulse-iOS -destination 'id=<udid>' -only-testing:QuotaPulseUITests
@MainActor final class WidgetGalleryTests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    private func firstExisting(_ queries: [XCUIElement], timeout: TimeInterval = 4) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for q in queries where q.exists { return q }
            usleep(200_000)
        }
        return nil
    }

    /// Enters jiggle mode and opens the widget gallery; returns the gallery's search field.
    private func openWidgetGallery() -> XCUIElement? {
        let home = springboard
        // Long-press empty space (bottom area between dock and last icon row).
        let p = home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        p.press(forDuration: 1.6)
        sleep(1)
        // iOS 18+: "Edit" menu → "Add Widget". iOS 17: "+" button top-left labelled "Add Widget".
        if let edit = firstExisting([home.buttons["Edit"], home.buttons["edit"]], timeout: 3) {
            edit.tap()
            if let add = firstExisting([home.buttons["Add Widget"], home.menuItems["Add Widget"], home.staticTexts["Add Widget"]], timeout: 3) { add.tap() }
        } else if let add = firstExisting([home.buttons["Add Widget"], home.buttons["Add"]], timeout: 3) {
            add.tap()
        } else {
            // Fallback: the + is in the top-left corner during jiggle mode.
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.07)).tap()
        }
        return firstExisting([home.searchFields.firstMatch, home.textFields.firstMatch], timeout: 5)
    }

    private func addFromGallery(family: String) -> Bool {
        guard let search = openWidgetGallery() else { XCTFail("widget gallery did not open"); return false }
        search.tap()
        search.typeText("QuotaPulse")
        sleep(1)
        guard let result = firstExisting([springboard.cells.containing(.staticText, identifier: "QuotaPulse").firstMatch,
                                          springboard.staticTexts["QuotaPulse"].firstMatch,
                                          springboard.buttons["QuotaPulse"].firstMatch], timeout: 5) else {
            XCTFail("QuotaPulse not listed in the widget gallery"); return false
        }
        result.tap()
        sleep(1)
        // The widget page pages through families horizontally; swipe to the requested one.
        let swipes: Int = family == "medium" ? 1 : (family == "large" ? 2 : 0)
        for _ in 0..<swipes { springboard.swipeLeft(); usleep(600_000) }
        guard let add = firstExisting([springboard.buttons["Add Widget"], springboard.buttons[" Add Widget"]], timeout: 4) else {
            XCTFail("Add Widget button missing"); return false
        }
        add.tap()
        sleep(1)
        if let done = firstExisting([springboard.buttons["Done"]], timeout: 2) { done.tap() } else { XCUIDevice.shared.press(.home) }
        sleep(1)
        return true
    }

    func testAddHomeScreenWidgets() {
        XCTAssertTrue(addFromGallery(family: ProcessInfo.processInfo.environment["WIDGET_FAMILY"] ?? "small"))
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
