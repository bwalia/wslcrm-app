import XCTest
@testable import WSLCRM

/// The workspace area's shared pieces: every menu key of the area opens a native screen, descriptors
/// made for one parent record, the permission catalogue and grants (roles and API keys), and reading
/// OpsAPI's envelopes.
@MainActor
final class WorkspaceModuleTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Menu keys

    func testEveryWorkspaceKeyOpensANativeScreen() {
        let keys = ["namespace", "activity", "api-keys", "webhooks", "sso", "vault", "plugins", "roles", "users",
                    "namespaces", "employees", "settings", "billing", "billing_licenses", "billing_subscriptions",
                    "domains", "stores", "services", "document_templates", "reports"]
        for key in keys {
            XCTAssertNotNil(NativeModules.destination(forKey: key), "\(key) has no native screen")
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
            if let id = ModuleCatalog.screenKeys[key] {
                XCTAssertNotNil(ModuleCatalog.screen(id), "\(key) → \(id) doesn't draw")
            }
        }
    }

    func testEveryPartScreenIdResolves() {
        let ids = [WorkspaceScreen.home, WorkspaceScreen.settings, WorkspaceScreen.members, WorkspaceScreen.roles,
                   WorkspaceScreen.email, WorkspaceScreen.menuConfig, WorkspaceScreen.activity, WorkspaceScreen.apiKeys,
                   WorkspaceScreen.webhooks, WorkspaceScreen.sso, WorkspaceScreen.plugins, WorkspaceScreen.account,
                   WorkspaceScreen.personalAPIKeys, WorkspaceScreen.vault, WorkspaceScreen.users,
                   WorkspaceScreen.namespaces, WorkspaceScreen.employees, WorkspaceScreen.auditLog,
                   WorkspaceScreen.billing, WorkspaceScreen.subscriptions, WorkspaceScreen.licences,
                   WorkspaceScreen.domains, WorkspaceScreen.services, WorkspaceScreen.templates]
        for id in ids {
            XCTAssertNotNil(ModuleCatalog.screen(id), "\(id) is linked to but no part draws it")
        }
    }

    // MARK: Descriptors for one parent

    func testAScopedDescriptorFillsTheParentAndKeepsTheRecordPlaceholders() throws {
        let base = ResourceDescriptor(
            id: "test.features", title: "Features", noun: "feature", systemImage: "star",
            api: ResourceAPISpec(list: "/api/v2/billing/apps/{app}/features", item: "/api/v2/billing/apps/{app}/features/{key}",
                                 create: "/api/v2/billing/apps/{app}/features", update: "/api/v2/billing/apps/{app}/features/{key}",
                                 delete: "/api/v2/billing/apps/{app}/features/{key}", paging: .none, searchParam: nil),
            list: ListSpec(title: ["name"]),
            form: FormSpec([SectionSpec(nil, [FieldSpec("plan", "Plan",
                                                        .reference(ReferenceSpec(list: "/api/v2/billing/plans?app={app}")))])]),
            actions: [ActionSpec("off", "Switch off", systemImage: "power", path: "/api/v2/billing/apps/{app}/features/{key}/off")])
        let scoped = ModuleCatalog.scoped(base, ["app": "a 1"])
        XCTAssertEqual(scoped.id, "test.features@a 1")
        XCTAssertEqual(scoped.api.list, "/api/v2/billing/apps/a%201/features")
        XCTAssertEqual(scoped.api.item, "/api/v2/billing/apps/a%201/features/{key}")
        XCTAssertEqual(scoped.actions.first?.path, "/api/v2/billing/apps/a%201/features/{key}/off")
        guard case .reference(let spec)? = scoped.form?.sections.first?.fields.first?.kind else { return XCTFail() }
        XCTAssertEqual(spec.list, "/api/v2/billing/plans?app=a%201")
        // The kit's screens find it by id, like a catalogue descriptor.
        XCTAssertEqual(ModuleCatalog.descriptor(scoped.id)?.api.list, scoped.api.list)
        XCTAssertNil(ModuleCatalog.descriptor("test.features@someone-else"))

        let record = try XCTUnwrap(WorkspaceAPI.record(try json(#"{"uuid":"f1","key":"exports"}"#)))
        XCTAssertEqual(record.fill(scoped.api.item ?? ""), "/api/v2/billing/apps/a%201/features/exports")
    }

    // MARK: Permissions

    func testThePermissionCatalogueReadsTheMetaEndpoint() throws {
        // GET /api/v2/namespace/roles/meta/permissions (no envelope; NamespaceRoleQueries.lua:668).
        let catalog = PermissionCatalog(json: try json("""
        {"modules":[{"name":"users","display_name":"Users","description":"People","category":"core"},
                    {"name":"chat","display_name":"Chat","category":"collaboration","allowed_actions":["access","read","reply"]}],
         "actions":[{"name":"access","display_name":"Access"},{"name":"create","display_name":"Create"},
                    {"name":"read","display_name":"Read"},{"name":"manage","display_name":"Manage"}]}
        """))
        XCTAssertEqual(catalog.modules.map(\.name), ["users", "chat"])
        XCTAssertEqual(catalog.actions.map(\.displayName), ["Access", "Create", "Read", "Full access"])
        let chat = try XCTUnwrap(catalog.modules.last)
        XCTAssertEqual(catalog.actions(for: chat).map(\.name), ["access", "read", "manage"],
                       "only its allowed actions, plus full access")
        XCTAssertEqual(catalog.grouped(excluding: ["users"]).map(\.0), ["Collaboration"])
        XCTAssertEqual(catalog.grouped(matching: "use").first?.1.map(\.name), ["users"])

        let empty = PermissionCatalog(json: try json(#"{"modules":{},"actions":{}}"#))
        XCTAssertTrue(empty.modules.isEmpty, "lua-cjson's {} for an empty list")
        XCTAssertEqual(empty.actions, PermissionCatalog.standardActions)
    }

    func testGrantsReadEveryShapeAndEncodeWithoutEmptyModules() throws {
        let role = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"uuid":"r","permissions":"{\\"users\\":[\\"read\\",\\"update\\"],\\"chat\\":[]}","permissions_parsed":[]}
        """)))
        XCTAssertEqual(PermissionCoding.grid(role, keys: ["permissions"]), ["users": ["read", "update"]],
                       "a role's permissions are stored as JSON text")
        let key = try XCTUnwrap(WorkspaceAPI.record(try json(#"{"uuid":"k","scopes":{"cms":["read","create"]}}"#)))
        XCTAssertEqual(PermissionCoding.grid(key), ["cms": ["read", "create"]])

        let body = PermissionCoding.json(["users": ["update", "read"], "chat": []])
        XCTAssertEqual(String(decoding: try JSONEncoder.sorted.encode(body), as: UTF8.self), #"{"users":["read","update"]}"#)
        XCTAssertEqual(PermissionCoding.summary(["update", "read"]), "Read, Update")
        XCTAssertEqual(PermissionCoding.summary(["manage", "read"]), "Full access")
    }

    // MARK: Envelopes

    func testWorkspaceResponsesReadWhateverTheEnvelope() throws {
        // GET /api/v2/namespace → {namespace, membership, stats}.
        let namespace = WorkspaceAPI.record(try json(#"{"namespace":{"uuid":"n1","name":"Acme"},"membership":{"is_owner":true}}"#),
                                            key: "namespace")
        XCTAssertEqual(namespace?.string("name"), "Acme")
        // GET /api/v2/namespace/members → {data, total, page, per_page, total_pages}.
        let page = WorkspaceAPI.page(try json("""
        {"data":[{"uuid":"m1","user":{"full_name":"Ann Lee"}}],"total":11,"page":1,"per_page":10,"total_pages":2}
        """), page: 1, perPage: 10)
        XCTAssertEqual(page.items.first?.personName("user."), "Ann Lee")
        XCTAssertTrue(page.hasMore)
        // GET /api/v2/namespace/mail-accounts → {success, data: {accounts: […]}}.
        let accounts = WorkspaceAPI.records(try json(#"{"success":true,"data":{"accounts":[{"uuid":"a"}],"routing":[]}}"#),
                                            key: "data.accounts")
        XCTAssertEqual(accounts.map(\.id), ["a"])
        XCTAssertEqual(WorkspaceAPI.object(try json(#"{"mfa_required":true,"can_change":false}"#)).bool("can_change"), false)
    }

    func testBodiesLeaveOutBlanksAndKeepJSONTypes() throws {
        let body = JSONValue.fields([
            "name": .text("  Acme  "), "description": .text("   "), "domain": .textOrEmpty(""),
            "expires_in_days": .int(7), "is_default": .bool(false),
        ])
        XCTAssertEqual(String(decoding: try JSONEncoder.sorted.encode(body), as: UTF8.self),
                       #"{"domain":"","expires_in_days":7,"is_default":false,"name":"Acme"}"#)
    }
}
