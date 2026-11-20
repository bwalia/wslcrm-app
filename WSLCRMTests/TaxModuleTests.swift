import XCTest
@testable import WSLCRM

/// The tax, VAT and bookkeeping area: every menu key opens a native screen, the descriptors read OpsAPI's real
/// response shapes, and the calls send exactly what the server reads (form fields for the tax/HMRC routes,
/// JSON for VAT/bookkeeping/filing/assistant, the HMRC fraud-prevention headers, no sign-out on HMRC's 401).
final class TaxModuleTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try ResourceService.decode(Data(text.utf8)) }

    // MARK: Every key is native

    static let keys = ["tax", "tax_bank_accounts", "tax_statements", "tax_transactions", "tax_categories",
                       "tax_income_types", "tax_my_income", "tax_reports", "tax_hmrc", "tax_file", "tax_filing_requests",
                       "tax_agent", "tax_vat", "tax_vat_clients", "accounting"]

    @MainActor
    func testEveryTaxMenuKeyOpensANativeScreen() {
        for key in Self.keys {
            guard case .native(let route)? = NativeModules.destination(forKey: key) else {
                return XCTFail("\(key) has no native screen")
            }
            XCTAssertNotNil(ModuleCatalog.screen(route.id), "\(key) → \(route.id) draws nothing")
            XCTAssertFalse(NativeModules.notYetNative.contains(key))
        }
    }

    @MainActor
    func testScreensReachedFromInsideTheAreaResolve() {
        for id in ["tax.file:2025-26", "tax.review:2025-26", "tax.agent:2025-26", "tax.my_income:2024-25",
                   "tax.income:rental|2025-26", "tax.vat:namespace", "tax.vat:client=abc", "accounting.bank",
                   "accounting.expenses", "accounting.reports", "accounting.money:in", "accounting.money:out",
                   "accounting.sales_ledger", "accounting.purchase_ledger"] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(ModuleCatalog.screen("tax.income:"), "an income type needs its key")
        for id in ["tax.categories", "accounting.accounts", "accounting.journal", "accounting.journal_lines",
                   "accounting.expenses"] {
            XCTAssertNotNil(ModuleCatalog.descriptor(id), id)
        }
    }

    func testVATContextFromTheScreenParameter() {
        XCTAssertEqual(VATContext(parameter: nil), .own)
        XCTAssertEqual(VATContext(parameter: "namespace").query["scope"] ?? nil, "namespace")
        XCTAssertEqual(VATContext(parameter: "client=link-1"), .client("link-1"))
        XCTAssertEqual(VATContext(parameter: "client=link-1").query["client"] ?? nil, "link-1")
    }

    // MARK: Descriptors read real responses

    func testTaxCategoriesParseAndSharedOnesAreReadOnly() throws {
        let page = ResourceService.parsePage(try json("""
        {"data":[{"id":3,"uuid":"c-1","key":"sales_income","name":"Sales","category_type":"income","is_deductible":false,
        "non_business":false,"is_global":true},{"id":9,"uuid":"c-2","key":"ns4_tools","name":"Tools","category_type":"expense",
        "is_deductible":true,"is_global":false}]}
        """), listKey: nil, idKeys: ModuleCatalog.taxCategories.api.idKeys, requestedPage: 1, perPage: 0)
        XCTAssertEqual(page.items.map(\.id), ["c-1", "c-2"])
        let rule = try XCTUnwrap(ModuleCatalog.taxCategories.writableWhen)
        XCTAssertFalse(rule.matches(page.items[0]), "shared categories can't be changed")
        XCTAssertTrue(rule.matches(page.items[1]))
        XCTAssertEqual(ModuleCatalog.taxCategories.api.update, "/api/v2/tax/categories/{uuid}")
    }

    func testAccountingListsReadPagingFromMeta() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"id":1,"uuid":"a-1","code":"1000","name":"Bank Account","account_type":"asset",
        "is_active":true,"is_system":true,"current_balance":1250.5}],"meta":{"total":60,"page":1,"per_page":25,"total_pages":3}}
        """), listKey: nil, idKeys: ModuleCatalog.accountingAccounts.api.idKeys, requestedPage: 1, perPage: 25)
        XCTAssertEqual(page.items.first?.id, "a-1")
        XCTAssertEqual(page.total, 60)
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(try XCTUnwrap(ModuleCatalog.accountingAccounts.writableWhen).matches(page.items[0]),
                       "built-in accounts aren't edited")
        XCTAssertEqual(FieldFormatter.text(page.items[0], ModuleCatalog.accountingAccounts.list.trailing!), "£1,250.50")
    }

    func testJournalEntryShowsItsLines() throws {
        let entry = try XCTUnwrap(ResourceService.parseRecord(try json("""
        {"success":true,"data":{"uuid":"j-1","entry_number":"7","entry_date":"2026-11-02","description":"Rent",
        "status":"posted","total_amount":500,"lines":[{"id":1,"account_id":4,"account_code":"6000","account_name":"Rent",
        "debit_amount":500,"credit_amount":0},{"id":2,"account_id":1,"account_code":"1000","account_name":"Bank Account",
        "debit_amount":0,"credit_amount":500}]}}
        """), itemKey: nil, idKeys: ["uuid"]))
        XCTAssertEqual(entry.records("lines").count, 2)
        let related = try XCTUnwrap(ModuleCatalog.accountingJournal.related.first)
        XCTAssertEqual(related.embeddedKey, "lines")
        XCTAssertNotNil(ModuleCatalog.descriptor(related.descriptorID))
        let void = try XCTUnwrap(ModuleCatalog.accountingJournal.actions.first)
        XCTAssertEqual(entry.fill(void.path), "/api/v2/accounting/journal-entries/j-1/void")
        XCTAssertTrue(void.inputs.contains { $0.key == "reason" && $0.required }, "the server requires a reason")
    }

    // MARK: Calls send what the server reads

    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> (APIClient, InMemoryTokenStore) {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "access", refreshToken: "refresh"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: store)
        await client.setNamespace("ns-1")
        return (client, store)
    }

    func testHMRCWritesAreFormFieldsWithTheDeviceSignals() async throws {
        let (client, _) = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/hmrc/nino")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), "nino=QQ123456C&consent=true")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gov-Client-Connection-Method"), "MOBILE_APP_VIA_SERVER")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gov-Client-Device-ID"), "device-1")
            return .json(200, #"{"success":true,"data":{"has_nino":true,"last4":"456C"}}"#)
        }
        let api = TaxAPI(client: client, fraudHeaders: ["X-Gov-Client-Connection-Method": "MOBILE_APP_VIA_SERVER",
                                                        "X-Gov-Client-Device-ID": "device-1"])
        let saved = try await api.form(.post, "/api/v2/hmrc/nino", [("nino", "QQ123456C"), ("consent", "true")],
                                       namespace: false).payload.record
        XCTAssertEqual(saved.string("last4"), "456C")
    }

    func testHMRCNotConnectedIsNotTheSignInEnding() async throws {
        let counter = Counter()
        let (client, store) = await client { request in
            if request.url?.path == "/auth/refresh" { counter.increment("refresh"); return .json(200, #"{"token":"new"}"#) }
            return .json(401, #"{"error":"No HMRC token found. Please connect HMRC first."}"#)
        }
        let api = TaxAPI(client: client)
        do {
            try await api.form(.post, "/api/v2/hmrc/businesses/fetch", namespace: false)
            XCTFail("expected the HMRC error")
        } catch let error as APIError {
            XCTAssertEqual(error.serverError?.message, "No HMRC token found. Please connect HMRC first.")
        }
        XCTAssertEqual(counter.value("refresh"), 0, "HMRC's 401 is not a session problem")
        XCTAssertNotNil(store.load(), "the person stays signed in")
        let hasTokens = await client.hasTokens
        XCTAssertTrue(hasTokens)
    }

    func testFilingRequestAndAssistantSendJSON() async throws {
        let (client, _) = await client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(request.jsonBody)
            if request.url?.path == "/api/v2/tax/filing/requests" {
                XCTAssertEqual(body["tax_year"] as? String, "2025-26")
                XCTAssertEqual(body["declaration_accepted"] as? Bool, true)
                XCTAssertEqual(body["figures_hash"] as? String, "abc")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Namespace-Id"), "ns-1")
            } else {
                XCTAssertEqual(request.url?.path, "/api/v2/tax/agent/sessions/s-1/message")
                XCTAssertEqual(body["text"] as? String, "Show my estimate")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Gov-Client-Timezone"), "the assistant can reach HMRC")
            }
            return .json(200, #"{"success":true,"data":{"uuid":"r-1","status":"submitted","open":true}}"#)
        }
        let api = TaxAPI(client: client, fraudHeaders: ["X-Gov-Client-Timezone": "UTC+00:00"])
        try await api.json(.post, "/api/v2/tax/filing/requests", ["tax_year": .string("2025-26"),
                                                                   "declaration_accepted": .bool(true),
                                                                   "figures_hash": .string("abc")])
        try await api.json(.post, "/api/v2/tax/agent/sessions/s-1/message", ["text": .string("Show my estimate")])
    }

    func testStatementUploadIsMultipartWithTheAccount() async throws {
        let (client, _) = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/tax/upload")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"bank_account_id\"\r\n\r\nacc-1"))
            XCTAssertTrue(body.contains("name=\"file\"; filename=\"march.csv\""))
            return .json(201, #"{"statement_id":"st-1","status":"UPLOADED"}"#)
        }
        let file = StatementFile(name: "march.csv", data: Data("Date,Amount\n".utf8), mimeType: "text/csv")
        XCTAssertNil(file.problem)
        let r = try await TaxAPI(client: client).upload("/api/v2/tax/upload", file: file.part,
                                                         fields: [("bank_account_id", "acc-1")])
        XCTAssertEqual(r["statement_id"]?.stringValue, "st-1")
    }

    func testDownloadKeepsTheServersFileName() async throws {
        let (client, _) = await client { request in
            XCTAssertEqual(request.url?.query, "tax_year=2025-26")
            return StubURLProtocol.Response(status: 200, body: Data("PK".utf8), headers: [
                "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                "Content-Disposition": "attachment; filename=\"tax-calculation-2025-26.xlsx\""])
        }
        let url = try await TaxAPI(client: client).download("/api/v2/tax/filing/export", query: ["tax_year": "2025-26"],
                                                            fallbackName: "x.xlsx")
        XCTAssertEqual(url.lastPathComponent, "tax-calculation-2025-26.xlsx")
        XCTAssertEqual(try Data(contentsOf: url), Data("PK".utf8))
    }

    func testWhichCallsCarryTheFraudSignals() {
        XCTAssertTrue(TaxAPI.isHMRCBound("/api/v2/hmrc/status"))
        XCTAssertTrue(TaxAPI.isHMRCBound("/api/v2/tax/hmrc/calculate-preview"))
        XCTAssertTrue(TaxAPI.isHMRCBound("/auth/hmrc/initiate"))
        XCTAssertTrue(TaxAPI.isHMRCBound("/api/v2/tax/agent/sessions"))
        XCTAssertTrue(TaxAPI.isHMRCBound("/api/v2/vat/returns/r-1/submit"), "VAT filing reaches HMRC")
        XCTAssertFalse(TaxAPI.isHMRCBound("/api/v2/tax/categories"))
        XCTAssertFalse(TaxAPI.isHMRCBound("/api/v2/accounting/accounts"))
    }

    // MARK: HMRC sign-in and fraud signals

    func testTheSignInSheetReadsWhereHMRCSentThePersonBack() {
        XCTAssertEqual(HMRCSignIn.outcome(of: URL(string: "wslcrm://hmrc/settings?hmrc_connected=true")!), .connected)
        XCTAssertEqual(HMRCSignIn.outcome(of: URL(string: "wslcrm://hmrc/file?statement=&hmrc_connected=true")!), .connected)
        XCTAssertEqual(HMRCSignIn.outcome(of: URL(string: "wslcrm://hmrc/vat?hmrc_error=access_denied")!),
                       .failed("access_denied"))
        XCTAssertEqual(HMRCSignIn.outcome(of: URL(string: "wslcrm://hmrc/file")!), .failed("missing_params"))
        XCTAssertEqual(HMRCSignIn.returnAddress, "wslcrm://hmrc", "a host, so the server's slash-trim keeps it intact")
        XCTAssertTrue(HMRCConnectMessage.text(for: "access_denied").contains("Give permission"))
    }

    func testFraudSignalFormats() {
        XCTAssertEqual(HMRCFraudSignals.timezone(TimeZone(secondsFromGMT: 3600)!), "UTC+01:00")
        XCTAssertEqual(HMRCFraudSignals.timezone(TimeZone(secondsFromGMT: -16200)!), "UTC-04:30")
        XCTAssertEqual(HMRCFraudSignals.screens(width: 390, height: 844, scale: 3),
                       "width=390&height=844&scaling-factor=3&colour-depth=24")
        XCTAssertEqual(HMRCFraudSignals.windowSize(width: 390, height: 844), "width=390&height=844")
        XCTAssertEqual(HMRCFraudSignals.userAgent(osVersion: "17.4", model: "iPhone15,2"),
                       "os-family=iOS&os-version=17.4&device-manufacturer=Apple&device-model=iPhone15%2C2")
        let defaults = UserDefaults(suiteName: "tax-tests-\(UUID().uuidString)")!
        let first = HMRCFraudSignals.deviceID(defaults)
        XCTAssertEqual(HMRCFraudSignals.deviceID(defaults), first, "the same device every time")
        XCTAssertNotNil(UUID(uuidString: first))
    }

    // MARK: Tax years, periods, figures

    func testTaxYears() {
        let calendar = Calendar(identifier: .gregorian)
        let april5 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 5))!
        let april6 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))!
        XCTAssertEqual(TaxYear.of(april5, calendar: calendar), "2025-26")
        XCTAssertEqual(TaxYear.of(april6, calendar: calendar), "2026-27")
        XCTAssertEqual(TaxYear.filing(april6), "2025-26")
        XCTAssertEqual(TaxYear.bounds("2025-26")?.from, "2025-04-06")
        XCTAssertEqual(TaxYear.bounds("2025-26")?.to, "2026-04-05")
        XCTAssertEqual(TaxYear.recent(count: 3, now: april6), ["2026-27", "2025-26", "2024-25"])
        XCTAssertTrue(TaxYear.isValid("2099-00"))
        XCTAssertFalse(TaxYear.isValid("2025"))
    }

    func testVATPeriodsComeFromTheStagger() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let quarters = VATPeriod.list(stagger: "quarterly_mar", now: now, calendar: calendar)
        XCTAssertEqual(quarters.count, 8)
        XCTAssertEqual(quarters[0].start, "2026-07-01")
        XCTAssertEqual(quarters[0].end, "2026-09-30")
        XCTAssertEqual(quarters[1].end, "2026-06-30")
        let april = VATPeriod.list(stagger: "quarterly_apr", now: now, calendar: calendar)
        XCTAssertEqual(april[0].start, "2026-08-01")
        XCTAssertEqual(april[0].end, "2026-10-31")
        let monthly = VATPeriod.list(stagger: "monthly", now: now, calendar: calendar)
        XCTAssertEqual(monthly[0].start, "2026-10-01")
        let annual = VATPeriod.list(stagger: "annual", now: now, calendar: calendar)
        XCTAssertEqual(annual[0].start, "2025-04-01")
        XCTAssertEqual(annual[0].end, "2026-03-31")
    }

    func testHMRCObligationsAreFlattened() throws {
        let nested = try json("""
        [{"businessId":"XBIS1","obligationDetails":[{"periodStartDate":"2025-04-06","periodEndDate":"2025-07-05",
        "dueDate":"2025-08-05","status":"open","periodKey":"#001"}]}]
        """).list
        let flat = FileMyTaxView.flattenObligations(nested)
        XCTAssertEqual(flat.first?.string("period_start"), "2025-04-06")
        XCTAssertEqual(flat.first?.string("status"), "open")
        XCTAssertEqual(FileMyTaxView.obligationKey(flat[0]), "2025-04-06|2025-07-05")
        let cached = FileMyTaxView.flattenObligations(try json(#"[{"period_start":"2025-04-06","period_end":"2026-04-05"}]"#).list)
        XCTAssertEqual(cached.count, 1)
    }

    func testWhatWillBeSentToHMRCIsLabelledAndSkipsZeros() throws {
        let se = Record(try json("""
        {"periodIncome":{"turnover":1200,"other":0},"periodExpenses":{"adminCosts":40.5,"travelCosts":0}}
        """).objectFields)
        let sections = HMRCFiguresBreakdown.sections(se)
        XCTAssertEqual(sections.map(\.title), ["Income", "Expenses"])
        XCTAssertEqual(sections[0].lines.map(\.label), ["Sales / turnover"])
        XCTAssertEqual(sections[1].lines.first?.label, "Office & admin costs")
        let property = Record(try json("""
        {"ukProperty":{"income":{"periodAmount":9000},"expenses":{"repairsAndMaintenance":300,"residentialFinancialCost":1200}}}
        """).objectFields)
        let p = HMRCFiguresBreakdown.sections(property)
        XCTAssertEqual(p.map(\.title).first, "Rental income")
        XCTAssertEqual(p[1].lines.map(\.label), ["Repairs & maintenance"], "mortgage interest isn't an expense")
        XCTAssertEqual(p.last?.lines.first?.amount, 1200)
    }

    func testMisfiledMoneyInFixesSendTheWebsFields() {
        XCTAssertEqual(MisfiledCreditFix.turnover.fields.map(\.1), ["sales_income", "turnover", "CONFIRMED"])
        XCTAssertEqual(MisfiledCreditFix.exclude.fields.map(\.1), ["transfer", "", "CONFIRMED"])
    }

    func testTransactionWordsAndStatementStages() throws {
        let credit = Record(try json(#"{"uuid":"t","amount":12.5,"transaction_type":"CREDIT","hmrc_box":"15","category":"sales_income"}"#).objectFields)
        XCTAssertEqual(TaxTransactionText.amount(credit), "+£12.50")
        XCTAssertEqual(TaxTransactionText.treatment(credit).text, "Business income · Box 15")
        let personal = Record(try json(#"{"amount":3,"transaction_type":"DEBIT","non_business":true}"#).objectFields)
        XCTAssertEqual(TaxTransactionText.treatment(personal).text, "Personal — not claimed")
        XCTAssertEqual(TaxTransactionText.source(Record(["classified_by": .string("ai"), "confidence_score": .number(0.92)])),
                       "AI · 92% sure")
        XCTAssertEqual(StatementStatus(Record(["processing_status": .string("ERROR")])), .failed)
        XCTAssertEqual(StatementStatus(Record(["workflow_step": .string("CLASSIFIED")])), .sorted)
        XCTAssertEqual(TaxStatementsView.stageLabel(Record(["processing_status": .string("CLASSIFYING"),
                                                            "transaction_count": .number(10),
                                                            "classified_count": .number(4)])), "Sorting (4 of 10)…")
        XCTAssertNotNil(StatementFile(name: "scan.heic", data: Data([1]), mimeType: "image/heic").problem,
                        "the server takes statements by extension only")
    }

    // MARK: My Income

    func testIncomeFieldVisibilityMatchesTheServer() throws {
        let field = IncomeField(Record(try json(#"{"key":"end_date","label":"End","type":"date","show_if":{"field":"left_in_year","equals":true}}"#).objectFields))
        XCTAssertFalse(field.isVisible([:]))
        XCTAssertTrue(field.isVisible(["left_in_year": .bool(true)]))
        let bare = IncomeField(Record(try json(#"{"key":"x","label":"X","type":"text","show_if":{"field":"flag"}}"#).objectFields))
        XCTAssertTrue(bare.isVisible(["flag": .string("true")]))
        XCTAssertFalse(bare.isVisible(["flag": .bool(false)]))
        let select = IncomeField(Record(try json(#"{"key":"y","label":"Y","type":"text","show_if":{"field":"kind","equals":"flat"}}"#).objectFields))
        XCTAssertTrue(select.isVisible(["kind": .string("flat")]))
    }

    func testIncomeWordsAndTypeKeys() {
        XCTAssertEqual(IncomeWords.plural("property"), "properties")
        XCTAssertEqual(IncomeWords.plural("property abroad"), "properties abroad")
        XCTAssertEqual(IncomeWords.plural("business"), "businesses")
        XCTAssertEqual(IncomeWords.countOf(1, "job"), "1 job")
        XCTAssertEqual(IncomeTypeCoding.slugify("Crypto staking!"), "crypto_staking")
        XCTAssertEqual(IncomeTypeCoding.slugify("2nd home"), "f_2nd_home")
        XCTAssertEqual(IncomeTypeCoding.slugify("   "), "field")
    }

    func testIncomeTypeEditorWritesTheServersSchema() throws {
        var field = EditorField(key: "share", label: "Your share", type: "percentage")
        field.role = ""
        field.defaultText = "100"
        var rents = EditorField(key: "rents", label: "Rent received")
        rents.prefillOn = true
        rents.prefillCategories = ["rental_income"]
        var choice = EditorField(key: "kind", label: "Kind", type: "select")
        choice.optionsText = "Flat|A flat\nHouse"
        let schema = IncomeTypeCoding.schema([EditorSection(fields: [field, rents, choice])]).record
        let fields = schema.records("sections").first?.records("fields") ?? []
        XCTAssertEqual(fields[0].decimal("default"), 100)
        XCTAssertNil(fields[0]["role"], "\"not counted\" sends no role")
        XCTAssertEqual(fields[1].string("prefill.direction"), "credit")
        XCTAssertEqual(fields[1].array("prefill.categories").first?.stringValue, "rental_income")
        XCTAssertEqual(fields[2].records("options").map { $0.string("value") ?? "" }, ["flat", "house"])
        XCTAssertEqual(fields[2].records("options").first?.string("label"), "A flat")
        let mapping = IncomeTypeCoding.mapping([EditorMapping(field: "rents", input: "property_rents", scaleBy: "share",
                                                              subtract: true)])
        XCTAssertEqual(mapping.list.first?.record.int("sign"), -1)
        XCTAssertEqual(mapping.list.first?.record.string("scale_by"), "share")
        // Read back.
        let back = IncomeTypeCoding.sections(from: schema)
        XCTAssertEqual(back.first?.fields.map(\.key), ["share", "rents", "kind"])
        XCTAssertTrue(back.first?.fields[1].prefillOn == true)
    }

    func testFilingRequestHistoryWords() {
        XCTAssertEqual(FileForMeView.historyLabel(Record(["type": .string("reply")])), "You replied")
        XCTAssertEqual(FileForMeView.historyLabel(Record(["type": .string("status"), "status": .string("needs_info")])),
                       "Our accountant asked a question")
        XCTAssertEqual(FilingRequestDetailView.historyLabel(Record(["type": .string("export")])), "Tax sheet downloaded")
        XCTAssertEqual(FileForMeView.rank("needs_info"), 1)
    }
}
