import XCTest
@testable import WSLCRM

/// The native module kit: parsing every OpsAPI response shape, turning forms into request bodies,
/// formatting fields, and the routing table that keeps every module native.
final class ModuleKitTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    // MARK: Lists, whatever the envelope

    func testStandardEnvelopeWithLimitOffsetMeta() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"uuid":"a","email":"a@example.com"},{"uuid":"b"}],"meta":{"total":30,"limit":25,"offset":0}}
        """), listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 25)
        XCTAssertEqual(page.items.map(\.id), ["a", "b"])
        XCTAssertEqual(page.total, 30)
        XCTAssertTrue(page.hasMore)
    }

    func testBareArrayAndNestedDataAndResults() throws {
        let bare = ResourceService.parsePage(try json(#"[{"id":7},{"id":8}]"#), listKey: nil, idKeys: ["uuid", "id"],
                                             requestedPage: 1, perPage: 0)
        XCTAssertEqual(bare.items.map(\.id), ["7", "8"])
        XCTAssertFalse(bare.hasMore, "one request returns everything")

        let nested = ResourceService.parsePage(try json("""
        {"success":true,"data":{"data":[{"uuid":"x"}],"meta":{"total":1,"page":1,"per_page":25}}}
        """), listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 25)
        XCTAssertEqual(nested.items.map(\.id), ["x"])
        XCTAssertEqual(nested.total, 1)

        let results = ResourceService.parsePage(try json(#"{"results":[{"deal_code":"WS1"}]}"#), listKey: nil,
                                                idKeys: ["deal_code"], requestedPage: 1, perPage: 0)
        XCTAssertEqual(results.items.first?.id, "WS1")
    }

    func testAnUnusualKeyAndAnEmptyCjsonObject() throws {
        let keyed = ResourceService.parsePage(try json(#"{"suppliers":[{"uuid":"s1"}],"count":1}"#), listKey: nil,
                                              idKeys: ["uuid"], requestedPage: 1, perPage: 0)
        XCTAssertEqual(keyed.items.map(\.id), ["s1"], "a single list under any key is found")

        let explicit = ResourceService.parsePage(try json(#"{"data":{"products":[{"uuid":"p"}],"options":[]}}"#),
                                                 listKey: "data.products", idKeys: ["uuid"], requestedPage: 1, perPage: 0)
        XCTAssertEqual(explicit.items.map(\.id), ["p"])

        let empty = ResourceService.parsePage(try json(#"{"success":true,"data":{}}"#), listKey: nil, idKeys: ["uuid"],
                                              requestedPage: 1, perPage: 25)
        XCTAssertTrue(empty.items.isEmpty, "lua-cjson sends an empty list as {}")
    }

    func testUnknownTotalStillPages() throws {
        let rows = (1...25).map { #"{"uuid":"\#($0)"}"# }.joined(separator: ",")
        let full = ResourceService.parsePage(try json(#"{"data":[\#(rows)]}"#), listKey: nil, idKeys: ["uuid"],
                                             requestedPage: 1, perPage: 25)
        XCTAssertTrue(full.hasMore, "a full page without a total may have more")
        let short = ResourceService.parsePage(try json(#"{"data":[{"uuid":"z"}]}"#), listKey: nil, idKeys: ["uuid"],
                                              requestedPage: 2, perPage: 25)
        XCTAssertFalse(short.hasMore)
    }

    // MARK: Single records

    func testRecordShapes() throws {
        XCTAssertEqual(ResourceService.parseRecord(try json(#"{"success":true,"data":{"uuid":"a"}}"#), itemKey: nil,
                                                   idKeys: ["uuid"])?.id, "a")
        XCTAssertEqual(ResourceService.parseRecord(try json(#"{"uuid":"b","name":"B"}"#), itemKey: nil,
                                                   idKeys: ["uuid"])?.id, "b")
        XCTAssertEqual(ResourceService.parseRecord(try json(#"{"success":true,"data":{"data":{"uuid":"c"}}}"#),
                                                   itemKey: nil, idKeys: ["uuid"])?.id, "c")
        XCTAssertEqual(ResourceService.parseRecord(try json(#"{"template":{"uuid":"d"}}"#), itemKey: "template",
                                                   idKeys: ["uuid"])?.id, "d")
    }

    func testDotPathsAndPathTemplates() throws {
        guard case .object(let fields) = try json("""
        {"uuid":"o 1","customer":{"name":"Ann"},"items":[{"sku":"A1"}],"total":"12.50","paid":1,"tags":{}}
        """) else { return XCTFail() }
        let record = Record(fields)
        XCTAssertEqual(record.string("customer.name"), "Ann")
        XCTAssertEqual(record.string("items.0.sku"), "A1")
        XCTAssertEqual(record.decimal("total"), Decimal(string: "12.50"))
        XCTAssertEqual(record.bool("paid"), true)
        XCTAssertEqual(record.array("tags").count, 0)
        XCTAssertEqual(record.fill("/api/v2/orders/{uuid}/invoice"), "/api/v2/orders/o%201/invoice")
        XCTAssertEqual(ResourceService.placeholders(in: "/a/{uuid}/b/{line_uuid}"), ["uuid", "line_uuid"])
    }

    // MARK: Forms

    private let pence = FieldSpec("amount_minor", "Amount", .money(currencyKey: nil, minorUnits: true, currency: "GBP"))

    func testMoneyIsSentInPenceAndShownInPounds() {
        XCTAssertEqual(FormCoding.json(pence, .text("1,249.99"), isNew: true), .number(124999))
        XCTAssertEqual(FormCoding.json(pence, .text("£5"), isNew: true), .number(500))
        let record = Record(["amount_minor": .number(124999)])
        XCTAssertEqual(FormCoding.initialValue(pence, record: record), .text("1249.99"))
        XCTAssertEqual(FieldFormatter.text(record, pence), Decimal(string: "1249.99")!.formatted(.currency(code: "GBP")))
        XCTAssertEqual(FormCoding.problem(pence, .text("abc")), "Amount must be a number.")
    }

    func testBlankMeansLeaveOutWhenNewAndClearWhenEditing() {
        let name = FieldSpec("name", "Name")
        XCTAssertNil(FormCoding.json(name, .text("  "), isNew: true))
        XCTAssertEqual(FormCoding.json(name, .text(""), isNew: false), .string(""), "OpsAPI clears a field with \"\"")
        XCTAssertEqual(FormCoding.problem(FieldSpec("name", "Name", required: true), .text(" ")), "Name is needed.")
        let secret = FieldSpec("api_key", "Key", .secret)
        XCTAssertNil(FormCoding.json(secret, .text(""), isNew: false), "a blank secret keeps the stored one")
    }

    func testOnlyChangesAreSentButANestedObjectGoesWhole() {
        let fields = [FieldSpec("checkout_enabled", "Checkout", .bool), FieldSpec("po_bill_to.city", "City"),
                      FieldSpec("po_bill_to.postcode", "Postcode")]
        let original: [String: FormValue] = ["checkout_enabled": .flag(true), "po_bill_to.city": .text("Leeds"),
                                             "po_bill_to.postcode": .text("LS1 1AA")]
        var values = original
        values["po_bill_to.city"] = .text("York")
        let body = FormCoding.body(fields: fields, values: values, original: original, isNew: false, sendOnlyChanges: true)
        XCTAssertNil(body["checkout_enabled"], "untouched")
        XCTAssertEqual(body["po_bill_to"], .object(["city": .string("York"), "postcode": .string("LS1 1AA")]))
    }

    func testServerMessagesUseTheFieldsLabel() {
        let days = FieldSpec("quote_valid_days", "Quotes valid for (days)", .integer)
        XCTAssertEqual(FormCoding.readable("quote_valid_days must be a whole number from 1 to 365", field: days),
                       "Quotes valid for (days) must be a whole number from 1 to 365")
    }

    func testAPickedRecordSendsItsID() {
        let supplier = FieldSpec("supplier_uuid", "Supplier",
                                 .reference(ReferenceSpec(list: "/x", displayKey: "supplier_name")))
        let record = Record(["supplier_uuid": .string("s-1"), "supplier_name": .string("Acme")])
        XCTAssertEqual(FormCoding.initialValue(supplier, record: record), .picked(value: "s-1", label: "Acme"))
        XCTAssertEqual(FieldFormatter.text(record, supplier), "Acme")
        XCTAssertEqual(FormCoding.json(supplier, .picked(value: "", label: ""), isNew: false), .null)
        XCTAssertEqual(FormCoding.problem(FieldSpec("s", "Supplier", .reference(ReferenceSpec(list: "/x")), required: true),
                                          .picked(value: "", label: "")), "Choose supplier.")
    }

    // MARK: Showing fields

    func testFormatting() {
        let record = Record(["due": .string("2026-09-30"), "margin": .number(0.25), "status": .string("in_progress"),
                             "tags": .array([.string("a"), .string("b")]), "lines": .array([.null, .null])])
        XCTAssertEqual(FieldFormatter.text(record, FieldSpec("margin", "M", .percent)), "25%")
        XCTAssertEqual(FieldFormatter.text(record, FieldSpec("status", "S", .status(.standard))), "In progress")
        XCTAssertEqual(FieldFormatter.text(record, FieldSpec("tags", "T", .tags)), "a, b")
        XCTAssertEqual(FieldFormatter.text(record, FieldSpec("lines", "L", .count)), "2")
        XCTAssertNotNil(FieldFormatter.text(record, FieldSpec("due", "D", .date)))
        XCTAssertNil(FieldFormatter.text(record, FieldSpec("missing", "X")))
        XCTAssertEqual(StatusStyle.standard.tone(for: "Overdue"), .danger)
    }

    func testConditions() {
        let builtin = Record(["builtin": .bool(true)])
        let own = Record(["builtin": .bool(false)])
        let writable = Condition.field("builtin", notIn: ["true"])
        XCTAssertFalse(writable.matches(builtin))
        XCTAssertTrue(writable.matches(own))
        XCTAssertTrue(Condition.field("status", in: ["available"]).matches(Record(["status": .string("AVAILABLE")])))
    }
}

/// Every module the server can put in the menu opens a native screen, or is on the visible backlog.
@MainActor
final class NativeModulesTests: XCTestCase {
    func testTheBacklogIsWhatHasNoScreenYet() {
        for key in NativeModules.notYetNative {
            XCTAssertNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.replaced.contains(key), key)
        }
        // The progress report in the test log: what is still to build natively.
        print("Not native yet (\(NativeModules.notYetNative.count)):", NativeModules.notYetNative.sorted())
    }

    func testEveryMappedKeyIsARealServerKey() {
        let known = Set(NativeModules.serverKeys)
        let mapped = Set(NativeModules.screens.keys).union(ModuleCatalog.resourceKeys.keys).union(ModuleCatalog.screenKeys.keys)
        XCTAssertEqual(mapped.subtracting(known).sorted(), [], "a typo, or a new server key to add to serverKeys")
    }

    func testEveryHandBuiltScreenResolves() {
        for (key, id) in ModuleCatalog.screenKeys {
            XCTAssertNotNil(ModuleCatalog.screen(id), "\(key) → screen \(id)")
        }
    }

    func testAKeyBelongsToOneGroup() {
        var owner: [String: String] = [:]
        for group in ModuleCatalog.groups {
            for key in Array(group.resources.keys) + Array(group.screens.keys) {
                XCTAssertNil(owner[key], "\(key) is in both \(owner[key] ?? "") and \(group.id)")
                XCTAssertNil(NativeModules.screens[key], "\(key) is already an original screen")
                owner[key] = group.id
            }
        }
    }

    func testEveryCatalogueEntryIsWellFormed() {
        var seen = Set<String>()
        for descriptor in ModuleCatalog.all {
            XCTAssertTrue(seen.insert(descriptor.id).inserted, "duplicate \(descriptor.id)")
            XCTAssertTrue(descriptor.api.list.hasPrefix("/api/"), descriptor.id)
            XCTAssertFalse(descriptor.list.title.isEmpty, descriptor.id)
            if let form = descriptor.form {
                XCTAssertTrue(descriptor.api.create != nil || descriptor.api.update != nil, "\(descriptor.id) has a form but no save")
                XCTAssertFalse(form.fields.isEmpty, descriptor.id)
            }
            for action in descriptor.actions {
                XCTAssertTrue(action.path.hasPrefix("/api/"), "\(descriptor.id).\(action.id)")
            }
            for related in descriptor.related {
                XCTAssertNotNil(ModuleCatalog.descriptor(related.descriptorID), "\(descriptor.id) → \(related.descriptorID)")
            }
            for link in descriptor.links {
                if case .resource(let id) = link.target { XCTAssertNotNil(ModuleCatalog.descriptor(id), id) }
            }
        }
        for (key, id) in ModuleCatalog.resourceKeys {
            XCTAssertNotNil(ModuleCatalog.descriptor(id), "\(key) → \(id)")
        }
    }
}

/// Workspace logos are drawn natively (the app has no web views).
final class NativeSVGTests: XCTestCase {
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let sx = CGFloat(cg.width) / image.size.width, sy = CGFloat(cg.height) / image.size.height
        context.draw(cg, in: CGRect(x: -x * sx, y: -(CGFloat(cg.height) - y * sy), width: CGFloat(cg.width),
                                    height: CGFloat(cg.height)))
        return pixel
    }

    /// The DBS logo as the dashboard serves it: a rounded square, a curved band, two lines of text.
    static let dbs = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" role="img" aria-label="DBS Ltd">
      <rect x="4" y="4" width="88" height="88" rx="22" fill="#0b2545"/>
      <path d="M4 66 Q48 52 92 66 V70 Q92 92 70 92 H26 Q4 92 4 70 Z" fill="#13a89e"/>
      <text x="48" y="54" text-anchor="middle" font-family="Helvetica" font-size="30" font-weight="800" fill="#ffffff">DBS</text>
      <text x="48" y="83" text-anchor="middle" font-size="13" font-weight="700" letter-spacing="3" fill="#ffffff">LTD</text>
    </svg>
    """

    func testTheDBSLogoIsDrawnWithItsShapesAndColours() throws {
        let image = try XCTUnwrap(NativeSVG.render(Data(Self.dbs.utf8), side: 96, scale: 1))
        let corner = try pixel(image, x: 1, y: 1)
        XCTAssertLessThan(corner[3], 30, "the rounded corner is transparent")
        let navy = try pixel(image, x: 20, y: 20)
        XCTAssertGreaterThan(navy[3], 200)
        XCTAssertLessThan(navy[0], 40, "navy square")
        let teal = try pixel(image, x: 20, y: 78)
        XCTAssertGreaterThan(teal[1], 120, "teal band (green channel)")
        XCTAssertLessThan(teal[0], 60)
    }

    func testPathsWithArcsAndRelativeCommands() throws {
        let svg = """
        <svg viewBox="0 0 10 10"><path d="m1 5a4 4 0 1 0 8 0a4 4 0 1 0-8 0z" fill="red"/></svg>
        """
        let image = try XCTUnwrap(NativeSVG.render(Data(svg.utf8), side: 10, scale: 1))
        let centre = try pixel(image, x: 5, y: 5)
        XCTAssertGreaterThan(centre[0], 200, "the circle drawn from two arcs is filled")
        XCTAssertLessThan(try pixel(image, x: 0.5, y: 0.5)[3], 30, "outside the circle stays clear")
    }

    func testColoursAndTransforms() {
        XCTAssertEqual(SVGColor.parse("#fff")?.components?.first, 1)
        XCTAssertNil(SVGColor.parse("none"))
        XCTAssertEqual(SVGColor.parse("rgb(255,0,0)")?.components?[0], 1)
        let t = SVGTransform.parse("translate(10 20) scale(2)")
        XCTAssertEqual(CGPoint(x: 1, y: 1).applying(t), CGPoint(x: 12, y: 22))
        XCTAssertEqual(SVGShape.numbers("10-5.5.5e1"), [10, -5.5, 5])
        XCTAssertNil(NativeSVG.render(Data("<html></html>".utf8)), "not an SVG")
    }
}

