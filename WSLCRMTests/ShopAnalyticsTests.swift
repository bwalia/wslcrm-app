import XCTest
@testable import WSLCRM

/// Shop analytics (`/api/v2/shop/admin/analytics`, `/survey`, `/export`) and the shop admin screens built
/// natively: chats, knowledge, message templates, VIP members, credits, legal, settings, waitlist, below cost.
/// Fixtures follow opsapi's ShopAnalyticsQueries.report, ShopSurveyQueries.report, ShopChatQueries.adminGet,
/// ShopSearchQueries.listKnowledge and ShopMessageTemplateQueries (lua-cjson sends `{}` for an empty list).
final class ShopAnalyticsTests: XCTestCase {

    private func decode<T: Decodable & Sendable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(Envelope.Standard<T>.self, from: Data(json.utf8)).data
    }

    // MARK: Analytics report

    static let report = """
    {"success":true,"data":{
      "window":{"from":"2026-10-22","to":"2026-11-20","to_exclusive":"2026-11-21","days":30,"bucket":"day",
                "timezone":"Europe/London","includes_today":true,
                "previous":{"from":"2026-09-22","to":"2026-10-21","to_exclusive":"2026-10-22","days":30}},
      "generated_at":"2026-11-20T10:15:00Z","currency":"GBP",
      "sales":{"orders":12,"revenue_minor":1849950,"revenue_ex_vat_minor":1541625,"vat_minor":308325,"shipping_minor":12000,
               "refunds_minor":25000,"refunded_orders":1,"net_revenue_minor":1824950,"aov_minor":154163,
               "trade_discount_minor":4500,"credit_used_minor":0,"customers":10,"new_customers":7,"returning_customers":3},
      "checkout":{"sessions":20,"started":18,"paid":12,"payment_failed":2,"pending":3,"cancelled":1,"from_quote":4,"paid_rate":0.6667},
      "carts":{"created":40,"with_items":30,"reached_checkout":18,"converted":12,"abandoned":9,"abandoned_value_minor":420000,
               "open":3,"abandon_after_hours":24,"conversion_rate":0.4,"abandonment_rate":null},
      "quotes":{"created":8,"value_minor":2600000,"by_source":{"cart":3,"chat":2,"admin":3},"viewed":6,"accepted":2,
                "converted":3,"converted_value_minor":900000,"expired":1,"conversion_rate":0.375,"average_value_minor":325000},
      "chat":{"chats":50,"ai_replied":48,"no_reply":2,"contact_saved":11,"quotes":2,"added_to_cart":9,"orders":3,"completed":20,
              "member_chats":4,"user_messages":180,"revenue_minor":450000,"reply_rate":0.96,"completion_rate":0.4,
              "order_rate":0.06,"avg_user_messages":3.6},
      "trade":{"joins":2,"cancellations":0,"active_now":17},
      "series":[{"bucket":"2026-11-19","orders":1,"revenue_minor":150000,"revenue_ex_vat_minor":125000,"checkouts":2,"carts":3,"chats":4,"quotes":0},
                {"bucket":"2026-11-20","orders":2,"revenue_minor":300000,"revenue_ex_vat_minor":250000,"checkouts":3,"carts":2,"chats":1,"quotes":1}],
      "top_products":[{"product_uuid":"p1","name":"Studio W7","sku":"W7","units":4,"orders":3,"revenue_ex_vat_minor":800000,"revenue_minor":960000},
                      {"product_uuid":null,"name":null,"sku":null,"units":1,"orders":1,"revenue_ex_vat_minor":1000,"revenue_minor":1200}],
      "basket_adds":{},
      "basket_adds_complete":true,
      "chat_tools":[{"name":"search_catalog","chats":30,"uses":41},{"name":"brand_new_tool","chats":1,"uses":1}],
      "chat_countries":[{"country":"GB","chats":40},{"country":null,"chats":2}],
      "visitor_tracking":{"enabled":false,"status":"awaiting_privacy_signoff"},
      "previous":{"sales":{"orders":10,"revenue_minor":1500000,"revenue_ex_vat_minor":1250000,"vat_minor":250000,"shipping_minor":0,
                          "refunds_minor":0,"refunded_orders":0,"net_revenue_minor":1500000,"aov_minor":150000,
                          "trade_discount_minor":0,"credit_used_minor":0,"customers":9,"new_customers":5,"returning_customers":4},
                  "checkout":{"sessions":0,"started":0,"paid":0,"payment_failed":0,"pending":0,"cancelled":0,"from_quote":0,"paid_rate":null},
                  "carts":{"created":0,"with_items":0,"reached_checkout":0,"converted":0,"abandoned":0,"abandoned_value_minor":0,"open":0,
                           "abandon_after_hours":24,"conversion_rate":null,"abandonment_rate":null},
                  "quotes":{"created":0,"value_minor":0,"by_source":{"cart":0,"chat":0,"admin":0},"viewed":0,"accepted":0,"converted":0,
                            "converted_value_minor":0,"expired":0,"conversion_rate":null,"average_value_minor":null},
                  "chat":{"chats":0,"ai_replied":0,"no_reply":0,"contact_saved":0,"quotes":0,"added_to_cart":0,"orders":0,"completed":0,
                          "member_chats":0,"user_messages":0,"revenue_minor":0,"reply_rate":null,"completion_rate":null,
                          "order_rate":null,"avg_user_messages":null},
                  "trade":null},
      "changes":{"revenue_minor":0.2333,"orders":0.2,"aov_minor":0.0277,"abandoned":-0.1}
    }}
    """

    func testReportDecodesTheServerShape() throws {
        let r = try decode(ShopAnalyticsReport.self, Self.report)
        XCTAssertEqual(r.window.bucket, .day)
        XCTAssertEqual(r.window.previous.from, "2026-09-22")
        XCTAssertEqual(r.sales.revenueExVatMinor, 1_541_625)
        XCTAssertEqual(r.sales.aovMinor, 154_163)
        XCTAssertNil(r.carts.abandonmentRate, "null rate stays nil: shown as —, never 0%")
        XCTAssertEqual(r.quotes.bySource.admin, 3)
        XCTAssertEqual(r.chat.avgUserMessages, 3.6)
        XCTAssertEqual(r.trade?.activeNow, 17)
        XCTAssertEqual(r.series.count, 2)
        XCTAssertEqual(r.series[1].value(.revenue), 300_000)
        XCTAssertEqual(r.series[1].value(.quotes), 1)
        XCTAssertTrue(r.basketAdds.isEmpty, "`{}` is an empty list from lua-cjson")
        XCTAssertEqual(r.topProducts[1].id, "unknown")
        XCTAssertEqual(r.chatTools[0].label, "Searched the catalogue")
        XCTAssertEqual(r.chatTools[1].label, "brand_new_tool", "unknown tools show as sent")
        XCTAssertEqual(r.chatCountries[0].name, "United Kingdom")
        XCTAssertEqual(r.chatCountries[1].name, "Unknown")
        XCTAssertNil(r.previous?.trade)
        XCTAssertEqual(r.changes?.revenueMinor, 0.2333)
        XCTAssertNil(r.changes?.customers, "no comparison for a key the server left out")
    }

    func testReportWithoutComparison() throws {
        // compare=false: the server leaves out `previous` and `changes`.
        guard case .object(var envelope) = try JSONDecoder().decode(JSONValue.self, from: Data(Self.report.utf8)),
              case .object(var data)? = envelope["data"] else { return XCTFail("fixture shape") }
        data["previous"] = nil
        data["changes"] = nil
        envelope["data"] = .object(data)
        let json = String(decoding: try JSONEncoder().encode(JSONValue.object(envelope)), as: UTF8.self)
        let r = try decode(ShopAnalyticsReport.self, json)
        XCTAssertNil(r.previous)
        XCTAssertNil(r.changes)
        XCTAssertEqual(r.sales.orders, 12)
    }

    // MARK: Query

    func testQueryItemsMatchTheDashboard() {
        XCTAssertEqual(ShopAnalyticsQuery().items, [URLQueryItem(name: "days", value: "30")])
        let custom = ShopAnalyticsQuery(days: nil, from: "2026-01-01", to: "2026-03-31", bucket: .week, compare: false)
        XCTAssertEqual(custom.items.map(\.name), ["from", "to", "bucket", "compare"])
        XCTAssertEqual(custom.items.last?.value, "false")
        XCTAssertEqual(custom.surveyItems.map(\.name), ["from", "to"], "the survey takes the window only")
        let both = ShopAnalyticsQuery(days: 90, from: "2026-01-01", to: "2026-01-31")
        XCTAssertFalse(both.items.contains { $0.name == "days" }, "a from date wins over days")
    }

    func testCustomRangeIsCheckedLikeTheServer() throws {
        let calendar = Calendar.ukCalendar
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 9)))
        let ok = ShopAnalyticsQuery.custom(from: start, to: end)
        XCTAssertNil(ok.problem)
        XCTAssertEqual(ok.query?.from, "2026-03-01")
        XCTAssertEqual(ok.query?.to, "2026-03-31")
        XCTAssertNil(ok.query?.days)
        XCTAssertNotNil(ShopAnalyticsQuery.custom(from: end, to: start).problem, "start after end")
        let long = try XCTUnwrap(calendar.date(byAdding: .day, value: -800, to: end))
        XCTAssertNotNil(ShopAnalyticsQuery.custom(from: long, to: end).problem, "more than two years")
    }

    // MARK: Formatting

    func testFormatting() {
        XCTAssertEqual(ShopAnalyticsFormat.percent(nil), "—")
        XCTAssertEqual(ShopAnalyticsFormat.percent(0.4), "40%")
        XCTAssertEqual(ShopAnalyticsFormat.percent(0.6667), "66.7%")
        XCTAssertEqual(ShopAnalyticsFormat.change(0.2333), "+23%")
        XCTAssertEqual(ShopAnalyticsFormat.change(-0.042), "−4.2%")
        XCTAssertEqual(ShopAnalyticsFormat.change(0.001), "0.1%", "flat changes carry no sign")
        XCTAssertEqual(ShopAnalyticsFormat.change(23), "24×")
        XCTAssertNil(ShopAnalyticsFormat.change(nil))
        XCTAssertEqual(ShopAnalyticsFormat.isGood(-0.1, lowerIsBetter: true), true, "fewer abandoned carts is good news")
        XCTAssertEqual(ShopAnalyticsFormat.isGood(-0.1, lowerIsBetter: false), false)
        XCTAssertNil(ShopAnalyticsFormat.isGood(0.001, lowerIsBetter: false))
        XCTAssertEqual(ShopAnalyticsFormat.pounds(1_849_950), "£18,500")
        XCTAssertEqual(ShopAnalyticsFormat.pounds(nil), "—")
        XCTAssertEqual(ShopAnalyticsFormat.compactPounds(1_260), "£1.3k")
        XCTAssertEqual(ShopAnalyticsFormat.compactPounds(950), "£950")
        XCTAssertEqual(ShopAnalyticsFormat.compactPounds(3_000_000), "£3m")
        XCTAssertEqual(ShopAnalyticsFormat.bucketLabel("2026-10-06", kind: .week), "w/c 6 Oct")
        XCTAssertEqual(ShopAnalyticsFormat.bucketLabel("2026-10-01", kind: .month), "Oct 2026")
        XCTAssertEqual(ShopAnalyticsFormat.longDate("2026-11-20"), "20 Nov 2026")
    }

    func testExportFilenameComesFromTheServer() {
        XCTAssertEqual(ShopAnalyticsExport.filename(fromContentDisposition: #"attachment; filename="shop-daily.csv""#, report: .daily),
                       "shop-daily.csv")
        XCTAssertEqual(ShopAnalyticsExport.filename(fromContentDisposition: nil, report: .chatTools), "shop-chat_tools.csv")
        XCTAssertEqual(ShopAnalyticsExport.filename(fromContentDisposition: #"attachment; filename="../../etc/x.csv""#, report: .products),
                       "..-..-etc-x.csv", "a header never picks a folder")
        XCTAssertEqual(ShopAnalyticsExport.allCases.map(\.rawValue), ["daily", "products", "chat_tools", "survey"])
    }

    // MARK: Survey

    func testSurveyDecodes() throws {
        let r = try decode(ShopSurveyReport.self, """
        {"success":true,"data":{"survey":"what-do-i-need","window":{"from":"2026-10-22","to":"2026-11-20","days":30,
          "timezone":"Europe/London","includes_today":true},"generated_at":"2026-11-20T10:00:00Z",
          "visitors":{"view":40,"start":30,"answer":28,"back":3,"result":12,"lead":4,"ask":1,"apply":2},
          "funnel":[{"stage":"view","visitors":40},{"stage":"start","visitors":30,"rate_from_previous":0.75,"rate_from_view":0.75}],
          "dropoff":[{"step":1,"visitors":30,"previous_visitors":null,"lost_from_previous":null,"questions":[{"question":"job","visitors":30}]},
                     {"step":2,"visitors":20,"previous_visitors":30,"lost_from_previous":0.3333,"questions":{}}],
          "answers":[{"question":"budget","step":6,"answers":[{"answer":"b100","visitors":5}]},
                     {"question":"job","step":1,"answers":[{"answer":"team","visitors":20},{"answer":"odd","visitors":1}]}],
          "results_by_product":[{"product":"p96","visitors":7}],
          "apply_by_plan":{"y":1,"m":1,"total":2,"unknown":0},
          "trade_signups":{"checkouts_started":5,"joined":3,"joined_by_plan":{"y":2,"m":1}},
          "retention_months":13,"complete":true}}
        """)
        XCTAssertFalse(r.visitors.isEmpty)
        XCTAssertEqual(r.funnel[1].rateFromPrevious, 0.75)
        XCTAssertTrue(r.dropoff[1].questions.isEmpty)
        XCTAssertEqual(r.orderedAnswers.map(\.question), ["job", "budget"], "the survey's own question order")
        XCTAssertEqual(ShopSurveyLabels.answer("job", "team"), "Private AI for my team")
        XCTAssertEqual(ShopSurveyLabels.answer("job", "odd"), "odd")
        XCTAssertEqual(ShopSurveyLabels.product("p96"), "RTX PRO 6000")
        XCTAssertEqual(ShopSurveyLabels.stage("lead"), "Sent their build")
        XCTAssertEqual(r.tradeSignups?.joined, 3)
    }

    // MARK: Chats

    func testChatTranscriptDecodes() throws {
        let chat = try decode(ShopChatRecord.self, """
        {"success":true,"data":{"uuid":"c1","email":"ada@example.com","summary":null,"message_count":3,"created_at":"2026-11-19T09:00:00Z",
          "updated_at":"2026-11-19T09:05:00Z","contact_name":"Ada","contact_phone":"+44 20 7946 0000","client_ip":"81.2.69.160",
          "country":"GB","is_member":true,"requirements":{},"improve_consent":true,"consent_at":"2026-11-19T09:06:00Z",
          "crm_lead_uuid":"l1","cart_uuid":"cart1","quote_uuid":null,"quote_number":null,"order_uuid":"o1","order_number":"WS-1001",
          "messages":[{"role":"user","content":"Need a GPU box","at":"2026-11-19T09:00:00Z"},
                      {"role":"assistant","content":"Try **Studio W7**","tools":["search_catalog"]},
                      {"role":"tool","content":"","tools":["get_product"]}]}}
        """)
        XCTAssertEqual(chat.countryName, "United Kingdom")
        XCTAssertTrue(chat.isMember)
        XCTAssertNil(chat.requirements, "an empty requirements object shows nothing")
        XCTAssertEqual(chat.outcomes, ["Order"], "a cart that became an order counts once, as the order")
        XCTAssertEqual(chat.opening, "Need a GPU box")
        XCTAssertEqual(chat.messages[1].tools, ["search_catalog"])
        XCTAssertEqual(String(chat.messages[1].attributed.characters), "Try Studio W7", "assistant Markdown is rendered")
        XCTAssertEqual(chat.crmLeadUuid, "l1")
    }

    // MARK: Knowledge

    func testKnowledgeEntryAndNewDocumentChecks() throws {
        let page = try JSONDecoder.opsAPI().decode(Envelope.Standard<LossyArray<ShopKnowledgeEntry>>.self, from: Data("""
        {"success":true,"data":[{"source_type":"faq","source_ref":"warranty","title":"Warranty","url":null,"chunks":3,
          "embedded_chunks":2,"characters":2400,"preview":"Q: What warranty","updated_at":"2026-11-01T10:00:00Z"}],
         "meta":{"total":1}}
        """.utf8))
        let entry = try XCTUnwrap(page.data.elements.first)
        XCTAssertEqual(entry.unembedded, 1)
        XCTAssertTrue(entry.isTruncated)
        XCTAssertEqual(entry.id, "faq:warranty")

        var input = ShopKnowledgeDocumentInput(sourceType: "url", title: "Returns", url: nil, content: "30 days")
        XCTAssertNotNil(input.problem, "a web page needs its address")
        input.url = "https://example.com/returns"
        XCTAssertNil(input.problem)
        input.sourceType = "faq"
        input.url = nil
        XCTAssertNil(input.problem)
        input.content = "  "
        XCTAssertNotNil(input.problem)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(ShopKnowledgeDocumentInput(
            sourceType: "manual", title: "Guide", url: nil, content: "Text"))) as? [String: Any]
        XCTAssertEqual(body?["source_type"] as? String, "manual")
        XCTAssertEqual(try String(decoding: JSONEncoder.opsAPI().encode(ShopReindexBody(sources: ["products"])), as: UTF8.self),
                       #"{"sources":["products"]}"#)
    }

    // MARK: Templates

    func testTemplatesAndPlaceholders() throws {
        let kinds = try JSONDecoder.opsAPI().decode(Envelope.Standard<LossyArray<ShopTemplateKindInfo>>.self, from: Data("""
        {"success":true,"data":[{"kind":"price_request","label":"Price request",
          "placeholders":[{"name":"supplier.name","description":"Their company"},{"name":"lines","description":"The lines"}],
          "builtin":{"uuid":null,"kind":"price_request","name":"Price request (built-in)","subject":"Price for {{deal.code}}",
                     "body":"Hello {{supplier.contact}}","supplier_uuid":null,"supplier_name":null,"is_default":false,
                     "is_active":true,"builtin":true}}]}
        """.utf8)).data.elements
        let info = try XCTUnwrap(kinds.first)
        XCTAssertEqual(info.placeholders.count, 2)
        let builtin = try XCTUnwrap(info.builtin)
        XCTAssertTrue(builtin.builtin)
        XCTAssertNil(builtin.uuid)

        let copy = ShopTemplateDraft.start(from: nil, builtin: builtin, kind: .priceRequest, copy: true)
        XCTAssertNil(copy.uuid)
        XCTAssertEqual(copy.name, "Price request (copy)")
        XCTAssertEqual(copy.subject, "Price for {{deal.code}}")
        XCTAssertTrue(copy.isActive)

        let allowed: Set<String> = ["supplier.name", "lines", "deal.code"]
        XCTAssertNil(ShopTemplateText.problem(kind: "price_request", subject: "Price {{deal.code}}", body: "{{lines}}", allowed: allowed))
        XCTAssertEqual(ShopTemplateText.problem(kind: "price_request", subject: "", body: "x", allowed: allowed), "Write a subject.")
        XCTAssertTrue(ShopTemplateText.problem(kind: "price_request", subject: "Hi", body: "{{customer.name}}", allowed: allowed)?
            .contains("only allowed in a supplier introduction") == true, "suppliers must not see who the customer is")
        XCTAssertTrue(ShopTemplateText.problem(kind: "price_request", subject: "Hi", body: "{{nope}}", allowed: allowed)?
            .contains("isn’t a placeholder") == true)
        XCTAssertEqual(ShopTemplateText.problem(kind: "price_request", subject: "Hi", body: "{{lines", allowed: allowed),
                       "A placeholder is missing a {{ or }}.")

        let preview = ShopTemplateText.preview("Hello {{supplier.contact}},\nRef: {{missing}}\nThanks", values: ["supplier.contact": "Sam"])
        XCTAssertEqual(preview, "Hello Sam,\nThanks", "a line whose placeholders are all empty is left out")

        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy.input)) as? [String: Any]
        XCTAssertTrue(body?["supplier_uuid"] is NSNull, "any supplier is sent as null so an edit can clear it")
        XCTAssertEqual(body?["is_active"] as? Bool, true)
        XCTAssertEqual(body?["kind"] as? String, "price_request")
    }

    // MARK: Members

    func testMemberStatsMatchTheDashboard() throws {
        let page = ResourceService.parsePage(try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"success":true,"data":[
          {"uuid":"m1","email":"a@x.com","tier":"founding","billing_interval":"year","status":"active","net_minor":120000,
           "joined_at":"2026-11-18T10:00:00Z","lead_uuid":"l1","paid_by":"card"},
          {"uuid":"m2","email":"b@x.com","tier":"standard","billing_interval":"month","status":"past_due","net_minor":5000,
           "joined_at":"2026-01-01T10:00:00Z"},
          {"uuid":"m3","email":"c@x.com","tier":"standard","billing_interval":"month","status":"canceled","net_minor":5000}]}
        """.utf8)), listKey: nil, idKeys: ModuleCatalog.shopMembers.api.idKeys, requestedPage: 1, perPage: 0)
        let now = try XCTUnwrap(APIDate.parse("2026-11-20T10:00:00Z"))
        let stats = ShopMemberStats(page.items, now: now)
        XCTAssertEqual(stats.live, 2, "active and payment overdue are in force")
        XCTAssertEqual(stats.founding, 1)
        XCTAssertEqual(stats.newThisWeek, 1)
        XCTAssertEqual(stats.monthlyNetMinor, 15_000, "a yearly fee counts a twelfth a month")
        XCTAssertEqual(stats.overdue, 1)
        XCTAssertTrue(ShopMemberStats.isNew(page.items[0], now: now))
    }

    // MARK: Descriptors

    func testCreditIsGivenWithManagePermissionAndPence() throws {
        let credits = ModuleCatalog.shopCredits
        XCTAssertNil(credits.api.create, "the server checks shop.manage for POST /credits, so it is not a create form")
        let grant = try XCTUnwrap(credits.listActions.first { $0.id == "grant" })
        XCTAssertEqual(grant.action, .manage)
        XCTAssertEqual(grant.path, "/api/v2/shop/admin/credits")
        let amount = try XCTUnwrap(grant.inputs.first { $0.key == "amount_minor" })
        XCTAssertEqual(FormCoding.json(amount, .text("250"), isNew: true), .number(25000))
        let days = try XCTUnwrap(grant.inputs.first { $0.key == "expires_in_days" })
        XCTAssertEqual(FormCoding.initialValue(days, record: nil), .text("365"))
    }

    func testLegalSettingsWaitlistAndBelowCost() throws {
        XCTAssertEqual(ModuleCatalog.shopLegal.list.filters.map(\.param), ["document_key", "checkpoint"])
        let party = ModuleCatalog.shopSettings.form?.fields.map(\.key) ?? []
        XCTAssertTrue(party.contains("po_bill_to.vat_number"))
        XCTAssertFalse(party.contains("po_bill_to.name"), "the server's purchase-order party has no name key")

        let waitlist = ModuleCatalog.shopWaitlist
        let rows = ResourceService.parsePage(try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"success":true,"data":[{"email":"a@x.com","is_member":true,"created_at":"2026-11-01T10:00:00Z","notified_at":null,
          "product_uuid":"p1","sku":"W7","product_name":"Studio W7"},
         {"email":"b@x.com","is_member":false,"created_at":"2026-11-02T10:00:00Z","notified_at":null,
          "product_uuid":"p1","sku":"W7","product_name":"Studio W7"}]}
        """.utf8)), listKey: waitlist.api.listKey, idKeys: waitlist.api.idKeys, requestedPage: 1, perPage: 0)
        XCTAssertEqual(rows.items.count, 2)
        XCTAssertNotEqual(rows.items[0].id, rows.items[1].id, "two people waiting for one product are two rows")
        XCTAssertNotNil(ModuleCatalog.descriptor("shop.waitlist"))

        let below = ModuleCatalog.shopBelowCost
        XCTAssertEqual(below.query["include_quotes"], "true")
        XCTAssertTrue(below.sections.contains { $0.key == "quotes" })
    }
}
