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
}
