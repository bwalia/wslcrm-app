import SwiftUI
import UIKit

/// What a document template is for (`document_templates.type`).
enum TemplateKind: String, CaseIterable, Identifiable, Sendable {
    case invoice, order, timesheet

    var id: String { rawValue }
    var label: String {
        switch self {
        case .invoice: "Invoice"
        case .order: "Order confirmation"
        case .timesheet: "Timesheet"
        }
    }
    var plural: String {
        switch self {
        case .invoice: "invoices"
        case .order: "orders"
        case .timesheet: "timesheets"
        }
    }
    var systemImage: String {
        switch self {
        case .invoice: "doc.text"
        case .order: "shippingbox"
        case .timesheet: "clock"
        }
    }
    /// Invoices and orders are printed from their template on the server (and chosen in Invoice and order design).
    var isDocument: Bool { self != .timesheet }
    var designKind: DocumentDesign.Kind? { self == .invoice ? .invoice : self == .order ? .order : nil }
    /// The designer makes invoices and orders.
    var builderKind: BuilderKind? { self == .invoice ? .invoice : self == .order ? .order : nil }
}

/// One template, as `GET /api/v2/templates` lists it (and `GET /api/v2/templates/:uuid` returns it, with its HTML).
struct DocTemplate: Identifiable, Hashable, Sendable {
    let record: Record
    var id: String { record.string("uuid") ?? record.id }
    var kind: TemplateKind? { record.string("type").flatMap(TemplateKind.init(rawValue:)) }
    var typeName: String { record.string("type") ?? "" }
    var name: String { record.string("name") ?? "Template" }
    var detail: String? { record.string("description")?.trimmedOrNil }
    var version: Int { record.int("version") ?? 1 }
    var isDefault: Bool { record.bool("is_default") == true }
    var isActive: Bool { record.bool("is_active") != false }
    var updatedAt: Date? { record.date("updated_at") }
    /// Made with the drag-and-drop designer (`config.builder`, one this app can read); only the full template has its config.
    var isDesigned: Bool { builder != nil }
    var builder: BuilderDoc? { BuilderDoc.read(record.objectMap("config")) }
    var builderKind: BuilderKind? { kind?.builderKind }

    init(_ record: Record) { self.record = record }

    /// The parts `POST /api/v2/templates/preview-pdf` prints (the full template only).
    var pdfSource: TemplatePDFSource? {
        guard let kind, kind.isDocument else { return nil }
        return TemplatePDFSource(kind: kind, html: record.string("template_html") ?? "", css: record.string("template_css"),
                                 footerHTML: record.string("footer_html"), headerHTML: record.string("header_html"),
                                 pageSize: record.string("page_size"), orientation: record.string("page_orientation"),
                                 margins: [record.string("margin_top"), record.string("margin_bottom"),
                                           record.string("margin_left"), record.string("margin_right")])
    }
}

/// A ready-made look (`GET /api/v2/templates/starters/:type`): its parts, to preview it before it's made.
struct TemplateStarter: Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let description: String
    let source: TemplatePDFSource
    var id: String { key }

    static func list(_ json: JSONValue, kind: TemplateKind) -> [TemplateStarter] {
        let data = json["data"] ?? json
        let rows = (data["starters"] ?? data).arrayItems
        return rows.compactMap { row in
            guard let key = row["key"]?.stringValue, let name = row["name"]?.stringValue else { return nil }
            return TemplateStarter(key: key, name: name, description: row["description"]?.stringValue ?? "",
                                   source: TemplatePDFSource(kind: kind, html: row["html"]?.stringValue ?? "",
                                                             css: row["css"]?.stringValue,
                                                             footerHTML: row["footer_html"]?.stringValue))
        }
    }
}

/// What a PDF preview is made from: a template's parts and its page (`POST /api/v2/templates/preview-pdf`).
struct TemplatePDFSource: Hashable, Sendable {
    var kind: TemplateKind
    var html: String
    var css: String?
    var footerHTML: String?
    var headerHTML: String?
    var pageSize: String?
    var orientation: String?
    /// top, bottom, left, right ("14mm"); nil keeps the server's.
    var margins: [String?] = []

