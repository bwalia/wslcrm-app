import XCTest
@testable import WSLCRM

/// The shared record page (DesignSystem/DetailPage.swift): the bits with logic in them.
final class DetailPageTests: XCTestCase {

    func testMonogramTakesTheFirstLetterOfTheFirstTwoWords() {
        XCTAssertEqual(Monogram.initials("Bob Blasdel"), "BB")
        XCTAssertEqual(Monogram.initials("harbour vfx ltd"), "HV")
        XCTAssertEqual(Monogram.initials("Mary-Jane Watson"), "MJ")
        XCTAssertEqual(Monogram.initials("  Priya  "), "P")
        XCTAssertEqual(Monogram.initials("2nd Avenue Cafe"), "AC", "words that don't start with a letter are skipped")
        XCTAssertEqual(Monogram.initials("42"), "4", "nothing but digits still shows something")
        XCTAssertEqual(Monogram.initials(""), "?")
    }

    func testLeadTimelinePicksASymbolFromWhatHappened() throws {
        func item(_ title: String, direction: String? = nil) throws -> LeadTimelineItem {
            var json: [String: Any] = ["kind": "activity", "title": title]
            json["direction"] = direction
            return try JSONDecoder().decode(LeadTimelineItem.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("Replied: Your quote", direction: "inbound")),
                       "arrowshape.turn.up.left.fill")
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("Call logged: no answer")), "phone.fill")
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("Email sent")), "envelope.fill")
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("Meeting booked")), "calendar")
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("Moved to Qualified")), "arrow.right")
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("AI analysis finished")), "sparkles")
        XCTAssertEqual(LeadDetailView.timelineSymbol(try item("Maintenance visit")), "circle.fill", "not \"ai\" inside a word")
    }

    func testLeadAILeavesOutWhatItDidNotKnow() {
        XCTAssertNil(LeadAIText.known("Unknown"))
        XCTAssertNil(LeadAIText.known(" n/a "))
        XCTAssertNil(LeadAIText.known(""))
        XCTAssertNil(LeadAIText.known(nil))
        XCTAssertEqual(LeadAIText.known("An 8-GPU training server"), "An 8-GPU training server")
        XCTAssertEqual(LeadAIText.known("Unknown brand of chiller"), "Unknown brand of chiller", "only a bare \"Unknown\"")
    }
}
