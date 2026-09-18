import XCTest
@testable import WSLCRM

/// The engineer's part-replacement proposal (opsapi #619): one multipart request carrying the
/// catalogue part, the reason, the catalogue's prices and the mandatory fault photo.
final class PartProposalTests: XCTestCase {
    private func api(session: URLSession) async -> FieldServiceAPI {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: session,
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        return FieldServiceAPI(client: client,
                               cache: ResponseCache(directory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString)))
    }

    /// The shape opsapi actually answers with (captured from int): the pending line and the
    /// photo that justifies it, together under `data`.
    private static let itemJSON = #"""
    {"success":true,"data":{
      "photo":{"uuid":"ph-1","filename":"fault.jpg","url":"https://minio.test/opsapi/fault.jpg",
               "caption":"Fault evidence"},
      "item":{"uuid":"item-1","item_type":"part","description":"Condenser fan motor",
              "part_name":"Condenser fan motor","quantity":1,"unit_price":148.5,"line_total":148.5,
              "approval_status":"pending","invoiced":false}}}
    """#

    func testProposalSendsTheCataloguePartReasonPricesAndPhotoInOneRequest() async throws {
        let captured = Capture()
        let session = StubURLProtocol.session { request in
            captured.path = request.url?.path
            captured.contentType = request.value(forHTTPHeaderField: "Content-Type")
            captured.body = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
            return .json(201, Self.itemJSON)
        }

        let item = try await api(session: session)
            .proposePart(jobUuid: "job-1", partUuid: "part-9", quantity: 2,
                         reason: "  Condenser fan motor seized  ", unitPrice: Decimal(string: "148.50"),
                         taxRate: 20, visitUuid: "visit-3", jpeg: Data("jpeg-bytes".utf8))

        XCTAssertEqual(item.uuid, "item-1")
        XCTAssertEqual(item.approvalStatus, .pending, "a proposal arrives pending, never pre-approved")
        XCTAssertEqual(captured.path, "/api/v2/field-service/jobs/job-1/part-proposals")
        XCTAssertTrue(captured.contentType?.hasPrefix("multipart/form-data; boundary=") == true)

        let body = try XCTUnwrap(captured.body)
        XCTAssertTrue(body.contains(#"name="part_uuid""#) && body.contains("part-9"))
        XCTAssertTrue(body.contains(#"name="quantity""#) && body.contains("\r\n2\r\n"))
        XCTAssertTrue(body.contains("Condenser fan motor seized"))
        XCTAssertFalse(body.contains("  Condenser fan motor seized  "), "the reason is trimmed")
        XCTAssertTrue(body.contains(#"name="unit_price""#) && body.contains("148.5"))
        XCTAssertTrue(body.contains(#"name="tax_rate""#) && body.contains("\r\n20\r\n"))
        XCTAssertTrue(body.contains(#"name="visit_uuid""#) && body.contains("visit-3"))
        XCTAssertTrue(body.contains(#"name="photo"; filename="fault-"#))
        XCTAssertTrue(body.contains("jpeg-bytes"), "the evidence travels with the proposal")
    }

    func testAnOversizedPhotoIsRefusedBeforeItIsUploaded() async {
        let reached = Counter()
        let session = StubURLProtocol.session { _ in
            reached.increment("request")
            return .json(201, Self.itemJSON)
        }

        do {
            _ = try await api(session: session)
                .proposePart(jobUuid: "job-1", partUuid: "part-9", quantity: 1, reason: "Seized",
                             unitPrice: 10, taxRate: 20, visitUuid: nil,
                             jpeg: Data(count: 11 * 1024 * 1024))
            XCTFail("an 11 MB photo should not be sent")
        } catch let error as APIError {
            XCTAssertTrue(error.localizedDescription.contains("too large"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(reached.value("request"), 0, "nothing leaves the device")
    }

    func testEvidenceIsFetchedForTheItemBeingApproved() async throws {
        let captured = Capture()
        let session = StubURLProtocol.session { request in
            captured.path = request.url?.path
            return .json(200, #"""
            {"success":true,"data":[{"uuid":"ph-1","url":"https://minio.test/a.jpg","caption":"Seized motor"}]}
            """#)
        }

        let photos = try await api(session: session).itemPhotos(itemUuid: "item-1")

        XCTAssertEqual(captured.path, "/api/v2/field-service/job-items/item-1/photos")
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.caption, "Seized motor")
    }

    /// The price and VAT a proposal sends are the catalogue's, so the model has to carry the rate.
    func testCataloguePartDecodesItsTaxRate() throws {
        let json = #"""
        {"uuid":"p1","name":"Condenser fan motor","sku":"CFM-24","unit_price":"148.50","tax_rate":"20.00",
         "stock_quantity":2,"reorder_level":3,"is_active":true}
        """#
        let part = try JSONDecoder.opsAPI().decode(FsPart.self, from: Data(json.utf8))

        XCTAssertEqual(part.unitPrice, Decimal(string: "148.50"))
        XCTAssertEqual(part.taxRate, 20)
        XCTAssertTrue(part.isLowStock, "2 in stock against a reorder level of 3 is worth flagging while picking")
    }
}

/// Collects what the stub saw, so assertions read in the order the request is built.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String?] = [:]

    var path: String? {
        get { lock.withLock { storage["path"] ?? nil } }
        set { lock.withLock { storage["path"] = newValue } }
    }
    var contentType: String? {
        get { lock.withLock { storage["contentType"] ?? nil } }
        set { lock.withLock { storage["contentType"] = newValue } }
    }
    var body: String? {
        get { lock.withLock { storage["body"] ?? nil } }
        set { lock.withLock { storage["body"] = newValue } }
    }
}
