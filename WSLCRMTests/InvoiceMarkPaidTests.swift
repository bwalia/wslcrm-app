import XCTest
@testable import WSLCRM

/// Marking an invoice paid (`POST /api/v2/invoices/:uuid/mark-paid`), drafts included, and the payment's new fields.
final class InvoiceMarkPaidTests: XCTestCase {
    private func payment(_ extra: String) throws -> InvoicePayment {
        try JSONDecoder.opsAPI().decode(InvoicePayment.self, from: Data((#"{"uuid":"p-1","amount":"70.00""# + extra + "}").utf8))
    }

    private func invoice(_ status: String, balance: String = "120.00") throws -> Invoice {
        let json = #"{"id":"inv-1","invoice_number":"INV-1","status":"\#(status)","total_amount":"120.00","balance_due":"\#(balance)"}"#
        return try JSONDecoder.opsAPI().decode(Invoice.self, from: Data(json.utf8))
    }

    private func object(_ body: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any])
    }

    func testAPaymentDecodesWithTheNewFields() throws {
        let paid = try payment(#","payment_method":"stripe","payer_name":"Jo Bloggs","stripe_payment_intent_id":"pi_123","source":"shop""#)
        XCTAssertEqual(paid.payerName, "Jo Bloggs")
        XCTAssertEqual(paid.stripePaymentIntentId, "pi_123")
        XCTAssertEqual(paid.source, "shop")
        XCTAssertEqual(paid.displayReference, "pi_123", "the Stripe payment stands in for a missing bank reference")
        XCTAssertEqual(InvoiceDetailView.paymentDetail(paid), "Card (Stripe) · Paid by Jo Bloggs · pi_123")

        let banked = try payment(#","reference_number":"BACS-1","stripe_payment_intent_id":"pi_9""#)
        XCTAssertEqual(banked.displayReference, "BACS-1")
    }

    func testAPaymentDecodesWithoutOrWithNullNewFields() throws {
        for extra in ["", #","payer_name":null,"stripe_payment_intent_id":null,"source":null,"reference_number":null"#] {
            let old = try payment(extra)
            XCTAssertEqual(old.amount, 70)
            XCTAssertNil(old.payerName)
            XCTAssertNil(old.stripePaymentIntentId)
            XCTAssertNil(old.source)
            XCTAssertNil(old.displayReference)
            XCTAssertEqual(InvoiceDetailView.paymentDetail(old), "")
        }
    }

    func testTheSheetSendsEveryField() throws {
        let date = CalendarDay(year: 2026, month: 11, day: 28).date()
        let json = try object(PaymentSheet.body(amount: 70, method: "check", date: date, reference: " CHQ-12 ",
                                                payerName: " Jo Bloggs ", notes: "Posted"))
        XCTAssertEqual(json["amount"] as? Double, 70)
        XCTAssertEqual(json["payment_method"] as? String, "check")
        XCTAssertEqual(json["payment_date"] as? String, "2026-11-28")
        XCTAssertEqual(json["reference"] as? String, "CHQ-12")
        XCTAssertEqual(json["payer_name"] as? String, "Jo Bloggs")
        XCTAssertEqual(json["notes"] as? String, "Posted")
    }

    func testTheSheetLeavesOutEmptyOptionalFields() throws {
        let json = try object(PaymentSheet.body(amount: 120, method: "bank_transfer", date: Date(), reference: "",
                                                payerName: "  ", notes: ""))
        XCTAssertEqual(Set(json.keys), ["amount", "payment_method", "payment_date"])
        XCTAssertEqual(PaymentSheet.methods.first, "bank_transfer", "bank transfer is the default")
        XCTAssertTrue(PaymentSheet.methods.contains("check"), "Cheque is sent as the server's code")
    }

    func testDraftsAreMarkedPaidAndOthersRecordAPayment() throws {
        let draft = try invoice("draft")
        XCTAssertTrue(draft.canRecordPayment, "a draft can be marked paid: the server issues it first")
        XCTAssertEqual(draft.paymentActionTitle, "Mark as paid")
        XCTAssertEqual(InvoiceDetailView.paymentNotice(120, currency: "GBP", issued: true),
                       "Invoice issued and payment of £120.00 recorded. Nothing was emailed.")

        let sent = try invoice("sent", balance: "70.00")
        XCTAssertTrue(sent.canRecordPayment)
        XCTAssertEqual(sent.paymentActionTitle, "Record payment")

        for status in ["paid", "void", "cancelled"] {
            XCTAssertFalse(try invoice(status).canRecordPayment, "\(status) hides it")
        }
        XCTAssertFalse(try invoice("sent", balance: "0").canRecordPayment, "nothing left to pay")
    }

    func testTheServersErrorIsShownAsIs() {
        let message = "That's more than the 70.00 still to pay"
        let error = ServerError.parse(status: 400, data: Data(#"{"success":false,"error":"\#(message)"}"#.utf8), headers: [:])
        XCTAssertEqual(error.message, message)
    }
}
