import XCTest
@testable import WSLCRM

/// "As easy as the web" fixes for shop & sales: products, invoices, purchase orders, store orders,
/// shop orders and the customer page. Response shapes follow the Lua routes/queries named on each test.
@MainActor
final class ShopEasyTests: XCTestCase {

    /// Records every request and answers each with the first stub whose path matches.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func add(_ r: URLRequest) { lock.withLock { stored.append(r) } }
        func last(_ path: String) -> URLRequest? { requests.last { $0.url?.path == path } }
    }

    private func client(_ recorder: Recorder, _ stubs: [String: String]) async -> APIClient {
        let client = APIClient(baseURL: URL(string: "https://api.test")!,
                               session: StubURLProtocol.session { request in
                                   recorder.add(request)
                                   let path = request.url?.path ?? ""
                                   let body = stubs[path] ?? stubs.first { path.hasPrefix($0.key) }?.value ?? #"{"success":true}"#
                                   return .json(200, body)
                               },
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return client
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    // MARK: 1. Inactive products (routes/products.lua → StoreproductQueries.searchProducts)

    func testProductsListAsksForActiveInactiveOrAllAndDecodesTheInactiveFlag() async throws {
        let recorder = Recorder()
        let api = CommerceAPI(client: await client(recorder, ["/api/v2/products": #"""
        {"data":[{"id":7,"uuid":"p-7","name":"Old mug","price":"8.50","is_active":false,"track_inventory":true,
          "inventory_quantity":0,"namespace_id":3}],"total":1,"currency":"GBP"}
        """#]))
        let page = try await api.products(search: "MUG-1", storeUuid: nil, namespaceInternalId: 3, page: 1, show: .inactive)
        XCTAssertEqual(page.items.first?.isActive, false)
        let q = query(recorder.last("/api/v2/products"))
        XCTAssertEqual(q["is_active"], "false")
        XCTAssertEqual(q["search"], "MUG-1", "search also matches SKU and barcode on the server")
        _ = try await api.products(search: "", storeUuid: nil, namespaceInternalId: 3, page: 1, show: .all)
        XCTAssertEqual(query(recorder.last("/api/v2/products"))["is_active"], "all")
        _ = try await api.products(search: "", storeUuid: nil, namespaceInternalId: 3, page: 1)
        XCTAssertEqual(query(recorder.last("/api/v2/products"))["is_active"], "true", "the default stays active only")
    }

    // MARK: 2–3. Email again / reminders, and saying what happened (routes/invoices.lua)

    static func invoice(status: String, due: String, paid: String = "0", balance: String = "120.00") throws -> Invoice {
        let json = """
        {"id":"inv-1","internal_id":4,"invoice_number":"INV-0004","status":"\(status)","customer_name":"Acme Ltd",
         "customer_email":"pay@acme.test","issue_date":"2026-09-01","due_date":"\(due)","currency":"GBP",
         "subtotal":"100.00","tax_amount":"20.00","total_amount":"120.00","amount_paid":"\(paid)","balance_due":"\(balance)",
         "line_items":[],"payments":[]}
        """
        return try JSONDecoder.opsAPI().decode(Invoice.self, from: Data(json.utf8))
    }

    func testEveryInvoiceButAVoidOneCanBeEmailedAndAnOverdueOneIsAReminder() throws {
        let draft = try Self.invoice(status: "draft", due: "2099-01-01")
        XCTAssertTrue(draft.canEmail)
        XCTAssertEqual(draft.emailActionTitle, "Email to customer")
        XCTAssertNil(EmailInvoiceSheet.reminderNote(draft))

        let sent = try Self.invoice(status: "sent", due: "2099-01-01")
        XCTAssertTrue(sent.canEmail, "a sent invoice can be emailed again")
        XCTAssertFalse(sent.canSend)
        XCTAssertEqual(sent.emailActionTitle, "Email again")

        let overdue = try Self.invoice(status: "sent", due: "2026-10-01")
        XCTAssertEqual(overdue.displayStatus, .overdue)
        XCTAssertEqual(overdue.emailActionTitle, "Send a reminder")
        let note = try XCTUnwrap(EmailInvoiceSheet.reminderNote(overdue))
        XCTAssertTrue(note.contains("£120.00 is still to pay"), note)

        let paid = try Self.invoice(status: "paid", due: "2026-10-01", paid: "120.00", balance: "0")
        XCTAssertTrue(paid.canEmail)
        XCTAssertFalse(try Self.invoice(status: "void", due: "2026-10-01").canEmail)
    }

    func testEmailingSendsThePdfAndRecipientTheRouteReads() async throws {
        let recorder = Recorder()
        let api = InvoicesAPI(client: await client(recorder, ["/api/v2/invoices/inv-1/email": #"""
        {"success":true,"data":{"message":"Invoice emailed to pay@acme.test","to":"pay@acme.test","status":"sent"}}
        """#]))
        let result = try await api.email("inv-1", pdf: Data("%PDF".utf8), filename: "INV-0004.pdf", to: "pay@acme.test",
                                         message: "Reminder")
        XCTAssertEqual(result.to, "pay@acme.test")
        let body = try XCTUnwrap(recorder.last("/api/v2/invoices/inv-1/email")?.jsonBody)
        XCTAssertEqual(body["pdf_base64"] as? String, Data("%PDF".utf8).base64EncodedString())
        XCTAssertEqual(body["filename"] as? String, "INV-0004.pdf")
        XCTAssertEqual(body["to"] as? String, "pay@acme.test")
        XCTAssertEqual(body["message"] as? String, "Reminder")
        XCTAssertEqual(InvoiceDetailView.paymentNotice(50, currency: "GBP"), "Payment of £50.00 recorded.")
    }

    // MARK: 4. Purchase order money tiles (PurchaseOrderQueries.getStats)

    func testPurchaseOrderStatsShowOneAmountPerCurrency() throws {
        let json = #"""
        {"success":true,"data":{"total_count":5,"draft_count":1,"open_count":3,"overdue_count":1,"to_bill_count":1,
         "by_status":[{"status":"sent","count":3}],
         "by_currency":[{"currency":"GBP","total_count":4,"total_value":1500,"draft_count":1,"open_count":2,"open_value":1200,
                         "overdue_count":1,"to_bill_count":1,"to_bill_value":240.5,"billed_value":60},
                        {"currency":"EUR","total_count":1,"total_value":300,"draft_count":0,"open_count":1,"open_value":300,
                         "overdue_count":0,"to_bill_count":0,"to_bill_value":0,"billed_value":0}]}}
        """#
        let stats = try JSONDecoder.opsAPI().decode(Envelope.Invoices<PurchaseOrderStats>.self, from: Data(json.utf8)).data
        XCTAssertEqual(stats.openCount, 3)
        XCTAssertEqual(stats.byCurrency.map(\.currency), ["GBP", "EUR"])
        XCTAssertEqual(stats.amounts(\.openValue), "£1,200.00 + €300.00")
        XCTAssertEqual(stats.amounts(\.toBillValue), "£240.50 + €0.00")
        XCTAssertEqual(stats.amounts(\.billedValue), "£60.00 + €0.00")
        let empty = try JSONDecoder.opsAPI().decode(PurchaseOrderStats.self, from: Data(#"{"open_count":0,"by_currency":{}}"#.utf8))
        XCTAssertEqual(empty.amounts(\.openValue), "£0.00", "lua-cjson sends {} for no currencies")
    }

    // MARK: 5. Store pickers (StoreQueries.all pages with perPage)

    func testStorePickersAskForAHundredStoresWithPerPage() async throws {
        let recorder = Recorder()
        let c = await client(recorder, ["/api/v2/stores": #"{"data":[{"id":1,"uuid":"st-1","name":"High Street"}],"total":1}"#])
        _ = try await SalesAPI(client: c).stores()
        XCTAssertEqual(query(recorder.last("/api/v2/stores"))["perPage"], "100")
        XCTAssertNil(query(recorder.last("/api/v2/stores"))["limit"])
        _ = try await DeliveryAPI(client: c).stores()
        XCTAssertEqual(query(recorder.last("/api/v2/stores"))["perPage"], "100")
    }

    // MARK: 8. Price changes (ShopSupplierQueries.decide: only pending ones)

    func testPriceChangeActionsOnlyShowOnPendingRows() {
        let actions = ModuleCatalog.shopPriceChanges.actions
        XCTAssertEqual(actions.map(\.id), ["approve", "reject"])
        XCTAssertEqual(actions.first?.path, "/api/v2/shop/admin/price-changes/{uuid}/approve")
        for action in actions {
            XCTAssertEqual(action.visibleWhen, Condition.field("status", in: ["pending"]))
        }
        XCTAssertEqual(ShopPriceChangesView.choices.first?.value, "pending", "the list starts on the waiting ones")
    }

    // MARK: 9. Refunds (ShopOrderQueries.adminRefund)

    func testRefundPreviewThenRefundSendTheServersBody() async throws {
        let recorder = Recorder()
        let api = ShopAPI(client: await client(recorder, ["/api/v2/shop/admin/orders/o-1/refund": #"""
        {"success":true,"data":{"order_uuid":"o-1","order_number":"SO-1001","dry_run":true,"full":false,"refund_minor":2100,
         "clawback_minor":250,"clawback_gross_minor":300,"returned_net_minor":2000,"member_discount_minor":500,
         "refunded_before_minor":0,"stripe_refund_id":null}}
        """#]))
        let preview = try await api.refund(orderUuid: "o-1", .of(full: false, returnedNet: "20.00", reason: "Wrong size", preview: true))
        XCTAssertEqual(preview.refundMinor, 2100)
        XCTAssertEqual(preview.clawbackGrossMinor, 300)
        XCTAssertNil(preview.stripeRefundId)
        let body = try XCTUnwrap(recorder.last("/api/v2/shop/admin/orders/o-1/refund")?.jsonBody)
        XCTAssertEqual(body["amount_net_minor"] as? Int, 2000)
        XCTAssertEqual(body["dry_run"] as? Bool, true)
        XCTAssertEqual(body["reason"] as? String, "Wrong size")
        XCTAssertNil(body["full"])

        _ = try await api.refund(orderUuid: "o-1", .of(full: true, returnedNet: "", reason: "Faulty", preview: false))
        let full = try XCTUnwrap(recorder.last("/api/v2/shop/admin/orders/o-1/refund")?.jsonBody)
        XCTAssertEqual(full["full"] as? Bool, true)
        XCTAssertNil(full["dry_run"], "the real refund leaves dry_run out")
        XCTAssertNil(full["amount_net_minor"])
        XCTAssertTrue(ShopOrderStatus.delivered.isRefundable)
        XCTAssertFalse(ShopOrderStatus.pendingPayment.isRefundable)
    }

    // MARK: 11. Purchase invoices (PurchaseInvoiceQueries.list)

    func testPurchaseInvoicesReadRowsAndTotalsPerCurrency() async throws {
        let recorder = Recorder()
        let api = PurchaseOrdersAPI(client: await client(recorder, ["/api/v2/purchase-invoices": #"""
        {"success":true,"data":[{"uuid":"pi-1","kind":"invoice","number":"INV-77","state":"overdue","invoice_date":"2026-10-01",
          "due_date":"2026-10-31","days_late":23,"net":"100.00","vat":"20.00","total":"120.00","paid":"0.00","outstanding":"120.00",
          "currency":"GBP","supplier_name":"Acme Supplies","supplier_order_ref":null,"payment_terms":null,"has_document":false,
          "recorded_by":"staff","purchase_order":{"uuid":"po-1","po_number":"PO-0001"}}],
         "meta":{"total":1,"limit":25,"offset":0,"summary":{"GBP":{"owed":"120.00","overdue":"120.00","paid":"50.00",
          "owed_count":1,"overdue_count":1}}}}
        """#, "/api/v2/purchase-orders/po-1/portal/invoices": #"{"success":true,"data":{"purchase_order":{"id":"po-1"}}}"#]))
        let (page, totals) = try await api.purchaseInvoices(search: "Acme", state: "owed", page: 2)
        XCTAssertEqual(page.items.first?.string("number"), "INV-77")
        XCTAssertEqual(page.items.first?.string("purchase_order.po_number"), "PO-0001")
        XCTAssertEqual(totals.text(\.owed), "£120.00")
        XCTAssertEqual(totals.text(\.paid), "£50.00")
        XCTAssertEqual(totals.overdueCount, 1)
        let q = query(recorder.last("/api/v2/purchase-invoices"))
        XCTAssertEqual(q["state"], "owed")
        XCTAssertEqual(q["q"], "Acme")
        XCTAssertEqual(q["offset"], "25")
        XCTAssertEqual(PurchaseInvoiceTotals.parse(.object([:])).text(\.owed), "£0.00")

        try await api.recordSupplierInvoice(poUuid: "po-1", ["kind": .string("invoice"), "number": .string("INV-78"),
                                                             "invoice_date": .string("2026-11-20"), "total": .string("60.00")])
        let body = try XCTUnwrap(recorder.last("/api/v2/purchase-orders/po-1/portal/invoices")?.jsonBody)
        XCTAssertEqual(body["number"] as? String, "INV-78")
        XCTAssertEqual(body["total"] as? String, "60.00")
        XCTAssertEqual(PortalText.invoiceFields.map(\.key),
                       ["kind", "number", "invoice_date", "net", "vat", "total", "due_date", "supplier_order_ref",
                        "payment_terms", "note"])
    }

    // MARK: 6. Choose a customer (GET /api/v2/customers) and start a sale from them

    static let customerJSON = #"""
    {"uuid":"c-1","email":"jo@acme.test","first_name":"Jo","last_name":"Bloggs","phone":"07700 900123",
     "addresses":"[{\"name\":\"Jo Bloggs\",\"company\":\"Acme Ltd\",\"address1\":\"1 High St\",\"address2\":\"\",\"city\":\"Leeds\",\"province\":\"West Yorkshire\",\"zip\":\"LS1 1AA\",\"country\":\"United Kingdom\",\"is_default\":true}]"}
    """#

    func testAPickedCustomerFillsTheInvoiceTheQuoteAndTheStoreOrder() throws {
        let customer = try JSONDecoder.opsAPI().decode(Customer.self, from: Data(Self.customerJSON.utf8))
        let picked = PickedCustomer(customer)
        XCTAssertEqual(picked.name, "Jo Bloggs")
        XCTAssertEqual(picked.addressText, "1 High St\nLeeds\nWest Yorkshire\nLS1 1AA\nUnited Kingdom")
        let draft = picked.shopDraft
        XCTAssertEqual(draft.email, "jo@acme.test")
        XCTAssertEqual(draft.company, "Acme Ltd")
        XCTAssertEqual(draft.postalCode, "LS1 1AA")
        XCTAssertEqual(draft.country, "GB", "the shop wants two letters")
        let address = picked.storeOrderAddress
        XCTAssertEqual(address.line1, "1 High St")
        XCTAssertNil(address.line2, "blank parts are left out")
        XCTAssertEqual(address.postcode, "LS1 1AA")
        XCTAssertTrue(picked.hasAddress)
        XCTAssertEqual(SalesOrderQuery(search: "jo@acme.test").items(page: 1, perPage: 25).first { $0.name == "q" }?.value,
                       "jo@acme.test", "a customer's orders are found by their email")
    }

    // MARK: 7. Mark a bank transfer paid (ShopOrderQueries.markPaid)

    func testMarkPaidSendsTheAmountAndTheOrderShowsWhereToPay() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(
            ShopMarkPaidBody(method: "bank_transfer", reference: "SO-1001", paidAt: nil, amountMinor: 12000))) as? [String: Any]
        XCTAssertEqual(body?["amount_minor"] as? Int, 12000)
        XCTAssertEqual(body?["reference"] as? String, "SO-1001")
        XCTAssertNil(body?["paid_at"])
        XCTAssertEqual(ShopMarkPaidForm.shortfall(10000, total: 12000), 2000)
        XCTAssertNil(ShopMarkPaidForm.shortfall(12000, total: 12000))

        let extras = try JSONDecoder.opsAPI().decode(ShopOrderExtras.self, from: Data(#"""
        {"payment_method":"bank_transfer","payment_reference":"SO-1001",
         "payment_methods":[{"kind":"bank_transfer","label":"Main account","account_name":"Acme Ltd","sort_code":"12-34-56",
                             "account_number":"12345678","is_default":true}]}
        """#.utf8))
        XCTAssertEqual(extras.paymentReference, "SO-1001")
        XCTAssertEqual(extras.paymentMethods.first?.rows.map(\.0), ["Account name", "Sort code", "Account number"])
        let card = try JSONDecoder.opsAPI().decode(ShopOrderExtras.self, from: Data(#"{"payment_method":"card","payment_methods":{}}"#.utf8))
        XCTAssertTrue(card.paymentMethods.isEmpty)
    }

    // MARK: 10. Stock adjust (POST …/products/{uuid}/stock)

    func testStockAdjustSaysWhatChanged() {
        let target = ShopStockTarget(kind: .product, uuid: "p-1", name: "Mug", current: 7)
        XCTAssertEqual(ShopStockAdjustForm.message(target, delta: 5), "Stock of Mug increased by 5, now 12.")
        XCTAssertEqual(ShopStockAdjustForm.message(target, delta: -2), "Stock of Mug reduced by 2, now 5.")
    }

    // MARK: 12. Invoice create (POST /api/v2/invoices)

    func testANewInvoiceSendsDatesTermsHowToPayAndLines() throws {
        let issued = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3)))
        let body = InvoiceCreateSheet.body(
            name: " Acme Ltd ", email: "", address: "1 High St\nLeeds", issued: issued, terms: 14, currency: "GBP",
            notes: "", poNumber: "PO-9", methodUuid: "",
            items: [LineItemBody(description: "Design", quantity: 2, unitPrice: 150, taxRate: 20),
                    LineItemBody(description: " ", quantity: 1, unitPrice: 0, taxRate: 20)])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as? [String: Any])
        XCTAssertEqual(json["customer_name"] as? String, "Acme Ltd")
        XCTAssertEqual(json["issue_date"] as? String, "2026-11-03")
        XCTAssertEqual(json["due_date"] as? String, "2026-11-17", "the due date follows the terms")
        XCTAssertEqual(json["payment_terms_days"] as? Int, 14)
        XCTAssertEqual(json["po_number"] as? String, "PO-9")
        XCTAssertEqual(json["customer_address"] as? String, "1 High St\nLeeds")
        XCTAssertNil(json["payment_method_uuid"], "the default bank account is the server's own default")
        XCTAssertNil(json["customer_email"])
        XCTAssertNil(json["notes"])
        let lines = try XCTUnwrap(json["line_items"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 1, "blank lines are dropped")
        XCTAssertEqual(lines.first?["unit_price"] as? Double, 150)
        XCTAssertEqual(lines.first?["tax_rate"] as? Double, 20)
        XCTAssertEqual(InvoiceCreateSheet.termsLabel(0), "Due on receipt")
    }

    func testTheInvoicePdfShowsTheDiscountSoTheTotalsAddUp() throws {
        var invoice = try Self.invoice(status: "sent", due: "2099-01-01")
        invoice.totalAmount = 110
        let rows = InvoicePDFRenderer.totals(invoice) { "£\($0)" }
        XCTAssertEqual(rows.map(\.0), ["Subtotal", "Discounts", "Tax", "Total", "Paid", "Balance due"])
        XCTAssertEqual(rows[1].1, "−£10")
        let plain = InvoicePDFRenderer.totals(try Self.invoice(status: "sent", due: "2099-01-01")) { "\($0)" }
        XCTAssertFalse(plain.map(\.0).contains("Discounts"))
    }
    // MARK: 13. Paperwork from the phone (routes/supplier-portal.lua: payments and delivered take multipart)

    func testProofOfPaymentGoesAsMultipartWithTheFieldsAsText() async throws {
        XCTAssertEqual(PortalText.formFields(["amount": .string("12.50"), "method": .string("bacs"), "sent_on": .string("2026-11-20"),
                                              "flag": .bool(true)]).map(\.0), ["amount", "flag", "method", "sent_on"])
        let recorder = Recorder()
        let api = PurchaseOrdersAPI(client: await client(recorder, ["/api/v2/purchase-orders/po-1/portal/payments":
            #"{"success":true,"data":{"purchase_order":{"id":"po-1"}}}"#]))
        _ = try await api.portalPostWithFile("po-1", "/payments", ["amount": .string("12.50"), "method": .string("bacs")],
                                             file: .init(fieldName: "file", filename: "proof.pdf", mimeType: "application/pdf",
                                                         data: Data("%PDF".utf8)))
        let request = try XCTUnwrap(recorder.last("/api/v2/purchase-orders/po-1/portal/payments"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") ?? false)
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"amount\"\r\n\r\n12.50"), text)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"proof.pdf\""), text)
    }

    // MARK: 15. Wording and polish

    func testAttributesReadAsRowsAndSaveAsTheSameJSON() throws {
        let rows = try XCTUnwrap(ShopAttributeRow.rows(#"{"psu_watts": 2000, "memory_type": "DDR5-RDIMM", "ecc": true}"#))
        XCTAssertEqual(rows.map(\.name), ["ecc", "memory_type", "psu_watts"])
        XCTAssertEqual(rows.map(\.value), ["true", "DDR5-RDIMM", "2000"])
        let json = ShopAttributeRow.json(rows + [ShopAttributeRow(name: " ", value: "ignored"),
                                                 ShopAttributeRow(name: "gpu_slots", value: "4")])
        let back = try XCTUnwrap(ShopJSON.object(json).0)
        XCTAssertEqual(back, .object(["psu_watts": .number(2000), "memory_type": .string("DDR5-RDIMM"), "ecc": .bool(true),
                                      "gpu_slots": .number(4)]))
        XCTAssertNil(ShopAttributeRow.rows(#"{"ports": ["usb", "hdmi"]}"#), "lists are edited as text")
        XCTAssertEqual(ShopAttributeRow.rows("")?.count, 0)
    }

    func testPlainWordsForPaymentMethods() {
        XCTAssertEqual(PaymentSheet.methodLabel("check"), "Cheque")
        XCTAssertEqual(PaymentSheet.methodLabel("paypal"), "PayPal")
        XCTAssertEqual(PaymentSheet.methodLabel("credit_card"), "Card")
    }

    func testQuoteDealCodeLinksOrStartsADeal() async throws {
        let recorder = Recorder()
        let api = ShopAPI(client: await client(recorder, ["/api/v2/shop/admin/quotes/q-1/deal-code":
            #"{"success":true,"data":{"deal_code":"WS-DT5Z-994X","previous":null,"moved":true}}"#]))
        let code = try await api.linkDealCode(quoteUuid: "q-1", code: " ws-dt5z-994x ")
        XCTAssertEqual(code, "WS-DT5Z-994X")
        let body = try XCTUnwrap(recorder.last("/api/v2/shop/admin/quotes/q-1/deal-code")?.jsonBody)
        XCTAssertEqual(body["deal_code"] as? String, "ws-dt5z-994x", "the server tidies the code")
        XCTAssertNil(body["new"])
        _ = try await api.linkDealCode(quoteUuid: "q-1", code: nil)
        let fresh = try XCTUnwrap(recorder.last("/api/v2/shop/admin/quotes/q-1/deal-code")?.jsonBody)
        XCTAssertEqual(fresh["new"] as? Bool, true)
        XCTAssertNil(fresh["deal_code"])
    }

    // MARK: Signatures: store orders (routes/orders.lua) and deliveries (routes/delivery-assignments.lua)

    static let signatureJSON = #"""
    {"success":true,"data":{"signature":{"uuid":"sig-1","signer_name":"Jo Bloggs","note":"At the door",
      "signed_at":"2026-11-24T10:15:00Z","captured_by":"sam@shop.test","image_sha256":"ab12","image_bytes":2048},
     "can_sign":false,"status":"delivered"}}
    """#

    func testAStoreOrderIsSignedForAndHandedOverInOneStep() async throws {
        let recorder = Recorder()
        let api = SalesAPI(client: await client(recorder, ["/api/v2/orders/o-1/signature": Self.signatureJSON]))
        let state = try await api.signStoreOrder("o-1", StoreOrderSignatureBody(signerName: "Jo Bloggs",
                                                                                 image: "data:image/png;base64,iVBORw0KGgo=",
                                                                                 note: nil, markHandedOver: true))
        XCTAssertEqual(state.signature?.signerName, "Jo Bloggs")
        XCTAssertEqual(state.signature?.capturedBy, "sam@shop.test")
        XCTAssertFalse(state.canSign)
        let body = try XCTUnwrap(recorder.last("/api/v2/orders/o-1/signature")?.jsonBody)
        XCTAssertEqual(body["signer_name"] as? String, "Jo Bloggs")
        XCTAssertEqual(body["image"] as? String, "data:image/png;base64,iVBORw0KGgo=")
        XCTAssertEqual(body["mark_handed_over"] as? Bool, true)
        XCTAssertNil(body["note"])

        try await api.voidStoreOrderSignature("o-1", reason: "Wrong person")
        let void = try XCTUnwrap(recorder.last("/api/v2/orders/o-1/signature/void")?.jsonBody)
        XCTAssertEqual(void["reason"] as? String, "Wrong person")

        XCTAssertEqual(SignatureCapture.problem(name: "J", png: Data([1])), "Type the name of the person signing.")
        XCTAssertNotNil(SignatureCapture.problem(name: "Jo", png: Data(count: 301 * 1024)), "the server takes 300 KB at most")
        XCTAssertNil(SignatureCapture.problem(name: "Jo", png: Data([1, 2, 3])))
    }

    func testADeliveryPartnerSeesTheirDeliveriesAndDeliversWithASignature() async throws {
        let recorder = Recorder()
        let api = DeliveryAPI(client: await client(recorder, [
            "/api/v2/delivery-partner/assignments": #"""
            {"assignments":[{"uuid":"da-1","status":"in_transit","delivery_fee":"4.50","pickup_address":"1 Mill Lane",
              "delivery_address":"2 High St","delivery_city":"Leeds","delivery_postal_code":"LS1 1AA","customer_name":"Jo Bloggs",
              "order_number":"ORD-1","total_amount":"40.00","store_name":"High Street","store_phone":"0113 000",
              "delivery_latitude":null,"delivery_longitude":null,"proof_of_delivery":null}]}
            """#,
            "/api/v2/delivery-assignments/da-1/status": #"""
            {"success":true,"message":"Assignment status updated from 'in_transit' to 'delivered'","assignment":{"uuid":"da-1",
             "status":"delivered"},"order_status":"delivered","previous_status":"in_transit"}
            """#,
            "/api/v2/delivery-assignments/da-1/signature": Self.signatureJSON,
        ]))
        let rows = try await api.myAssignments(status: "active")
        XCTAssertEqual(rows.first?.id, "da-1")
        XCTAssertEqual(MyDeliveryDetailView.address(try XCTUnwrap(rows.first)), "2 High St, Leeds, LS1 1AA")
        let list = try XCTUnwrap(recorder.last("/api/v2/delivery-partner/assignments"))
        XCTAssertEqual(query(list)["status"], "active")
        XCTAssertNil(list.value(forHTTPHeaderField: "X-Namespace-Id"), "a partner needs no workspace")

        let message = try await api.moveMyAssignment("da-1", DeliveryStatusBody(status: "delivered", notes: nil,
                                                                               signature: "data:image/png;base64,iVBORw0KGgo=",
                                                                               signerName: "Jo Bloggs"))
        XCTAssertEqual(message, "Assignment status updated from 'in_transit' to 'delivered'")
        let put = try XCTUnwrap(recorder.last("/api/v2/delivery-assignments/da-1/status"))
        XCTAssertEqual(put.httpMethod, "PUT")
        let body = try XCTUnwrap(put.jsonBody)
        XCTAssertEqual(body["status"] as? String, "delivered")
        XCTAssertEqual(body["signer_name"] as? String, "Jo Bloggs")
        XCTAssertEqual(body["signature"] as? String, "data:image/png;base64,iVBORw0KGgo=", "JSON keeps + / = as they are")
        XCTAssertNil(body["notes"])

        let proof = try await api.assignmentSignature("da-1")
        XCTAssertEqual(proof.signature?.signerName, "Jo Bloggs")

        XCTAssertEqual(MyDeliverySteps.next(from: "pending").map(\.status), ["accepted", "rejected"])
        XCTAssertEqual(MyDeliverySteps.next(from: "accepted").map(\.status), ["picked_up", "cancelled"])
        XCTAssertEqual(MyDeliverySteps.next(from: "picked_up").map(\.status), ["in_transit", "cancelled"])
        let last = MyDeliverySteps.next(from: "in_transit")
        XCTAssertEqual(last.map(\.status), ["delivered", "delivered", "failed"])
        XCTAssertEqual(last.map(\.signs), [true, false, false], "only the first one asks for the signature")
        XCTAssertTrue(MyDeliverySteps.next(from: "delivered").isEmpty)
    }
}
