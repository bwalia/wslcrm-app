import XCTest
@testable import WSLCRM

/// The sales group (till, shop analytics, delivery, sales orders, the new-quote builder) and the
/// delivery screens' request shapes, against the server's routes (routes/delivery-*.lua,
/// routes/store-delivery-partners.lua).
@MainActor
final class SalesModuleTests: XCTestCase {
    // MARK: Group

    func testSalesMenuKeysOpenNativeScreens() {
        XCTAssertEqual(NativeModules.destination(forKey: "pos"), .native(NativeScreenRoute(SalesScreen.pos)))
        XCTAssertEqual(NativeModules.destination(forKey: "shop_analytics"), .native(NativeScreenRoute(SalesScreen.shopAnalytics)))
        XCTAssertEqual(NativeModules.destination(forKey: "delivery"), .native(NativeScreenRoute(SalesScreen.delivery)))
        for key in ["pos", "shop_analytics", "delivery", "orders", "shop"] {
            XCTAssertFalse(NativeModules.notYetNative.contains(key), "\(key) should be native")
        }
    }

    func testEverySalesScreenResolves() {
        for id in SalesScreen.all {
            XCTAssertNotNil(ModuleCatalog.screen(id), "No screen for \(id)")
        }
        XCTAssertTrue(ModuleCatalog.groups.contains { $0.id == "sales" })
    }

    // MARK: Delivery: reading

    func testLinkedPartnersParse() throws {
        let json = try decode("""
        {"partners":[{"link_id":3,"is_preferred":true,"is_active":true,"linked_at":"2026-11-01 10:00:00","id":12,
          "uuid":"dp-1","company_name":"Swift Couriers","contact_person_name":"Sam","contact_person_phone":"07700900000",
          "contact_person_email":"sam@example.com","service_type":"same_day","rating":"4.60","total_deliveries":120,
          "successful_deliveries":118,"current_active_orders":2,"max_daily_capacity":40,"pricing_model":"hybrid",
          "base_charge":"3.00","per_km_charge":"0.80","percentage_charge":null,"is_verified":true,"partner_is_active":true}]}
        """)
        let rows = DeliveryAPI.rows(json, "partners")
        XCTAssertEqual(rows.count, 1)
        let partner = try XCTUnwrap(rows.first)
        XCTAssertEqual(partner.id, "dp-1")
        XCTAssertEqual(partner.string("id"), "12", "the numeric id is what a delivery request sends")
        XCTAssertEqual(partner.bool("is_preferred"), true)
        XCTAssertEqual(DeliveryWords.serviceType(partner.string("service_type")), "Same day")
        XCTAssertEqual(DeliveryWords.pricingModel(partner.string("pricing_model")), "Fixed charge plus distance")
        XCTAssertEqual(DeliveryWords.money(partner, "base_charge", currency: "GBP"), Formatters.money(3, currency: "GBP"))
    }

