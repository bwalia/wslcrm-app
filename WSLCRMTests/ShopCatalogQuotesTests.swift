import XCTest
@testable import WSLCRM

/// The new-quote builder, quote editing and the product editor / catalogue import encode exactly what
/// OpsAPI takes (`ShopQuoteQueries.adminCreate`, `ShopCatalogQueries.saveProduct`, `/import`).
final class ShopCatalogQuotesTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeQuote(_ text: String) throws -> ShopQuote {
        try JSONDecoder.opsAPI().decode(ShopQuote.self, from: Data(text.utf8))
    }

    // MARK: Building a quote

    func testCreateBodyKeepsSelectionCodesTermsAndCustomLines() throws {
        var customer = ShopCustomerDraft()
        customer.name = " Sam Jones "
        customer.email = "sam@example.com"
        customer.company = "Acme Ltd"
        customer.postalCode = "LS1 1AA"
        var product = ShopLineDraft()
        product.productSlug = "studio-w7"
        product.productUuid = "p-1"
        product.qty = 2
        product.selections = .object(["gpuCard": .array([.object(["option": .string("rtx6000"), "qty": .number(2)])])])
        product.override = "7999.50"
        var custom = ShopLineDraft.customLine()
        custom.name = "VIP membership"
        custom.unitPrice = "50"
        custom.hasPeriod = true
        custom.periodStart = try XCTUnwrap(CalendarDay(string: "2026-12-01")?.date())
        custom.periodEnd = try XCTUnwrap(CalendarDay(string: "2026-12-31")?.date())
        var terms = ShopOrderTermsDraft(kind: .order)
        terms.applyTrade = true
        terms.discount = "25.00"
        terms.discountLabel = "Welcome"

        let body = ShopQuoteCreate(status: "draft", kind: terms.kind.rawValue, customer: customer.json,
                                   lines: [product.input, custom.input], notes: "Thanks", internalNotes: "", validUntil: nil,
                                   shippingMinor: 1250, customerPoNumber: "PO-1", terms: terms.fields())
        let out = try json(JSONEncoder().encode(body))

        XCTAssertEqual(out["source"] as? String, "admin")
        XCTAssertEqual(out["status"] as? String, "draft")
        XCTAssertEqual(out["kind"] as? String, "order")
        XCTAssertEqual(out["shipping_minor"] as? Int, 1250)
        XCTAssertEqual(out["customer_po_number"] as? String, "PO-1")
        XCTAssertEqual(out["discount_minor"] as? Int, 2500)
        XCTAssertEqual(out["discount_label"] as? String, "Welcome")
        XCTAssertEqual(out["apply_trade_discount"] as? Bool, true)
        XCTAssertTrue(out["delivery_address"] is NSNull, "an empty delivery address is sent as null")
        XCTAssertNil(out["valid_until"], "no date: the server uses the shop's quote_valid_days")

        let sentCustomer = try XCTUnwrap(out["customer"] as? [String: Any])
        XCTAssertEqual(sentCustomer["name"] as? String, "Sam Jones")
        XCTAssertEqual((sentCustomer["address"] as? [String: Any])?["postal_code"] as? String, "LS1 1AA")
        XCTAssertEqual((sentCustomer["address"] as? [String: Any])?["country"] as? String, "GB")
        XCTAssertNil(sentCustomer["phone"])

        let lines = try XCTUnwrap(out["lines"] as? [[String: Any]])
        XCTAssertEqual(lines[0]["product_slug"] as? String, "studio-w7")
        XCTAssertEqual(lines[0]["qty"] as? Int, 2)
        XCTAssertEqual(lines[0]["price_override_minor"] as? Int, 799_950)
        XCTAssertEqual(Set(((lines[0]["selections"] as? [String: Any]) ?? [:]).keys), ["gpuCard"], "group codes stay verbatim")
        XCTAssertNil(lines[0]["custom"])
        XCTAssertEqual(lines[1]["custom"] as? Bool, true)
        XCTAssertEqual(lines[1]["name"] as? String, "VIP membership")
        XCTAssertEqual(lines[1]["unit_price_minor"] as? Int, 5000)
        XCTAssertEqual(lines[1]["period_start"] as? String, "2026-12-01")
        XCTAssertEqual(lines[1]["period_end"] as? String, "2026-12-31")
        XCTAssertNil(lines[1]["product_slug"], "a custom line never names a product")
    }

    func testBuilderChecksMatchTheDashboard() {
        var customer = ShopCustomerDraft()
        customer.email = "not-an-email"
        XCTAssertEqual(customer.errors.count, 2)
        var line = ShopLineDraft.customLine()
        line.unitPrice = "abc"
        XCTAssertEqual(line.errors(index: 1).count, 2, "a custom line needs a name and a price")
        var product = ShopLineDraft()
        XCTAssertEqual(product.errors(index: 2), ["Line 2: choose a product."])
        product.productSlug = "x"
        product.override = "-5"
        XCTAssertEqual(product.errors(index: 2).count, 1)
        var terms = ShopOrderTermsDraft()
        terms.discount = "lots"
        terms.address["email"] = "nope"
        XCTAssertEqual(terms.errors.count, 2)
    }

    func testTurningTheTradeDiscountOffSaysSo() {
        var terms = ShopOrderTermsDraft()
        XCTAssertNil(terms.fields(hadTrade: false)["apply_trade_discount"], "never on: nothing to clear")
        XCTAssertEqual(terms.fields(hadTrade: true)["apply_trade_discount"], .bool(false))
        terms.applyTrade = true
        XCTAssertEqual(terms.fields(hadTrade: true)["apply_trade_discount"], .bool(true))
    }

    // MARK: Editing a quote

    private let lockedQuote = """
    {"uuid":"q-2","quote_number":"WSQ-2026-00012-R1","status":"accepted","kind":"order","customer":{"name":"Sam","email":"sam@example.com"},
     "lines":[{"uuid":"l-1","product_slug":"studio-w7","product_uuid":"p-1","product_name":"Studio W7","qty":1,
               "unit_price_minor":799900,"line_subtotal_minor":799900,"line_vat_minor":159980,"line_total_minor":959880,
               "selections":{"gpuCard":[{"option":"rtx6000","qty":2}]},"violations":[{"kind":"power","message":"Needs the 1600 W PSU"}]},
              {"uuid":"l-2","custom":true,"product_name":"VIP membership","label":"VIP membership","description":"December",
               "period_start":"2026-12-01","period_end":"2026-12-31","qty":1,"unit_price_minor":5000,"vat_rate":0.2,
               "line_subtotal_minor":5000,"line_vat_minor":1000,"line_total_minor":6000}],
     "subtotal_minor":804900,"vat_minor":160980,"shipping_minor":0,"total_minor":965880,"currency":"GBP",
     "delivery_address":{"name":"Goods In","line1":"1 High St","city":"Leeds","postcode":"LS1 1AA"},
     "customer_po_number":"PO-4471","revision_no":1,"revision_of":{"uuid":"q-1","quote_number":"WSQ-2026-00012"},
     "superseded_by":null,"revisions":[{"uuid":"q-1","quote_number":"WSQ-2026-00012","revision_no":0,"status":"cancelled","superseded":true},
       {"uuid":"q-2","quote_number":"WSQ-2026-00012-R1","revision_no":1,"status":"accepted","superseded":false}],
     "has_order":false,"can_edit":false,"can_revise":true,"order":{"uuid":"o-9","order_number":"WS-1009"}}
    """

    func testQuoteDecodesRevisionsLockAndDelivery() throws {
        let quote = try decodeQuote(lockedQuote)
        XCTAssertTrue(quote.isLocked, "confirmed by the customer: what they agreed stays")
        XCTAssertFalse(quote.linesEditable)
        XCTAssertTrue(quote.canRevise)
        XCTAssertEqual(quote.revisions.count, 2)
        XCTAssertEqual(quote.revisionOf?.quoteNumber, "WSQ-2026-00012")
        XCTAssertEqual(quote.customerPoNumber, "PO-4471")
        XCTAssertEqual(quote.orderUuid, "o-9")
        XCTAssertEqual(quote.orderNumber, "WS-1009")
        XCTAssertEqual(ShopDeliveryAddressDraft(quote.deliveryAddress).summary, "Goods In, 1 High St, Leeds, LS1 1AA")
        XCTAssertEqual(quote.lines[0].violations, ["Needs the 1600 W PSU"])
        XCTAssertTrue(quote.lines[1].custom)
        XCTAssertEqual(ShopQuoteProgressSection.nextStep(quote).title, "Awaiting payment")
    }

    /// The bug found by comparing with the dashboard: a custom line went back as a product with no slug and the server
    /// refused the whole edit. It now goes back as a custom line.
    func testSavedCustomLineGoesBackAsCustom() throws {
        let quote = try decodeQuote(lockedQuote)
        let update = ShopQuoteUpdate(lines: quote.lines.map(ShopLineInput.init))
        let out = try json(JSONEncoder().encode(update))
        let lines = try XCTUnwrap(out["lines"] as? [[String: Any]])
        XCTAssertEqual(lines[0]["product_slug"] as? String, "studio-w7")
        XCTAssertEqual(Set(((lines[0]["selections"] as? [String: Any]) ?? [:]).keys), ["gpuCard"])
        XCTAssertEqual(lines[1]["custom"] as? Bool, true)
        XCTAssertEqual(lines[1]["name"] as? String, "VIP membership")
        XCTAssertEqual(lines[1]["unit_price_minor"] as? Int, 5000)
        XCTAssertEqual(lines[1]["period_end"] as? String, "2026-12-31")
        XCTAssertEqual(lines[1]["vat_rate"] as? Double, 0.2)
        XCTAssertNil(lines[1]["product_slug"])

        let drafts = quote.lines.map(ShopLineDraft.init)
        XCTAssertTrue(drafts[1].custom && drafts[1].hasPeriod)
        XCTAssertEqual(drafts[1].input, ShopLineInput(quote.lines[1]))
    }

    func testUpdateFieldsCanClearValues() throws {
        let update = ShopQuoteUpdate(fields: ["customer_po_number": .null, "delivery_address": .null])
        let out = try json(JSONEncoder().encode(update))
        XCTAssertTrue(out["customer_po_number"] is NSNull)
        XCTAssertTrue(out["delivery_address"] is NSNull)
        XCTAssertEqual(out.count, 2)

        let revise = ShopQuoteRevise(reason: " Leeds office ", customerPoNumber: "", deliveryMethod: nil).json
        XCTAssertEqual(revise, .object(["reason": .string("Leeds office"), "customer_po_number": .null]))
    }

    func testSelectionsFillDefaultsAndSummarise() throws {
        let product = try JSONDecoder.opsAPI().decode(ShopProduct.self, from: Data("""
        {"uuid":"p-1","sku":"W7","slug":"studio-w7","name":"Studio W7","option_groups":[
          {"code":"cpu","name":"Processor","selection":"single","required":true,"sort_order":1,"options":[
            {"code":"w9","name":"Xeon w9","is_default":true,"price_delta_minor":0},{"code":"w7","name":"Xeon w7","price_delta_minor":-50000}]},
          {"code":"gpuCard","name":"Graphics","selection":"multi","sort_order":0,"max_qty":4,"options":[
            {"code":"rtx6000","name":"RTX 6000","price_delta_minor":650000,"max_qty":4}]}]}
        """.utf8))
        XCTAssertEqual(product.optionGroups.map(\.code), ["gpuCard", "cpu"], "groups in their sort order")
        var picked = ShopSelections(.object(["gpuCard": .array([.object(["option": .string("rtx6000"), "qty": .number(2)])])]))
        picked.fillDefaults(product.optionGroups)
        XCTAssertEqual(picked.picked["cpu"], ["w9": 1])
        XCTAssertEqual(picked.summary(product.optionGroups), "2 × RTX 6000, Xeon w9")
        XCTAssertEqual(picked.json["gpuCard"], .array([.object(["option": .string("rtx6000"), "qty": .number(2)])]))
    }

    func testQuotePDFAddressFollowsTheCustomerLink() {
        XCTAssertEqual(ShopQuotePDF.url(publicURL: "https://shop.example.com/quotes/q-2?t=abc")?.absoluteString,
                       "https://shop.example.com/api/quotes/q-2/pdf?t=abc")
        XCTAssertNil(ShopQuotePDF.url(publicURL: "/quotes/q-2?t=abc"), "a relative path has no site to fetch from")
        XCTAssertNil(ShopQuotePDF.url(publicURL: nil))
    }

    // MARK: Product editor

    private let productDocument = """
    {"uuid":"p-1","sku":"W7","slug":"studio-w7","name":"Studio W7","brand":"WS","product_type":"workstation",
     "price_mode":"configurable","status":"active","category":{"uuid":"c-1","slug":"workstations","name":"Workstations"},
     "base_price_minor":799900,"cost_minor":null,"vat_rate":0.2,"stock_qty":3,"low_stock_threshold":2,"lead_time_days":10,
     "allow_backorder":true,"price_verified":true,"is_featured":false,"sort_order":0,"tags":["ai","studio"],
     "specs":{"GPU":"4× RTX PRO 6000"},"attributes":{"gpu_slots":4,"psu_watts":2000},"images":["https://example.com/a.jpg"],
     "seo":{"en":{"title":"Studio W7","faqs":[{"q":"Quiet?","a":"Yes"}]}},
     "photos":[{"url":"https://example.com/p.webp","fallback_url":"https://example.com/p.jpg","width":1600,"height":1200,"alt":{"en":"Front"}}],
     "option_groups":[
       {"uuid":"g-1","code":"gpu","name":"Graphics","selection":"multi","required":false,"min_qty":0,"max_qty":4,"sort_order":0,"is_active":true,
        "options":[{"uuid":"o-1","code":"rtx6000","name":"RTX 6000","price_delta_minor":650000,"cost_minor":520000,"stock_qty":null,
                    "component_product":{"uuid":"p-9","sku":"RTX6000","name":"RTX 6000 card"},"max_qty":4,"is_default":false,"is_active":true,
                    "sort_order":0,"attributes":{"watts":600,"slots":2}}]},
       {"uuid":"g-2","code":"legacy","name":"Old group","selection":"single","is_active":false,"sort_order":1,"options":[]}],
     "rules":[{"uuid":"r-1","kind":"attr_match","params":{"group":"gpu","attr":"slots","equals":2},"message":"Two-slot cards only","is_active":true}]}
    """

    func testProductEditorSendsTheWholeDocument() throws {
        let doc = try JSONDecoder().decode([String: JSONValue].self, from: Data(productDocument.utf8))
        let draft = ShopProductDraft(doc)
        XCTAssertEqual(draft.vatRate, "20")
        XCTAssertEqual(draft.categoryUuid, "c-1")
        XCTAssertEqual(draft.groups.count, 2)
        XCTAssertEqual(draft.groups[0].options[0].componentName, "RTX 6000 card")

        let (body, errors) = draft.payload(isNew: false)
        XCTAssertEqual(errors, [])
        let out = try json(JSONEncoder().encode(JSONValue.object(try XCTUnwrap(body))))
        XCTAssertNil(out["stock_qty"], "an existing product's stock moves only through stock adjustments")
        XCTAssertEqual(out["vat_rate"] as? Double, 0.2)
        XCTAssertEqual(out["base_price_minor"] as? Int, 799_900)
        XCTAssertTrue(out["cost_minor"] is NSNull)
        XCTAssertEqual(out["category_uuid"] as? String, "c-1")
        XCTAssertEqual(out["tags"] as? [String], ["ai", "studio"])
        XCTAssertEqual((out["attributes"] as? [String: Any])?["psu_watts"] as? Int, 2000)
        XCTAssertEqual(((out["seo"] as? [String: Any])?["en"] as? [String: Any])?["title"] as? String, "Studio W7")
        XCTAssertNil((out["seo"] as? [String: Any])?["fr"], "empty languages are left out")
        let photo = try XCTUnwrap((out["photos"] as? [[String: Any]])?.first)
        XCTAssertEqual(photo["fallback_url"] as? String, "https://example.com/p.jpg")
        XCTAssertEqual((photo["alt"] as? [String: Any])?["en"] as? String, "Front")

        let groups = try XCTUnwrap(out["option_groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2, "every group is sent: the server switches off any left out")
        XCTAssertEqual(groups[1]["is_active"] as? Bool, false, "an inactive group stays inactive")
        let option = try XCTUnwrap((groups[0]["options"] as? [[String: Any]])?.first)
        XCTAssertEqual(option["uuid"] as? String, "o-1")
        XCTAssertEqual(option["component_product_uuid"] as? String, "p-9")
        XCTAssertTrue(option["stock_qty"] is NSNull, "a component supplies the stock")
        XCTAssertEqual(option["cost_minor"] as? Int, 520_000)
        XCTAssertEqual((option["attributes"] as? [String: Any])?["watts"] as? Int, 600)

        let rule = try XCTUnwrap((out["rules"] as? [[String: Any]])?.first)
        XCTAssertEqual(rule["uuid"] as? String, "r-1")
        XCTAssertEqual(rule["sort_order"] as? Int, 10)
        let params = try XCTUnwrap(rule["params"] as? [String: Any])
        XCTAssertEqual(params["equals"] as? Int, 2, "params the form doesn't model are kept")
        XCTAssertNil(params["equals_product_attr"], "an empty product attribute isn't sent")
    }

    func testProductEditorChecks() {
        var draft = ShopProductDraft()
        draft.name = "Thing"
        draft.sku = "T1"
        draft.priceMode = "configurable"
        XCTAssertTrue(draft.payload(isNew: true).errors.contains("A configurable product needs at least one option group."))

        var group = ShopGroupDraft()
        group.code = "gpu"
        group.name = "Graphics"
        var option = ShopOptionDraft()
        option.code = "a"
        option.name = "A"
        option.isDefault = true
        var second = option
        second.code = "b"
        group.options = [option, second]
        draft.groups = [group, group]
        var rule = ShopRuleDraft(kind: "excludes")
        rule.params = ["a": .string("gpu.a"), "b": .string("gpu.zzz")]
        rule.message = "No"
        draft.rules = [rule]
        let errors = draft.payload(isNew: true).errors
        XCTAssertTrue(errors.contains("Two groups have the code “gpu”."))
        XCTAssertTrue(errors.contains("Graphics: a pick-one group can only have one default option."))
        XCTAssertTrue(errors.contains("Rule 1 (Excludes): there is no option “gpu.zzz”."))

        draft.groups = [group]
        draft.groups[0].options[1].isDefault = false
        draft.rules = []
        let (body, okErrors) = draft.payload(isNew: true)
        XCTAssertEqual(okErrors, [])
        XCTAssertEqual(body?["slug"], .string("thing"), "the web address is made from the name")
        XCTAssertEqual(body?["stock_qty"], .number(0))
        XCTAssertEqual(ShopProductDraft.signedMinor("-12.50"), -1250)
    }

    // MARK: Catalogue import

    func testCSVImportReadsASpreadsheet() {
        let csv = "\u{FEFF}sku,name,base_price,vat_rate,tags,category,spec:GPU,description\r\n"
            + "W7,\"Studio W7, quiet\",7999.00,20,ai;studio,workstations,4× RTX,\"Line one\nline two\"\r\n"
            + ",No SKU,10,20,,,,\r\n"
            + "W8,Bad price,lots,20,,,,\r\n"
        let file = ShopCatalogImportFile.read(Data(csv.utf8), filename: "products.csv")
        XCTAssertEqual(file.products.count, 1)
        XCTAssertEqual(file.problems, ["Row 3: the SKU is missing.", "Row 4: base_price must be an amount like 1999.00."])
        let product = file.products[0]
        XCTAssertEqual(product["name"], .string("Studio W7, quiet"))
        XCTAssertEqual(product["slug"], .string("studio-w7-quiet"))
        XCTAssertEqual(product["base_price_minor"], .number(799_900))
        XCTAssertEqual(product["vat_rate"], .number(0.2))
        XCTAssertEqual(product["tags"], .array([.string("ai"), .string("studio")]))
        XCTAssertEqual(product["category_slug"], .string("workstations"))
        XCTAssertEqual(product["specs"], .object(["GPU": .string("4× RTX")]))
        XCTAssertEqual(product["description"], .string("Line one\nline two"))

        let body = file.body(overwritePrices: false, overwriteStock: true)
        XCTAssertEqual(body["overwrite_prices"], .bool(false))
        XCTAssertEqual(body["overwrite_stock"], .bool(true))
        XCTAssertNil(body["categories"], "no categories in a spreadsheet")
    }

    func testJSONImportTakesTheServersDocument() {
        let text = #"{"categories":[{"slug":"gpus","name":"GPUs"}],"products":[{"sku":"G1","name":"Card"},{"name":"No sku"}]}"#
        let file = ShopCatalogImportFile.read(Data(text.utf8), filename: "catalogue.json")
        XCTAssertEqual(file.categories.count, 1)
        XCTAssertEqual(file.products.count, 2)
        XCTAssertEqual(file.problems, ["Product 2 has no SKU."])
        let result = try? JSONDecoder.opsAPI().decode(Envelope.Standard<ShopImportResult>.self, from: Data("""
        {"success":true,"data":{"categories":{"created":1,"updated":0},"products":{"created":1,"updated":0},"prices":"kept",
         "errors":[{"type":"product","ref":"No sku","error":"sku is required"}]}}
        """.utf8)).data
        XCTAssertEqual(result?.products?.created, 1)
        XCTAssertEqual(result?.errors?.first?.error, "sku is required")
    }
}
