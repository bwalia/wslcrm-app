import XCTest
@testable import WSLCRM

/// Bookkeeping: writes respect RBAC as `lapis/routes/accounting.lua` checks it, the expense edit form picks its
/// category like Add expense, the purchase ledger searches, and money in/out takes several entries at once.
final class AccountingEasyTests: XCTestCase {
    /// `accounting.read` alone: the screens hide import, add, reconcile, approve and reject, and say why.
    func testAReadOnlyMemberCantWriteTheBooks() {
        let reader = PermissionSet(isAdmin: false, isOwner: false, grants: ["accounting": ["read"]], menuKeys: ["accounting"])
        XCTAssertTrue(reader.can(.read, moduleName: AccountingRights.module))
        XCTAssertFalse(reader.can(.create, moduleName: AccountingRights.module), "import, expenses, journals, money in/out")
        XCTAssertFalse(reader.can(.update, moduleName: AccountingRights.module), "reconcile, approve, reject")
        let bookkeeper = PermissionSet(isAdmin: false, isOwner: false, grants: ["accounting": ["manage"]], menuKeys: [])
        XCTAssertTrue(bookkeeper.can(.create, moduleName: AccountingRights.module))
        XCTAssertTrue(bookkeeper.can(.update, moduleName: AccountingRights.module))
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: [:], menuKeys: [])
        XCTAssertTrue(owner.can(.create, moduleName: AccountingRights.module), "owners pass, as on the server")
        XCTAssertTrue(AccountingRights.readOnlyNote.contains("Ask an owner or admin"))
    }

    /// The edit form's category is picked from the workspace's expense accounts and saved by name, as Add expense does.
    func testEditExpensePicksTheCategoryFromExpenseAccounts() async throws {
        let field = try XCTUnwrap(ModuleCatalog.accountingExpenses.form?.fields.first { $0.key == "category" })
        guard case .reference(let spec) = field.kind else { return XCTFail("category is picked from a list") }
        XCTAssertTrue(field.required)
        XCTAssertEqual(spec.valueKey, "name")
        XCTAssertEqual(spec, AddExpenseForm.categoryPicker)

        let store = InMemoryTokenStore(AuthTokens(accessToken: "access", refreshToken: "refresh"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/v2/accounting/accounts")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "expense")
            XCTAssertEqual(query.first { $0.name == "is_active" }?.value, "true")
            return .json(200, """
            {"success":true,"data":[{"id":12,"uuid":"a-12","code":"6100","name":"Travel","account_type":"expense"}],
            "meta":{"total":1,"page":1,"per_page":500,"total_pages":1}}
            """)
        }, tokenStore: store)
        await client.setNamespace("ns-1")
        let page = try await ResourceService(client: client).page(spec.descriptor, search: "", page: 1)
        XCTAssertEqual(page.items.map(\.id), ["Travel"], "the account's name is what's saved")
    }

    /// `GET /accounting/expenses` doesn't filter on `search` yet, so the ledger fetches the latest 500 and filters.
    func testPurchaseLedgerSearch() {
        XCTAssertEqual(PurchaseLedgerView.query(status: "", category: "", search: " ")["search"] ?? nil, nil)
        let query = PurchaseLedgerView.query(status: "pending", category: "travel", search: " taxi ")
        XCTAssertEqual(query["search"] ?? nil, "taxi")
        XCTAssertEqual(query["per_page"] ?? nil, "500")
        XCTAssertEqual(query["status"] ?? nil, "pending")
        let taxi = Record(["uuid": .string("x-1"), "description": .string("Airport TAXI"), "vendor": .string("Uber"),
                           "category": .string("travel")])
        XCTAssertTrue(PurchaseLedgerView.matches(taxi, "taxi"))
        XCTAssertTrue(PurchaseLedgerView.matches(taxi, "uber"))
        XCTAssertTrue(PurchaseLedgerView.matches(taxi, ""))
        XCTAssertFalse(PurchaseLedgerView.matches(taxi, "stationery"))
    }

    /// Several money in/out entries go in one `bank-transactions/import {transactions: [...]}`; each with a category
    /// gets its own balanced journal against the bank (1000) and VAT (2100) accounts.
    func testMoneyEntriesBuildTheImportAndJournals() throws {
        var sale = MoneyEntryLine(description: "Website build", party: "Acme", category: 40, amount: "120", reference: "INV-7")
        sale.date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        let cash = MoneyEntryLine(description: "Cash sale", amount: "10", vatRate: 0)
        XCTAssertTrue(sale.isReady && cash.isReady)
        XCTAssertFalse(MoneyEntryLine().isReady)
        XCTAssertEqual(sale.vat, 20)
        XCTAssertEqual(sale.transaction(moneyIn: true), .object([
            "transaction_date": .string("2026-11-03"), "description": .string("Website build (Acme) Ref: INV-7"),
            "amount": .number(120), "transaction_type": .string("credit"), "category": .string("40")]))
        guard case .object(let out) = cash.transaction(moneyIn: false) else { return XCTFail("an object") }
        XCTAssertEqual(out["transaction_type"], .string("debit"))
        XCTAssertNil(out["category"])
        XCTAssertNil(cash.journal(moneyIn: false, bankID: 1, vatID: 2), "no category, no journal")

        let journal = try XCTUnwrap(sale.journal(moneyIn: true, bankID: 1, vatID: 2))
        XCTAssertEqual(journal["reference"], .string("INV-7"))
        let lines = journal["lines"]?.list ?? []
        XCTAssertEqual(lines.count, 3)
        func total(_ key: String) -> Double {
            lines.reduce(0) { sum, line in if case .number(let n)? = line[key] { return sum + n }; return sum }
        }
        XCTAssertEqual(total("debit_amount"), total("credit_amount"), "balanced")
        XCTAssertEqual(lines[2]["credit_amount"], .number(20), "VAT on sales")
    }
}
