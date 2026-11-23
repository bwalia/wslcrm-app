import SwiftUI
import XCTest
@testable import WSLCRM

/// CRM, leads and engage made as easy as the web: the logic behind each fix, and every request body and
/// response shape checked against the OpsAPI route that serves it.
@MainActor
final class EasyCRMTests: XCTestCase {

    // MARK: Leads: "How did the call go?" after a call (crm-leads.lua POST /:uuid/calls)

    func testTheCallSheetOpensOnlyAfterComingBackFromACall() {
        var followUp = LeadCallFollowUp()
        XCTAssertFalse(followUp.phaseChanged(to: .background), "nothing dialled")
        XCTAssertFalse(followUp.phaseChanged(to: .active))

        followUp.dial()
        XCTAssertFalse(followUp.phaseChanged(to: .inactive), "iOS asks “Call …?” first")
        XCTAssertFalse(followUp.phaseChanged(to: .active), "back from the question, not from a call")
        XCTAssertFalse(followUp.phaseChanged(to: .background), "the call is in the Phone app")
        XCTAssertTrue(followUp.phaseChanged(to: .active), "back from the call: ask how it went")
        XCTAssertFalse(followUp.phaseChanged(to: .background))
        XCTAssertFalse(followUp.phaseChanged(to: .active), "asked once only")
    }

    // MARK: Leads: visible stage moves (POST /:uuid/stage; converting is its own step)

    func testASwipeMovesALeadToTheNextOpenStage() {
        XCTAssertEqual(LeadStage.new.nextOpen, .contacting)
        XCTAssertEqual(LeadStage.contacting.nextOpen, .qualified)
        XCTAssertEqual(LeadStage.qualified.nextOpen, .meeting)
        XCTAssertNil(LeadStage.meeting.nextOpen, "the server refuses stage=converted (use_convert)")
        XCTAssertNil(LeadStage.nurture.nextOpen)
        XCTAssertNil(LeadStage.lost.nextOpen)
        XCTAssertNil(LeadStage.converted.nextOpen)
    }
}