/// Home's "Needs you today": counts from the person's own modules, and the hub each belongs to.
final class HomeDigestTests: XCTestCase {
    func testSignalsCountRealWorkAndSkipZeroes() throws {
        let shop = try JSONDecoder.opsAPI().decode(ShopKPIs.self, from: Data("""
        {"orders_today":1,"orders_7d":3,"orders_30d":9,"paid_orders_30d":8,"revenue_paid_30d_minor":120000,
         "pending_payment":2,"awaiting_fulfilment":0,"open_quotes":5,"open_quotes_value_minor":50000,"quotes_30d":6,
         "quote_conversion_rate":0.5,"low_stock_count":0,"low_stock":[],"chats_7d":0,"active_products":10,
         "unverified_prices":0,"currency":"GBP","payments_enabled":true,"webhook_configured":true,
         "latest_orders":[],"latest_quotes":[]}
        """.utf8))
        let now = Date()
        let past = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        let due = past.formatted(.iso8601.year().month().day())
        func task(_ uuid: String, _ status: String) throws -> KanbanTask {
            try JSONDecoder.opsAPI().decode(KanbanTask.self, from: Data("""
            {"uuid":"\(uuid)","title":"\(uuid)","status":"\(status)","priority":"none","project_uuid":"p1","due_date":"\(due)"}
            """.utf8))
        }
        let overdue = try task("t1", "open")
        let done = try task("t2", "completed")
        let digest = HomeDigest.signals(shop: shop, steps: nil, tasks: [overdue, done], overdueInvoices: 3,
                                        fieldService: nil, deals: nil, pa: nil, isEngineer: false, now: now)
        XCTAssertEqual(digest.signals.map(\.id), ["shop.payment", "shop.quotes", "tasks.overdue", "invoices.overdue"],
                       "zero counts and finished tasks are left out")
        XCTAssertEqual(digest.activity[.shop], 7)
        XCTAssertEqual(digest.activity[.tasks], 1)
        XCTAssertNil(digest.activity[.propertyPA], "nothing from the PA unless it has something for them")
    }
}

