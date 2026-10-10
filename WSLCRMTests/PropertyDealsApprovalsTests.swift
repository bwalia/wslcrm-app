import XCTest
@testable import WSLCRM

/// Property Deals Phase 3: approvals, push registration and deep links.
final class PropertyDealsApprovalsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.opsAPI().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func api(_ handler: @escaping StubURLProtocol.Handler) async -> PropertyDealsAPI {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        let cache = ResponseCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return PropertyDealsAPI(client: client, cache: cache)
    }

    static let inboxItem = """
    { "uuid": "a1", "title": "Chase seller's solicitor", "subject_type": "chase", "action": "send_email",
      "rule": "any_operator", "status": "pending",
      "payload": { "to": "conveyancing@harrow-co.example", "subject": "7 Mill Lane", "body": "Dear Harrow & Co", "attempt": 2 },
      "payload_version": 1, "deal_uuid": "d1", "deal_name": "7 Mill Lane", "agent_key": "legal_chaser",
      "provider": "local", "model": "llama3.1:8b", "cost_usd": 0.0, "from_jobshout": false,
      "run_sources": [ { "kind": "chase", "title": "Last chase 50 hours ago" }, "https://example.com/enquiries" ],
      "can_decide": true, "decisions": {} }
    """

    // MARK: Decoding

    func testInboxItemFromTheContractExample() throws {
        let inbox = try decode(Envelope.Standard<LossyArray<PDApproval>>.self,
                               #"{ "success": true, "data": [\#(Self.inboxItem)] }"#).data.elements
        let approval = try XCTUnwrap(inbox.first)
        XCTAssertEqual(approval.rule, .anyOperator)
        XCTAssertEqual(approval.status, .pending)
        XCTAssertEqual(approval.decisions, [], "an empty JSONB list arriving as {} decodes as no decisions")
        XCTAssertTrue(approval.isLocalModel)
        XCTAssertNil(approval.originalPayload, "nulls are left out")
        XCTAssertEqual(PDApprovalSource.list(from: approval.runSources).map(\.title),
                       ["Last chase 50 hours ago", "https://example.com/enquiries"])
        XCTAssertNotNil(PDApprovalSource.list(from: approval.runSources).last?.url)
    }

    func testUnknownRuleAndStatusDontBreakTheInbox() throws {
        let approval = try decode(PDApproval.self, #"{ "uuid": "a", "title": "T", "rule": "board", "status": "escalated" }"#)
        XCTAssertEqual(approval.rule, .unknown)
        XCTAssertEqual(approval.status, .unknown)
    }

    // MARK: Decide body

    func testApproveAsIsSendsOnlyTheDecision() throws {
        let body = try encode(PDDecideBody(decision: .approve))
        XCTAssertEqual(body as NSDictionary, ["decision": "approve"])
    }

    func testApproveEditedSendsTheWholeEditedPayloadWithItsOriginalKeys() throws {
        let approval = try decode(PDApproval.self, Self.inboxItem)
        var draft = PDApprovalDraft(payload: approval.payload)
        XCTAssertEqual(draft.fields.map(\.key), ["to", "subject", "body"], "string fields only, email order")
        XCTAssertFalse(draft.isEdited)
        draft.fields[2].value = "Dear Harrow & Co, please reply by 3pm."
        XCTAssertTrue(draft.isEdited)

        let body = try encode(PDDecideBody(decision: .approve, note: "Added a deadline", payload: draft.payload))
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["body"] as? String, "Dear Harrow & Co, please reply by 3pm.")
        XCTAssertEqual(payload["attempt"] as? Int, 2, "non-text values are carried through untouched")
        XCTAssertEqual(payload["to"] as? String, "conveyancing@harrow-co.example")
        XCTAssertEqual(body["note"] as? String, "Added a deadline")
    }

    func testDecideCarriesTheVersionThatWasShown() throws {
        let body = try encode(PDDecideBody(decision: .approve, payloadVersion: 3))
        XCTAssertEqual(body as NSDictionary, ["decision": "approve", "payload_version": 3])
    }

    func testWhatHappenedAfterApproval() throws {
        let sent = try decode(PDApproval.self, #"""
        { "uuid": "a", "title": "T", "rule": "any_operator", "status": "executed", "action": "send_email",
          "execution_result": { "chase_uuid": "c1", "sent_to": "sol@firm.example" } }
        """#)
        XCTAssertEqual(PDApprovalExecution(sent)?.text, "Sent to sol@firm.example.")
        XCTAssertEqual(PDApprovalExecution(sent)?.failed, false)
        let failed = try decode(PDApproval.self, #"""
        { "uuid": "a", "title": "T", "rule": "any_operator", "status": "failed", "action": "send_email",
          "execution_result": { "error": "no email server configured" } }
        """#)
        XCTAssertEqual(PDApprovalExecution(failed)?.failed, true)
        XCTAssertTrue(PDApprovalExecution(failed)?.text.contains("no email server configured") ?? false)
        let v1 = try decode(PDApproval.self, #"{ "uuid": "a", "title": "T", "rule": "manager", "status": "approved", "action": "confirm_booking" }"#)
        XCTAssertNil(PDApprovalExecution(v1), "v1 servers stop at approved: nothing more to say")
    }

    func testNotificationPreferenceChangesSendOnlyWhatChanged() throws {
        let body = try encode(PDNotificationPreferences.push(false, for: .approvalRequested))
        XCTAssertEqual(body as NSDictionary, ["approval_requested": ["push": false]])
        let prefs = try decode(PDNotificationPreferences.self, #"""
        { "sla_warning": { "push": true, "email": false }, "overdue": { "push": false, "email": false },
          "agent_update": { "push": true, "email": false }, "quiet_hours": { "from": "21:00", "to": "07:00" } }
        """#)
        XCTAssertEqual(prefs[.overdue]?.push, false)
        XCTAssertEqual(prefs.quietHours?.from, "21:00")
        XCTAssertNil(prefs[.digest], "missing categories show as on (the server's default)")
    }

    func testTurningQuietHoursOffSendsNull() async throws {
        let sent = Counter()
        let api = await api { request in
            if let body = request.jsonBody, body.keys.contains("quiet_hours"), body["quiet_hours"] is NSNull {
                sent.increment("null")
            }
            return .json(200, #"{ "success": true, "data": {} }"#)
        }
        _ = try await api.setQuietHours(nil)
        XCTAssertEqual(sent.value("null"), 1, "null clears quiet hours on the server")
    }

    func testRejectCarriesTheReasonAndNoPayload() throws {
        let body = try encode(PDDecideBody(decision: .reject, note: "Wrong solicitor"))
        XCTAssertEqual(body as NSDictionary, ["decision": "reject", "note": "Wrong solicitor"])
    }

    func testDraftLabels() {
        XCTAssertEqual(PDApprovalDraft.label("to_party"), "To party")
        XCTAssertEqual(PDApprovalDraft.label("toName"), "To name")
        XCTAssertEqual(PDApprovalDraft.label("subject"), "Subject")
    }

    // MARK: Approvals are never queued

    /// The iOS rule: an approval is sent while the approver is looking at it, or not at all.
    func testDecideGoesStraightToTheServerAndIsNotAQueueableKind() async throws {
        let sent = Counter()
        let api = await api { request in
            sent.increment("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return .json(200, #"{ "success": true, "data": { "uuid": "a1", "title": "T", "rule": "any_operator", "status": "approved" } }"#)
        }
        let result = try await api.decide("a1", PDDecideBody(decision: .approve))
        XCTAssertEqual(result.status, .approved)
        XCTAssertEqual(sent.value("POST /api/v2/property-deals/approvals/a1/decide"), 1)

        let kinds: [PendingMutation.Kind] = [.pdTaskComplete, .pdTaskSnooze, .pdTaskNote, .pdChecklistToggle, .pdContactLog]
        XCTAssertFalse(kinds.contains { $0.rawValue.lowercased().contains("approv") })
        XCTAssertNil(PendingMutation.Kind(rawValue: "pdApprovalDecide"), "there is no queued approval kind")
    }

    func testDecideOfflineFailsInsteadOfQueueing() async {
        let api = await api { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await api.decide("a1", PDDecideBody(decision: .approve))
            XCTFail("an offline approval must fail, not be kept for later")
        } catch {
            XCTAssertTrue(error.asAPIError.isConnectivityProblem)
            XCTAssertTrue(PDApprovalDetailView.describe(error.asAPIError).contains("nothing was sent"))
        }
    }

    func testAlreadyDecidedIsExplained() async {
        let api = await api { _ in .json(409, #"{ "success": false, "error": "Already approved" }"#) }
        do {
            _ = try await api.decide("a1", PDDecideBody(decision: .approve))
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(PDApprovalDetailView.describe(error.asAPIError), "Already approved. Nothing more was sent.")
        }
    }

    func testCurrentApprovalReadsFreshAndIsNilOnceDecided() async throws {
        let reads = Counter()
        let api = await api { _ in
            reads.increment("inbox")
            return .json(200, #"{ "success": true, "data": [] }"#)
        }
        let current = try await api.currentApproval("a1")
        XCTAssertNil(current, "no longer waiting for me: someone decided it")
        XCTAssertEqual(reads.value("inbox"), 1)
    }

    // MARK: Push registration

    func testDeviceTokenRegistrationMatchesTheServerContract() throws {
        let body = try encode(DeviceTokensAPI.Registration(token: "ab12", apnsEnvironment: "production",
                                                           bundleId: "uk.co.workstation.wslcrm", deviceName: "Sam's iPhone"))
        XCTAssertEqual(body as NSDictionary, ["token": "ab12", "token_type": "apns", "apns_environment": "production",
                                              "bundle_id": "uk.co.workstation.wslcrm", "device_name": "Sam's iPhone"])
    }

    func testDeviceTokenIsSentWithoutAWorkspaceHeader() async throws {
        let headers = Counter()
        let session = StubURLProtocol.session { request in
            if request.value(forHTTPHeaderField: "X-Namespace-Id") == nil { headers.increment("no-namespace") }
            return .json(201, #"{ "message": "ok", "data": {} }"#)
        }
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: session,
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        try await DeviceTokensAPI(client: client).register(.init(token: "ab12", apnsEnvironment: "development",
                                                                 bundleId: "b", deviceName: "d"))
        XCTAssertEqual(headers.value("no-namespace"), 1, "a device token belongs to the person, not one workspace")
    }

    // MARK: Deep links

    func testPushPayloadsRouteToTheirScreens() {
        let base: [AnyHashable: Any] = ["namespace_id": "ns-2", "plugin": "property_deals", "event": "overdue"]
        func link(_ extra: [AnyHashable: Any]) -> AppDeepLink? { AppDeepLink(userInfo: base.merging(extra) { $1 }) }

        XCTAssertEqual(link(["route": "task", "uuid": "t1"])?.target, .task("t1"))
        XCTAssertEqual(link(["route": "approval", "uuid": "a1"])?.target, .approval("a1"))
        XCTAssertEqual(link(["route": "deal", "uuid": "d1"])?.target, .deal("d1"))
        XCTAssertEqual(link(["route": "digest"])?.target, .today)
        XCTAssertEqual(link(["route": "task", "uuid": "t1"])?.namespaceId, "ns-2")
        XCTAssertNil(link(["route": "task"]), "a task push without a uuid isn't routable")
        XCTAssertNil(link(["route": "invoice", "uuid": "i1"]))
    }

    func testCustomSchemeLinks() throws {
        let link = try XCTUnwrap(AppDeepLink(url: URL(string: "wslcrm://pd/approval/a1?namespace_id=ns-2")!))
        XCTAssertEqual(link.target, .approval("a1"))
        XCTAssertEqual(link.namespaceId, "ns-2")
        XCTAssertEqual(AppDeepLink(url: URL(string: "wslcrm://pd/digest")!)?.target, .today)
        XCTAssertNil(AppDeepLink(url: URL(string: "https://pd/task/t1")!))
        XCTAssertNil(AppDeepLink(url: URL(string: "wslcrm://shop/order/o1")!))
    }

    func testLinksSwitchWorkspaceFirstAndIgnoreForeignOnes() {
        let current = Workspace(uuid: "ns-1", name: "Demo Buyers Ltd")
        let other = Workspace(uuid: "ns-2", name: "North Lettings")
        let workspaces = [current, other]
        func resolve(_ namespace: String?) -> DeepLinkResolution {
            DeepLinkResolver.resolve(AppDeepLink(namespaceId: namespace, target: .task("t1")),
                                     currentWorkspaceId: current.uuid, workspaces: workspaces)
        }
        XCTAssertEqual(resolve("ns-1"), .open)
        XCTAssertEqual(resolve(nil), .open, "no workspace in the link: open where we are")
        XCTAssertEqual(resolve("ns-2"), .switchWorkspace(other))
        XCTAssertEqual(resolve("ns-9"), .ignore, "not a member: never open another tenant's data")
    }

    @MainActor
    func testRouterKeepsTheLinkUntilItIsOpened() {
        let router = DeepLinkRouter()
        router.open(URL(string: "wslcrm://pd/task/t1")!)
        XCTAssertEqual(router.pending?.target, .task("t1"))
        router.open(URL(string: "https://example.com")!)
        XCTAssertEqual(router.pending?.target, .task("t1"), "an unrelated URL doesn't replace it")
        router.clear()
        XCTAssertNil(router.pending)
    }

    func testAPNSEnvironmentDefaultsToTheSandbox() {
        XCTAssertEqual(PushCenter.environment(from: Bundle(for: Self.self)), "development")
    }
}
