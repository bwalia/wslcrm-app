import XCTest

/// The Property Deals manager (the back office) against the in-app stub server: hot leads and
/// "call now", a lead's replies and news, what's due for the team, renovations on kanban boards,
/// and the purchase orders that go with them (opsapi #709–#711). Screenshots attached for review.
@MainActor
final class PropertyDealsBackOfficeUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestStubServer", "-UITestRole", "pdmanager"]
        app.launch()
        let identifier = app.textFields["login.identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 15))
        identifier.tap()
        identifier.typeText("priya")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("correct-horse")
        app.buttons["login.submit"].tap()
        let code = app.textFields["twofactor.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20), "managers land on Today")
    }

    private func element(_ identifier: String, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "missing \(identifier)", file: file, line: line)
        return match
    }

    @discardableResult
    private func scrollTo(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<12 where !(match.waitForExistence(timeout: 2) && match.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(match.exists, "missing \(identifier) after scrolling", file: file, line: line)
        return match
    }

    private func text(containing substring: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
    }

    private func screenshot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        field.tap()
        field.typeText(text)
    }

    // MARK: Hot leads

    func testHotLeadCallThenCalledClosesIt() {
        launch()
        element("pd.today.section.hot")
        XCTAssertTrue(text(containing: "Pat Keen").exists)
        XCTAssertTrue(text(containing: "Hot leads to call: 1").exists, "the portfolio tiles count hot leads")
        XCTAssertTrue(text(containing: "Active renovations: 1").exists)
        XCTAssertTrue(app.links["pd.hot.call"].exists || element("pd.hot.call").exists, "Call dials the number")
        screenshot("pd-30-hot-lead")

        element("pd.hot.called").tap()
        XCTAssertTrue(app.navigationBars["Called"].waitForExistence(timeout: 5))
        text(containing: "Left a message").tap()
        element("pd.called.save").tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.descendants(matching: .any).matching(identifier: "pd.today.section.hot").firstMatch)
        waitForExpectations(timeout: 10)
    }

    func testLeadRepliesNewsAndLoggingAHotReply() {
        launch()
        element("pd.today.section.hot")
        text(containing: "Asks for a visit tomorrow").tap()
        XCTAssertTrue(app.navigationBars["Pat Keen"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Yes please, can you come round tomorrow?").waitForExistence(timeout: 5), "the scored reply")
        scrollTo("pd.lead.captureNews")
        XCTAssertTrue(text(containing: "New charge on Keen Lettings Ltd").exists, "Companies House news")
        screenshot("pd-31-lead")

        scrollTo("pd.lead.logReply").tap()
        type("Yes, call me today about the house", into: "pd.reply.text")
        element("pd.reply.save").tap()
        let logged = element("pd.lead.logged")
        XCTAssertTrue(logged.label.contains("Hot"), "scored hot")
        XCTAssertTrue(logged.label.contains("call now"), "a hot reply raises a call task")
        screenshot("pd-32-reply-logged")
    }

    // MARK: Due soon and renovations

    func testDueSoonShowsTheTeamThenOnlyMine() {
        launch()
        scrollTo("pd.today.due").tap()
        XCTAssertTrue(element("pd.due.scope").label.contains("Everyone's"), "managers see the team")
        element("pd.due.section.overdue")
        element("pd.due.section.tomorrow")
        XCTAssertTrue(text(containing: "Strip out the kitchen").exists, "renovation jobs are in the list")
        XCTAssertTrue(text(containing: "Confirm the buyer's proof of funds").exists, "a colleague's task")
        screenshot("pd-33-due-soon")

        element("pd.due.filter").tap()
        app.buttons["Only mine"].firstMatch.tap()
        let mine = NSPredicate(format: "label CONTAINS %@", "Your tasks")
        expectation(for: mine, evaluatedWith: element("pd.due.scope"))
        waitForExpectations(timeout: 10)
        XCTAssertFalse(text(containing: "Confirm the buyer's proof of funds").exists)
    }

    func testStartARenovationFromADealThenRaiseItsPurchaseOrder() {
        launch()
        scrollTo("pd.today.renovations").tap()
        element("pd.renovation.rn1")
        XCTAssertTrue(text(containing: "4 of 19 jobs done").exists)
        screenshot("pd-34-renovations")
        app.navigationBars.buttons.firstMatch.tap()

        scrollTo("pd.today.deal.d0000000-0000-4000-8000-000000000001").tap()
        scrollTo("pd.deal.startRenovation").tap()
        type("Renovation — 7 Mill Lane", into: "pd.renovation.name")
        element("pd.renovation.start").tap()
        scrollTo("pd.renovation.purchaseOrders")
        screenshot("pd-35-deal-renovation")

        element("pd.renovation.purchaseOrders").tap()
        element("po.row.PO-000001")
        XCTAssertFalse(text(containing: "PO-000002").exists, "only this board's orders")
        element("po.new").tap()
        type("Minster Timber", into: "po.create.supplier")
        type("Joists, 4.8m", into: "po.create.line0.description")
        element("po.create.save").tap()
        element("po.row.PO-000003")
        screenshot("pd-36-renovation-purchase-orders")
    }

    // MARK: Purchase orders

    func testPurchaseOrderAcknowledgeReceiveAndBill() {
        launch()
        app.tabBars.buttons["More"].tap()
        element("more.purchaseOrders").tap()
        element("po.row.PO-000002")
        screenshot("po-01-list")

        element("po.row.PO-000001").tap()
        XCTAssertTrue(text(containing: "York Kitchens Ltd").waitForExistence(timeout: 10))
        screenshot("po-02-detail")
        element("po.acknowledge").tap()
        XCTAssertTrue(text(containing: "Acknowledged").waitForExistence(timeout: 10))

        element("po.receive").tap()
        element("po.receive.all").tap()
        element("po.receive.save").tap()
        XCTAssertTrue(text(containing: "All 3 received").waitForExistence(timeout: 10))
        screenshot("po-03-received")

        element("po.bill").tap()
        app.buttons["Create the bill"].firstMatch.tap()
        XCTAssertTrue(text(containing: "Billed").waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "po.receive").firstMatch.exists,
                       "nothing left to receive once billed")
    }
}