    var body: JSONValue {
        var fields: [String: JSONValue] = ["type": .string(kind.rawValue), "html": .string(html)]
        let optional: [(String, String?)] = [
            ("css", css), ("footer_html", footerHTML), ("header_html", headerHTML), ("page_size", pageSize),
            ("page_orientation", orientation),
        ] + zip(["margin_top", "margin_bottom", "margin_left", "margin_right"], margins).map { ($0, $1) }
        for (key, value) in optional { if let value = value?.trimmedOrNil { fields[key] = .string(value) } }
        return .object(fields)
    }

    /// Changes whenever what the page prints changes: a thumbnail's cache key.
    var fingerprint: String {
        var hasher = Hasher()
        hasher.combine(self)
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }
}

/// The workspace's invoice and order designs as the server sends them (`GET /api/v2/document-designs`), kept as JSON
/// so a change sends every setting back: the server replaces the whole design on save.
struct DocumentDesignSet: Equatable, Sendable {
    var designs: [String: [String: JSONValue]]

    init(_ json: JSONValue) {
        let data = json["data"]?.objectValue ?? json.objectValue ?? [:]
        designs = data.compactMapValues(\.objectValue)
    }

    /// Invoice first, then order; only the kinds this deployment has.
    var kinds: [TemplateKind] { [TemplateKind.invoice, .order].filter { designs[$0.rawValue] != nil } }

    func usesTemplate(_ kind: TemplateKind) -> Bool { designs[kind.rawValue]?["source"]?.stringValue == "template" }
    func templateUUID(_ kind: TemplateKind) -> String? {
        usesTemplate(kind) ? designs[kind.rawValue]?["template_uuid"]?.stringValue : nil
    }
    func templateName(_ kind: TemplateKind) -> String? { designs[kind.rawValue]?["template_name"]?.stringValue }
    func isCustom(_ kind: TemplateKind) -> Bool { designs[kind.rawValue]?["is_custom"]?.boolValue == true }
    /// The kinds a template is used for now.
    func inUse(_ uuid: String) -> [TemplateKind] { kinds.filter { templateUUID($0) == uuid } }
    /// Changes when the design does: previews are filled with its colours and logo.
    func stamp(_ kind: TemplateKind) -> String {
        designs[kind.rawValue]?["updated_at"]?.stringValue ?? "standard"
    }

    /// The whole design with how it's drawn changed: the quick layout (`template: nil`) or that template.
    func choosing(_ kind: TemplateKind, template: String?) -> JSONValue {
        var design = designs[kind.rawValue] ?? [:]
        design["source"] = .string(template == nil ? "design" : "template")
        if let template { design["template_uuid"] = .string(template) }
        return .object(design)
    }

    /// The app's drawing settings for this kind (the quick layout).
    func design(_ kind: TemplateKind) -> DocumentDesign {
        guard let designKind = kind.designKind else { return .standard(.invoice) }
        guard let fields = designs[kind.rawValue], let data = try? JSONEncoder.sorted.encode(JSONValue.object(fields)),
              let raw = try? JSONDecoder.opsAPI().decode(DocumentDesign.Raw.self, from: data) else { return .standard(designKind) }
        return DocumentDesign(kind: designKind, raw: raw)
    }
}

/// The document template calls (`lapis/routes/document-templates.lua`, `document-designs.lua`).
struct DocTemplatesAPI: Sendable {
    let api: WorkspaceAPI

    init(_ services: Services) { api = services.workspace() }
    init(api: WorkspaceAPI) { self.api = api }

    func list(kind: TemplateKind?, search: String = "") async throws -> [DocTemplate] {
        // ponytail: the first 200 templates; a workspace with more would page.
        let json = try await api.get("/api/v2/templates", query: ["page": "1", "perPage": "200", "type": kind?.rawValue,
                                                                   "search": search.trimmedOrNil])
        return WorkspaceAPI.records(json).map(DocTemplate.init)
    }

