import XCTest
@testable import WSLCRM

/// The shop back office (`/api/v2/shop/admin`). Fixtures follow the shapes OPSAPI's shop queries
/// build (`ShopDashboardQueries.kpis`, `ShopQuoteQueries.shape`, `ShopCatalogQueries.adminDocument`,
/// `ShopMarketQueries.productDetail`), including lua-cjson's `{}` for an empty array.
final class ShopTests: XCTestCase {

    // MARK: Decoding

    func testDashboardKPIs() throws {
        let kpis = try Fixture.decode(Envelope.Standard<ShopKPIs>.self, from: "shop_dashboard").data
        XCTAssertEqual(kpis.orders7d, 9)
        XCTAssertEqual(kpis.revenuePaid30dMinor, 18_994_950)
        XCTAssertEqual(kpis.awaitingFulfilment, 3)
        XCTAssertEqual(kpis.quoteConversionRate, 0.4167, accuracy: 0.0001)
        XCTAssertEqual(kpis.chats7d, 14)
        XCTAssertTrue(kpis.paymentsEnabled)
        XCTAssertFalse(kpis.webhookConfigured)
        XCTAssertTrue(kpis.latestQuotes.isEmpty, "`{}` is an empty array from lua-cjson")

        let order = try XCTUnwrap(kpis.latestOrders.first)
        XCTAssertEqual(order.status, .paid)
        XCTAssertEqual(order.customerName, "Ana Ruiz")
        XCTAssertEqual(order.itemCount, 2)
        XCTAssertNotNil(order.paidAt)

        let low = try XCTUnwrap(kpis.lowStock.first)
        XCTAssertTrue(low.isOption)
        XCTAssertEqual(low.title, "Studio W7 · RTX 5090")
        XCTAssertEqual(low.available, 0)
        XCTAssertEqual(low.lowStockThreshold, 2)
        XCTAssertTrue(low.isLow)
    }

    func testQuoteDetail() throws {
        let quote = try Fixture.decode(Envelope.Standard<ShopQuote>.self, from: "shop_quote_detail").data
        XCTAssertEqual(quote.status, .sent)
        XCTAssertEqual(quote.customer.displayName, "Ben Ode")
        XCTAssertEqual(quote.customer.formattedAddress, "1 High St, Leeds, LS1 1AA, GB")
        XCTAssertEqual(quote.crmLeadId, 88)
        XCTAssertNil(quote.orderUuid)
        XCTAssertTrue(quote.linesEditable)

        XCTAssertEqual(quote.lines.count, 2)
        let configured = quote.lines[0]
        XCTAssertEqual(configured.priceOverrideMinor, 450_000)
        XCTAssertEqual(configured.listUnitPriceMinor, 489_900)
        XCTAssertEqual(configured.breakdown, ["RTX 5090", "2 × 128 GB DDR5"])
        let warranty = quote.lines[1]
        XCTAssertEqual(warranty.qty, 2, "qty may arrive as a string")
        XCTAssertFalse(warranty.valid)
        XCTAssertTrue(warranty.breakdown.isEmpty)
    }

    func testProductDocument() throws {
        let product = try Fixture.decode(Envelope.Standard<ShopProduct>.self, from: "shop_product_detail").data
        XCTAssertEqual(product.summary.sku, "WS-W7")
        XCTAssertEqual(product.summary.available, 3)
        XCTAssertTrue(product.summary.lowStock, "the document has no low_stock flag; available <= threshold, as the server rules it")
        XCTAssertEqual(product.summary.category?.name, "Workstations")
        XCTAssertEqual(product.vatRate, 0.2, accuracy: 0.0001, "NUMERIC columns can arrive as strings")
        XCTAssertEqual(product.specs.map(\.key), ["chassis", "psu_watts"])
        XCTAssertEqual(product.specs.last?.value, "1000")
        XCTAssertEqual(product.rules.first?.kind, "power")

        // Stock-tracked: its own count, or a component product's. Untracked options are left out.
        XCTAssertEqual(product.trackedOptions.map(\.option.code), ["rtx5090", "rtx5080"])
        XCTAssertEqual(product.trackedOptions[1].option.componentName, "RTX 5080 card")
    }

    func testMarketDetailWithHeldAnomaly() throws {
        let detail = try Fixture.decode(Envelope.Standard<ShopMarketDetail>.self, from: "shop_market_product").data
        XCTAssertEqual(detail.product.basePriceMinor, 249_900)
        XCTAssertEqual(detail.summary?.medianExVatMinor, 249_900)
        XCTAssertEqual(detail.sources.first?.latestObservation?.priceExVatMinor, 249_900)

        let held = try XCTUnwrap(detail.observations.first)
        XCTAssertFalse(held.accepted)
        XCTAssertTrue(held.isAnomaly)
        XCTAssertEqual(held.changePct ?? 0, -56.7, accuracy: 0.001)
        XCTAssertEqual(held.confidence ?? 0, 0.6, accuracy: 0.001)
    }

