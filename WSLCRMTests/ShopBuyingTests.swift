import XCTest
@testable import WSLCRM

/// Buying from suppliers: supplier price lists, items and links, portal logins, price requests on a deal and the
/// comparison, stock enquiry answers and competitor market sources. Response shapes copied from
/// lapis/queries/ShopSupplierQueries.lua (`supplier_view`, `items`, `importText`, `link`), ShopDealQueries.lua
/// (`request_shape`, `get`), lib/deal-codes.lua (`compare`), routes/supplier-portal.lua and ShopMarketQueries.lua
/// (`present_source`, `present_obs`). Request bodies are checked against the validators in the same files.
@MainActor
final class ShopBuyingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(type, from: Data(json.utf8))
    }

    private func object(_ value: JSONValue) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.sorted.encode(value)) as? [String: Any])
    }

    // MARK: Suppliers

    private let supplierJSON = """
    {"success":true,"data":{"uuid":"s1","name":"Boston","feed_format":"csv","feed_url":"https://feeds.example.com/p.csv",
     "feed_options":{"delimiter":"\\t"},"auth_type":"basic","auth_username":"shop","auth_header_name":null,"has_auth_secret":true,
     "mapping":{"supplier_sku":"Code","name":"Description","cost":"Trade","mpn":"MPN"},"filter":{"keywords":["rtx","a100"]},
     "prices_include_vat":false,"currency":"GBP","default_margin_pct":12.5,"change_threshold_pct":10,"update_lead_times":true,
     "sync_hours":24,"is_active":true,"last_synced_at":"2026-11-19T08:00:00Z","last_status":"ok","last_error":null,
     "last_summary":{"records":120,"kept":80,"filtered_out":40,"invalid":2,"created":5,"updated":75,"cost_changed":6,
       "big_cost_changes":1,"deactivated":3,"auto_linked":0,"invalid_examples":["row 7: no cost"],
       "pricing":{"applied":3,"pending":2,"unchanged":70,"lead_times_updated":4,"blocked_below_cost":1,"blocked":[]}},
     "portal_enabled":false,"contact_email":null,"po_email":"po@boston.example","po_phone":"07700 900456","po_address":null,
     "account_number":"A1","po_notes":null,"contact_name":"Sam","item_counts":{"active":80,"total":83,"linked":12}}}
    """

    func testSupplierHasItsPriceListSetUp() throws {
        let s = try decode(Envelope.Standard<ShopSupplier>.self, supplierJSON).data
        XCTAssertEqual(s.feedFormat, "csv")
        XCTAssertEqual(s.feedOptions.delimiter, "\t")
        XCTAssertEqual(s.authType, "basic")
        XCTAssertTrue(s.hasAuthSecret)
        XCTAssertEqual(s.mapping["supplier_sku"], "Code")
        XCTAssertEqual(s.filterKeywords, ["rtx", "a100"])
        XCTAssertFalse(s.usesStandardFilter)
        XCTAssertEqual(s.defaultMarginPct, 12.5)
        XCTAssertEqual(s.itemCounts.linked, 12)
        XCTAssertEqual(s.feedLine, "CSV · every 24 h")
        XCTAssertEqual(s.syncState.text, "Up to date")
        let summary = try XCTUnwrap(s.lastSummary)
        XCTAssertEqual(summary.invalidExamples, ["row 7: no cost"])
        XCTAssertEqual(summary.pricing?.blockedBelowCost, 1)
        XCTAssertTrue(summary.sentence.hasPrefix("Read 120 rows and kept 80 items; 40 didn’t match your keywords."))
        XCTAssertTrue(summary.sentence.contains("Prices: 3 updated, 2 waiting for your approval, 1 below cost (not used)."))
    }

    func testFilterKeywordsStandardOrEverything() throws {
        let standard = try decode(ShopSupplier.self, #"{"uuid":"a","name":"A","filter":{}}"#)
        XCTAssertTrue(standard.usesStandardFilter, "no keyword list: the server's standard list")
        XCTAssertEqual(ShopSupplierDraft(standard).keep, .standard)
        // An emptied list comes back from lua-cjson as `{}`.
        let everything = try decode(ShopSupplier.self, #"{"uuid":"b","name":"B","filter":{"keywords":{}},"mapping":{}}"#)
        XCTAssertFalse(everything.usesStandardFilter)
        XCTAssertEqual(ShopSupplierDraft(everything).keep, .everything)
        XCTAssertEqual(everything.feedLine, "CSV · files uploaded by hand")
        XCTAssertEqual(everything.syncState.text, "Never updated")
    }

    func testSupplierDraftBodyForAnEdit() throws {
        let s = try decode(Envelope.Standard<ShopSupplier>.self, supplierJSON).data
        var draft = ShopSupplierDraft(s)
        XCTAssertEqual(draft.delimiter, "\\t", "a tab is shown as \\t")
        XCTAssertEqual(draft.keep, .keywords)
        XCTAssertEqual(draft.keywords, "rtx, a100")
        XCTAssertNil(draft.problem)
        draft.contactEmail = "  "
        let body = try object(draft.body(isNew: false))
        XCTAssertEqual(body["name"] as? String, "Boston")
        XCTAssertEqual(body["feed_options"] as? [String: String], ["delimiter": "\\t"])
        XCTAssertEqual(body["mapping"] as? [String: String], ["supplier_sku": "Code", "name": "Description", "cost": "Trade", "mpn": "MPN"],
                       "mapping keys go out exactly as the server names them")
        XCTAssertEqual((body["filter"] as? [String: Any])?["keywords"] as? [String], ["rtx", "a100"])
        XCTAssertEqual(body["auth_username"] as? String, "shop")
        XCTAssertTrue(body["auth_header_name"] is NSNull)
        XCTAssertNil(body["auth_secret"], "an empty secret keeps the saved one")
        XCTAssertTrue(body["contact_email"] is NSNull, "an emptied field is cleared")
        XCTAssertEqual(body["default_margin_pct"] as? Double, 12.5)
        XCTAssertEqual(body["sync_hours"] as? Int, 24)
        XCTAssertNil(body["currency"], "currency can't be changed")

        draft.removeSecret = true
        XCTAssertEqual(try object(draft.body(isNew: false))["auth_secret"] as? String, "", "an empty string removes it")
        draft.removeSecret = false
        draft.authSecret = "s3cret"
        XCTAssertEqual(try object(draft.body(isNew: false))["auth_secret"] as? String, "s3cret")

        draft.keep = .everything
        XCTAssertEqual(((try object(draft.body(isNew: false))["filter"]) as? [String: Any])?["keywords"] as? [String], [])
        draft.keep = .standard
        XCTAssertEqual((try object(draft.body(isNew: false))["filter"]) as? [String: String], [:], "no list: back to the standard one")
    }

    func testNewSupplierDraftRules() throws {
        var draft = ShopSupplierDraft()
        XCTAssertEqual(draft.problem, "Give the supplier a name.")
        draft.name = "Ingram"
        XCTAssertEqual(draft.problem, "Fill in the column name for “Their product code (SKU)”.")
        draft.mapping = ["supplier_sku": "SKU", "name": "Name", "cost": "Cost"]
        XCTAssertNil(draft.problem)
        draft.feedUrl = "ftp://x"
        XCTAssertNotNil(draft.problem)
        draft.feedUrl = ""
        draft.feedFormat = "xml"
        XCTAssertEqual(draft.problem, "Say which XML element holds one product (for example product).")
        draft.recordTag = "product"
        draft.defaultMarginPct = "600"
        XCTAssertNotNil(draft.problem)
        draft.defaultMarginPct = "15"
        draft.keep = .keywords
        XCTAssertNotNil(draft.problem, "keywords chosen but none typed")
        draft.keep = .standard
        XCTAssertNil(draft.problem)
        let body = try object(draft.body(isNew: true))
        XCTAssertNil(body["filter"], "a new supplier left on the standard list sends no filter")
        XCTAssertNil(body["auth_secret"])
        XCTAssertTrue(body["feed_url"] is NSNull)
        XCTAssertEqual(body["feed_options"] as? [String: String], ["record_tag": "product"])
    }

    func testUploadedFilesKeepTheirType() {
        XCTAssertEqual(ShopSupplierDetailView.contentType(for: URL(fileURLWithPath: "/tmp/list.CSV")), "text/csv")
        XCTAssertEqual(ShopSupplierDetailView.contentType(for: URL(fileURLWithPath: "/tmp/list.json")), "application/json")
        XCTAssertEqual(ShopSupplierDetailView.contentType(for: URL(fileURLWithPath: "/tmp/list.xml")), "application/xml")
        XCTAssertEqual(ShopSupplierDetailView.contentType(for: URL(fileURLWithPath: "/tmp/list.txt")), "text/plain")
    }

    // MARK: Items and links

    func testSupplierItemsAndLinking() throws {
        let json = """
        {"success":true,"data":[
          {"uuid":"i1","supplier_sku":"B-1","mpn":"900-1","name":"RTX 6000","brand":"NVIDIA","category":null,"cost_minor":412500,
           "previous_cost_minor":400000,"rrp_minor":null,"stock_qty":4,"in_stock":true,"lead_time_days":3,"url":null,"is_active":true,
           "last_seen_at":"2026-11-19T08:00:00Z","cost_changed_at":"2026-11-18T08:00:00Z","cost_change_pct":3.13,
           "product_uuid":"p1","product_sku":"WS-1","product_name":"Workstation GPU","pricing_source":"supplier",
           "product_price_minor":470000,"product_margin_pct":null},
          {"uuid":"i2","supplier_sku":"B-2","mpn":null,"name":"Cable","brand":null,"category":null,"cost_minor":500,
           "previous_cost_minor":null,"rrp_minor":null,"stock_qty":null,"in_stock":false,"lead_time_days":null,"url":null,
           "is_active":false,"cost_changed_at":null,"cost_change_pct":null,"product_uuid":null,"product_sku":null,
           "product_name":null,"pricing_source":null,"product_price_minor":null,"product_margin_pct":null}],
         "meta":{"total":2,"limit":25,"offset":0}}
        """
        let rows = try decode(Envelope.Standard<LossyArray<ShopSupplierItem>>.self, json).data.elements
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].isLinked)
        XCTAssertEqual(rows[0].costChangePct ?? 0, 3.13, accuracy: 0.001)
        XCTAssertEqual(rows[0].stockLine, "4 in stock · 3 days lead time")
        XCTAssertFalse(rows[1].isLinked)
        XCTAssertEqual(rows[1].stockLine, "Out of stock")
        XCTAssertFalse(rows[1].isActive)

        let link = try object(ShopSupplierLinkBody(productUuid: "p1", pricingSource: "supplier", marginPct: 15).json)
        XCTAssertEqual(link["product_uuid"] as? String, "p1")
        XCTAssertEqual(link["margin_pct"] as? Double, 15)
        let unlink = try object(ShopSupplierLinkBody(productUuid: nil, pricingSource: "manual", marginPct: nil).json)
        XCTAssertTrue(unlink["product_uuid"] is NSNull, "unlinking sends product_uuid null")
        XCTAssertTrue(unlink["margin_pct"] is NSNull, "null margin falls back to the category, then the supplier")

        let pending = try decode(ShopSupplierLinkResult.self, #"{"linked":true,"pricing_source":"supplier","pricing":{"applied":0,"pending":1,"unchanged":0}}"#)
        XCTAssertEqual(pending.message, "Linked. The new price is waiting for your approval in Price changes.")
        XCTAssertTrue(try decode(ShopSupplierLinkResult.self, #"{"linked":false}"#).message.hasPrefix("Unlinked"))
    }

    func testSupplierPurchaseOrdersAndPortalLogins() throws {
        let po = try decode(ShopSupplierPurchaseOrder.self, """
        {"uuid":"po1","po_number":"PO-0012","status":"sent","supplier_name":"Boston","reference":null,"issue_date":"2026-11-01",
         "expected_date":null,"currency":"GBP","total":"1250.50","created_at":"2026-11-01T09:00:00Z","sent_at":null,"received_at":null,
         "billed_at":null,"shop_order_uuid":"o1","shop_order_number":"WS-1001","end_customer_po":"CUST-9"}
        """)
        XCTAssertEqual(po.total, Decimal(string: "1250.50"))
        XCTAssertEqual(po.shopOrderNumber, "WS-1001")

        let users = try decode(ShopPortalUsers.self, """
        {"supplier":{"id":"s1","name":"Boston","portal_enabled":true},"portal":{"enabled":true,"emails_enabled":false},
         "users":[{"id":"u1","name":null,"email":"sam@boston.example","status":"invited","activated_at":null,"last_seen_at":null,"disabled_at":null},
                  {"id":"u2","name":"Ann","email":"ann@boston.example","status":"disabled","activated_at":"2026-10-01T00:00:00Z","last_seen_at":"2026-10-02T00:00:00Z","disabled_at":"2026-11-01T00:00:00Z"}]}
        """)
        XCTAssertTrue(users.portalEnabled)
        XCTAssertEqual(users.users.map(\.statusLabel), ["Invited", "Switched off"])
        let empty = try decode(ShopPortalUsers.self, #"{"users":{},"portal":{"enabled":false}}"#)
        XCTAssertTrue(empty.users.isEmpty, "`{}` is an empty list")
        let invite = try decode(ShopPortalLink.self, #"{"user":{"id":"u3","email":"x@y.z","name":null,"status":"invited"},"set_password_path":"/supplier/set-password?token=abc","expires_in_days":7,"emailed":false,"message":"Login created for x@y.z."}"#)
        XCTAssertEqual(invite.setPasswordPath, "/supplier/set-password?token=abc")
        XCTAssertEqual(invite.expiresInDays, 7)
    }

    // MARK: Deals

    private let dealJSON = """
    {"success":true,"data":{"deal_code":"WS-UEEG-XBD6","customer":{"name":"Ben Ode","email":"ben@ode.example","phone":null,"company":"Ode Labs"},
     "leads":[{"uuid":"l1","name":"Ben Ode","email":"ben@ode.example","phone":null,"company":"Ode Labs","status":"qualified","source":"shop","created_at":"2026-11-01T00:00:00Z"}],
     "quotes":[{"uuid":"q1","quote_number":"WSQ-2026-00012","revision_no":0,"kind":"quote","status":"sent","total_minor":600000,"subtotal_minor":500000,"currency":"GBP","created_at":"2026-11-01T00:00:00Z","superseded":false,"order_uuid":null,"order_number":null}],
     "orders":{},"purchase_orders":[{"uuid":"po1","po_number":"PO-1","status":"draft","supplier_name":"Boston","total":"100.00","currency":"GBP","reference":null,"created_at":"2026-11-02T00:00:00Z","sent_at":null,"drop_ship":true,"drop_ship_confirmed":false,"legacy_drop_ship":true}],
     "supplier_requests":[{"uuid":"r1","deal_code":"WS-UEEG-XBD6","supplier_uuid":"s1","supplier_name":"Boston","contact_name":"Sam","contact_email":"po@boston.example",
        "sent_at":"2026-11-03","spec":"2 × RTX 6000","lines":[{"line_uuid":"ql1","description":"RTX 6000","qty":2,"unit_price_minor":412500,"note":null},{"line_uuid":null,"description":"Delivery","qty":1,"unit_price_minor":null}],
        "supplier_quote_ref":"BQ-77","lead_time":"3 days","valid_until":"2026-11-30","notes":"Called Sam","channel":"email","kind":"price","created_at":"2026-11-03T00:00:00Z","updated_at":"2026-11-03T00:00:00Z"}],
     "notes":[{"source":"Quote WSQ-2026-00012","uuid":"q1","kind":"quote","text":"Wants it before Christmas"}],
     "lines":[{"uuid":"ql1","description":"RTX 6000","qty":2,"unit_price_minor":450000}],"lines_from":"Quote WSQ-2026-00012",
     "compare":{"rows":[{"line_uuid":"ql1","description":"RTX 6000","qty":2,"our_unit_minor":450000,
        "suppliers":[{"request_uuid":"r1","supplier_name":"Boston","cost_unit_minor":412500,"profit_unit_minor":37500,"profit_line_minor":75000,"below_cost":false}]}],"below_cost_count":0},
     "audit":[{"action":"purchase_order.created","detail":{"po_number":"PO-1"},"at":"2026-11-02T00:00:00Z","by":"Ann"},{"action":"viewed","detail":null,"at":"2026-11-03T00:00:00Z","by":null}]}}
    """

    func testDealComparisonNotesLeadsAndActivity() throws {
        let deal = try decode(Envelope.Standard<ShopDeal>.self, dealJSON).data
        XCTAssertEqual(deal.lines.first?.uuid, "ql1")
        XCTAssertEqual(deal.currency, "GBP")
        XCTAssertTrue(deal.orders.isEmpty)
        XCTAssertTrue(try XCTUnwrap(deal.purchaseOrders.first).legacyDropShip)
        XCTAssertEqual(deal.compare.suppliers.map(\.name), ["Boston"])
        XCTAssertEqual(deal.compare.rows.first?.suppliers.first?.profitLineMinor, 75_000)
        XCTAssertEqual(deal.notes.first?.text, "Wants it before Christmas")
        XCTAssertEqual(deal.leads.first?.status, "qualified")
        XCTAssertEqual(deal.audit.map(\.title), ["Purchase order drafted PO-1", "Viewed the deal"])
        let request = try XCTUnwrap(deal.supplierRequests.first)
        XCTAssertEqual(request.supplierUuid, "s1")
        XCTAssertEqual(request.spec, "2 × RTX 6000")
        XCTAssertEqual(request.lines.first?.lineUuid, "ql1")
        XCTAssertEqual(request.pricedTotalMinor, 825_000, "only priced lines count, times their quantity")
    }

    func testNewSupplierRequestStartsFromTheDealLines() throws {
        let deal = try decode(Envelope.Standard<ShopDeal>.self, dealJSON).data
        let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z"))
        var draft = ShopSupplierRequestDraft(deal: deal, today: today)
        XCTAssertEqual(draft.sentAt, CalendarDay(date: today))
        XCTAssertEqual(draft.lines.map(\.lineUuid), ["ql1"])
        XCTAssertEqual(draft.lines.first?.qty, "2")
        XCTAssertEqual(draft.problem, "Choose a supplier or type its name.")
        draft.supplierName = "Ingram"
        draft.lines[0].price = "4125"
        draft.lines.append(.init(description: "  ", qty: "1"))
        draft.lines.append(.init(description: "Carriage", qty: "1", price: "15.5"))
        XCTAssertNil(draft.problem)
        let body = try object(draft.body(isNew: true))
        XCTAssertEqual(body["supplier_name"] as? String, "Ingram")
        XCTAssertNil(body["supplier_uuid"])
        let lines = try XCTUnwrap(body["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 2, "lines without a description are left out")
        XCTAssertEqual(lines[0]["line_uuid"] as? String, "ql1")
        XCTAssertEqual(lines[0]["unit_price_minor"] as? Int, 412_500)
        XCTAssertEqual(lines[0]["qty"] as? Int, 2)
        XCTAssertTrue(lines[1]["line_uuid"] is NSNull)
        XCTAssertEqual(lines[1]["unit_price_minor"] as? Int, 1_550)
        XCTAssertTrue(body["valid_until"] is NSNull)
        XCTAssertEqual(body["sent_at"] as? String, CalendarDay(date: today).isoString)
        draft.lines[1].price = "abc"
        XCTAssertNotNil(draft.problem)
    }

    func testEditingARequestKeepsItsSupplierAndPrices() throws {
        let deal = try decode(Envelope.Standard<ShopDeal>.self, dealJSON).data
        let draft = ShopSupplierRequestDraft(try XCTUnwrap(deal.supplierRequests.first))
        XCTAssertEqual(draft.supplierUuid, "s1")
        XCTAssertEqual(draft.lines.first?.price, "4125.00")
        XCTAssertEqual(draft.validUntil?.isoString, "2026-11-30")
        let body = try object(draft.body(isNew: false))
        XCTAssertEqual(body["supplier_uuid"] as? String, "s1")
        XCTAssertNil(body["supplier_name"])
        XCTAssertEqual(body["spec"] as? String, "2 × RTX 6000")
        XCTAssertTrue(((body["lines"] as? [[String: Any]])?[1]["unit_price_minor"]) is NSNull, "an unpriced line stays unpriced")
    }

    func testEmailDraftOpensInTheMailApp() throws {
        let withLink = try decode(ShopSupplierEmailDraft.self, #"{"to":"po@boston.example","subject":"Price request: WS-1","body":"Hello Sam","mailto":"mailto:po@boston.example?subject=Price%20request","sent":false}"#)
        XCTAssertEqual(withLink.mailURL?.absoluteString, "mailto:po@boston.example?subject=Price%20request")
        let built = try decode(ShopSupplierEmailDraft.self, #"{"to":null,"subject":"Price request: WS-1","body":"Hi there"}"#)
        XCTAssertEqual(built.mailURL?.scheme, "mailto")
        XCTAssertTrue(built.mailURL?.absoluteString.contains("subject=Price%20request:%20WS-1") ?? false)
    }

    // MARK: Stock enquiries

    func testRecordingAStockEnquiryAnswer() throws {
        let enquiry = try decode(ShopStockEnquiry.self, """
        {"uuid":"e1","supplier_uuid":"s1","supplier_name":"Boston","contact_name":"Sam","contact_email":null,"qty":2,"sent_at":"2026-11-10",
         "channel":"email","message":null,"stock_qty":null,"lead_time":null,"unit_price_minor":null,"valid_until":null,
         "supplier_quote_ref":"BQ-1","notes":null,"answered":false}
        """)
        XCTAssertEqual(enquiry.supplierQuoteRef, "BQ-1")
        var draft = ShopEnquiryAnswerDraft(enquiry)
        draft.stockQty = "4"
        draft.price = "412.50"
        draft.leadTime = "3-5 working days"
        XCTAssertNil(draft.problem)
        let body = try object(draft.body)
        XCTAssertEqual(body["stock_qty"] as? Int, 4)
        XCTAssertEqual(body["unit_price_minor"] as? Int, 41_250)
        XCTAssertEqual(body["supplier_quote_ref"] as? String, "BQ-1")
        XCTAssertTrue(body["valid_until"] is NSNull)
        XCTAssertTrue(body["notes"] is NSNull)
        draft.stockQty = "lots"
        XCTAssertNotNil(draft.problem)
    }

    // MARK: Market sources

    func testMarketSourceAndObservationDetails() throws {
        let detail = try decode(Envelope.Standard<ShopMarketDetail>.self, """
        {"success":true,"data":{"product":{"uuid":"p1","sku":"WS-1","name":"Mac Studio","base_price_minor":399900,"price_verified":true},
         "sources":[{"uuid":"m1","product_uuid":"p1","product_sku":"WS-1","product_name":"Mac Studio","name":"Apple UK","url":"https://apple.example/mac",
           "fetch_mode":"firecrawl","prices_include_vat":true,"currency":"GBP","match":{"mpn":"MX1","title_must_include":["Mac Studio","M5"]},
           "is_active":true,"last_checked_at":"2026-11-19T00:00:00Z","last_status":"anomaly","last_error":null,"pending_anomalies":1,
           "latest_observation":{"uuid":"o1","source_uuid":"m1","source_name":"Apple UK","price_ex_vat_minor":299900,"price_inc_vat_minor":359880,
             "currency":"GBP","availability":"in_stock","stock_qty":null,"title":"Mac Studio M5","method":"json_ld","confidence":0.92,
             "evidence":"£3,598.80","flags":{"anomaly":true,"change_pct":-25.0,"previous_price_minor":399900},"accepted":false,
             "fetched_at":"2026-11-19T00:00:00Z","fresh":true}}],
         "summary":null,"observations":{}}}
        """).data
        XCTAssertTrue(detail.product.priceVerified)
        let source = try XCTUnwrap(detail.sources.first)
        XCTAssertEqual(source.fetchMode, "firecrawl")
        XCTAssertEqual(source.pendingAnomalies, 1)
        XCTAssertTrue(source.latestIsFresh)
        XCTAssertEqual(source.match.titleMustInclude, ["Mac Studio", "M5"])
        XCTAssertEqual(source.match.summary, "MPN MX1 · title has Mac Studio, M5")
        let observation = try XCTUnwrap(source.latestObservation)
        XCTAssertTrue(observation.isAnomaly)
        XCTAssertEqual(observation.previousPriceMinor, 399_900)
        XCTAssertEqual(observation.evidence, "£3,598.80")
        XCTAssertEqual(observation.sourceUuid, "m1")

        var draft = ShopMarketSourceDraft(source)
        XCTAssertEqual(draft.titleMustInclude, "Mac Studio, M5")
        XCTAssertNil(draft.problem)
        draft.currency = "eur"
        draft.mpn = ""
        let body = try object(draft.body(productUuid: "p1"))
        XCTAssertEqual(body["product_uuid"] as? String, "p1")
        XCTAssertEqual(body["currency"] as? String, "EUR")
        XCTAssertEqual(body["fetch_mode"] as? String, "firecrawl")
        XCTAssertEqual(body["match"] as? [String: [String]], ["title_must_include": ["Mac Studio", "M5"]], "empty match keys are left out")
        draft.url = "apple.example/mac"
        XCTAssertNotNil(draft.problem)
        XCTAssertEqual(ShopMarketSourceDraft().problem, "Name the retailer, e.g. Apple UK.")
    }
}
