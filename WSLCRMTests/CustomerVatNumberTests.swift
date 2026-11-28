import XCTest
@testable import WSLCRM

/// A customer's VAT number (`customers.vat_number`) and the invoice's own copy (`invoices.customer_vat_number`).
final class CustomerVatNumberTests: XCTestCase {
    private func customer(_ extra: String) throws -> Customer {
        try JSONDecoder.opsAPI().decode(Customer.self, from: Data((#"{"uuid":"c-1","email":"jo@acme.test""# + extra + "}").utf8))
    }

    private func invoice(_ extra: String) throws -> Invoice {
        try JSONDecoder.opsAPI().decode(Invoice.self, from: Data((#"{"id":"inv-1","invoice_number":"INV-1""# + extra + "}").utf8))
    }

    private func object(_ body: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any])
    }

    func testCustomerDecodesWithAndWithoutAVatNumber() throws {
        XCTAssertEqual(try customer(#","vat_number":"GB123456789""#).vatNumber, "GB123456789")
        XCTAssertNil(try customer("").vatNumber, "older servers don't send it")
        XCTAssertNil(try customer(#","vat_number":null"#).vatNumber)
        XCTAssertNil(try customer(#","vat_number":"""#).vatNumber)
    }

    func testInvoiceDecodesWithAndWithoutACustomerVatNumber() throws {
        XCTAssertEqual(try invoice(#","customer_vat_number":"GB123456789""#).customerVatNumber, "GB123456789")
        XCTAssertNil(try invoice("").customerVatNumber, "older servers don't send it")
        XCTAssertNil(try invoice(#","customer_vat_number":null"#).customerVatNumber)
    }

    func testTheCustomerFormSendsTheVatNumberAndAnEmptyOneClearsIt() throws {
        var body = CustomerBody(email: "jo@acme.test", vatNumber: "gb 123 4567 89")
        XCTAssertEqual(try object(body)["vat_number"] as? String, "gb 123 4567 89", "the server tidies it")
        body.vatNumber = ""
        XCTAssertEqual(try object(body)["vat_number"] as? String, "", "an emptied field clears it")
        body.vatNumber = nil
        XCTAssertNil(try object(body)["vat_number"], "never touched: left out")
    }

    func testANewInvoiceForAPickedCustomerSendsTheirUuidAndVatNumber() throws {
        let picked = PickedCustomer(try customer(#","vat_number":"GB123456789""#))
        XCTAssertEqual(picked.uuid, "c-1")
        XCTAssertEqual(picked.vatNumber, "GB123456789")

        func create(vat: String, uuid: String?) throws -> [String: Any] {
            try object(InvoiceCreateSheet.body(name: "Jo", email: "", address: "", issued: Date(), terms: 30, currency: "GBP",
                                               notes: "", poNumber: "", methodUuid: "", items: [], vatNumber: vat,
                                               customerUuid: uuid))
        }
        let json = try create(vat: picked.vatNumber, uuid: picked.uuid)
        XCTAssertEqual(json["customer_uuid"] as? String, "c-1")
        XCTAssertEqual(json["customer_vat_number"] as? String, "GB123456789")
        XCTAssertEqual(try create(vat: " ", uuid: "c-1")["customer_vat_number"] as? String, "",
                       "a removed number isn't copied back from the customer")
        let typed = try create(vat: "", uuid: nil)
        XCTAssertNil(typed["customer_vat_number"])
        XCTAssertNil(typed["customer_uuid"])
    }

    func testEditingAnInvoiceSendsItsVatNumber() throws {
        let invoice = try invoice(#","status":"draft","customer_name":"Acme","customer_vat_number":"GB1""#)
        func edit(_ vat: String) throws -> [String: Any] {
            try object(InvoiceEditSheet.body(invoice: invoice, customerName: "Acme", customerEmail: "", customerAddress: "",
                                             issueDate: Date(), dueDate: Date(), currency: "GBP", terms: "",
                                             customerNumber: "INV-1", poNumber: "", methodUuid: "", notes: "",
                                             customerVatNumber: vat))
        }
        XCTAssertEqual(try edit(" GB999 ")["customer_vat_number"] as? String, "GB999")
        XCTAssertEqual(try edit("")["customer_vat_number"] as? String, "", "an emptied field clears it")
    }

    func testTheServersVatNumberErrorIsShownAsIs() {
        let message = "That doesn't look like a VAT number (letters and numbers, e.g. GB123456789)"
        let error = ServerError.parse(status: 400, data: Data(#"{"error":"\#(message)"}"#.utf8), headers: [:])
        XCTAssertEqual(error.message, message)
    }
}