    // MARK: Writes

    /// Lines go back with their selections untouched: the app's snake_case encoder would turn a
    /// group code like `gpuCard` into `gpu_card`, and the server would price a different machine.
    func testQuoteUpdateKeepsSelectionsVerbatim() throws {
        let quote = try Fixture.decode(Envelope.Standard<ShopQuote>.self, from: "shop_quote_detail").data
        var edited = quote.lines[0]
        edited.qty = 3
        edited.priceOverrideMinor = nil
        let update = ShopQuoteUpdate(internalNotes: "x", shippingMinor: 0, lines: [ShopLineInput(edited), ShopLineInput(quote.lines[1])])

        let data = try JSONEncoder().encode(update)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["internal_notes"] as? String, "x")
        XCTAssertEqual(json["shipping_minor"] as? Int, 0)
        XCTAssertNil(json["status"], "unset fields are not sent")

        let lines = try XCTUnwrap(json["lines"] as? [[String: Any]])
        XCTAssertEqual(lines[0]["product_slug"] as? String, "studio-w7")
        XCTAssertEqual(lines[0]["qty"] as? Int, 3)
        XCTAssertEqual(lines[0]["uuid"] as? String, "ql-1")
        XCTAssertNil(lines[0]["price_override_minor"], "clearing an override omits it")
        let selections = try XCTUnwrap(lines[0]["selections"] as? [String: Any])
        XCTAssertEqual(Set(selections.keys), ["gpuCard", "cpu_cooler"])
        XCTAssertEqual((lines[1]["selections"] as? [String: Any])?.isEmpty, true)
    }

    func testProductPatchSendsOnlyWhatChanged() throws {
        let data = try JSONEncoder.opsAPI().encode(ShopProductBody(basePriceMinor: 199_900, priceVerified: true, categoryUuid: ""))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["base_price_minor", "price_verified", "category_uuid"],
                       "option_groups and rules must never be sent: the server would replace them")
    }

    func testMoneyParsing() {
        XCTAssertEqual(ShopMoney.minor(from: "1,249.99"), 124_999)
        XCTAssertEqual(ShopMoney.minor(from: "£12.5"), 1_250)
        XCTAssertEqual(ShopMoney.minor(from: "0.005"), 1)
        XCTAssertEqual(ShopMoney.minor(from: " 40 "), 4_000)
        XCTAssertNil(ShopMoney.minor(from: ""))
        XCTAssertNil(ShopMoney.minor(from: "abc"))
        XCTAssertNil(ShopMoney.minor(from: "-5"))
        XCTAssertEqual(ShopMoney.plain(124_999), "1249.99")
        XCTAssertEqual(ShopMoney.plain(500), "5.00")
    }

    func testStatusTargets() {
        XCTAssertEqual(ShopOrderStatus.pendingPayment.manualTargets, [.cancelled], "payment is Stripe's job")
        XCTAssertFalse(ShopOrderStatus.paid.manualTargets.contains(.paid))
        XCTAssertTrue(ShopOrderStatus.refunded.manualTargets.isEmpty)
        XCTAssertTrue(ShopQuoteStatus.converted.manualTargets.isEmpty)
        XCTAssertEqual(ShopOrderStatus(api: "payment_failed"), .paymentFailed)
        XCTAssertEqual(ShopOrderStatus(api: "lost_in_post"), .unknown)
    }

    // MARK: Navigation

    func testShopTabFollowsTheWorkspaceMenu() {
        func policy(menu: Set<String>, grants: [String: Set<String>] = [:], admin: Bool = false) -> NavigationPolicy {
            NavigationPolicy(permissions: PermissionSet(isAdmin: admin, isOwner: false, grants: grants, menuKeys: menu),
                             isEngineerRole: false)
        }
        XCTAssertTrue(policy(menu: ["shop"]).showsShop)
        XCTAssertEqual(policy(menu: ["shop"]).home, .shop, "a shop-only user lands on the shop")
        XCTAssertTrue(policy(menu: ["customers"], grants: ["shop": ["read"]]).showsShop)
        XCTAssertFalse(policy(menu: ["customers"], admin: true).showsShop, "admins don't get a tab for a feature that's off")
        XCTAssertFalse(policy(menu: ["customers"]).showsShop)
        XCTAssertEqual(policy(menu: ["shop", "field_service_jobs"]).home, .fieldService)
    }
}
