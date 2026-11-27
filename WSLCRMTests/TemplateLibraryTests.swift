import XCTest
@testable import WSLCRM

/// The templates library, the starter gallery, Invoice and order design and the PDF errors
/// (lapis/routes/document-templates.lua, document-designs.lua, document-pdfs.lua). Fixtures are real responses
/// from a local OpsAPI, trimmed.
@MainActor
final class TemplateLibraryTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    // MARK: Parsing

    func testTheListAndATemplateParse() throws {
        let list = WorkspaceAPI.records(try fixture("templates_list")).map(DocTemplate.init)
        let t = try XCTUnwrap(list.first)
        XCTAssertEqual(t.id, "4b1bc959-d638-46cb-bcf6-8698371ef2ef")
        XCTAssertEqual(t.kind, .invoice)
        XCTAssertEqual(t.name, "Classic invoice")
        XCTAssertEqual(t.version, 1)
        XCTAssertTrue(t.isActive)
        XCTAssertFalse(t.isDefault)
        XCTAssertNotNil(t.updatedAt, "the server's \"2026-11-27 10:20:00.9\" dates read")
        XCTAssertEqual(t.pdfSource?.html, "", "the list has no HTML")

        let full = DocTemplate(try XCTUnwrap(WorkspaceAPI.record(try fixture("templates_detail"))))
        XCTAssertFalse(full.isDesigned, "config is [] (an empty Lua table): not made with the designer")
        let source = try XCTUnwrap(full.pdfSource)
        XCTAssertTrue(source.html.hasPrefix("<div class=\"doc layout-clean\""))
        XCTAssertEqual(source.margins, ["14mm", "18mm", "16mm", "16mm"])
        let body = source.body
        XCTAssertEqual(body["type"], .string("invoice"))
        XCTAssertEqual(body["margin_left"], .string("16mm"))
        XCTAssertNotNil(body["footer_html"], "the page footer prints in the preview too")
        XCTAssertNil(body["header_html"], "an empty part isn't sent")

        let designed = DocTemplate(Record(["uuid": .string("t"), "type": .string("order"),
                                           "config": .object(["builder": BuilderPresets.make("classic", .order).json])]))
        XCTAssertTrue(designed.isDesigned)
        XCTAssertFalse(DocTemplate(Record(["uuid": .string("t"), "type": .string("order"),
                                           "config": .object(["builder": .object(["v": .number(1)])])])).isDesigned,
                       "a page this app can't read opens in the code editor")
        XCTAssertEqual(designed.kind, .order)
        XCTAssertNil(DocTemplate(Record(["uuid": .string("t"), "type": .string("timesheet")])).pdfSource,
                     "a timesheet has no server PDF")
    }

    func testStartersParseWithTheirParts() throws {
        let starters = TemplateStarter.list(try fixture("templates_starters_invoice"), kind: .invoice)
        XCTAssertEqual(starters.map(\.key), ["classic", "modern"])
        XCTAssertEqual(starters.first?.name, "Classic")
        XCTAssertFalse(starters.first?.description.isEmpty ?? true)
        XCTAssertFalse(starters.first?.source.html.isEmpty ?? true)
        XCTAssertNotNil(starters.first?.source.css)
        XCTAssertNotNil(starters.first?.source.footerHTML)
        XCTAssertEqual(starters.first?.source.kind, .invoice)
        XCTAssertTrue(TemplateStarter.list(.object(["data": .object(["type": .string("x"), "starters": .array([])])]), kind: .order).isEmpty)
        XCTAssertEqual(starters[0].source.fingerprint, starters[0].source.fingerprint)
    }

    func testVersionsParse() throws {
        let versions = WorkspaceAPI.records(try fixture("templates_versions"))
        XCTAssertEqual(versions.first?.int("version"), 1)
        XCTAssertNotNil(versions.first?.date("created_at"))
    }

    // MARK: Invoice and order design

    func testTheDesignsSayWhatEachKindUses() throws {
        var set = DocumentDesignSet(try fixture("document_designs"))
        XCTAssertEqual(set.kinds, [.invoice, .order])
        XCTAssertFalse(set.usesTemplate(.invoice))
        XCTAssertNil(set.templateUUID(.invoice))
        XCTAssertEqual(set.stamp(.invoice), "standard")
        XCTAssertEqual(set.design(.invoice).billToLabel, "BILLED TO")
        XCTAssertEqual(set.design(.order).title, "ORDER")

        set.designs["invoice"]?["source"] = .string("template")
        set.designs["invoice"]?["template_uuid"] = .string("t-1")
        set.designs["invoice"]?["template_name"] = .string("Classic")
        XCTAssertEqual(set.inUse("t-1"), [.invoice])
        XCTAssertEqual(set.templateName(.invoice), "Classic")
        XCTAssertTrue(set.design(.invoice).usesTemplate)
        XCTAssertEqual(set.design(.invoice).templateName, "Classic")

        XCTAssertEqual(DocumentDesignSet(.object(["data": .object(["invoice": .object([:])])])).kinds, [.invoice],
                       "no shop: invoices only")
    }

    func testChoosingATemplateSendsTheWholeDesign() throws {
        var set = DocumentDesignSet(try fixture("document_designs"))
        set.designs["order"]?["accent"] = .string("#aa0033")
        set.designs["order"]?["logo"] = .string("data:image/png;base64,iVBORw0KGgo=")
        let body = set.choosing(.order, template: "t-9")
        XCTAssertEqual(body["source"], .string("template"))
        XCTAssertEqual(body["template_uuid"], .string("t-9"))
        // The server replaces the whole design on save: everything else must go back as it was.
        XCTAssertEqual(body["accent"], .string("#aa0033"))
        XCTAssertEqual(body["logo"], .string("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertEqual(body["title"], .string("ORDER"))
        XCTAssertNotNil(body["show"]?["delivery_address"])
        let back = DocumentDesignSet(.object(["invoice": body])).choosing(.invoice, template: nil)
        XCTAssertEqual(back["source"], .string("design"))
        XCTAssertEqual(back["template_uuid"], .string("t-9"), "the last template is remembered, as on the web")
    }

    func testUnsavedChangesIgnoreTheServersOwnFields() {
        let saved: [String: JSONValue] = ["style": .string("band"), "is_custom": .bool(true), "updated_at": .string("x"),
                                          "template_name": .string("A"), "logo": .null]
        let draft: [String: JSONValue] = ["style": .string("band")]
        XCTAssertEqual(DocumentLookView.comparable(saved), DocumentLookView.comparable(draft))
        XCTAssertNotEqual(DocumentLookView.comparable(["style": .string("clean")]), DocumentLookView.comparable(draft))
        XCTAssertEqual(DocumentLookView.parts(.invoice).map(\.0).last, "notes")
        XCTAssertTrue(DocumentLookView.parts(.order).map(\.0).contains("delivery_address"))
        XCTAssertFalse(DocumentLookView.parts(.order).map(\.0).contains("notes"), "orders have no notes part (SHOW.order)")
    }

    func testALogoBecomesASmallPNGDataURL() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 600)).image { _ in
            UIColor.systemTeal.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1800, height: 600)).fill()
        }
        let url = try XCTUnwrap(DocumentLookView.logoDataURL(big))
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,iVBORw0KGgo"), "the server checks the first bytes")
        XCTAssertLessThanOrEqual(url.count, 400 * 1024)
        let image = try XCTUnwrap(DocumentDesign.logoData(url).flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size.width, 600)
    }

    func testTheQuickLayoutSampleDrawsBothKinds() throws {
        XCTAssertNotNil(DocumentSamples.invoicePDF(design: .standard(.invoice), company: "Northbridge"))
        XCTAssertNotNil(DocumentSamples.orderPDF(design: .standard(.order), company: nil))
    }

    // MARK: PDF problems

    func testPDFErrorsInPlainWords() {
        func problem(_ status: Int, _ body: String) -> TemplatePDFProblem {
            TemplatePDFProblem(APIError.from(status: status, data: Data(body.utf8), headers: [:]))
        }
        let mistake = problem(422, #"{"code":"TEMPLATE_ERROR","part":"template_html","error":"Line 3: {{ is never closed with }}.","line":3,"success":false}"#)
        XCTAssertEqual(mistake, .mistake("Your template has a mistake on line 3: {{ is never closed with }}.", line: 3))
        XCTAssertEqual(problem(422, #"{"code":"TEMPLATE_ERROR","error":"Page footer, line 2: the if is never closed","success":false}"#),
                       .mistake("Your template has a mistake: Page footer, line 2: the if is never closed.", line: nil))
        XCTAssertEqual(problem(503, #"{"error":"PDFs from templates aren't switched on here yet.","code":"PDF_SERVICE_UNAVAILABLE","success":false}"#),
                       .serviceUnavailable)
        XCTAssertEqual(problem(409, #"{"success":false,"code":"DESIGN_NOT_TEMPLATE","error":"drawn with the designer"}"#), .notTemplate)
        XCTAssertEqual(problem(404, #"{"error":"Invoice not found"}"#), .notFound)
        XCTAssertEqual(TemplatePDFProblem(nil), .other)
        XCTAssertTrue(TemplatePDFProblem.serviceUnavailable.explanation.contains("PDF service"))
        XCTAssertFalse(TemplatePDFProblem.serviceUnavailable.explanation.contains("Gotenberg"), "no jargon")
    }

    func testAPreviewPDFIsAskedForWithTheTemplatesParts() async throws {
        let sent = Box()
        let pdf = Self.pdf
        let api = DocTemplatesAPI(api: WorkspaceAPI(client: try await client { request in
            sent.body = request.jsonBody
            sent.accept = request.value(forHTTPHeaderField: "Accept")
            return StubURLProtocol.Response(status: 200, body: pdf, headers: ["Content-Type": "application/pdf"])
        }))
        let source = TemplatePDFSource(kind: .order, html: "<h1>{{ order.number }}</h1>", css: "h1{}", footerHTML: "",
                                       pageSize: "A4", margins: ["14mm", nil, "16mm", "16mm"])
        let data = try await api.previewPDF(source)
        XCTAssertEqual(data, Self.pdf)
        XCTAssertEqual(sent.body?["type"] as? String, "order")
        XCTAssertEqual(sent.body?["html"] as? String, "<h1>{{ order.number }}</h1>")
        XCTAssertEqual(sent.body?["css"] as? String, "h1{}")
        XCTAssertNil(sent.body?["footer_html"])
        XCTAssertNil(sent.body?["margin_bottom"])
        XCTAssertEqual(sent.body?["margin_top"] as? String, "14mm")
        XCTAssertEqual(sent.accept, "application/pdf")

        let down = DocTemplatesAPI(api: WorkspaceAPI(client: try await client { _ in
            .json(503, #"{"error":"PDFs from templates aren't switched on here yet.","code":"PDF_SERVICE_UNAVAILABLE","success":false}"#)
        }))
        do {
            _ = try await down.previewPDF(source)
            XCTFail("a 503 throws")
        } catch {
            XCTAssertEqual(TemplatePDFProblem(error), .serviceUnavailable)
        }
    }

    func testStartersForAKindWithoutAnyAreNoneNotAnError() async throws {
        let api = DocTemplatesAPI(api: WorkspaceAPI(client: try await client { _ in
            .json(404, #"{"success":false,"error":"There are no ready-made timesheet templates"}"#)
        }))
        let starters = try await api.starters(.timesheet)
        XCTAssertTrue(starters.isEmpty)
    }

    func testUsingATemplatePutsTheDesignAndForgetsTheCachedOne() async throws {
        let sent = Box()
        let api = DocTemplatesAPI(api: WorkspaceAPI(client: try await client { request in
            sent.path = request.url?.path
            sent.method = request.httpMethod
            sent.body = request.jsonBody
            return .json(200, #"{"success":true,"data":{}}"#)
        }))
        let set = DocumentDesignSet(try fixture("document_designs"))
        try await api.saveDesign(.invoice, set.choosing(.invoice, template: "t-1"))
        XCTAssertEqual(sent.path, "/api/v2/document-designs/invoice")
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.body?["source"] as? String, "template")
        XCTAssertEqual(sent.body?["bill_to_label"] as? String, "BILLED TO", "keys stay snake_case (no key conversion)")
    }

    func testDuplicateAndRestoreAreMadeFromTheTemplatesParts() async throws {
        // The server's clone and restore fail on any template with a config (DocumentTemplateQueries.lua:343, :517),
        // so the app copies and restores from the parts.
        let calls = Box()
        let detail = String(decoding: try JSONEncoder().encode(try fixture("templates_detail")), as: UTF8.self)
            .replacingOccurrences(of: #""config":[]"#, with: ##""config":{"builder":{"v":1},"primary_color":"#123456"}"##)
        let versions = String(decoding: try JSONEncoder().encode(try fixture("templates_versions")), as: UTF8.self)
        let api = DocTemplatesAPI(api: WorkspaceAPI(client: try await client { request in
            let path = request.url?.path ?? ""
            calls.log.append("\(request.httpMethod ?? "") \(path)")
            if request.httpMethod != "GET" { calls.bodies.append(request.jsonBody ?? [:]) }
            if path.hasSuffix("/versions") { return .json(200, versions) }
            if request.httpMethod == "GET" { return .json(200, detail) }
            return .json(201, #"{"success":true,"data":{"uuid":"new","type":"invoice","name":"Copy"}}"#)
        }))
        let copy = try await api.duplicate("4b1bc959-d638-46cb-bcf6-8698371ef2ef", name: "Copy")
        XCTAssertEqual(copy.id, "new")
        XCTAssertEqual(calls.log, ["GET /api/v2/templates/4b1bc959-d638-46cb-bcf6-8698371ef2ef", "POST /api/v2/templates"])
        let sent = try XCTUnwrap(calls.bodies.first)
        XCTAssertEqual(sent["name"] as? String, "Copy")
        XCTAssertEqual(sent["type"] as? String, "invoice")
        XCTAssertEqual(sent["margin_top"] as? String, "14mm")
        XCTAssertTrue((sent["template_html"] as? String)?.hasPrefix("<div class=\"doc") == true)
        let config = try XCTUnwrap(sent["config"] as? String, "config goes as a JSON string")
        XCTAssertTrue(config.contains(##""primary_color":"#123456""##))

        calls.log = []
        calls.bodies = []
        try await api.restore("t-1", version: 1)
        XCTAssertEqual(calls.log, ["GET /api/v2/templates/t-1/versions", "PUT /api/v2/templates/t-1"])
        XCTAssertTrue((calls.bodies.first?["template_css"] as? String)?.hasPrefix("* { box-sizing") == true)
        XCTAssertNotNil(calls.bodies.first?["config"] as? [String: Any], "an update takes the config as an object")
        do {
            try await api.restore("t-1", version: 9)
            XCTFail("a version that isn't there")
        } catch {
            XCTAssertEqual(error.asAPIError.serverError?.status, 404)
        }
    }

    // MARK: Helpers

    static let pdf: Data = {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            ("Template preview" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
    }()

    func testAThumbnailIsTheFirstPage() throws {
        let image = try XCTUnwrap(PDFThumbnail.image(Self.pdf, width: 300))
        XCTAssertEqual(image.size.width, 300, accuracy: 1)
        XCTAssertEqual(image.size.height, 300 * 842 / 595, accuracy: 1)
        XCTAssertNil(PDFThumbnail.image(Data("not a pdf".utf8)))
    }

    private func client(_ handler: @escaping StubURLProtocol.Handler) async throws -> APIClient {
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")), sleep: { _ in })
        await client.setNamespace("ns")
        return client
    }

    private final class Box: @unchecked Sendable {
        var log: [String] = []
        var bodies: [[String: Any]] = []
        var body: [String: Any]?
        var path: String?
        var method: String?
        var accept: String?
    }
}
