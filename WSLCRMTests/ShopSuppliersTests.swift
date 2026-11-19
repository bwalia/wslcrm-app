import XCTest
@testable import WSLCRM

/// Suppliers, messages to them, deals and the order page's extras. Fixtures follow what OpsAPI builds
/// (`ShopSupplierRequestQueries.draft`, `ShopSupplierIntroQueries.draft`, `ShopStockEnquiryQueries`,
/// `ShopDealQueries.get/recent/search`, `ShopOrderQueries.adminGet`, `ShopOrderSignatureQueries.get`,
/// `ShopSupplierQueries.list`), including lua-cjson's `{}` for an empty array.
final class ShopSuppliersTests: XCTestCase {

    // MARK: Messages to suppliers

    func testPriceRequestDraft() throws {
        let draft = try Fixture.decode(Envelope.Standard<ShopSupplierMessageDraft>.self, from: "shop_supplier_request_draft").data
        XCTAssertEqual(draft.dealCode, "WS-UEEG-XBD6")
        XCTAssertEqual(draft.subject, "Price request: WS-UEEG-XBD6")
        XCTAssertTrue(draft.body.hasPrefix("Hello Sam,"))
        XCTAssertEqual(draft.supplier.contactName, "Sam")
        XCTAssertEqual(draft.supplier.phoneIntl, "447700900456")
        XCTAssertTrue(draft.customerDetails.isEmpty, "`{}` is an empty list")
        XCTAssertEqual(draft.template?.builtin, true)
        XCTAssertEqual(draft.template?.id, "builtin", "the built-in template has no uuid")
        XCTAssertEqual(draft.templates.map(\.id), ["builtin", "7c7c7c7c-0000-4000-8000-000000000001"])
        XCTAssertEqual(draft.templates.last?.name, "Short and friendly")
    }

    func testIntroductionDraftWithoutPhone() throws {
        let draft = try Fixture.decode(Envelope.Standard<ShopSupplierMessageDraft>.self, from: "shop_supplier_intro_draft").data
        XCTAssertNil(draft.supplier.phoneIntl, "no phone: WhatsApp and text are off")
        XCTAssertNil(draft.supplier.contactName)
        XCTAssertEqual(draft.customer?.name, "Ben Ode")
        XCTAssertEqual(draft.customer?.company, "Ode Labs")
        XCTAssertNil(draft.customer?.phone)
        XCTAssertEqual(draft.templates.count, 1)
    }

    func testSendBodiesUseTheServersNames() throws {
        let intro = ShopSupplierMessageSend(supplierUuid: "s1", channel: .email, subject: "Hi", message: "Hello",
                                            templateUuid: nil, customerAgreed: true, ccCustomer: false, qty: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(intro)) as? [String: Any])
        XCTAssertEqual(json["supplier_uuid"] as? String, "s1")
        XCTAssertEqual(json["channel"] as? String, "email")
        XCTAssertEqual(json["customer_agreed"] as? Bool, true)
        XCTAssertEqual(json["cc_customer"] as? Bool, false)
        XCTAssertNil(json["qty"], "nil fields are left out")
        XCTAssertNil(json["template_uuid"])

