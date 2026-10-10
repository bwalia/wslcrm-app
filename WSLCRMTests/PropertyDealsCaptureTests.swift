import XCTest
@testable import WSLCRM

/// Property Deals Phase 4: quick capture as one chained, resumable offline write.
final class PropertyDealsCaptureTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("queue.json") }
    private var uploads: URL { directory.appendingPathComponent("uploads") }
    private let context = MutationContext(namespaceId: "ns", userId: "u1")
    private let base = "/api/v2/property-deals"

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func draft(photos: [String] = []) -> PDCaptureDraft {
        var draft = PDCaptureDraft()
        draft.firstName = "Pat"
        draft.lastName = "Probate"
        draft.phone = "07700 900123"
        draft.situation = .probate
        draft.vulnerable = true
        draft.vulnerabilityNote = "Recently bereaved"
        draft.notes = "Wants to sell before the winter."
        draft.addressLine1 = "7 Mill Lane"
        draft.town = "York"
        draft.postcode = "yo1 7aa"
        draft.latitude = 53.9576
        draft.longitude = -1.0827
        draft.photoFiles = photos
        return draft
    }

    private func json(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    // MARK: Building the chain

    func testLeadAndPropertyWithPhotosBecomeOneOrderedChain() throws {
        let mutation = PropertyDealsAPI.Mutations.capture(draft(photos: ["a.jpg", "b.jpg"]), context: context)
        let steps = try XCTUnwrap(mutation.steps)
        XCTAssertEqual(mutation.kind, .pdCapture)
        XCTAssertEqual(steps.map(\.label), ["Seller lead", "Seller details", "Property", "Link seller to property",
                                            "Photo 1 of 2", "Photo 2 of 2"])
        XCTAssertEqual(steps.map(\.path), ["/api/v2/crm/leads", "\(base)/leads/{{lead}}/details", "\(base)/properties",
                                           "\(base)/leads/{{lead}}/details", "\(base)/documents", "\(base)/documents"])
        XCTAssertEqual(steps[0].captures, "lead")
        XCTAssertEqual(steps[2].captures, "property")
        XCTAssertEqual(Set(steps.map(\.idempotencyKey)).count, steps.count, "every step has its own key")

        let lead = json(steps[0].body)
        XCTAssertEqual(lead["first_name"] as? String, "Pat")
        XCTAssertEqual(lead["notes"] as? String, "Wants to sell before the winter.", "the voice-note transcript goes in notes")
        let details = json(steps[1].body)
        XCTAssertEqual(details["lead_kind"] as? String, "seller")
        XCTAssertEqual(details["situation"] as? String, "probate")
        XCTAssertEqual(details["vulnerability_flag"] as? Bool, true)
        let property = json(steps[2].body)
        XCTAssertEqual(property["postcode"] as? String, "YO1 7AA")
        XCTAssertEqual(property["lat"] as? Double, 53.9576)
        XCTAssertEqual(json(steps[3].body)["property_uuid"] as? String, "{{property}}")
        XCTAssertEqual(steps[4].upload?.fields, [["property_uuid", "{{property}}"], ["category", "photo"]])
    }

    func testPropertyOnlyHasNoLeadSteps() throws {
        var draft = draft(photos: ["a.jpg"])
        draft.includeLead = false
        let steps = try XCTUnwrap(PropertyDealsAPI.Mutations.capture(draft, context: context).steps)
        XCTAssertEqual(steps.map(\.label), ["Property", "Photo 1 of 1"])
    }

    func testLeadOnlyHasNoPropertyOrPhotos() throws {
        var draft = draft(photos: ["a.jpg"])
        draft.includeProperty = false
        let steps = try XCTUnwrap(PropertyDealsAPI.Mutations.capture(draft, context: context).steps)
        XCTAssertEqual(steps.map(\.label), ["Seller lead", "Seller details"])
    }

    func testWhatStopsASave() {
        var draft = PDCaptureDraft()
        XCTAssertEqual(draft.problem, "Add the seller's first name.")
        draft.firstName = "Pat"
        XCTAssertEqual(draft.problem, "Add the address, or use your location.")
        draft.latitude = 53.9
        draft.longitude = -1.0
        XCTAssertNil(draft.problem, "a GPS pin is enough for a property")
        draft.vulnerable = true
        XCTAssertEqual(draft.problem, "Say briefly why they may be vulnerable.")
        draft.includeLead = false
        draft.includeProperty = false
        XCTAssertEqual(draft.problem, "Choose a seller, a property or both.")
    }

    // MARK: Replaying the chain

    private func scriptHappyPath(_ sender: FakeSender) async {
        await sender.scriptStep("POST /api/v2/crm/leads", [.success(#"{"uuid":"lead-1","first_name":"Pat"}"#)])
        await sender.scriptStep("POST \(base)/properties", [.success(#"{"success":true,"data":{"uuid":"prop-1"}}"#)])
    }

    func testChainSendsInOrderWithCapturedIdsAndCleansUpPhotos() async throws {
        let photo = try PendingUploads.store(Data("jpeg-bytes".utf8), ext: "jpg", in: uploads)
        let sender = FakeSender()
        await scriptHappyPath(sender)
        let queue = MutationQueue(fileURL: fileURL, sender: sender, uploadsDirectory: uploads)
        await queue.enqueue(PropertyDealsAPI.Mutations.capture(draft(photos: [photo]), context: context))

        let outcome = await queue.replay(forUser: "u1")
        XCTAssertEqual(outcome, .completed(sent: 1, failed: 0))
        let sent = await sender.stepsSent
        XCTAssertEqual(sent.map(\.path), ["/api/v2/crm/leads", "\(base)/leads/lead-1/details", "\(base)/properties",
                                          "\(base)/leads/lead-1/details", "\(base)/documents"])
        XCTAssertEqual(String(decoding: sent[3].body ?? Data(), as: UTF8.self), #"{"property_uuid":"prop-1"}"#)
        let upload = String(decoding: sent[4].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(upload.contains("prop-1") && upload.contains("jpeg-bytes") && upload.contains("name=\"file\""))
        XCTAssertTrue(sent.allSatisfy { $0.headers["Idempotency-Key"] != nil }, "every step carries its key")
        XCTAssertEqual(sent.map(\.namespaceOverride), Array(repeating: "ns", count: 5), "replayed in its own workspace")
        let isEmpty = await queue.all.isEmpty
        XCTAssertTrue(isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploads.appendingPathComponent(photo).path),
                       "the photo is deleted once uploaded")
    }

    /// Signal drops after the lead and its details are saved: the next replay (even after the app
    /// restarts) starts at the property, reusing the lead id and the same idempotency keys.
    func testLosingSignalMidwayResumesWhereItStopped() async throws {
        let sender = FakeSender()
        await scriptHappyPath(sender)
        await sender.scriptStep("POST \(base)/properties",
                                [.failure(.offline(URLError(.notConnectedToInternet))), .success(#"{"data":{"uuid":"prop-1"}}"#)])
        let queue = MutationQueue(fileURL: fileURL, sender: sender, uploadsDirectory: uploads)
        let mutation = PropertyDealsAPI.Mutations.capture(draft(), context: context)
        let propertyKey = try XCTUnwrap(mutation.steps?[2].idempotencyKey)
        await queue.enqueue(mutation)

        let first = await queue.replay(forUser: "u1")
        XCTAssertEqual(first, .interrupted(sent: 0))
        let all = await queue.all
        let stored = try XCTUnwrap(all.first)
        XCTAssertEqual(stored.results?["lead"], "lead-1", "the lead id is saved as soon as it arrives")
        XCTAssertEqual(stored.steps?.map(\.done), [true, true, false, false])

        let relaunched = MutationQueue(fileURL: fileURL, sender: sender, uploadsDirectory: uploads)
        let second = await relaunched.replay(forUser: "u1")
        XCTAssertEqual(second, .completed(sent: 1, failed: 0))
        let sent = await sender.stepsSent.map(\.path)
        XCTAssertEqual(sent.filter { $0 == "/api/v2/crm/leads" }.count, 1, "the lead is never created twice")
        let property = await sender.stepsSent.first { $0.path == "\(base)/properties" }
        XCTAssertEqual(property?.headers["Idempotency-Key"], propertyKey, "same key on the retry")
    }

    func testARejectedStepIsShownWithItsNameAndKept() async throws {
        let sender = FakeSender()
        await scriptHappyPath(sender)
        let invalid = ServerError(status: 422, message: "Validation failed", fieldErrors: ["postcode": "is not a UK postcode"],
                                  rawBody: "")
        await sender.scriptStep("POST \(base)/properties", [.failure(.validation(invalid))])
        let queue = MutationQueue(fileURL: fileURL, sender: sender, uploadsDirectory: uploads)
        await queue.enqueue(PropertyDealsAPI.Mutations.capture(draft(), context: context))

        let outcome = await queue.replay(forUser: "u1")
        XCTAssertEqual(outcome, .completed(sent: 0, failed: 1))
        let all = await queue.all
        let stored = try XCTUnwrap(all.first)
        guard case .failed(let message, let status) = stored.state else { return XCTFail("expected failed") }
        XCTAssertEqual(status, 422)
        XCTAssertTrue(message.hasPrefix("Property:"), message)
        XCTAssertEqual(stored.steps?.filter(\.done).count, 2, "the lead stays created; a retry starts at the property")
    }

    func testAMissingIdFailsTheChainInsteadOfGuessing() async throws {
        let sender = FakeSender()
        await sender.scriptStep("POST /api/v2/crm/leads", [.success(#"{"success":true,"data":{}}"#)])
        let queue = MutationQueue(fileURL: fileURL, sender: sender, uploadsDirectory: uploads)
        await queue.enqueue(PropertyDealsAPI.Mutations.capture(draft(), context: context))
        _ = await queue.replay(forUser: "u1")
        let all = await queue.all
        let stored = try XCTUnwrap(all.first)
        XCTAssertTrue(stored.isFailed, "no lead id: the details step must not run")
        let sent = await sender.stepsSent.map(\.path)
        XCTAssertEqual(sent, ["/api/v2/crm/leads"])
    }

    func testDiscardingACaptureDeletesItsPhotos() async throws {
        let photo = try PendingUploads.store(Data("x".utf8), ext: "jpg", in: uploads)
        let queue = MutationQueue(fileURL: fileURL, sender: FakeSender(), uploadsDirectory: uploads)
        let mutation = PropertyDealsAPI.Mutations.capture(draft(photos: [photo]), context: context)
        await queue.enqueue(mutation)
        await queue.discard(id: mutation.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploads.appendingPathComponent(photo).path))
    }

    func testQueueFilesSavedBeforeChainsStillLoad() throws {
        let old = #"""
        [{"id":"7D0C1B7E-1A3B-4C59-9E5F-000000000001","kind":"pdTaskNote","method":"POST","path":"/x","namespaceId":"ns",
          "userId":"u1","entityId":"t1","summary":"Note","hints":{},"createdAt":700000000,"attempts":0,"state":{"pending":{}}}]
        """#
        let items = try JSONDecoder().decode([PendingMutation].self, from: Data(old.utf8))
        XCTAssertEqual(items.first?.kind, .pdTaskNote)
        XCTAssertNil(items.first?.steps)
        XCTAssertNil(items.first?.idempotencyKey)
    }

    func testNotesAndContactLogsCarryAnIdempotencyKey() {
        let task = PDTaskRef(uuid: "t1", title: "Chase", dealUuid: "d1")
        let note = PropertyDealsAPI.Mutations.note(task, text: "Called", context: context)
        XCTAssertNotNil(note.endpoint.headers["Idempotency-Key"])
        let log = PropertyDealsAPI.Mutations.contactLog(task, body: PDChaseBody(dealUuid: "d1", taskUuid: "t1", toParty: "seller",
                                                                                toName: "Pat", toAddress: nil, channel: "phone",
                                                                                subject: nil, sentAt: Date()),
                                                        context: context)
        XCTAssertNotNil(log.endpoint.headers["Idempotency-Key"])
    }

    func testUUIDIsFoundInEachResponseShape() {
        XCTAssertEqual(MutationQueue.uuid(in: Data(#"{"success":true,"data":{"uuid":"a"}}"#.utf8)), "a")
        XCTAssertEqual(MutationQueue.uuid(in: Data(#"{"uuid":"b"}"#.utf8)), "b")
        XCTAssertEqual(MutationQueue.uuid(in: Data(#"{"data":{"lead":{"uuid":"c"}}}"#.utf8)), "c")
        XCTAssertNil(MutationQueue.uuid(in: Data(#"{"data":{}}"#.utf8)))
    }
}
