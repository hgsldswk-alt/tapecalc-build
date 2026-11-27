import XCTest

final class FlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ flags: [String] = [], language: String = "zh-Hans", reset: Bool = true,
                        paste: String? = nil, file: String? = nil) {
        let locales = ["en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "ja": "ja_JP"]
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", locales[language] ?? "en_US"] + (reset ? ["-reset"] : []) + flags
        app.launchEnvironment = [:]
        if let paste { app.launchEnvironment["TAPECALC_PASTE"] = paste }
        if let file { app.launchEnvironment["TAPECALC_IMPORT"] = file }
        app.launch()
        if flags.contains("-paywall") {
            XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 12))
        } else {
            XCTAssertTrue(app.buttons["home.tapes"].waitForExistence(timeout: 12))
        }
    }

    private func tap(_ identifier: String) {
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let candidates = app.buttons.matching(predicate)
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 6), identifier)
        let button = candidates.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(button, identifier)
        button?.tap()
    }

    private func menu(_ label: String, identifier: String) {
        let candidates = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 6), label)
        let button = candidates.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(button, label)
        button?.tap()
    }

    private func total(_ amount: String) {
        let total = app.staticTexts["home.total"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", amount),
                                                 object: total)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 6), .completed, "Expected \(amount)")
    }

    private func keys(_ keys: String) {
        for key in keys { tap("key." + String(key)) }
    }

    private func correctAmount(index: Int, delete: Int, with value: String, finish: Bool = true) {
        let amount = app.textFields["row.amount.\(index)"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        for _ in 0..<delete { tap("key.delete") }
        keys(value)
        if finish { tap("key.done") }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstAmountNegativeAndReopen() {
        launch()
        total("0.00")
        correctAmount(index: 0, delete: 0, with: "-1.25")
        total("-1.25")
        app.terminate()
        launch(reset: false)
        total("-1.25")
    }

    func testPasteCorrectCopyShareAndUndo() {
        launch(paste: "高铁 128\n午饭 65\n打车 32.5.0\n退款 -10")
        tap("home.paste")
        total("183.00")
        XCTAssertTrue(app.staticTexts["home.count"].label.contains("待核对"))
        XCTAssertFalse(app.buttons["home.copy"].isEnabled)
        XCTAssertFalse(app.buttons["home.share"].isEnabled)
        tap("home.undo")
        total("0.00")
        tap("home.paste")
        correctAmount(index: 2, delete: 6, with: "32.50")
        total("215.50")
        tap("home.copy")
        XCTAssertEqual(app.staticTexts["home.notice"].label, "已复制")
        tap("home.share")
        let marker = app.staticTexts["share.requested"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "分享明细图")
    }

    func testLongShareUsesTextAndPublicCardDoesNotLeaveApp() {
        launch(paste: Array(repeating: "1", count: 13).joined(separator: "\n"))
        tap("home.paste")
        total("13.00")
        tap("home.share")
        let marker = app.staticTexts["share.requested"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "完整明细文本已准备")
        tap("home.more")
        menu("分享核对卡（隐藏金额）", identifier: "more.public")
        let imageMarker = app.staticTexts.matching(identifier: "share.requested")
            .matching(NSPredicate(format: "label == %@", "分享明细图")).firstMatch
        XCTAssertTrue(imageMarker.waitForExistence(timeout: 15),
                      "Public card was not prepared.\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["home.more"].isHittable)
    }

    func testExpiredCanImportAndEditExistingTape() {
        launch()
        tap("home.tapes")
        tap("tape.meal")
        correctAmount(index: 0, delete: 0, with: "5")
        total("5.00")
        app.terminate()
        let file = #"{"version":1,"lines":[{"amount":"12.5","note":"Taxi 21"}]}"#
        launch(["-expired", "-import-fixture"], reset: false, file: file)
        total("17.50")
        XCTAssertEqual(app.staticTexts["home.notice"].label, "已导入 1 项")
        tap("home.undo")
        total("5.00")
        tap("home.tapes")
        tap("tape.new")
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["paywall.status"].label, "试用已结束")
        tap("paywall.done")
        correctAmount(index: 0, delete: 1, with: "6")
        total("6.00")
    }

    func testNextAmountAndRename() {
        launch()
        correctAmount(index: 0, delete: 0, with: "1", finish: false)
        tap("key.next")
        keys("2")
        tap("key.done")
        total("3.00")
        tap("home.more")
        menu("重命名纸带", identifier: "more.rename")
        let alert = app.alerts.firstMatch
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        field.typeText("Travel")
        alert.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["home.tapes"].label.contains("Travel"))
    }

    func testClearUsesSystemConfirmationAndUndo() {
        launch(paste: "1\n2")
        tap("home.paste")
        total("3.00")
        tap("home.more")
        menu("清空纸带", identifier: "more.clear")
        let clear = app.alerts.buttons["清空纸带"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        total("0.00")
        tap("home.undo")
        total("3.00")
    }

    func testStoreEnglish() { storeShots("en") }
    func testStoreSimplifiedChinese() { storeShots("zh-Hans") }
    func testStoreTraditionalChinese() { storeShots("zh-Hant") }
    func testStoreJapanese() { storeShots("ja") }

    private func storeShots(_ language: String) {
        launch(["-store-demo"], language: language)
        total("215.50")
        shot("store-\(language)-01-paste")

        correctAmount(index: 2, delete: 5, with: "42.50")
        total("225.50")
        shot("store-\(language)-02-edit")

        launch(["-store-demo", "-invalid-demo"], language: language)
        total("183.00")
        app.textFields["row.amount.2"].tap()
        XCTAssertTrue(app.buttons["key.done"].waitForExistence(timeout: 5))
        shot("store-\(language)-03-review")

        launch(["-store-demo"], language: language)
        tap("home.share")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["preview.done"].exists)
        shot("store-\(language)-04-share")

        launch(["-store-demo", "-notes-demo"], language: language)
        total("215.50")
        shot("store-\(language)-05-notes")
    }

    func testPaidScreenshot() {
        launch(["-paywall"])
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["paywall.claim"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        shot("paid-01-paywall")
    }
}