    func template(_ uuid: String) async throws -> DocTemplate {
        let json = try await api.get("/api/v2/templates/\(uuid)")
        guard let record = WorkspaceAPI.record(json) else { throw ResourceService.problem(404, APIError.goneMessage) }
        return DocTemplate(record)
    }

    /// The ready-made looks; none (not an error) for a kind that has none, such as timesheets.
    func starters(_ kind: TemplateKind) async throws -> [TemplateStarter] {
        do {
            return TemplateStarter.list(try await api.get("/api/v2/templates/starters/\(kind.rawValue)"), kind: kind)
        } catch let error as APIError {
            if case .notFound = error { return [] }
            throw error
        }
    }

    func fromStarter(_ kind: TemplateKind, starter: String, name: String) async throws -> DocTemplate {
        try made(try await api.send(.post, "/api/v2/templates/from-starter", body: .object([
            "type": .string(kind.rawValue), "starter": .string(starter), "name": .string(name)])))
    }

    func fromDesign(_ kind: TemplateKind, name: String) async throws -> DocTemplate {
        try made(try await api.send(.post, "/api/v2/templates/from-design/\(kind.rawValue)", body: .object(["name": .string(name)])))
    }

    /// A template from its parts (a blank page, one made with the designer, a copy).
    func create(_ body: [String: JSONValue]) async throws -> DocTemplate {
        var body = body
        // The server writes the first version's `config` as it arrives: an object fails there
        // (lapis/queries/DocumentTemplateQueries.lua:83), the same JSON as a string is stored fine.
        if let config = body["config"], case .object = config, let data = try? JSONEncoder.sorted.encode(config) {
            body["config"] = .string(String(decoding: data, as: UTF8.self))
        }
        return try made(try await api.send(.post, "/api/v2/templates", body: .object(body)))
    }

    /// An empty page for people who write HTML (not empty: the server fills an empty one with its own heading).
    func createBlank(_ kind: TemplateKind, name: String) async throws -> DocTemplate {
        try await create(["name": .string(name), "type": .string(kind.rawValue), "page_size": .string("A4"),
                          "page_orientation": .string("portrait"),
                          "template_html": .string("<!-- Write your template here. -->\n")])
    }

    func update(_ uuid: String, _ body: [String: JSONValue]) async throws -> DocTemplate {
        try made(try await api.send(.put, "/api/v2/templates/\(uuid)", body: .object(body)))
    }

    /// A copy under a new name, made here from the template's parts.
    /// ponytail: the server's own copy (`POST /api/v2/templates/:uuid/clone`) fails for every template with a config
    /// (DocumentTemplateQueries.lua:343, a decoded jsonb table passed back to the insert); use it again once fixed.
    func duplicate(_ uuid: String, name: String) async throws -> DocTemplate {
        let t = try await template(uuid)
        var body: [String: JSONValue] = ["name": .string(name), "type": .string(t.typeName),
                                         "config": .object(t.record.objectMap("config"))]
        for key in ["description", "template_html", "template_css", "header_html", "footer_html", "page_size", "page_orientation",
                    "margin_top", "margin_bottom", "margin_left", "margin_right"] {
            if let value = t.record.string(key) { body[key] = .string(value) }
        }
        return try await create(body)
    }

    /// Back to an earlier version: its HTML, CSS, header, footer and settings saved as the newest version (what's there
    /// now is kept as a version too, as the server's restore does).
    /// ponytail: done here because `POST /api/v2/templates/:uuid/restore/:version` fails the same way
    /// (DocumentTemplateQueries.lua:517 and :529); use it again once fixed.
    func restore(_ uuid: String, version: Int) async throws {
        let versions = WorkspaceAPI.records(try await api.get("/api/v2/templates/\(uuid)/versions"))
        guard let v = versions.first(where: { $0.int("version") == version }) else {
            throw ResourceService.problem(404, "That version isn’t there any more.")
        }
        var body: [String: JSONValue] = ["config": .object(v.objectMap("config"))]
        for key in ["template_html", "template_css", "header_html", "footer_html"] { body[key] = .string(v.string(key) ?? "") }
        _ = try await update(uuid, body)
    }

