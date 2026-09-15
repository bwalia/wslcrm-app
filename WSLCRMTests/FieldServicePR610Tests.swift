import XCTest
@testable import WSLCRM

/// Models and helpers added for opsapi #610 (sites, photos, quote lines, F-Gas, assign → visit).
final class FieldServicePR610Tests: XCTestCase {
    private func payload<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        let root = try JSONSerialization.jsonObject(with: Fixture.data("fs_pr610_payloads")) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: root[key]!)
        return try JSONDecoder.opsAPI().decode(T.self, from: data)
    }

    func testSiteDecodesWithTimestamptzOffsets() throws {
        let site = try payload("site", as: FsSite.self)
        XCTAssertEqual(site.name, "St Mary's — Ward 5")
        XCTAssertEqual(site.displayAddress, "Praed Street, London, W2 1NY")
        XCTAssertEqual(site.accessNotes, "Gate B, ask estates for keys")
        XCTAssertEqual(site.jobCount, 2)
        // fs_sites / fs_job_photos use TIMESTAMPTZ, which Postgres renders with a "+00" suffix.
        XCTAssertNotNil(APIDate.parse("2026-09-15 13:20:01.402113+00"))
        XCTAssertEqual(APIDate.parse("2026-09-15 13:20:01+00"), APIDate.parse("2026-09-15T13:20:01Z"))
    }

    func testPhotoURLIsPresigned() throws {
        let photo = try payload("photo", as: FsJobPhoto.self)
        XCTAssertEqual(photo.url?.host, "127.0.0.1")
        XCTAssertTrue(photo.url?.query?.contains("X-Amz-Signature") ?? false)
        XCTAssertNotNil(photo.createdAt)
    }

    func testQuoteLinesDecodeAndSummariseWithoutPrices() throws {
        let items = try payload("items", as: [JobItem].self)
        XCTAssertEqual(items[0].labourCategory, .engineerNT)
        XCTAssertEqual(items[0].days, 2)
        XCTAssertEqual(items[0].quoteSummary, "Engineer — normal time · 9h · 2d")
        XCTAssertTrue(items[1].isMaterial)
        XCTAssertEqual(items[1].partNumber, "A471Y18")
        XCTAssertEqual(items[1].quoteSummary, "1× Compressor · Daikin")
        XCTAssertTrue(items[2].isHire)
        XCTAssertEqual(items[2].quoteSummary, "Genie lift · 3d · HSS")
        for item in items { XCTAssertFalse(item.quoteSummary.contains("£"), "Engineer summaries never show prices") }
    }

    func testVisitCarriesSiteAndFGas() throws {
        let detail = try payload("visit", as: VisitDetail.self)
        XCTAssertEqual(detail.visit.siteName, "St Mary's — Ward 5")
        XCTAssertEqual(detail.visit.siteAccessNotes, "Gate B, ask estates for keys")
        XCTAssertTrue(detail.visit.hasFGasRecord)
        XCTAssertEqual(detail.visit.refrigerantAddedKg, Decimal(string: "1.25"))
        XCTAssertEqual(detail.visit.leakCheckResult, "pass")
        XCTAssertTrue(detail.visit.isUrgent)
    }

    func testJobFallsBackToSiteAddressAndShowsInvoice() throws {
        let job = try payload("job", as: Job.self)
        XCTAssertEqual(job.fullAddress, "Praed Street, London, W2 1NY", "No service address → the site's address")
        XCTAssertEqual(job.invoiceNumber, "INV-0003")
        XCTAssertEqual(InvoiceStatus(api: job.invoiceStatus), .draft)
    }

    func testServiceRequestSiteAndConvertResult() throws {
        let request = try payload("request", as: ServiceRequest.self)
        XCTAssertEqual(request.siteUuid, "s1000000-0000-0000-0000-000000000001")
        XCTAssertEqual(request.productRef, "SN-99812")
        let result = try payload("convert", as: ConvertToJobResult.self)
        XCTAssertTrue(result.engineerAssigned)
        XCTAssertEqual(result.visitUuid, "v1")
    }

    func testNotificationsResponse() throws {
        let response = try payload("notifications", as: NotificationsResponse.self)
        XCTAssertEqual(response.unreadCount, 1)
        XCTAssertEqual(response.notifications.first?.id, "n1")
        XCTAssertEqual(response.notifications.first?.title, "New job assigned")
        XCTAssertFalse(response.notifications.first?.isRead ?? true)
    }

    func testConvertBodyEncodesEngineerAndUTCStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let local = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9, minute: 30))!  // BST
        let body = ConvertToJobBody(title: "AC not cooling", engineerUuid: "u-eng", scheduledStart: local)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as! [String: Any]
        XCTAssertEqual(json["engineer_uuid"] as? String, "u-eng")
        XCTAssertEqual(json["scheduled_start"] as? String, "2026-09-16T08:30:00Z", "Sent as UTC — the API drops offsets")
        XCTAssertNil(json["job_type_uuid"], "nil keys are omitted, never sent as null")
    }

    func testQuoteLineBodyKeys() throws {
        let body = AddJobItemBody(itemType: "hire", description: "Genie lift", quantity: 1, unitPrice: 0, visitUuid: "v1",
                                  days: 3, supplier: "HSS", partNumber: "D152728")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.opsAPI().encode(body)) as! [String: Any]
        XCTAssertEqual(json["item_type"] as? String, "hire")
        XCTAssertEqual(json["part_number"] as? String, "D152728")
        XCTAssertEqual(json["days"] as? Int, 3)
        XCTAssertNil(json["labour_category"])
    }

    func testMultipartBody() {
        let file = Endpoint.FilePart(fieldName: "photo", filename: "a\"b.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let body = Endpoint.multipartBody(fields: [("visit_uuid", "v1")], file: file, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"visit_uuid\"\r\n\r\nv1\r\n"))
        XCTAssertTrue(text.contains("name=\"photo\"; filename=\"ab.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
        let endpoint = Endpoint(.post, "/x").withMultipart(fields: [], file: file, boundary: "B")
        XCTAssertEqual(endpoint.contentType, "multipart/form-data; boundary=B")
    }

    /// Pins the client workaround for opsapi #610 dropping `site_id` on create.
    func testCreateRequestWithSiteLinksSiteWithFollowUpPut() async throws {
        let calls = Counter()
        let session = StubURLProtocol.session { request in
            let body = request.jsonBody ?? [:]
            if request.httpMethod == "POST" {
                calls.increment("post")
                XCTAssertEqual(body["site_uuid"] as? String, "site-1")
                return .json(201, #"{"success":true,"data":{"uuid":"sr1","request_number":"SR-1","title":"T","channel":"phone","priority":"normal","status":"new","metadata":[]}}"#)
            }
            calls.increment("put")
            XCTAssertEqual(request.url?.path, "/api/v2/field-service/service-requests/sr1")
            XCTAssertEqual(body["site_uuid"] as? String, "site-1")
            XCTAssertEqual(body.count, 1, "Only the site link is sent")
            return .json(200, #"{"success":true,"data":{"uuid":"sr1","request_number":"SR-1","title":"T","channel":"phone","priority":"normal","status":"new","site_uuid":"site-1","site_name":"Ward 5","metadata":[]}}"#)
        }
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: session,
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        let api = FieldServiceAPI(client: client, cache: ResponseCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let created = try await api.createServiceRequest(ServiceRequestBody(title: "T", channel: "phone", priority: "normal", siteUuid: "site-1"))
        XCTAssertEqual(created.request.siteName, "Ward 5")
        XCTAssertEqual(calls.value("post"), 1)
        XCTAssertEqual(calls.value("put"), 1)
    }

    func testPhotoCompressionCapsDimensions() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let data = JobPhotosModel.jpeg(from: image)
        XCTAssertNotNil(data)
        let decoded = UIImage(data: data!)!
        XCTAssertEqual(max(decoded.size.width, decoded.size.height), 2048)
    }
}

@MainActor
final class MyWorkBucketingTests: XCTestCase {
    private func visit(_ uuid: String, _ status: String, hoursFromNow: Double, now: Date, priority: String = "normal") throws -> Visit {
        let start = APIDate.string(from: now.addingTimeInterval(hoursFromNow * 3600)).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        let json = #"{"uuid":"\#(uuid)","status":"\#(status)","scheduled_start":"\#(start)","is_billable":true,"follow_up_required":false,"job_uuid":"j-\#(uuid)","job_number":"JOB-\#(uuid)","job_title":"Job \#(uuid)","job_status":"scheduled","job_priority":"\#(priority)"}"#
        return try JSONDecoder.opsAPI().decode(Visit.self, from: Data(json.utf8))
    }

    func testWindowMatchesDashboard() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 14))!
        let window = MyWorkViewModel.window(now: now, calendar: calendar)
        XCTAssertEqual(window.from, calendar.date(from: DateComponents(year: 2026, month: 9, day: 12)))
        XCTAssertEqual(window.to, calendar.date(from: DateComponents(year: 2026, month: 10, day: 6)))
    }

    func testBackgroundRefreshSharesMyWorkCacheKeyAllDay() {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 7, minute: 5, second: 0, of: Date())!
        let evening = calendar.date(bySettingHour: 22, minute: 40, second: 0, of: Date())!
        XCTAssertEqual(MyWorkRefresh.query(now: morning).queryItems, MyWorkRefresh.query(now: evening).queryItems)
        XCTAssertEqual(MyWorkRefresh.query(now: morning).queryItems.first { $0.name == "per_page" }?.value, "200")
    }

    func testOfflinePrefetchCachesOnlyOpenVisits() async throws {
        let calls = Counter()
        let session = StubURLProtocol.session { request in
            calls.increment(request.url?.path ?? "")
            return .json(404, #"{"error":"Not found"}"#)
        }
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: session,
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        await client.setNamespace("ns")
        let api = FieldServiceAPI(client: client, cache: ResponseCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let now = Date()
        let visits = try [visit("a", "scheduled", hoursFromNow: 1, now: now), visit("b", "on_site", hoursFromNow: 0, now: now),
                          visit("c", "completed", hoursFromNow: -2, now: now)]
        await MyWorkRefresh.prefetchForOffline(visits, api: api)
        let base = "/api/v2/field-service"
        for path in ["\(base)/jobs/j-a", "\(base)/jobs/j-b", "\(base)/visits/a", "\(base)/visits/b"] {
            XCTAssertEqual(calls.value(path), 1, path)
        }
        XCTAssertEqual(calls.value("\(base)/jobs/j-c"), 0)
        XCTAssertEqual(calls.value("\(base)/visits/c"), 0)
    }

    func testAssignmentTrackerAnnouncesOnlyNewOpenVisits() throws {
        let now = Date()
        let tracker = AssignmentTracker(userUuid: "test-\(UUID().uuidString)")
        let first = try [visit("a", "scheduled", hoursFromNow: 1, now: now)]
        XCTAssertTrue(tracker.newAssignments(in: first).isEmpty, "Nothing is 'new' before a baseline exists")
        tracker.remember(first)
        let second = try first + [visit("b", "scheduled", hoursFromNow: 2, now: now), visit("c", "completed", hoursFromNow: -1, now: now)]
        XCTAssertEqual(tracker.newAssignments(in: second).map(\.uuid), ["b"])
    }
}
