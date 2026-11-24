import XCTest
@testable import WSLCRM

/// Fixes from the deep audit in the sales area: delivery requests for partners, proof of delivery, store-order
/// tracking and the courier's signature, permission gates and wording. Shapes follow lapis/routes and queries.
final class SalesDeepAuditTests: XCTestCase {

    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> APIClient {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return client
    }

    private static func form(_ request: URLRequest) -> [String: String] {
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    // MARK: Delivery requests for the partner (routes/delivery-requests.lua, DeliveryRequestQueries.findByPartnerId)

    static let partnerRequestsJSON = #"""
    {"requests":[
     {"id":7,"uuid":"dr-1","order_id":41,"delivery_partner_id":3,"request_type":"seller_to_partner","status":"pending",
      "proposed_fee":"4.50","message":"Fragile","response_message":null,"expires_at":"2026-11-25 10:00:00",
      "created_at":"2026-11-24 10:00:00","order_number":"ORD-41","total_amount":"32.00",
      "shipping_address":"{\"name\":\"Jo Bloggs\",\"address1\":\"1 High St\",\"city\":\"Leeds\",\"zip\":\"LS1 1AA\"}",
      "store_name":"Corner Shop","store_slug":"corner-shop","store_phone":"0113 000"},
     {"id":8,"uuid":"dr-2","order_id":42,"delivery_partner_id":3,"request_type":"partner_to_seller","status":"pending",
      "proposed_fee":"3","order_number":"ORD-42","store_name":"Corner Shop"}]}
    """#

    func testThePartnerSeesRequestsWithoutAWorkspaceAndCanAnswerThem() async throws {
        let seen = Counter()
        let client = await client { request in
            let url = request.url!
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Namespace-Id"), "a partner may have no workspace")
            if request.httpMethod == "GET" {
                XCTAssertEqual(url.path, "/api/v2/delivery-requests/partner")
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "pending")
                return .json(200, Self.partnerRequestsJSON)
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            seen.increment(url.path)
            if url.path.hasSuffix("/accept") { XCTAssertEqual(Self.form(request)["response_message"], "On my way") }
            if url.path.hasSuffix("/cancel") { XCTAssertNil(Self.form(request)["response_message"]) }
            return .json(200, #"{"message":"ok"}"#)
        }
        let api = DeliveryAPI(client: client)
        let rows = try await api.myRequests()
        XCTAssertEqual(rows.map(\.id), ["dr-1", "dr-2"])
        XCTAssertEqual(MyDeliveryRequestAnswer.choices(for: rows[0]), [.accept, .reject], "the store asked: the partner answers")
        XCTAssertEqual(MyDeliveryRequestAnswer.choices(for: rows[1]), [.cancel], "the partner's own offer can be withdrawn")
        XCTAssertEqual(MyDeliveryRequestAnswer.choices(for: rows[0].setting("status", .string("accepted"))), [])

        try await api.answerMyRequest("dr-1", .accept, message: "On my way")
        try await api.answerMyRequest("dr-2", .cancel, message: "ignored")
        XCTAssertEqual(seen.value("/api/v2/delivery-requests/dr-1/accept"), 1)
        XCTAssertEqual(seen.value("/api/v2/delivery-requests/dr-2/cancel"), 1)
    }

    func testCancellingADeliveryOnAnOlderServerSaysWhatToDo() {
        let cancel = MyDeliverySteps.next(from: "accepted").first { $0.status == "cancelled" }!
        let crash = APIError.server(ServerError(status: 500, message: "Failed to update", fieldErrors: [:], rawBody: ""))
        XCTAssertTrue(MyDeliverySteps.failure(cancel, crash).localizedDescription.contains("Call the store"))
        let pickUp = MyDeliverySteps.next(from: "accepted").first { $0.status == "picked_up" }!
        XCTAssertEqual(MyDeliverySteps.failure(pickUp, crash).serverError, crash.serverError, "other steps keep the server's message")
    }

    // MARK: Proof of delivery (DeliverySignatureQueries.proof_of_delivery)

    func testProofOfDeliveryReadsTheSignatureJSONOrPlainText() throws {
        let json = #"{"notes":"Left with reception","signer_name":"Jo Bloggs","signature_uuid":"s-1","signed_at":"2026-11-24T14:05:00Z"}"#
        let pod = try XCTUnwrap(DeliveryProof(json))
        XCTAssertEqual(pod.signerName, "Jo Bloggs")
        XCTAssertEqual(pod.notes, "Left with reception")
        XCTAssertNotNil(pod.signedAt)
        XCTAssertTrue(pod.signedLine?.hasPrefix("Jo Bloggs, ") == true)
        XCTAssertFalse(pod.signedLine?.contains("{") == true, "never raw JSON on screen")

        XCTAssertEqual(DeliveryProof("Parcel in the porch")?.notes, "Parcel in the porch")
        XCTAssertNil(DeliveryProof("  "))
        XCTAssertNil(DeliveryProof(#"{"signature_uuid":"s-1"}"#), "nothing a person can read")
    }

    // MARK: Store order tracking (routes/orders.lua ORDER_UPDATABLE)

    func testTrackingFieldsClearASavedNumberButNeverWipeOneTheScreenCouldNotSee() throws {
        let day = try XCTUnwrap(StoreOrderEdit.expectedDay(Record(["estimated_delivery_date": .string("2026-12-03")])))
        let fields = StoreOrderEdit.trackingFields(carrier: "DPD", trackingURL: "", trackingNumber: "  ",
                                                   savedTrackingNumber: "TRK-1", expected: day)
        XCTAssertEqual(fields.first { $0.0 == "tracking_number" }?.1, "", "cleared on purpose")
        XCTAssertEqual(fields.first { $0.0 == "estimated_delivery_date" }?.1, "2026-12-03", "a date only, as the column")

        let blank = StoreOrderEdit.trackingFields(carrier: "", trackingURL: "", trackingNumber: "",
                                                  savedTrackingNumber: nil, expected: nil)
        XCTAssertNil(blank.first { $0.0 == "tracking_number" }, "nothing typed and nothing saved: leave it alone")
        XCTAssertNil(blank.first { $0.0 == "estimated_delivery_date" })

        let typed = StoreOrderEdit.trackingFields(carrier: "", trackingURL: "", trackingNumber: " AB123 ",
                                                  savedTrackingNumber: nil, expected: nil)
        XCTAssertEqual(typed.first { $0.0 == "tracking_number" }?.1, "AB123")
        XCTAssertNotNil(StoreOrderEdit.expectedDay(Record(["estimated_delivery": .string("2026-12-04")])), "the older column")
    }

    // MARK: The courier's signature on a store order (GET /api/v2/orders/:uuid/signature)

    func testTheCourierSignatureMeansNobodyIsAskedToSignAgain() throws {
        let body = #"""
        {"success":true,"data":{"signature":null,"can_sign":true,
         "courier_signature":{"uuid":"s-9","signer_name":"Jo Bloggs","signed_at":"2026-11-24T14:05:00Z","captured_by":"Sam Driver",
          "image_url":"/api/v2/orders/o-1/signature/courier/image","courier":"Swift Couriers"}}}
        """#
        let state = try JSONDecoder.opsAPI().decode(Envelope.Standard<ShopOrderSignatureState>.self, from: Data(body.utf8)).data
        XCTAssertEqual(state.courierSignature?.signerName, "Jo Bloggs")
        XCTAssertEqual(state.courierSignature?.courier, "Swift Couriers")
        XCTAssertEqual(state.courierSignature?.imageUrl, "/api/v2/orders/o-1/signature/courier/image")
        XCTAssertFalse(state.needsSignature)

        let older = #"{"success":true,"data":{"signature":null,"can_sign":true,"courier_signature":null}}"#
        let plain = try JSONDecoder.opsAPI().decode(Envelope.Standard<ShopOrderSignatureState>.self, from: Data(older.utf8)).data
        XCTAssertNil(plain.courierSignature)
        XCTAssertTrue(plain.needsSignature, "today's server: the customer can still sign at the counter")
    }

    // MARK: Supplier messages (ShopMessageTemplateQueries.pick)

    func testBuiltInWordingIsAskedForByName() {
        XCTAssertEqual(ShopSupplierMessageSheet.draftTemplate("builtin"), "builtin", "nil would bring back the default instead")
        XCTAssertNil(ShopSupplierMessageSheet.draftTemplate(""), "nothing chosen yet: the supplier's own or the default")
        XCTAssertEqual(ShopSupplierMessageSheet.draftTemplate("t-1"), "t-1")
    }

    // MARK: Shop product form (ShopCatalogQueries.validate_product_doc: sku and name required, both unique)

    func testANewProductWithoutACodeGetsOneMadeFromItsWebAddress() {
        var draft = ShopProductDraft()
        draft.name = "Blue Mug"
        draft.basePrice = "8.50"
        let (body, errors) = draft.payload(isNew: true)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(body?["slug"], .string("blue-mug"))
        XCTAssertEqual(body?["sku"], .string("BLUE-MUG"), "the server refuses a product without a code")

        draft.sku = "MUG-01"
        XCTAssertEqual(draft.payload(isNew: true).body?["sku"], .string("MUG-01"), "a typed code is kept")
    }

    // MARK: Permission gates (what the server checks)

    private func role(_ grants: [String: Set<String>], menu: Set<String> = []) -> PermissionSet {
        PermissionSet(isAdmin: false, isOwner: false, grants: grants, menuKeys: menu)
    }

    func testShopPhotosNeedTheMediaLibrarysCmsOrShopPermission() {
        let shopEditor = ShopPolicy(permissions: role(["shop": ["read", "update"]]))
        XCTAssertTrue(shopEditor.canUploadPhotos, "cms-media.lua: cms.update or shop.update")
        XCTAssertTrue(shopEditor.canBrowseMedia)
        let shopReader = ShopPolicy(permissions: role(["shop": ["read"]]))
        XCTAssertFalse(shopReader.canUploadPhotos)
        XCTAssertTrue(shopReader.canBrowseMedia)
        let contentEditor = ShopPolicy(permissions: role(["cms": ["update"]]))
        XCTAssertTrue(contentEditor.canUploadPhotos)
        XCTAssertFalse(ShopPolicy(permissions: role(["orders": ["manage"]])).canBrowseMedia)
        XCTAssertFalse(ShopPolicy(permissions: role(["shop": ["read"]])).canOpenLeads)
        XCTAssertTrue(ShopPolicy(permissions: role(["crm_leads": ["read"]])).canOpenLeads)
    }

    func testMoneyBackIsShopManage() {
        XCTAssertFalse(ShopPolicy(permissions: role(["shop": ["update"]])).canManage, "refunds, credit, invoiced fees")
        XCTAssertTrue(ShopPolicy(permissions: role(["shop": ["manage"]])).canManage)
        let grant = ModuleCatalog.shopCredits.listActions.first { $0.id == "grant" }
        XCTAssertEqual(grant?.action, .manage, "POST /credits is shop.manage")
        XCTAssertEqual(ModuleCatalog.shopCredits.actions.first { $0.id == "void" }?.action, .update, "voiding stays shop.update")
        XCTAssertEqual(ModuleCatalog.shopMembers.listActions.first { $0.id == "invoiced" }?.action, .manage)
    }

    func testTheStoreSideOfDeliveryIsTheDeliveryRole() {
        let dispatcher = role(["delivery": ["read", "create", "update"]])
        XCTAssertTrue(DeliveryWords.can(.create, dispatcher), "Add a partner / ask a partner")
        XCTAssertTrue(DeliveryWords.can(.update, dispatcher), "answer an offer, withdraw a request, move a delivery")
        XCTAssertFalse(DeliveryWords.can(.delete, dispatcher), "remove a partner")
        XCTAssertFalse(DeliveryWords.can(.read, role(["orders": ["manage"]])))
        XCTAssertTrue(DeliveryWords.can(.delete, role(["delivery": ["manage"]])))
        XCTAssertEqual(DeliveryWords.ownerMoves(from: "accepted").map(\.status), ["cancelled"], "the table allows it now")
    }

    func testTheStoreWithdrawsItsOwnRequest() async throws {
        let seen = Counter()
        let client = await client { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Namespace-Id"), "ns", "the store's workspace decides")
            seen.increment(request.url!.path)
            return .json(200, #"{"message":"Request cancelled successfully"}"#)
        }
        try await DeliveryAPI(client: client).withdraw(request: "dr-9")
        XCTAssertEqual(seen.value("/api/v2/delivery-requests/dr-9/cancel"), 1)
    }

    func testMarketingScreensNeedTheirOwnReadPermission() {
        let writer = role([Marketing.RBAC.campaigns: ["manage"], Marketing.RBAC.templates: ["read"]])
        XCTAssertTrue(Marketing.canOpen(Marketing.Screen.campaigns, writer))
        XCTAssertTrue(Marketing.canOpen(Marketing.Screen.studio, writer))
        XCTAssertFalse(Marketing.canOpen(Marketing.Screen.conversations, writer), "replies are conversations.read")
        XCTAssertFalse(Marketing.canOpen(Marketing.Screen.pixels, writer), "pixels are analytics.read")
        XCTAssertFalse(Marketing.canOpen(Marketing.Screen.settings, writer))
        XCTAssertTrue(Marketing.canOpen(Marketing.Screen.guide, writer), "the guide calls nothing")
    }

    func testTheAuthorOfACampaignIsNotOfferedApproval() {
        let campaign = MktCampaign(Record(["uuid": .string("c-1"), "created_by": .string("u-me"), "status": .string("awaiting_approval")]))
        XCTAssertTrue(MktCamp.isAuthor(campaign, me: "u-me"))
        XCTAssertFalse(MktCamp.isAuthor(campaign, me: "u-other"))
        XCTAssertTrue(MktCamp.waitsForSomeoneElse(.awaitingApproval, campaign, me: "u-me", canManage: true))
        XCTAssertFalse(MktCamp.waitsForSomeoneElse(.awaitingApproval, campaign, me: "u-other", canManage: true))
        XCTAssertFalse(MktCamp.isAuthor(MktCampaign(Record(["uuid": .string("c-2")])), me: "u-me"), "no author recorded")
    }

    func testConvertingALeadNeedsDealCreateToo() {
        let workable = LeadPermissions(canWork: true, isManager: false, canAssignAny: false, canConvert: true)
        let seller = role(["crm_leads": ["read", "update"], "crm_deals": ["create"]])
        let leadsOnly = role(["crm_leads": ["manage"]])
        XCTAssertTrue(LeadPermissions.showsConvert(workable, seller))
        XCTAssertFalse(LeadPermissions.showsConvert(workable, leadsOnly), "crm-leads.lua convert: crm_deals.create as well")
        XCTAssertFalse(LeadPermissions.showsConvert(LeadPermissions(canWork: false, canConvert: true), seller),
                       "someone else's lead")
        XCTAssertTrue(LeadPermissions.showsConvert(nil, seller), "an older server without the lead's own permissions")
    }

    func testTheShopOrderListFilterWordsReadNaturally() {
        XCTAssertEqual(ShopOrderListFilter.placedDays(1).label, "Placed in the last day")
        XCTAssertEqual(ShopOrderListFilter.placedDays(30).label, "Placed in the last 30 days")
        var q = QueryBuilder()
        ShopOrderListFilter.paidDays(30).add(to: &q)
        XCTAssertEqual(q.items.first?.name, "paid_days", "the web's ?paid_days=30")
    }

    func testAHandOverReadsAsSuchInTheOrderHistory() {
        let entry = Record(["action": .string("status_change"), "previous_status": .string("processing"),
                            "new_status": .string("processing"), "old_fulfillment_status": .string("unfulfilled"),
                            "new_fulfillment_status": .string("fulfilled")])
        XCTAssertEqual(StoreOrderDetailView.historyLine(entry), "Handed over")
    }
}