/// The tab bar: Home and Apps always, the person's pins in between.
@MainActor
final class TabBarPinsTests: XCTestCase {
    private func menu(_ keys: [String]) -> AppMenu {
        AppMenu(sections: [.init(key: nil, title: nil, items: keys.map {
            AppMenu.Item(key: $0, name: $0 == "crm" ? "CRM" : "Purchase orders", icon: nil, path: "/dashboard/x")
        })], secondary: [])
    }

    func testPinsAreStoredAndRestored() {
        for pin in [TabPin.hub(.shop), .app("crm"), .app("plugin:property_deals:today")] {
            XCTAssertEqual(TabPin(storageKey: pin.storageKey), pin)
        }
        XCTAssertNil(TabPin(storageKey: "nonsense"))
    }

    func testTheBarShowsPinsTheyCanStillOpenOrTheirBusiestWork() {
        let owner = PermissionSet(isAdmin: false, isOwner: true, grants: [:], menuKeys: ["shop", "projects", "crm"])
        let policy = NavigationPolicy(permissions: owner, isEngineerRole: false, activity: [.tasks: 3])
        let catalog = AppCatalog(menu: menu(["crm", "purchase_orders"]))
        XCTAssertEqual(TabBarLayout.slots(policy: policy, catalog: catalog, pins: nil).map(\.pin), [.hub(.tasks), .hub(.shop)],
                       "automatic: their work areas, busiest first")
        let pinned = TabBarLayout.slots(policy: policy, catalog: catalog,
                                        pins: [.app("crm"), .hub(.fieldService), .app("gone"), .hub(.shop), .app("purchase_orders")])
        XCTAssertEqual(pinned.map(\.pin), [.app("crm"), .hub(.shop), .app("purchase_orders")],
                       "pins they can't open here are skipped; never more than three")
        XCTAssertEqual(pinned.first?.title, "CRM")
    }

    func testPinningFromAutomaticKeepsTheBarFull() {
        let defaults = UserDefaults(suiteName: "tabbar-\(UUID().uuidString)")!
        let preferences = HomePreferences(defaults: defaults)
        preferences.activate(user: "u1", workspace: "w1")
        preferences.togglePin(.app("crm"), current: [.hub(.tasks), .hub(.shop), .hub(.fieldService)])
        XCTAssertEqual(preferences.pins, [.hub(.tasks), .hub(.shop), .app("crm")], "the new pin replaces the last place")
        preferences.togglePin(.hub(.shop), current: preferences.pins ?? [])
        XCTAssertEqual(preferences.pins, [.hub(.tasks), .app("crm")])

        let again = HomePreferences(defaults: defaults)
        again.activate(user: "u1", workspace: "w1")
        XCTAssertEqual(again.pins, [.hub(.tasks), .app("crm")], "kept for this person and workspace")
        again.activate(user: "u1", workspace: "other")
        XCTAssertNil(again.pins, "another workspace has its own bar")
        XCTAssertEqual(TabBarLayout.shortTitle("Property deals settings and more"), "Property deals")
    }
}