    func testEmptyListsFromLuaCjsonParse() throws {
        // lua-cjson sends an empty array as {}.
        XCTAssertTrue(DeliveryAPI.rows(try decode(#"{"requests":{}}"#), "requests").isEmpty)
        XCTAssertTrue(DeliveryAPI.rows(try decode(#"{"delivery_partners":[]}"#), "delivery_partners").isEmpty)
    }

    func testRequestRowsReadTheirOrderAndPartner() throws {
        let json = try decode("""
        {"requests":[{"id":5,"uuid":"rq-1","order_id":44,"delivery_partner_id":12,"request_type":"partner_to_seller",
          "status":"pending","proposed_fee":"4.50","message":"Can do it today","response_message":null,
          "created_at":"2026-11-20 09:00:00","expires_at":"2026-11-21 09:00:00",
          "order":{"id":44,"uuid":"o-1","order_number":"ORD-20261120-AB12CD34","total_amount":"59.00","status":"confirmed"},
          "delivery_partner":{"id":12,"uuid":"dp-1","company_name":"Swift Couriers","vehicle_types":["bike","van"]}}]}
        """)
        let request = try XCTUnwrap(DeliveryAPI.rows(json, "requests").first)
        XCTAssertEqual(request.id, "rq-1")
        XCTAssertEqual(request.string("order.order_number"), "ORD-20261120-AB12CD34")
        XCTAssertEqual(request.string("order.uuid"), "o-1")
        XCTAssertEqual(request.array("delivery_partner.vehicle_types").compactMap(\.stringValue), ["bike", "van"])
        XCTAssertEqual(DeliveryWords.requestType(request.string("request_type")), "They offered to deliver")
        XCTAssertEqual(DeliveryWords.requestStatus.label(for: "pending"), "Waiting for an answer")
        XCTAssertEqual(DeliveryWords.requestStatus.label(for: "rejected"), "Declined")
    }

    func testAssignmentAndPricingParse() throws {
        let assignment = try XCTUnwrap(DeliveryAPI.record(try decode("""
        {"assignment":{"id":9,"uuid":"as-1","status":"picked_up","delivery_fee":"5.00","order_number":"ORD-1",
          "delivery_company":"Swift Couriers","customer_name":"Ann Lee"}}
        """), "assignment"))
        XCTAssertEqual(assignment.id, "as-1")
        XCTAssertEqual(DeliveryWords.ownerMoves(from: assignment.string("status") ?? "").map { $0.status }, ["in_transit"])

        let config = try XCTUnwrap(DeliveryAPI.record(try decode("""
        {"success":true,"config":{"base_fee":30,"per_km_rate":8,"currency":"INR",
          "distance_brackets":[{"max_km":5,"rate":8},{"max_km":10,"rate":10}]}}
        """), "config"))
        XCTAssertEqual(config.string("currency"), "INR")
        XCTAssertEqual(config.records("distance_brackets").count, 2)
    }

    func testOwnerMovesLeavePartnerStepsToThePartner() {
        XCTAssertEqual(DeliveryWords.ownerMoves(from: "pending").map { $0.status }, ["rejected"])
        XCTAssertEqual(DeliveryWords.ownerMoves(from: "in_transit").map { $0.status }, ["failed"])
        // picked_up and delivered are the partner's; the store may cancel an accepted delivery (the table allows it now).
        XCTAssertEqual(DeliveryWords.ownerMoves(from: "accepted").map { $0.status }, ["cancelled"])
        XCTAssertTrue(DeliveryWords.ownerMoves(from: "delivered").isEmpty)
    }

    // MARK: Delivery: writing (the routes read form fields)

    func testAskingAPartnerSendsTheFormTheRouteReads() {
        var ask = DeliveryAsk(orderID: "44", partnerID: "12", fee: " 4.50 ", message: "")
        XCTAssertNil(ask.problem)
        XCTAssertEqual(Endpoint.formEncode(ask.form),
                       "order_id=44&delivery_partner_id=12&request_type=seller_to_partner&proposed_fee=4.50")
        ask.message = "Fragile, please"
        XCTAssertEqual(ask.form.last?.0, "message")

        ask.fee = "4.5.0"
        XCTAssertEqual(ask.problem, "The fee must be an amount like 4.50.")
        ask.fee = ""
        XCTAssertNil(ask.problem)
        XCTAssertFalse(ask.form.contains { $0.0 == "proposed_fee" }, "no fee: the server uses 0")
        XCTAssertEqual(DeliveryAsk(orderID: "", partnerID: "12", fee: "", message: "").problem, "Choose the order to deliver.")
        XCTAssertEqual(DeliveryAsk(orderID: "44", partnerID: "", fee: "", message: "").problem,
                       "Choose the delivery partner to ask.")
    }

    func testPartnerSearchAlwaysAsksForVerifiedPartners() {
        var search = DeliveryPartnerSearch()
        XCTAssertEqual(search.items.map(\.name), ["is_verified", "limit"])
        XCTAssertEqual(search.items.first?.value, "true")
        search.city = " Leeds "
        search.serviceType = "express"
        search.minRating = "4"
        let items = Dictionary(uniqueKeysWithValues: search.items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["city"], "Leeds")
        XCTAssertEqual(items["service_type"], "express")
        XCTAssertEqual(items["min_rating"], "4")
    }

    func testLinkFormAndPaths() {
        XCTAssertEqual(Endpoint.formEncode(DeliveryAPI.linkForm(partnerUUID: "dp-1", preferred: true)),
                       "delivery_partner_uuid=dp-1&is_preferred=true")
        XCTAssertEqual(DeliveryAPI.path("my shop/1"), "my%20shop%2F1")
    }

    func testSettingAFieldKeepsTheRecordsIdentity() throws {
        let partner = try XCTUnwrap(DeliveryAPI.rows(try decode(#"{"partners":[{"uuid":"dp-1","is_active":true}]}"#), "partners").first)
        let paused = partner.setting("is_active", .bool(false))
        XCTAssertEqual(paused.id, "dp-1")
        XCTAssertEqual(paused.bool("is_active"), false)
    }

    private func decode(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }
}