    func delete(_ uuid: String) async throws { try await api.send(.delete, "/api/v2/templates/\(uuid)") }

    func makeDefault(_ uuid: String) async throws {
        try await api.send(.post, "/api/v2/templates/\(uuid)/set-default", body: .object([:]))
    }

    /// The PDF of a template's parts filled with this workspace's sample figures. Throws the server's error
    /// (`TemplatePDFProblem` reads it: 422 a mistake, with its line; 503 no PDF service).
    func previewPDF(_ source: TemplatePDFSource) async throws -> Data {
        var endpoint = Endpoint(.post, "/api/v2/templates/preview-pdf").withRawBody(try JSONEncoder.sorted.encode(source.body))
        endpoint.headers["Accept"] = "application/pdf"
        let (data, _) = try await api.client.sendRaw(endpoint)
        guard data.starts(with: Data("%PDF".utf8)) else { throw ResourceService.problem(502, "The preview isn't a PDF.") }
        return data
    }

    // MARK: Invoice and order design

    func designs() async throws -> DocumentDesignSet { DocumentDesignSet(try await api.get("/api/v2/document-designs")) }

    func saveDesign(_ kind: TemplateKind, _ body: JSONValue) async throws {
        try await api.send(.put, "/api/v2/document-designs/\(kind.rawValue)", body: body)
        await MainActor.run { DocumentDesigns.forget() }
    }

    func resetDesign(_ kind: TemplateKind) async throws {
        try await api.send(.delete, "/api/v2/document-designs/\(kind.rawValue)")
        await MainActor.run { DocumentDesigns.forget() }
    }

    private func made(_ json: JSONValue) throws -> DocTemplate {
        guard let record = WorkspaceAPI.record(json) else { throw ResourceService.problem(502, "The template wasn't made. Try again.") }
        return DocTemplate(record)
    }
}

/// Who may do what with templates and designs, as the server checks it.
enum TemplateAccess {
    /// The Templates page (`ProtectedPage module="templates"`); thumbnails need it too (`preview-pdf`: templates.read).
    static func read(_ p: PermissionSet) -> Bool { p.can(.read, moduleName: "templates") }
    static func create(_ p: PermissionSet) -> Bool { p.can(.create, moduleName: "templates") }
    static func update(_ p: PermissionSet) -> Bool { p.can(.update, moduleName: "templates") }
    static func delete(_ p: PermissionSet) -> Bool { p.can(.delete, moduleName: "templates") }
    /// `GET /api/v2/document-designs`: namespace.read, invoices.read or shop.read.
    static func readDesigns(_ p: PermissionSet) -> Bool {
        p.can(.read, moduleName: "namespace") || p.can(.read, .invoices) || p.can(.read, .shop)
    }
    /// Changing how a kind looks: the people who send it (invoices.update, shop.update).
    static func changeDesign(_ kind: TemplateKind, _ p: PermissionSet) -> Bool {
        kind == .order ? p.can(.update, .shop) : p.can(.update, .invoices)
    }
}

// MARK: - Thumbnails

/// The first page of each template's preview, made once per template version and kept on disk. The server makes
/// the PDF (`preview-pdf`, 30 a minute), so at most two are asked for at a time; when the PDF service is missing
/// it isn't asked again for two minutes, and the cards show a drawn page instead.
@MainActor
@Observable
final class TemplateThumbnails {
    static let shared = TemplateThumbnails()

    private(set) var images: [String: UIImage] = [:]
    /// Keys whose preview couldn't be made (no PDF service, or a mistake in the template).
    private(set) var failed: [String: TemplatePDFProblem] = [:]
    private(set) var serviceDownUntil: Date?
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("template-thumbnails", isDirectory: true)

    var serviceDown: Bool { serviceDownUntil.map { $0 > Date() } ?? false }

