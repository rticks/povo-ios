import XCTest

final class PovoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["アカウント"].waitForExistence(timeout: 15))
        return app
    }
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<7 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    func testAccountListAndDetailAllFiveBuckets() {
        let app = launch()
        let row = element(app, "account-demo-main")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        screenshot(app, "01-accounts-light")
        row.tap()
        XCTAssertTrue(element(app, "usage-value").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["基本"].exists)
        XCTAssertTrue(app.staticTexts["ボーナス"].exists)
        XCTAssertTrue(app.staticTexts["プラス"].exists)
        screenshot(app, "02-detail-light")
    }
    func testEmptyStateAndLoginFormNoNetwork() {
        let app = launch(["--empty"])
        let add = element(app, "add-first-account")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        screenshot(app, "03-empty")
        add.tap()
        let field = element(app, "login-email")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "send-otp").isEnabled)
        screenshot(app, "04-login")
    }
    func testCatalogueRendersAndPaymentsAreDisabledInUITestMode() {
        let app = launch()
        element(app, "account-demo-main").tap()
        let store = element(app, "open-topping-store")
        XCTAssertTrue(store.waitForExistence(timeout: 5)); store.tap()
        XCTAssertTrue(app.staticTexts["データ追加3GB（30日間）"].waitForExistence(timeout: 10))
        for button in app.buttons.matching(identifier: "購入").allElementsBoundByIndex { XCTAssertFalse(button.isEnabled) }
        screenshot(app, "05-catalogue")
    }
    func testSettingsAndWidgetPreview() {
        let app = launch()
        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(element(app, "theme-picker").waitForExistence(timeout: 5))
        screenshot(app, "06-settings")
        let preview = app.buttons["ウィジェットのプレビュー"]
        scrollTo(preview, app: app); preview.tap()
        XCTAssertTrue(app.staticTexts["円形メーターの表示例"].waitForExistence(timeout: 5))
        screenshot(app, "07-widget-preview")
    }
    func testDarkMode() {
        let app = launch(["--dark"])
        XCTAssertTrue(element(app, "account-demo-main").waitForExistence(timeout: 5))
        screenshot(app, "08-accounts-dark")
        element(app, "account-demo-main").tap()
        XCTAssertTrue(element(app, "usage-value").waitForExistence(timeout: 5))
        screenshot(app, "09-detail-dark")
    }
    func testFailedAccountKeepsItsLastReading() {
        let app = launch(["--error"])
        XCTAssertTrue(app.staticTexts["3.25 GB"].waitForExistence(timeout: 5))
        screenshot(app, "10-login-required")
    }
    func testLargeTextLayout() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(element(app, "account-demo-main").waitForExistence(timeout: 5))
        screenshot(app, "11-large-text")
    }
    func testSuspensionEditorPersistsManualAnchor() {
        let app = launch()
        element(app, "account-demo-main").tap()
        let editor = element(app, "edit-suspension")
        scrollTo(editor, app: app); editor.tap()
        let duration = element(app, "suspension-duration")
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.tap(); duration.typeText("365")
        let save = element(app, "save-suspension")
        XCTAssertTrue(save.isEnabled)
        screenshot(app, "12-suspension-editor")
        save.tap()
        XCTAssertTrue(app.buttons["この回線を更新"].waitForExistence(timeout: 5))
    }
}