        let stock = ShopSupplierMessageSend(supplierUuid: "s1", channel: .sms, subject: "S", message: "M", templateUuid: "t1",
                                            customerAgreed: nil, ccCustomer: nil, qty: 3)
        let s = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(stock)) as? [String: Any])
        XCTAssertEqual(s["qty"] as? Int, 3)
        XCTAssertEqual(s["template_uuid"] as? String, "t1")
        XCTAssertNil(s["customer_agreed"])
    }

    func testStockEnquirySendAndList() throws {
        let result = try Fixture.decode(Envelope.Standard<ShopSupplierMessageResult>.self, from: "shop_stock_enquiry_send").data
        XCTAssertEqual(result.channel, "whatsapp")
        XCTAssertEqual(result.link, "https://wa.me/447700900456?text=Stock%20enquiry")
        XCTAssertNil(result.sentTo)

        let list = try Fixture.decode(Envelope.Standard<LossyArray<ShopStockEnquiry>>.self, from: "shop_stock_enquiries").data.elements
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].answered)
        XCTAssertEqual(list[0].stockQty, 4)
        XCTAssertEqual(list[0].unitPriceMinor, 412_500)
        XCTAssertEqual(list[0].channelLabel, "email")
        XCTAssertFalse(list[1].answered)
        XCTAssertEqual(list[1].channelLabel, "text message")
    }

    func testMessageKindsAreTheirOwnSheets() {
        XCTAssertEqual(ShopSupplierMessageKind.priceRequest(quoteUuid: "q").title, "Ask a supplier")
        XCTAssertEqual(ShopSupplierMessageKind.introduction(quoteUuid: "q").title, "Introduce to a supplier")
        XCTAssertEqual(ShopSupplierMessageKind.stockEnquiry(productUuid: "p").title, "Ask about stock")
        XCTAssertNotEqual(ShopSupplierMessageKind.priceRequest(quoteUuid: "q").id, ShopSupplierMessageKind.introduction(quoteUuid: "q").id)
    }

    // MARK: Phone numbers

    func testPhoneNumbersForWhatsApp() {
        XCTAssertEqual(ShopPhone.international("07700 900456"), "447700900456", "a leading 0 is a UK number")
        XCTAssertEqual(ShopPhone.international("+44 7700 900456"), "447700900456")
        XCTAssertEqual(ShopPhone.international("0044 7700 900456"), "447700900456", "00 is the international prefix")
        XCTAssertEqual(ShopPhone.international("+1 (415) 555-0100"), "14155550100")
        XCTAssertNil(ShopPhone.international("12345"), "too short")
        XCTAssertNil(ShopPhone.international(""))
        XCTAssertNil(ShopPhone.international(nil))
        XCTAssertEqual(ShopPhone.whatsApp("07700 900456")?.absoluteString, "https://wa.me/447700900456")
        XCTAssertEqual(ShopPhone.sms("07700 900456")?.absoluteString, "sms:+447700900456")
    }

    // MARK: Suppliers

    func testSupplierList() throws {
        let list = try Fixture.decode(Envelope.Standard<LossyArray<ShopSupplier>>.self, from: "shop_suppliers").data.elements
        XCTAssertEqual(list.count, 2)
        let sam = list[0]
        XCTAssertEqual(sam.contactName, "Sam")
        XCTAssertEqual(sam.email, "price-test@example.com", "the PO email comes first")
        XCTAssertEqual(sam.phone, "07700 900456")
        XCTAssertEqual(sam.pickerLabel, "Test Supplier Ltd (Sam)")
        XCTAssertTrue(sam.isActive)
        let other = list[1]
        XCTAssertNil(other.email)
        XCTAssertNil(other.phone)
        XCTAssertEqual(other.pickerLabel, "Another Supplier")
        XCTAssertFalse(other.isActive)
        XCTAssertTrue(other.portalEnabled)
    }

    func testSupplierContactUpdateKeys() throws {
        let body = ShopSupplierContactUpdate(name: "Boston", contactName: "Sam", contactEmail: "", poEmail: "po@example.com",
                                             poPhone: "07700 900456", poAddress: "", accountNumber: "A1", poNotes: "")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["name", "contact_name", "contact_email", "po_email", "po_phone", "po_address",
                                        "account_number", "po_notes"],
                       "only contact fields: the price feed and its mapping stay as they are")
        XCTAssertEqual(json["contact_email"] as? String, "", "an empty field clears it")
    }

    // MARK: Deals

    func testDealDetail() throws {
        let deal = try Fixture.decode(Envelope.Standard<ShopDeal>.self, from: "shop_deal_detail").data
        XCTAssertEqual(deal.dealCode, "WS-UEEG-XBD6")
        XCTAssertEqual(deal.customer.company, "Ode Labs")
        XCTAssertEqual(deal.quotes.first?.status, .sent)
        XCTAssertEqual(deal.quotes.first?.revisionNo, 1)
        XCTAssertEqual(deal.orders.first?.status, .pendingPayment)
        let po = try XCTUnwrap(deal.purchaseOrders.first)
        XCTAssertEqual(po.total, 7200, "Postgres numeric arrives as a string")
        XCTAssertTrue(po.dropShip)

        XCTAssertEqual(deal.supplierRequests.count, 2)
        let price = deal.supplierRequests[0]
        XCTAssertEqual(price.channelLabel, "WhatsApp")
        XCTAssertTrue(price.isAnswered)
        XCTAssertEqual(price.lines.first?.unitPriceMinor, 3_600_000)
        XCTAssertEqual(price.lines.first?.qty, 2)
        let intro = deal.supplierRequests[1]
        XCTAssertEqual(intro.kind, "intro")
        XCTAssertTrue(intro.lines.isEmpty, "`{}` is an empty list")
        XCTAssertNil(intro.channelLabel)
        XCTAssertFalse(intro.isAnswered)
    }

    func testDealListAndSearch() throws {
        let recent = try Fixture.decode(Envelope.Standard<ShopDealResults>.self, from: "shop_deals_recent").data
        XCTAssertEqual(recent.results.map(\.dealCode), ["WS-UEEG-XBD6", "WS-AAAA-BBBB"])
        XCTAssertEqual(recent.results[0].purchaseOrders, 1)
        XCTAssertNil(recent.results[1].customer)
        XCTAssertNil(recent.exact)

        let search = try Fixture.decode(Envelope.Standard<ShopDealResults>.self, from: "shop_deals_search").data
        XCTAssertEqual(search.results.first?.matchedBy, "quote_number")
        XCTAssertEqual(search.results.first?.match, "WSQ-2026-00027")
    }

    // MARK: Order page

    func testOrderExtras() throws {
        let data = try Fixture.data("shop_order_admin")
        let order = try JSONDecoder.opsAPI().decode(Envelope.Standard<ShopOrder>.self, from: data).data
        let extras = try JSONDecoder.opsAPI().decode(Envelope.Standard<ShopOrderExtras>.self, from: data).data
        XCTAssertEqual(order.status, .pendingPayment)
        XCTAssertEqual(extras.dealCode, "WS-UEEG-XBD6")
        XCTAssertEqual(extras.paymentMethod, "bank_transfer")
        XCTAssertTrue(extras.bankTransferDue)
        XCTAssertEqual(extras.daysWaiting, 1)
        XCTAssertEqual(extras.customerPoNumber, "PO-ODE-9")
        XCTAssertNil(extras.invoiceUuid)
        XCTAssertEqual(extras.deliveryDate, "2026-11-25")
        XCTAssertEqual(ShopOrderDetailView.windowLabel(extras.deliveryWindow ?? ""), "morning")

        XCTAssertEqual(extras.customerUpdates.count, 2)
        let comment = extras.customerUpdates[0]
        XCTAssertEqual(comment.headline, "Update")
        XCTAssertTrue(comment.removable)
        XCTAssertNotNil(comment.at)
        let email = extras.customerUpdates[1]
        XCTAssertEqual(email.headline, "We've got your order")
        XCTAssertFalse(email.removable, "emails we sent can't be taken back")

        let change = try XCTUnwrap(extras.deliveryChangeRequests.first)
        XCTAssertTrue(change.isPending)
        XCTAssertEqual(ShopAnyAddress.format(change.requestedAddress), "2 Low St, Leeds, LS2 2BB, GB")
        XCTAssertEqual(change.windowLabel, "Afternoon")
        XCTAssertEqual(change.customerNote, "Back gate please")
    }

    func testOrderSignature() throws {
        let state = try Fixture.decode(Envelope.Standard<ShopOrderSignatureState>.self, from: "shop_order_signature").data
        XCTAssertTrue(state.canSign)
        XCTAssertEqual(state.signature?.signerName, "Ben Ode")
        XCTAssertEqual(state.signature?.capturedBy, "Alex Example")
        XCTAssertNotNil(state.signature?.signedAt)
    }

    func testSignatureCaptureBody() throws {
        let body = ShopSignatureCapture(signerName: "Ben Ode", image: "data:image/png;base64,AAAA", note: nil, markDelivered: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any])
        XCTAssertEqual(json["signer_name"] as? String, "Ben Ode")
        XCTAssertEqual(json["mark_delivered"] as? Bool, false)
        XCTAssertNil(json["note"])
    }

    @MainActor
    func testSignaturePadMakesAPNG() throws {
        let strokes: [[CGPoint]] = [[CGPoint(x: 10, y: 10), CGPoint(x: 120, y: 80), CGPoint(x: 220, y: 40)], [CGPoint(x: 50, y: 150)]]
        let png = try XCTUnwrap(SignaturePad.png(strokes: strokes, size: CGSize(width: 320, height: 200)))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a PNG")
        XCTAssertGreaterThan(png.count, 200, "the server refuses an empty canvas (under 200 bytes)")
        XCTAssertLessThan(png.count, 300 * 1024, "and anything over 300 KB")
        XCTAssertNil(SignaturePad.png(strokes: strokes, size: .zero), "nothing drawn yet: no picture")
    }

    func testMarkPaidBody() throws {
        let body = ShopMarkPaidBody(method: "cheque", reference: nil, paidAt: "2026-11-19")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "cheque")
        XCTAssertEqual(json["paid_at"] as? String, "2026-11-19")
        XCTAssertNil(json["reference"])
    }

    func testMarkPaidTodaySendsNoDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T16:06:00Z")!
        XCTAssertNil(ShopMarkPaidForm.paidAt(now, now: now, calendar: calendar),
                     "today: the server records the time it was marked")
        let earlier = calendar.date(byAdding: .day, value: -2, to: now)!
        XCTAssertEqual(ShopMarkPaidForm.paidAt(earlier, now: now, calendar: calendar), "2026-11-17")
    }

    // MARK: Permissions

    func testMarkPaidNeedsManageAndAnalyticsItsOwnModule() {
        let editor = ShopPolicy(permissions: PermissionSet(isAdmin: false, isOwner: false, grants: ["shop": ["read", "update"]], menuKeys: ["shop"]))
        XCTAssertTrue(editor.canUpdate)
        XCTAssertFalse(editor.canManage, "saying money arrived releases the goods")
        XCTAssertFalse(editor.canSeeAnalytics)
        let manager = ShopPolicy(permissions: PermissionSet(isAdmin: false, isOwner: false, grants: ["shop": ["manage"], "shop_analytics": ["read"]], menuKeys: ["shop"]))
        XCTAssertTrue(manager.canManage)
        XCTAssertTrue(manager.canSeeAnalytics)
    }
}