    func load(_ key: String, make: @escaping @Sendable () async throws -> Data) async {
        if images[key] != nil { return }
        let file = folder.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
        if let image = UIImage(contentsOfFile: file.path) {
            images[key] = image
            return
        }
        if serviceDown {
            failed[key] = .serviceUnavailable
            return
        }
        await acquire()
        defer { release() }
        guard images[key] == nil, !Task.isCancelled else { return }
        do {
            let data = try await make()
            guard let image = PDFThumbnail.image(data) else { return }
            images[key] = image
            failed[key] = nil
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: file, options: .atomic)
        } catch {
            if case .cancelled = error.asAPIError { return }
            let problem = TemplatePDFProblem(error)
            failed[key] = problem
            if problem == .serviceUnavailable { serviceDownUntil = Date().addingTimeInterval(120) }
        }
    }

    /// The server said there's no PDF service: don't ask again for two minutes (invoice PDFs use the quick layout).
    func noteServiceDown() { serviceDownUntil = Date().addingTimeInterval(120) }

    /// Try the PDF service again (Try again on the banner).
    func retry() {
        serviceDownUntil = nil
        failed = [:]
    }

    private func acquire() async {
        if running < 2 {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// A page-shaped thumbnail: the template's first page, or a drawn page while it loads or when it can't be made.
struct TemplateThumbnail: View {
    let key: String
    var kind: TemplateKind = .invoice
    /// Makes the preview PDF; nil for a page that has none (timesheets): the drawn page shows.
    let make: (@Sendable () async throws -> Data)?
    /// A designer page, drawn here until (or instead of) its picture.
    var doc: BuilderDoc?
    private var store = TemplateThumbnails.shared

    init(key: String, kind: TemplateKind = .invoice, doc: BuilderDoc? = nil, make: (@Sendable () async throws -> Data)?) {
        self.key = key
        self.kind = kind
        self.doc = doc
        self.make = make
    }

    var body: some View {
        ZStack {
            if let image = store.images[key] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Group {
                    if let doc { BuilderCanvas(doc: doc).padding(0) } else { TemplatePageSketch(kind: kind) }
                }
                    .overlay(alignment: .bottom) {
                        if make != nil && store.failed[key] == nil && !store.serviceDown {
                            ProgressView().padding(8)
                        } else if case .mistake = store.failed[key] {
                            Label("Has a mistake", systemImage: "exclamationmark.triangle.fill")
                                .font(.wsCaption2).foregroundStyle(Tone.warning.textColor)
                                .padding(6).background(.thinMaterial, in: Capsule()).padding(8)
                        }
                    }
            }
        }
        .aspectRatio(210 / 297, contentMode: .fit)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.hairline))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .task(id: key) { if let make { await store.load(key, make: make) } }
        .accessibilityHidden(true)
    }
}

/// A clean drawing of a page (header, lines, a table and totals), shown when the real page can't be.
struct TemplatePageSketch: View {
    var kind: TemplateKind = .invoice

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // Bar widths are parts of the page inside its margins.
            let bar = { (width: CGFloat, color: Color) in
                RoundedRectangle(cornerRadius: w * 0.01).fill(color).frame(width: w * 0.84 * width, height: max(w * 0.022, 2))
            }
            VStack(alignment: .leading, spacing: w * 0.035) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: w * 0.02) {
                        bar(0.28, Color(white: 0.55))
                        bar(0.2, Color(white: 0.82))
                        bar(0.24, Color(white: 0.82))
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: w * 0.012).fill(Color.accentColor.opacity(0.7))
                        .frame(width: w * 0.22, height: w * 0.05)
                }
                Rectangle().fill(Color.accentColor.opacity(0.55)).frame(height: max(w * 0.006, 1))
                VStack(alignment: .leading, spacing: w * 0.02) {
                    bar(0.3, Color(white: 0.7))
                    bar(0.22, Color(white: 0.85))
                }
                VStack(spacing: w * 0.025) {
                    Rectangle().fill(Color.accentColor.opacity(0.2)).frame(height: w * 0.04)
                    ForEach(0..<(kind == .timesheet ? 5 : 3), id: \.self) { _ in bar(1, Color(white: 0.88)) }
                }
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: w * 0.02) {
                        bar(0.36, Color(white: 0.85))
                        bar(0.36, Color(white: 0.85))
                        bar(0.36, Color(white: 0.5))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(w * 0.08)
        }
        .background(Color.white)
    }
}
