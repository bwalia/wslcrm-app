import XCTest
@testable import WSLCRM

/// The deep audit's money fixes (invoices, purchase orders, VAT, tax, payroll), checked against the server's routes.
@MainActor
final class MoneyDeepAuditTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func add(_ r: URLRequest) { lock.withLock { stored.append(r) } }
        func last(_ path: String) -> URLRequest? { requests.last { $0.url?.path == path } }
        func all(_ path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }
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

    private func permissions(_ grants: [String: Set<String>], owner: Bool = false) -> PermissionSet {
        PermissionSet(isAdmin: false, isOwner: owner, grants: grants, menuKeys: [])
    }

    // MARK: Invoices: filter and payments

    /// `InvoiceQueries.list`: "overdue" is worked out on the server; any stored status filters as is.
    func testInvoiceListFiltersOverdueAndCancelled() async throws {
        let recorder = Recorder()
        let api = InvoicesAPI(client: await client(recorder, ["/api/v2/invoices": #"{"data":[],"meta":{"total":0}}"#]))
        _ = try await api.invoices(search: "", status: .overdue, page: 1)
        XCTAssertEqual(query(recorder.last("/api/v2/invoices"))["status"], "overdue")
        _ = try await api.invoices(search: "", status: .cancelled, page: 1)
        XCTAssertEqual(query(recorder.last("/api/v2/invoices"))["status"], "cancelled")
        _ = try await api.invoices(search: "", status: nil, page: 1)
        XCTAssertNil(query(recorder.last("/api/v2/invoices"))["status"])
        XCTAssertTrue(InvoiceFilterSheet.statuses.contains(.overdue))
        XCTAssertFalse(InvoiceFilterSheet.statuses.contains(.partiallyPaid), "the server never stores part paid")
        XCTAssertEqual(InvoiceFilterSheet.label(.overdue), "Overdue")
        XCTAssertEqual(InvoiceFilterSheet.label(.cancelled), "Cancelled")
    }

    func testDeletingAPaymentSaysHowMuch() {
        let payment = InvoicePayment(id: "p-1", amount: 120, paymentMethod: "cash", referenceNumber: nil, paymentDate: nil,
                                     notes: nil)
        XCTAssertEqual(InvoiceDetailView.deletePaymentTitle(payment, currency: "GBP"),
                       "Delete this \(Formatters.money(120, currency: "GBP") ?? "") payment?")
        XCTAssertEqual(InvoiceDetailView.deletePaymentTitle(nil, currency: "GBP"), "Delete this payment?")
    }

    // MARK: Idempotency keys (helper/idempotency.lua)

    func testARetryKeyIsKeptOnlyWhenTheReplyMayHaveBeenLost() {
        let problem = ServerError(status: 400, message: "Bad", fieldErrors: [:], rawBody: "")
        var key = MoneyRetryKey()
        let first = key.value
        key.settle(.offline(URLError(.timedOut)))
        XCTAssertEqual(key.value, first, "a timeout may have created it: the retry must replay")
        key.settle(.server(ServerError(status: 503, message: "Busy", fieldErrors: [:], rawBody: "")))
        XCTAssertEqual(key.value, first, "a 5xx releases the key on the server")
        key.settle(.validation(ServerError(status: 409, message: "Still running", fieldErrors: [:], rawBody: "")))
        XCTAssertEqual(key.value, first, "the first attempt is still running")
        key.settle(.validation(problem))
        XCTAssertNotEqual(key.value, first, "the server kept that answer: a changed form needs a new key")
        let second = key.value
        key.settle(nil)
        XCTAssertNotEqual(key.value, second, "after success the next one is new")
    }

    func testCreatesSendTheFormsKey() async throws {
        let recorder = Recorder()
        let client = await client(recorder, [
            "/api/v2/purchase-orders": #"{"success":true,"data":{"uuid":"po-1","po_number":"PO-1","status":"draft","currency":"GBP"}}"#,
            "/api/v2/purchase-orders/po-1": #"{"success":true,"data":{"uuid":"po-1","po_number":"PO-1","status":"draft","currency":"GBP"}}"#,
            "/api/v2/invoices": #"{"success":true,"data":{"uuid":"inv-1","invoice_number":"INV-1","status":"draft"}}"#,
        ])
        let pos = PurchaseOrdersAPI(client: client)
        _ = try await pos.create(PurchaseOrderBody(supplierName: "Acme", supplierEmail: nil, supplierPhone: nil, reference: nil,
                                                   expectedDate: nil, deliveryAddress: nil, currency: "GBP", notes: nil,
                                                   projectUuid: nil, items: nil, terms: nil), idempotencyKey: "form-1")
        let created = recorder.requests.first { $0.url?.path == "/api/v2/purchase-orders" && $0.httpMethod == "POST" }
        XCTAssertEqual(created?.value(forHTTPHeaderField: "Idempotency-Key"), "form-1")

        let invoices = InvoicesAPI(client: client)
        _ = try? await invoices.create(InvoiceCreateSheet.body(name: "Acme", email: "", address: "", issued: Date(), terms: 30,
                                                               currency: "GBP", notes: "", poNumber: "", methodUuid: "", items: []),
                                       idempotencyKey: "form-2")
        let invoice = recorder.requests.first { $0.url?.path == "/api/v2/invoices" && $0.httpMethod == "POST" }
        XCTAssertEqual(invoice?.value(forHTTPHeaderField: "Idempotency-Key"), "form-2")
    }

    // MARK: Purchase orders: what the route also checks (ledger_denied)

    private func po(bills: String = "[]") throws -> PurchaseOrder {
        try JSONDecoder.opsAPI().decode(PurchaseOrder.self, from: Data("""
        {"uuid":"po-1","po_number":"PO-1","status":"received","currency":"GBP","total":"120.00","metadata":{"bills":\(bills)},
         "items":[{"uuid":"i1","description":"Mug","quantity":"2","unit_price":"50","tax_rate":"20","line_total":"120",
                   "received_quantity":"2","billed_quantity":"0"}]}
        """.utf8))
    }

    func testBillingAndVoidingNeedTheBooksPermissionWhenBookkeepingIsOn() throws {
        let plain = try po()
        let posted = try po(bills: #"[{"uuid":"b-1","net":"100","tax":"20","gross":"120","expense_uuid":"e-1","lines":[]}]"#)
        let buyer = PermissionSet(isAdmin: false, isOwner: false, grants: ["purchase_orders": ["read", "update"]], menuKeys: ["invoices"])
        XCTAssertTrue(PurchaseOrderAccess.canBill(plain, buyer), "no Bookkeeping: nothing posts to the books")
        XCTAssertFalse(PurchaseOrderAccess.canBill(posted, buyer), "a bill was posted, so Bookkeeping is on")
        XCTAssertFalse(PurchaseOrderAccess.canVoidBill(posted, buyer))
        var withBooksMenu = buyer
        withBooksMenu.menuKeys.insert("accounting")
        XCTAssertFalse(PurchaseOrderAccess.canBill(plain, withBooksMenu), "Bookkeeping is in the menu")
        let bookkeeper = PermissionSet(isAdmin: false, isOwner: false,
                                       grants: ["purchase_orders": ["update"], "accounting": ["create"]], menuKeys: ["accounting"])
        XCTAssertTrue(PurchaseOrderAccess.canBill(posted, bookkeeper))
        XCTAssertFalse(PurchaseOrderAccess.canVoidBill(posted, bookkeeper), "voiding needs accounting.delete")
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: ["purchase_orders": ["read"]], menuKeys: ["accounting"])
        XCTAssertFalse(PurchaseOrderAccess.canBill(plain, owner), "owning the workspace isn't a pass")
    }

    func testASupplierInvoiceWithItsFileGoesUpAsTheMatchingDocument() throws {
        let fields = PurchaseOrdersAPI.supplierInvoiceUploadFields(["kind": .string("invoice"), "number": .string("INV-9"),
                                                                    "total": .string("60.00")])
        let map = Dictionary(fields, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(map["doc_type"], "vat_invoice", "KIND_DOC_TYPE: invoice → vat_invoice")
        XCTAssertEqual(map["visible_to_supplier"], "true")
        let invoice = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((map["invoice"] ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(invoice["number"] as? String, "INV-9")
        XCTAssertNil(invoice["kind"], "the kind travels as the document type")
        XCTAssertEqual(Dictionary(PurchaseOrdersAPI.supplierInvoiceUploadFields(["kind": .string("credit_note")]),
                                  uniquingKeysWith: { a, _ in a })["doc_type"], "credit_note")
    }

    // MARK: VAT (routes/vat.lua)

    func testVATWritesAreGatedLikeTheServer() {
        let none = permissions([:])
        let vat = permissions(["vat": ["read", "update"]])
        let agent = permissions(["vat_agent": ["read", "create"]])
        XCTAssertTrue(VATContext.own.allows(.update, none), "your own VAT needs no permission")
        XCTAssertFalse(VATContext.workspace.allows(.read, none))
        XCTAssertTrue(VATContext.workspace.allows(.update, vat))
        XCTAssertFalse(VATContext.workspace.allows(.delete, vat))
        XCTAssertFalse(VATContext.workspace.allows(.update, permissions(["vat": ["read"]], owner: true)),
                       "an owner with a read-only role can't change it")
        XCTAssertTrue(VATContext.client("l-1").allows(.create, agent))
        XCTAssertFalse(VATContext.client("l-1").allows(.update, agent), "a client's VAT needs vat_agent.update")
        XCTAssertFalse(VATContext.client("l-1").allows(.update, vat))
        XCTAssertEqual(VATContext(parameter: "namespace"), .workspace)
        XCTAssertNotNil(ModuleCatalog.screen("tax.vat:namespace"), "the business's VAT opens natively")
        XCTAssertTrue(TaxHomeView.pages.contains { $0.screen == "tax.vat:namespace" }, "and is on the Tax home")
    }

    func testAFiledVATReturnSaysItsReceiptInWords() {
        let draft = Record(["period_start": .string("2026-07-01"), "period_end": .string("2026-09-30"),
                            "hmrc_receipt": .object(["processingDate": .string("2026-10-20T09:30:00.000Z"),
                                                     "formBundleNumber": .string("256660290587"),
                                                     "chargeRefNumber": .string("XM002610011594")])])
        let text = VATView.receiptText(draft)
        XCTAssertTrue(text.contains("For \(Formatters.day(CalendarDay(year: 2026, month: 7, day: 1).date()) ?? "")"), text)
        XCTAssertTrue(text.contains("HMRC receipt number 256660290587"))
        XCTAssertTrue(text.contains("Payment reference XM002610011594"))
        XCTAssertFalse(text.contains("2026-10-20T"), "no raw timestamps")
    }

    // MARK: Tax

    func testMonthByMonthShowsTheChosenTaxYear() {
        let rows = ["2025-03", "2025-04", "2025-12", "2026-03", "2026-04"].map { Record(["month": .string($0)]) }
        XCTAssertEqual(TaxReportsView.months(rows, taxYear: "2025-26").compactMap { $0.string("month") },
                       ["2025-04", "2025-12", "2026-03"])
    }

    func testStatementsOverTenMegabytesAreStoppedBeforeSending() {
        let big = StatementFile(name: "big.pdf", data: Data(count: 10_000_001), mimeType: "application/pdf")
        XCTAssertEqual(big.problem, "That file is too big to send. The limit is 10 MB.")
        XCTAssertNil(StatementFile(name: "ok.pdf", data: Data(count: 9_000_000), mimeType: "application/pdf").problem)
    }

    // MARK: Payroll (routes/payroll.lua: schedules are payroll.create)

    func testSettingPayDaysNeedsCreateAndUpdate() {
        XCTAssertFalse(PayrollRights(update: true).setPayDays)
        XCTAssertFalse(PayrollRights(create: true).setPayDays)
        XCTAssertTrue(PayrollRights(create: true, update: true).setPayDays)
    }
}
