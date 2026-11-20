import XCTest
@testable import WSLCRM

/// The till (`/api/v2/pos`), the unified sales-order list (`/api/v2/sales-orders`) and store orders
/// (`/api/v2/orders`). Fixtures follow lapis/queries/PosQueries.lua, SalesOrderQueries.lua and routes/orders.lua.
final class SalesTillOrdersTests: XCTestCase {

    // MARK: Fixtures

    static let catalogueJSON = #"""
    {"success":true,"data":{"store":{"uuid":"st-1","name":"High Street","currency":"GBP","tax_rate":0.2},
     "products":[
      {"uuid":"p-1","name":"Flat white","sku":"FW","barcode":"5012345678900","price":"3.20","image":null,"stock":null,
       "tracked":false,"available":true,"category":"Coffee","variants":{}},
      {"uuid":"p-2","name":"T-shirt","sku":"TS","barcode":"5000000000002","price":"12.00","image":"https://cdn.test/ts.jpg",
       "stock":3,"tracked":true,"available":true,"category":"Clothes","variants":[
        {"uuid":"v-s","title":"Small","sku":"TS-S","price":"12.00","stock":1,"available":true},
        {"uuid":"v-l","title":"Large","sku":"TS-L","price":"14.00","stock":0,"available":false}]},
      {"uuid":"p-3","name":"Mug","sku":"MUG","barcode":null,"price":"8.50","image":null,"stock":2,"tracked":true,
       "available":true,"category":null,"variants":[]}],
     "categories":[{"uuid":"c-1","name":"Coffee"},{"uuid":"c-2","name":"Clothes"}]}}
    """#

    static let receiptJSON = #"""
    {"success":true,"data":{"uuid":"o-9","order_number":"ORD-20261120-AB12CD34","sold_at":"2026-11-20T10:15:00Z",
     "channel":"pos","store":{"uuid":"st-1","name":"High Street","address":"1 High St, Leeds, LS1 1AA","contact":"0113 000 · hi@shop.test"},
     "items":[{"name":"T-shirt — Small","sku":"TS-S","quantity":1,"price":"12.00","total":"12.00"},
              {"name":"Flat white","sku":null,"quantity":2,"price":"3.20","total":"6.40"}],
     "currency":"GBP","subtotal":"18.40","tax":"3.68","discount":"2.00","total":"20.08",
     "payment":{"method":"cash","label":"Cash","tendered":"25.00","change":"4.92","reference":null},
     "customer_email":null}}
    """#

    private func catalogue() throws -> POSCatalogue {
        try JSONDecoder.opsAPI().decode(Envelope.Standard<POSCatalogue>.self, from: Data(Self.catalogueJSON.utf8)).data
    }

    private func api(_ handler: @escaping StubURLProtocol.Handler) async -> SalesAPI {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return SalesAPI(client: client)
    }

    // MARK: Catalogue and cart

    func testTheCatalogueDecodesPricesStockVariationsAndAnEmptyCjsonList() throws {
        let c = try catalogue()
        XCTAssertEqual(c.store.taxRate, Decimal(string: "0.2"))
        XCTAssertEqual(c.products.count, 3)
        XCTAssertTrue(c.products[0].variants.isEmpty, "`{}` is an empty list from lua-cjson")
        XCTAssertNil(c.products[0].stock, "stock not tracked")
        XCTAssertEqual(c.products[1].variants.map(\.title), ["Small", "Large"])
        XCTAssertEqual(c.products[1].displayPrice.amount, 12)
        XCTAssertTrue(c.products[1].displayPrice.isFrom, "variations at different prices read “from £12.00”")
        XCTAssertEqual(c.categories.map(\.name), ["Coffee", "Clothes"])
    }

    func testTheCartStopsAtStockAndWorksOutTaxDiscountAndChange() throws {
        let c = try catalogue()
        var cart = POSCart()
        cart.taxRate = c.store.taxRate
        let mug = c.products[2]
        XCTAssertTrue(cart.add(mug, nil))
        XCTAssertTrue(cart.add(mug, nil))
        XCTAssertFalse(cart.add(mug, nil), "only 2 mugs in stock")
        XCTAssertEqual(cart.quantity(of: mug, nil), 2)

        cart.add(c.products[0], nil)                         // 3.20, untracked
        XCTAssertEqual(cart.subtotal, Decimal(string: "20.20"))
        XCTAssertEqual(cart.tax, Decimal(string: "4.04"))
        cart.discount = "1.24"
        XCTAssertEqual(cart.total, 23)
        XCTAssertEqual(cart.quickAmounts, [23, 25, 30, 40, 50])
        cart.tendered = "20"
        XCTAssertEqual(cart.problem, "The cash given is less than the total")
        cart.tendered = "25.00"
        XCTAssertNil(cart.problem)
        XCTAssertEqual(cart.change, 2)

        cart.discount = "5.5.0"
        XCTAssertEqual(cart.problem, "The discount must be an amount like 5.00")
        cart.discount = "99"
        XCTAssertEqual(cart.problem, "The discount is more than the sale")
        cart.discount = ""
        cart.method = .card
        cart.email = "not-an-email"
        XCTAssertEqual(cart.problem, "Check the email address")

        cart.setQuantity(POSCart.key(mug, nil), 0)
        XCTAssertEqual(cart.lines.count, 1, "a quantity of zero takes the line out")
        cart.reset()
        XCTAssertTrue(cart.lines.isEmpty)
        XCTAssertEqual(cart.taxRate, Decimal(string: "0.2"), "a new sale keeps the store's tax rate")
        XCTAssertEqual(cart.problem, "Add something to the sale")
    }

    func testScanningMatchesBarcodesAndVariationSKUsExactly() throws {
        let c = try catalogue()
        var cart = POSCart()
        XCTAssertEqual(cart.scan("5012345678900", in: c.products), .added("Flat white"))
        XCTAssertEqual(cart.scan(" ts-s ", in: c.products), .added("T-shirt — Small"), "a variation's SKU, any case")
        XCTAssertEqual(cart.scan("TS-S", in: c.products), .allInSale("T-shirt — Small", 1))
        XCTAssertEqual(cart.scan("TS-L", in: c.products), .outOfStock("T-shirt — Large"))
        if case .choose(let product) = cart.scan("5000000000002", in: c.products) {
            XCTAssertEqual(product.uuid, "p-2", "the product's own barcode asks which variation")
        } else {
            XCTFail("expected a choice of variation")
        }
        XCTAssertEqual(cart.scan("FW-", in: c.products), .notFound("FW-"), "no partial matches")
        XCTAssertEqual(POSCart.message(.notFound("123")), "No product has the barcode or SKU “123”.")
    }

    // MARK: Selling

    func testCompletingASaleSendsTheServersBodyWithAnIdempotencyKey() async throws {
        let c = try catalogue()
        var cart = POSCart()
        cart.add(c.products[1], c.products[1].variants[0])
        cart.add(c.products[0], nil)
        cart.add(c.products[0], nil)
        cart.discount = "2.00"
        cart.tendered = "25.00"
        cart.email = " ana@example.com "
        cart.note = "Gift wrap"

        let captured = SalesCapture()
        let api = await api { request in
            captured.set(request)
            return .json(201, Self.receiptJSON)
        }
        let receipt = try await api.sell(cart.body(storeUuid: "st-1"), idempotencyKey: "key-1")

        XCTAssertEqual(captured.path, "/api/v2/pos/sales")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.idempotencyKey, "key-1")
        let body = try XCTUnwrap(captured.json)
        XCTAssertEqual(body["store_uuid"]?.stringValue, "st-1")
        XCTAssertEqual(body["discount_amount"]?.stringValue, "2.00")
        XCTAssertEqual(body["note"]?.stringValue, "Gift wrap")
        XCTAssertEqual(body["customer"]?["email"]?.stringValue, "ana@example.com")
        XCTAssertNil(body["customer"]?["first_name"], "blank names aren't sent")
        XCTAssertEqual(body["payment"]?["method"]?.stringValue, "cash")
        XCTAssertEqual(body["payment"]?["tendered"]?.stringValue, "25.00")
        guard case .array(let items)? = body["items"] else { return XCTFail("items") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["product_uuid"]?.stringValue, "p-2")
        XCTAssertEqual(items[0]["variant_uuid"]?.stringValue, "v-s")
        XCTAssertEqual(items[1]["quantity"]?.stringValue, "2")
        XCTAssertNil(items[1]["variant_uuid"])

        XCTAssertEqual(receipt.orderNumber, "ORD-20261120-AB12CD34")
        XCTAssertEqual(receipt.total, Decimal(string: "20.08"))
        XCTAssertEqual(receipt.payment.change, Decimal(string: "4.92"))
        XCTAssertEqual(receipt.items.count, 2)
        XCTAssertNotNil(receipt.soldAt)
    }

    func testACardSaleSendsNoCashGivenAndTheTerminalReference() throws {
        var cart = POSCart()
        cart.add(try catalogue().products[0], nil)
        cart.method = .card
        cart.tendered = "50"
        cart.reference = " 4421 "
        let body = cart.body(storeUuid: "st-1")
        XCTAssertNil(body.payment.tendered)
        XCTAssertEqual(body.payment.reference, "4421")
        XCTAssertNil(body.customer, "a walk-in sends no customer")
    }

    @MainActor func testTheReceiptPrintsTheWebsLines() throws {
        let receipt = try JSONDecoder.opsAPI().decode(Envelope.Standard<POSReceipt>.self, from: Data(Self.receiptJSON.utf8)).data
        let lines = POSReceiptPDF.textLines(receipt).map { [$0.left, $0.right].compactMap { $0 }.joined(separator: " | ") }
        XCTAssertEqual(lines.first, "High Street")
        XCTAssertTrue(lines.contains { $0.hasPrefix("1 × T-shirt — Small") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Discount") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Paid by Cash") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Cash ") && $0.contains("Change") })
        XCTAssertEqual(lines.last, "Thank you for your purchase.")
    }

    func testTheDaySummaryDecodes() throws {
        let json = #"""
        {"success":true,"data":{"date":"2026-11-20","timezone":"Europe/London","currency":"GBP","sales":3,"total":"52.10",
         "by_method":[{"method":"cash","label":"Cash","sales":2,"total":"40.10"},{"method":"card","label":"Card","sales":1,"total":"12.00"}],
         "recent":[{"uuid":"o-9","order_number":"ORD-1","sold_at":"2026-11-20T10:15:00Z","items":3,"total":"20.08","method":"Cash"}]}}
        """#
        let summary = try JSONDecoder.opsAPI().decode(Envelope.Standard<POSSummary>.self, from: Data(json.utf8)).data
        XCTAssertEqual(summary.sales, 3)
        XCTAssertEqual(summary.byMethod.map(\.label), ["Cash", "Card"])
        XCTAssertEqual(summary.recent.first?.items, 3)
        XCTAssertEqual(summary.recent.first?.total, Decimal(string: "20.08"))
    }

    // MARK: Sales orders

    func testTheSalesOrderListReadsRowsStatsAndTheEmptyRevenueQuirk() throws {
        let json = #"""
        {"success":true,"data":[
          {"source":"shop","uuid":"s-1","order_number":"WS-1001","placed_at":"2026-11-19T09:00:00Z","stage":"confirmed",
           "payment":"paid","total":"1200.00","currency":"GBP","customer_name":"Ana Ruiz","customer_email":"ana@test",
           "company":"Ruiz Ltd","channel":"staff","path":"/dashboard/shop/orders/s-1"},
          {"source":"store","uuid":"o-9","order_number":"ORD-9","placed_at":"2026-11-20T10:15:00Z","stage":"delivered",
           "payment":"paid","total":"20.08","currency":"GBP","channel":"pos"}],
         "meta":{"total":2,"page":1,"per_page":25,"sources":["shop","store"],
          "stats":{"total":2,"awaiting_payment":0,"in_progress":1,"delivered":1,"revenue":{"GBP":"1220.08","EUR":"10.00"}}}}
        """#
        let page = try SalesOrderPage.parse(ResourceService.decode(Data(json.utf8)), page: 1, perPage: 25)
        XCTAssertEqual(page.orders.count, 2)
        XCTAssertEqual(page.sources, [.shop, .store])
        XCTAssertEqual(page.stats.inProgress, 1)
        XCTAssertEqual(page.stats.headlineRevenue?.currency, "GBP")
        XCTAssertEqual(page.stats.otherRevenue.first?.currency, "EUR")

        let shop = page.orders[0]
        XCTAssertEqual(shop.id, "shop:s-1")
        XCTAssertEqual(shop.originLabel, "Shop · Built by staff")
        XCTAssertEqual(shop.customerTitle, "Ruiz Ltd")
        XCTAssertEqual(shop.customerSubtitle, "Ana Ruiz")
        XCTAssertTrue(shop.showsPaid)

        let till = page.orders[1]
        XCTAssertEqual(till.customerTitle, "Walk-in customer")
        XCTAssertEqual(till.originLabel, "Store · Point of sale")

        let empty = #"{"success":true,"data":{},"meta":{"total":0,"sources":["store"],"stats":{"total":0,"revenue":[]}}}"#
        let none = try SalesOrderPage.parse(ResourceService.decode(Data(empty.utf8)), page: 1, perPage: 25)
        XCTAssertTrue(none.orders.isEmpty)
        XCTAssertNil(none.stats.headlineRevenue, "an empty revenue arrives as [] and means nothing paid")
    }

    @MainActor func testTheSalesOrderQuerySendsTheWebsParameters() {
        var query = SalesOrderQuery(search: " acme ", stage: .inProgress, source: .store, channel: .inPerson)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        query.from = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))
        let items = Dictionary(uniqueKeysWithValues: query.items(page: 2, perPage: 25).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["q"], "acme")
        XCTAssertEqual(items["stage"], "in_progress")
        XCTAssertEqual(items["source"], "store")
        XCTAssertEqual(items["channel"], "in_person")
        XCTAssertEqual(items["from"], "2026-11-01")
        XCTAssertNil(items["to"])
        XCTAssertEqual(items["page"], "2")
        XCTAssertEqual(items["per_page"], "25")
        XCTAssertEqual(SalesOrdersView.paid(Decimal(string: "7318.80")!, "GBP"), "£7,319")
    }

    // MARK: Store orders

    func testAStoreOrderStatusChangeIsSentAsFormFields() async throws {
        let captured = SalesCapture()
        let api = await api { request in
            captured.set(request)
            return .json(200, #"{"message":"Order status updated successfully","order":{"uuid":"o-1"}}"#)
        }
        try await api.changeStoreOrderStatus("o-1", StoreOrderStatusChange(status: .shipped, notes: " Sent by DPD "))
        XCTAssertEqual(captured.path, "/api/v2/orders/o-1/status")
        XCTAssertEqual(captured.method, "PUT")
        XCTAssertEqual(captured.contentType, "application/x-www-form-urlencoded",
                       "the route reads form parameters; a JSON body would be ignored")
        XCTAssertEqual(captured.body, "status=shipped&notes=Sent%20by%20DPD")
    }

    func testCreatingAStoreOrderSendsItemsVariantsAddressesAndAKey() async throws {
        let captured = SalesCapture()
        let api = await api { request in
            captured.set(request)
            return .json(201, #"{"success":true,"data":{"uuid":"o-2","order_number":"ORD-20261120-XYZ","status":"pending","items":[]}}"#)
        }
        let body = CreateStoreOrderBody(
            storeUuid: "st-1", customer: .init(email: "ana@test", firstName: "Ana", lastName: nil, phone: nil),
            items: [.init(productUuid: "p-2", variantUuid: "v-s", quantity: 2)], shippingAmount: "4.99", discountAmount: nil,
            customerNotes: nil, internalNotes: "Call first", paid: true, channel: .inPerson,
            shippingAddress: StoreOrderAddress(name: " Ana ", line1: "1 High St", city: "Leeds", postcode: "LS1 1AA").cleaned,
            billingAddress: StoreOrderAddress().cleaned)
        let created = try await api.createStoreOrder(body, idempotencyKey: "k-9")
        XCTAssertEqual(created.orderNumber, "ORD-20261120-XYZ")
        XCTAssertEqual(captured.idempotencyKey, "k-9")
        let json = try XCTUnwrap(captured.json)
        XCTAssertEqual(json["channel"]?.stringValue, "in_person")
        XCTAssertEqual(json["paid"]?.boolValue, true)
        XCTAssertEqual(json["shipping_amount"]?.stringValue, "4.99")
        guard case .array(let items)? = json["items"] else { return XCTFail("items") }
        XCTAssertEqual(items.first?["variant_uuid"]?.stringValue, "v-s")
        XCTAssertEqual(json["shipping_address"]?["name"]?.stringValue, "Ana")
        XCTAssertEqual(json["shipping_address"]?["postcode"]?.stringValue, "LS1 1AA")
        XCTAssertNil(json["billing_address"], "an empty address is left out")
    }

    func testAStoreOrderReadsItsItemsHistoryAndDelivery() async throws {
        let api = await api { _ in
            .json(200, #"""
            {"uuid":"o-1","order_number":"ORD-1","status":"processing","financial_status":"paid","currency":"GBP",
             "subtotal":20,"tax_amount":4,"shipping_amount":0,"discount_amount":0,"total_amount":24,"source":"phone",
             "shipping_address":{"name":"Ana","line1":"1 High St","city":"Leeds","postcode":"LS1 1AA"},
             "items":[{"id":7,"quantity":2,"price":10,"total":20,"product_title":"Mug","product_name":"Mug","sku":"MUG"}],
             "history":[{"id":3,"action":"status_change","previous_status":"pending","new_status":"processing",
                         "new_financial_status":"paid","old_financial_status":"pending","notes":"Paid by phone",
                         "created_at":"2026-11-20T09:00:00Z"}],
             "customer":{"uuid":"c-1","email":"ana@test","first_name":"Ana","last_name":"Ruiz","phone":"0113"},
             "store":{"uuid":"st-1","name":"High Street"},
             "delivery_partner":{"id":1,"uuid":"dp-1","company_name":"Swift Couriers","contact_person_name":"Sam"},
             "delivery_assignment":{"uuid":"as-1","status":"accepted","delivery_fee":3.5}}
            """#)
        }
        let order = try await api.storeOrder("o-1")
        XCTAssertEqual(order.orderNumber, "ORD-1")
        XCTAssertEqual(order.customerName, "Ana Ruiz")
        XCTAssertEqual(order.items.first?.int("quantity"), 2)
        XCTAssertEqual(order.money("total_amount"), 24)
        let entry = try XCTUnwrap(order.history.first)
        let shipping = order.record["shipping_address"]
        let (history, address) = await MainActor.run {
            (StoreOrderDetailView.historyLine(entry), StoreOrderDetailView.address(shipping))
        }
        XCTAssertEqual(history, "Pending → Processing · Payment: Paid")
        XCTAssertEqual(address, "Ana, 1 High St, Leeds, LS1 1AA")
        XCTAssertEqual(order.record.string("delivery_partner.company_name"), "Swift Couriers")
        XCTAssertEqual(StoreOrderStatus.next(after: "processing"), [.shipped, .delivered, .cancelled])
    }

    // MARK: Shop order workflow

    func testTheNextStepFollowsTheSupplierPO() {
        let paid = ShopOrderWorkflow.next(status: .paid, orderNumber: "WS-1", paymentMethod: "card", purchaseOrders: [])
        XCTAssertEqual(paid.step, .raisePO)
        let draft = ShopOrderPurchaseOrderRef(uuid: "po-1", poNumber: "PO-7", status: "draft", supplierName: "Scan")
        XCTAssertEqual(ShopOrderWorkflow.next(status: .processing, orderNumber: "WS-1", paymentMethod: nil, purchaseOrders: [draft]).step, .sendPO)
        var sent = draft
        sent.status = "sent"
        let receive = ShopOrderWorkflow.next(status: .paid, orderNumber: "WS-1", paymentMethod: nil, purchaseOrders: [sent])
        XCTAssertEqual(receive.step, .receive)
        XCTAssertTrue(receive.detail.contains("Scan"))
        var received = draft
        received.status = "received"
        XCTAssertEqual(ShopOrderWorkflow.next(status: .paid, orderNumber: "WS-1", paymentMethod: nil, purchaseOrders: [received]).step, .ship)
        var cancelled = draft
        cancelled.status = "cancelled"
        XCTAssertEqual(ShopOrderWorkflow.next(status: .paid, orderNumber: "WS-1", paymentMethod: nil, purchaseOrders: [cancelled]).step,
                       .raisePO, "a cancelled PO doesn't count")
        XCTAssertEqual(ShopOrderWorkflow.next(status: .pendingPayment, orderNumber: "WS-1", paymentMethod: "bank_transfer",
                                              purchaseOrders: []).step, .awaitingBankTransfer)
        XCTAssertEqual(ShopOrderWorkflow.transitions(.paid), [.processing, .shipped, .cancelled, .refunded])
        XCTAssertEqual(ShopOrderWorkflow.transitions(.cancelled), [])
        XCTAssertTrue(ShopOrderWorkflow.canEditDeliveryAddress(.processing))
        XCTAssertFalse(ShopOrderWorkflow.canEditDeliveryAddress(.shipped))
    }

    func testTheOrderExtrasReadPOsBillingAndTheAgreedDeliveryAddress() throws {
        let json = #"""
        {"success":true,"data":{"uuid":"s-1","order_number":"WS-1","status":"paid","payment_method":"bank_transfer",
         "paid_amount_minor":120000,"stripe_session_id":"cs_test_1","delivery_method":"Courier","delivery_change_pending":true,
         "billing_address":{"line1":"2 Low St","city":"York","postal_code":"YO1 1AA"},
         "delivery_address":{"name":"Ana","line1":"1 High St","city":"Leeds","postcode":"LS1 1AA","vat_number":"GB1"},
         "tracking":{"carrier":"DPD","tracking_number":"123","shipped_at":"2026-11-19T10:00:00Z"},
         "purchase_orders":[{"uuid":"po-1","po_number":"PO-7","status":"sent","supplier_name":"Scan","total":"900.00",
                             "created_at":"2026-11-18T09:00:00Z","sent_at":"2026-11-18T10:00:00Z"}],
         "customer_updates":{},"delivery_change_requests":[]}}
        """#
        let extras = try JSONDecoder.opsAPI().decode(Envelope.Standard<ShopOrderExtras>.self, from: Data(json.utf8)).data
        XCTAssertEqual(extras.purchaseOrders.first?.poNumber, "PO-7")
        XCTAssertEqual(extras.paidAmountMinor, 120_000)
        XCTAssertEqual(extras.stripeSessionId, "cs_test_1")
        XCTAssertEqual(extras.deliveryAddress?.vatNumber, "GB1")
        XCTAssertEqual(extras.deliveryAddress?.formatted, "Ana, 1 High St, Leeds, LS1 1AA")
        XCTAssertTrue(extras.deliveryChangePending)
        XCTAssertNotNil(extras.shippedAt)
        XCTAssertEqual(ShopAnyAddress.format(extras.billingAddress), "2 Low St, York, YO1 1AA")
        let order = try JSONDecoder.opsAPI().decode(Envelope.Standard<ShopOrder>.self, from: Data(json.utf8)).data
        XCTAssertEqual(order.tracking?.shippedAt, "2026-11-19T10:00:00Z", "kept so editing tracking doesn't lose it")
        let timeline = ShopOrderWorkflow.timeline(order: order, extras: extras)
        XCTAssertEqual(timeline.first { $0.label == "Supplier PO sent" }?.done, true)
        XCTAssertEqual(timeline.first { $0.label == "Goods received" }?.done, false)
    }

    func testUpdateEmailsAreBlockedForTheWebsReasons() throws {
        let json = #"""
        {"presets":[{"key":"delayed","label":"Delayed","headline":"Your order is delayed","message":"New date: [NEW DATE]"}],
         "to":"ana@test","customer_emails_enabled":true,"email_configured":true,"test_to":"me@shop.test","signature":"The team",
         "limits":{"headline_max":120,"message_max":4000,"per_day":5,"sent_last_24h":1},"history":{}}
        """#
        var info = try JSONDecoder.opsAPI().decode(ShopOrderUpdateEmailInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.presets.first?.label, "Delayed")
        XCTAssertTrue(info.history.isEmpty)
        XCTAssertEqual(info.sendBlocked(headline: "Delayed", message: "New date: [NEW DATE]"), "Replace [NEW DATE] before sending.")
        XCTAssertNil(info.sendBlocked(headline: "Delayed", message: "New date: 3 December"))
        info.limits.sentLast24h = 5
        XCTAssertEqual(info.sendBlocked(headline: "a", message: "b"), "This order has had 5 update emails in the last 24 hours.")
        info.customerEmailsEnabled = false
        XCTAssertEqual(info.sendBlocked(headline: "a", message: "b"), "Customer emails from the shop are off.")

        let preview = try JSONDecoder.opsAPI().decode(ShopOrderUpdateEmailPreview.self, from: Data(#"""
        {"subject":"Order WS-1","html":"<html><head><style>p{}</style></head><body><h1>Delayed</h1><p>Hello Ana,<br>New date &amp; time</p></body></html>","warnings":{}}
        """#.utf8))
        XCTAssertEqual(preview.plainText, "Delayed\nHello Ana,\nNew date & time")
    }

    func testTheSupplierPOBodyKeepsLineUuidsAndTheCustomerPONumberCanBeCleared() throws {
        let body = ShopOrderPOInput(supplierUuid: "sup-1", supplierName: nil, supplierEmail: "po@scan.test", supplierPhone: nil,
                                    expectedDate: "2026-12-01", deliveryMethod: nil, notes: nil,
                                    costs: ["9f1C-Line": "12.50"], includeCustom: false, dropShip: true, confirmDropShip: true)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder.shopOrderPO.encode(body))
        XCTAssertEqual(json["supplier_uuid"]?.stringValue, "sup-1")
        XCTAssertEqual(json["confirm_drop_ship"]?.boolValue, true)
        XCTAssertEqual(json["expected_date"]?.stringValue, "2026-12-01")
        XCTAssertEqual(json["costs"]?["9f1C-Line"]?.stringValue, "12.50", "line uuids are never rewritten")

        let cleared = String(decoding: try JSONEncoder().encode(ShopCustomerPONumberBody(value: "  ")), as: UTF8.self)
        XCTAssertEqual(cleared, #"{"customer_po_number":null}"#)
        let set = String(decoding: try JSONEncoder().encode(ShopCustomerPONumberBody(value: " PO-4471 ")), as: UTF8.self)
        XCTAssertEqual(set, #"{"customer_po_number":"PO-4471"}"#)
    }

    func testAmountsTypedAtTheTill() {
        XCTAssertTrue(SalesMoney.isAmount(""))
        XCTAssertTrue(SalesMoney.isAmount("12.5"))
        XCTAssertFalse(SalesMoney.isAmount("12.505"))
        XCTAssertFalse(SalesMoney.isAmount("-1"))
        XCTAssertEqual(SalesMoney.plain(Decimal(string: "7.1")!), "7.10")
        XCTAssertEqual(SalesMoney.r2(Decimal(string: "2.345")!), Decimal(string: "2.35"))
    }
}

/// What a stubbed request carried.
final class SalesCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest) { lock.withLock { self.request = request } }

    var path: String? { lock.withLock { request?.url?.path } }
    var method: String? { lock.withLock { request?.httpMethod } }
    var contentType: String? { lock.withLock { request?.value(forHTTPHeaderField: "Content-Type") } }
    var idempotencyKey: String? { lock.withLock { request?.value(forHTTPHeaderField: "Idempotency-Key") } }
    var query: [String: String] {
        lock.withLock {
            let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        }
    }
    var body: String? { lock.withLock { request?.httpBody.map { String(decoding: $0, as: UTF8.self) } } }
    var json: JSONValue? {
        lock.withLock { request?.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
    }
}
