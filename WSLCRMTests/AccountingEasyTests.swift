import XCTest
@testable import WSLCRM

/// Bookkeeping: writes respect RBAC as `lapis/routes/accounting.lua` checks it.
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
}
