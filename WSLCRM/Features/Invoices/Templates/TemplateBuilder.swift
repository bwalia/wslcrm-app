import Foundation

// The drag-and-drop template designer's page, ported from the web (opsapi-dashboard
// components/templates/builder/model.ts and compile.ts). A page in bands (like a report designer): pieces placed
// anywhere at the top, the items table (it grows and runs onto more pages), pieces below the items, and a page footer.
// Saved on the template as `config.builder`; `TemplateCompiler.compile` turns it into the HTML, CSS and page footer the
// server prints, character for character the same as the web's (WSLCRMTests/TemplateBuilderTests checks it against
// the TypeScript's own output), so a page designed in the app opens in the web's designer and the other way round.
//
// Positions and sizes are in millimetres from the band's top-left corner; text sizes in points.

enum BuilderKind: String, Codable, Sendable { case invoice, order }
enum BuilderBand: String, Codable, Sendable, CaseIterable { case header, after }

enum PieceType: String, Codable, Sendable, CaseIterable {
    case logo, image, title, text, company, customer, delivery, details, amount, status
    case totals, payment, notes, terms, vat, box, line
}

/// How a piece looks. Every field is optional, as on the web: unset means the page's own.
/// A colour is "#rrggbb", "" for none, or "accent" for the workspace's own colour.
struct PieceStyle: Codable, Equatable, Hashable, Sendable {
    var font: String?
    var size: Double?
    var weight: Double?
    var italic: Bool?
    var underline: Bool?
    var upper: Bool?
    var spacing: Double?
    var lineHeight: Double?
    var color: String?
    var labelColor: String?
    var align: String?
    var valign: String?
    var bg: String?
    var borderColor: String?
    var borderWidth: Double?
    var borderStyle: String?
    var radius: Double?
    var padding: Double?
    var opacity: Double?
    var highlight: String?
    var highlightText: String?
    var table: String?
    var gridColor: String?
    var labelBg: String?
    var valueWidth: Double?
    var plain: Bool?

    /// `{ ...self, ...over }`: every field `over` sets wins.
    func merged(_ over: PieceStyle) -> PieceStyle {
        var s = self
        func take<T>(_ path: WritableKeyPath<PieceStyle, T?>) { if let v = over[keyPath: path] { s[keyPath: path] = v } }
        take(\.font); take(\.size); take(\.weight); take(\.italic); take(\.underline); take(\.upper); take(\.spacing)
        take(\.lineHeight); take(\.color); take(\.labelColor); take(\.align); take(\.valign); take(\.bg); take(\.borderColor)
        take(\.borderWidth); take(\.borderStyle); take(\.radius); take(\.padding); take(\.opacity); take(\.highlight)
        take(\.highlightText); take(\.table); take(\.gridColor); take(\.labelBg); take(\.valueWidth); take(\.plain)
        return s
    }
}

struct BuilderPiece: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var type: PieceType
    var band: BuilderBand
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var style: PieceStyle
    /// title / text: words with {{ details }}
    var text: String?
    /// the small heading inside a piece
    var label: String?
    /// image: a data URL
    var src: String?
    /// how to pay: words under the bank details
    var note: String?
    /// which lines a piece prints
    var show: [String: Bool]?
    /// a person's own words for those lines ("Invoice#", "Balance due:")
    var names: [String: String]?
    var hidden: Bool?
    var locked: Bool?
}

struct BuilderColumn: Codable, Equatable, Hashable, Identifiable, Sendable {
    var key: String
    var label: String
    var show: Bool
    var align: String
    var width: Double?
    var id: String { key }
}

struct BuilderItems: Codable, Equatable, Hashable, Sendable {
    var columns: [BuilderColumn]
    var size: Double
    var color: String
    var headerBg: String
    var headerColor: String
    var headerWeight: Double
    var upper: Bool
    var stripe: String
    var lineColor: String
    /// "rows" | "grid" | "none"
    var lines: String
    var padding: Double
    var marginTop: Double
    var marginBottom: Double
    var headerCenter: Bool?
}

struct BuilderFooter: Codable, Equatable, Hashable, Sendable {
    var left: String
    var pageNumbers: Bool
    var size: Double
    var color: String
    var center: Bool?
    var line: Bool?
}

struct BuilderDoc: Codable, Equatable, Hashable, Sendable {
    struct Margins: Codable, Equatable, Hashable, Sendable {
        var tb: Double
        var lr: Double
    }
    struct Page: Codable, Equatable, Hashable, Sendable {
        var font: String
        var size: Double
        var color: String
        var margins: Margins
        /// "A4" | "Letter"
        var paper: String
    }
    struct Band: Codable, Equatable, Hashable, Sendable {
        var h: Double
    }

    var v = 1
    var kind: BuilderKind
    var page: Page
    var header: Band
    var after: Band
    var pieces: [BuilderPiece]
    var items: BuilderItems
    var footer: BuilderFooter

    /// The page's width inside its side margins (mm).
    var contentWidth: Double { (BuilderCatalog.paper[page.paper]?.w ?? 210) - 2 * page.margins.lr }

    func height(_ band: BuilderBand) -> Double { band == .header ? header.h : after.h }

    /// The designer's page on a template (`config.builder`), if it's one this app can read.
    static func read(_ config: [String: JSONValue]) -> BuilderDoc? {
        guard let builder = config["builder"], case .object = builder,
              let data = try? JSONEncoder().encode(builder),
              let doc = try? JSONDecoder().decode(BuilderDoc.self, from: data), doc.v == 1 else { return nil }
        return doc
    }

    /// As JSON for `config.builder`.
    var json: JSONValue {
        guard let data = try? JSONEncoder().encode(self), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return value
    }

    /// Every piece inside its band and the page's width (after the page, its margins or a band changes).
    func clamped() -> BuilderDoc {
        var d = self
        let width = contentWidth
        d.pieces = pieces.map { p in
            var p = p
            let bandH = height(p.band)
            p.w = min(max(p.w, 2), width)
            p.h = min(max(p.h, p.type == .line ? 0.2 : 2), bandH)
            p.x = min(max(p.x, 0), width - p.w)
            p.y = min(max(p.y, 0), bandH - p.h)
            return p
        }
        return d
    }
}

// MARK: - Catalogue

/// What each piece is, its look when added, and the lines a person can switch on and off (model.ts PIECES).
struct PieceInfo: Sendable {
    let name: String
    let help: String
    let group: String
    var kinds: [BuilderKind]?
    let band: BuilderBand
    let w: Double
    let h: Double
    var style = PieceStyle()
    var label: (@Sendable (BuilderKind) -> String)?
    var text: (@Sendable (BuilderKind) -> String)?
    var show: [String: Bool]?
    var lines: (@Sendable (BuilderKind) -> [(String, String)])?
}

enum BuilderCatalog {
    struct Font: Sendable {
        let key: String
        let label: String
        let stack: String
    }

    /// Only fonts the PDF service has (it can't download web fonts).
    static let fonts: [Font] = [
        Font(key: "noto-sans", label: "Clean (Noto Sans)", stack: "'Noto Sans', 'Helvetica Neue', Helvetica, Arial, sans-serif"),
        Font(key: "arial", label: "Classic (Arial)", stack: "'Liberation Sans', Arial, Helvetica, sans-serif"),
        Font(key: "calibri", label: "Friendly (Calibri)", stack: "Carlito, Calibri, 'Segoe UI', sans-serif"),
        Font(key: "condensed", label: "Compact (Condensed)", stack: "'DejaVu Sans Condensed', 'Arial Narrow', sans-serif"),
        Font(key: "noto-serif", label: "Book (Noto Serif)", stack: "'Noto Serif', Georgia, serif"),
        Font(key: "times", label: "Traditional (Times)", stack: "'Liberation Serif', 'Times New Roman', Times, serif"),
        Font(key: "cambria", label: "Elegant (Cambria)", stack: "Caladea, Cambria, Georgia, serif"),
        Font(key: "mono", label: "Typewriter (Courier)", stack: "'Liberation Mono', 'Courier New', monospace"),
    ]

    static func fontStack(_ key: String?) -> String { (fonts.first { $0.key == key } ?? fonts[0]).stack }

    static let paper: [String: (w: Double, h: Double)] = ["A4": (210, 297), "Letter": (215.9, 279.4)]

    static let swatches = [
        "#0f172a", "#334155", "#64748b", "#94a3b8", "#e2e8f0", "#f8fafc", "#ffffff",
        "#1d4ed8", "#2563eb", "#0891b2", "#0d9488", "#059669", "#65a30d", "#ca8a04",
        "#ea580c", "#dc2626", "#db2777", "#9333ea", "#4f46e5", "#7c2d12", "#fef3c7",
    ]

    private static let labelColour = "#64748b"

    static let pieces: [PieceType: PieceInfo] = [
        .logo: PieceInfo(name: "Logo", help: "Your logo from Invoice and order design", group: "Your business", band: .header, w: 45, h: 18),
        .company: PieceInfo(name: "Your details", help: "Business name, address, email, phone and VAT number", group: "Your business",
                            band: .header, w: 80, h: 30, style: PieceStyle(size: 8.5, lineHeight: 1.45, color: "#475569"),
                            show: ["name": true, "address": true, "email": true, "phone": true, "vat": true],
                            lines: { _ in [("name", "Business name"), ("address", "Address"), ("email", "Email"), ("phone", "Phone"),
                                           ("vat", "VAT number")] }),
        .image: PieceInfo(name: "Picture", help: "A picture of your own: a stamp, a signature, a badge", group: "Your business",
                          band: .header, w: 40, h: 25),
        .customer: PieceInfo(name: "Customer", help: "Who it is for: name, email and address", group: "The customer", band: .header,
                             w: 80, h: 24, style: PieceStyle(size: 9, lineHeight: 1.45, color: "#334155", labelColor: labelColour),
                             label: { $0 == .order ? "Customer" : "Billed to" },
                             show: ["label": true, "name": true, "email": true, "address": true],
                             lines: { _ in [("label", "Small heading"), ("name", "Name"), ("email", "Email"), ("address", "Address")] }),
        .delivery: PieceInfo(name: "Delivery address", help: "Where the order is going", group: "The customer", kinds: [.order],
                             band: .header, w: 60, h: 24,
                             style: PieceStyle(size: 9, lineHeight: 1.45, color: "#334155", labelColor: labelColour),
                             label: { _ in "Deliver to" }, show: ["label": true], lines: { _ in [("label", "Small heading")] }),
        .title: PieceInfo(name: "Title", help: "The big “Invoice” or “Order confirmation” heading", group: "The document", band: .header,
                          w: 80, h: 12, style: PieceStyle(size: 24, weight: 800, upper: true, spacing: 0.04, color: "accent", align: "right"),
                          text: { _ in "{{ document.title }}" }),
        .text: PieceInfo(name: "Text", help: "Your own words, with details like the number or a date", group: "The document",
                         band: .header, w: 70, h: 8, style: PieceStyle(size: 10, color: "#334155"), text: { _ in "Your words here" }),
        .details: PieceInfo(name: "Dates and numbers", help: "Number, dates and the customer’s PO number", group: "The document",
                            band: .header, w: 70, h: 22, style: PieceStyle(size: 8.5, color: "#0f172a", labelColor: labelColour),
                            show: ["number": true, "date": true, "due": true, "po": true, "quote": true, "delivery": true,
                                   "project": true, "by": true],
                            lines: { k in k == .order
                                ? [("number", "Order number"), ("date", "Order date"), ("quote", "Quote"), ("po", "Your PO number"),
                                   ("delivery", "Delivery")]
                                : [("number", "Invoice number"), ("date", "Issue date"), ("due", "Due date"), ("project", "Project"),
                                   ("by", "Order by"), ("po", "Your PO number")] }),
        .amount: PieceInfo(name: "Amount due", help: "The amount to pay, in large type", group: "The document", band: .header,
                           w: 70, h: 18, style: PieceStyle(size: 22, weight: 800, color: "#0f172a", labelColor: labelColour),
                           show: ["label": true, "due": true],
                           lines: { k in k == .order ? [("label", "Small heading")] : [("label", "Small heading"), ("due", "Due date under it")] }),
        .status: PieceInfo(name: "Status badge", help: "“Paid”, “Sent”, “Awaiting payment”…", group: "The document", band: .header,
                           w: 30, h: 6, style: PieceStyle(size: 7.5, weight: 700, upper: true, spacing: 0.08, color: "#ffffff",
                                                          align: "center", valign: "middle", bg: "accent", radius: 99)),
        .totals: PieceInfo(name: "Totals", help: "Subtotal, VAT, total and what’s left to pay", group: "Money", band: .after,
                           w: 75, h: 32, style: PieceStyle(size: 9, color: "#0f172a", labelColor: labelColour, highlight: "accent",
                                                           highlightText: "#ffffff"),
                           show: ["subtotal": true, "discount": true, "delivery": true, "vat": true, "total": true, "paid": true,
                                  "balance": true],
                           lines: { k in k == .order
                               ? [("subtotal", "Subtotal"), ("discount", "Discount"), ("delivery", "Delivery"), ("vat", "VAT"),
                                  ("balance", "Total")]
                               : [("subtotal", "Subtotal"), ("discount", "Discount"), ("vat", "VAT"), ("total", "Total"), ("paid", "Paid"),
                                  ("balance", "Balance due")] }),
        .payment: PieceInfo(name: "How to pay", help: "Your bank details and the payment reference", group: "Money", band: .after,
                            w: 95, h: 32, style: PieceStyle(size: 8.5, color: "#0f172a", labelColor: labelColour, bg: "#f8fafc",
                                                            borderColor: "#e2e8f0", borderWidth: 0.6, radius: 5, padding: 3.5),
                            label: { _ in "How to pay" }, show: ["label": true, "method": true, "reference": true],
                            lines: { _ in [("label", "Small heading"), ("method", "Which account (e.g. “Business account”)"),
                                           ("reference", "Reference")] }),
        .vat: PieceInfo(name: "VAT breakdown", help: "How much VAT at each rate", group: "Money", kinds: [.invoice], band: .after,
                        w: 90, h: 14, style: PieceStyle(size: 8, color: "#334155", labelColor: labelColour)),
        .notes: PieceInfo(name: "Notes", help: "The notes written on this invoice", group: "Words", kinds: [.invoice], band: .after,
                          w: 95, h: 14, style: PieceStyle(size: 8.5, color: "#334155", labelColor: labelColour),
                          label: { _ in "Notes" }, show: ["label": true], lines: { _ in [("label", "Small heading")] }),
        .terms: PieceInfo(name: "Terms", help: "Payment terms and the terms from your design", group: "Words", band: .after,
                          w: 180, h: 12, style: PieceStyle(size: 8, color: "#475569", labelColor: "#0f172a"),
                          label: { _ in "Payment terms" }, show: ["label": true, "days": true],
                          lines: { k in k == .order ? [("label", "Small heading")] : [("label", "Small heading"), ("days", "“Due within N days”")] }),
        .box: PieceInfo(name: "Box", help: "A coloured shape behind other pieces", group: "Shapes", band: .header, w: 60, h: 25,
                        style: PieceStyle(bg: "#f1f5f9", radius: 4)),
        .line: PieceInfo(name: "Line", help: "A straight line to divide the page", group: "Shapes", band: .header, w: 180, h: 0.4,
                         style: PieceStyle(bg: "#e2e8f0")),
    ]

    static func info(_ type: PieceType) -> PieceInfo { pieces[type]! }

    static let groups = ["Your business", "The customer", "The document", "Money", "Words", "Shapes"]

    /// The pieces a kind can have, in the catalogue's order.
    static func pieces(for kind: BuilderKind) -> [PieceType] {
        PieceType.allCases.filter { info($0).kinds?.contains(kind) ?? true }
    }

    /// Pieces whose lines a person can rename (the words printed beside each value).
    static let renamable: Set<PieceType> = [.details, .totals, .payment]

    /// Details a person can drop into their own words.
    static func placeholders(_ kind: BuilderKind) -> [(String, String)] {
        let common = [
            ("Your business name", "{{ company.name }}"), ("Your email", "{{ company.email }}"), ("Your phone", "{{ company.phone }}"),
            ("Customer name", "{{ customer.name }}"), ("Customer email", "{{ customer.email }}"),
            ("Your address (one line)", "{{ company.address }}"), ("Your company number", "{{ company.company_number }}"),
            ("Your VAT number", "{{ company.vat_number }}"), ("Your legal name", "{{ company.legal_name }}"),
            ("Today’s date", "{{ document.printed_on }}"),
        ]
        return kind == .order
            ? [("Order number", "{{ order.number }}"), ("Order date", "{{ order.date }}"), ("Order total", "{{ order.total_formatted }}"),
               ("Status", "{{ order.status_label }}"), ("Customer’s PO number", "{{ order.po_number }}"),
               ("Delivery date", "{{ order.delivery_date }}"), ("Payment reference", "{{ payment.reference }}")] + common
            : [("Invoice number", "{{ invoice.number }}"), ("Issue date", "{{ invoice.issue_date }}"), ("Due date", "{{ invoice.due_date }}"),
               ("Amount due", "{{ invoice.balance_due_formatted }}"), ("Invoice total", "{{ invoice.total_formatted }}"),
               ("Status", "{{ invoice.status_label }}"), ("Customer’s PO number", "{{ invoice.po_number }}"),
               ("Project", "{{ invoice.project }}"), ("Order by", "{{ invoice.ordered_by }}"),
               ("Payment reference", "{{ payment.reference }}")] + common
    }

    static func defaultColumns(_ kind: BuilderKind) -> [BuilderColumn] {
        kind == .order
            ? [BuilderColumn(key: "n", label: "#", show: true, align: "left", width: 5),
               BuilderColumn(key: "name", label: "Item", show: true, align: "left"),
               BuilderColumn(key: "sku", label: "Code", show: false, align: "left", width: 12),
               BuilderColumn(key: "qty", label: "Qty", show: true, align: "right", width: 8),
               BuilderColumn(key: "unit", label: "Unit price", show: true, align: "right", width: 15),
               BuilderColumn(key: "vat", label: "VAT", show: true, align: "right", width: 12),
               BuilderColumn(key: "total", label: "Amount", show: true, align: "right", width: 15),
               BuilderColumn(key: "net", label: "Before VAT", show: false, align: "right", width: 15)]
            : [BuilderColumn(key: "n", label: "#", show: true, align: "left", width: 5),
               BuilderColumn(key: "description", label: "Description", show: true, align: "left"),
               BuilderColumn(key: "qty", label: "Qty", show: true, align: "right", width: 8),
               BuilderColumn(key: "unit", label: "Unit price", show: true, align: "right", width: 15),
               BuilderColumn(key: "vat", label: "VAT", show: true, align: "right", width: 12),
               BuilderColumn(key: "total", label: "Amount", show: true, align: "right", width: 15),
               BuilderColumn(key: "net", label: "Before VAT", show: false, align: "right", width: 15)]
    }

    static func newID() -> String { "p" + UUID().uuidString.prefix(10).lowercased().replacingOccurrences(of: "-", with: "") }

    /// A new piece of a type, with its own sensible size, look and words.
    static func makePiece(_ type: PieceType, kind: BuilderKind, band: BuilderBand, x: Double, y: Double) -> BuilderPiece {
        let info = info(type)
        return BuilderPiece(id: newID(), type: type, band: band, x: x, y: y, w: info.w, h: info.h, style: info.style,
                            text: info.text?(kind), label: info.label?(kind), show: info.show)
    }

    /// A piece's name in the list ("Text" shows its words).
    static func name(_ p: BuilderPiece) -> String {
        if p.type == .text, let text = p.text, !text.isEmpty {
            let plain = text.replacingOccurrences(of: #"\{\{\s*|\s*\}\}"#, with: "", options: .regularExpression)
            return String(plain.prefix(28))
        }
        return info(p.type).name
    }
}

// MARK: - Ready-made designs

/// Starting points (model.ts PRESETS); everything can be moved and restyled.
enum BuilderPresets {
    struct Preset: Sendable {
        let key: String
        let name: String
        let description: String
        let make: @Sendable (BuilderKind) -> BuilderDoc
    }

    private struct Over {
        var style = PieceStyle()
        var text: String?
        var label: String?
        var note: String?
        var show: [String: Bool]?
        var names: [String: String]?
    }

    private static func piece(_ k: BuilderKind, _ type: PieceType, _ band: BuilderBand, _ x: Double, _ y: Double, _ w: Double,
                              _ h: Double, _ over: Over = Over()) -> BuilderPiece {
        var p = BuilderCatalog.makePiece(type, kind: k, band: band, x: x, y: y)
        p.w = w
        p.h = h
        if let v = over.text { p.text = v }
        if let v = over.label { p.label = v }
        if let v = over.note { p.note = v }
        if let v = over.show { p.show = v }
        if let v = over.names { p.names = v }
        p.style = p.style.merged(over.style)
        return p
    }

    private static func items(_ k: BuilderKind, _ change: (inout BuilderItems) -> Void = { _ in }) -> BuilderItems {
        var t = BuilderItems(columns: BuilderCatalog.defaultColumns(k), size: 8.5, color: "#0f172a", headerBg: "accent",
                             headerColor: "#ffffff", headerWeight: 700, upper: true, stripe: "#f8fafc", lineColor: "#e2e8f0",
                             lines: "rows", padding: 5, marginTop: 4, marginBottom: 6)
        change(&t)
        return t
    }

    private static func footer(_ k: BuilderKind) -> BuilderFooter {
        BuilderFooter(left: k == .order ? "{{ company.name }} · Order {{ order.number }}" : "{{ company.name }} · Invoice {{ invoice.number }}",
                      pageNumbers: true, size: 7.5, color: "#94a3b8")
    }

    private static func number(_ k: BuilderKind) -> String { k == .order ? "# {{ order.number }}" : "# {{ invoice.number }}" }

    private static func doc(_ k: BuilderKind, _ font: String, _ headerH: Double, _ afterH: Double, _ pieces: [BuilderPiece],
                            _ items: BuilderItems) -> BuilderDoc {
        BuilderDoc(kind: k, page: .init(font: font, size: 9, color: "#1e293b", margins: .init(tb: 16, lr: 15), paper: "A4"),
                   header: .init(h: headerH), after: .init(h: afterH), pieces: pieces, items: items, footer: footer(k))
    }

    static let all: [Preset] = [
        Preset(key: "classic", name: "Classic", description: "Logo and your details on the left, the title in your colour on the right.") { k in
            doc(k, "noto-sans", 78, 72, [
                piece(k, .logo, .header, 0, 0, 45, 18),
                piece(k, .company, .header, 0, 21, 85, 30),
                piece(k, .title, .header, 95, 0, 85, 12),
                piece(k, .text, .header, 95, 12, 85, 6, Over(style: PieceStyle(size: 10, weight: 600, color: "#64748b", align: "right"),
                                                             text: number(k))),
                piece(k, .status, .header, 150, 20, 30, 6),
                piece(k, .line, .header, 0, 55, 180, 0.4),
                piece(k, .customer, .header, 0, 59, 85, 19),
            ] + (k == .order ? [piece(k, .delivery, .header, 60, 59, 45, 19)] : []) + [
                piece(k, .details, .header, 110, 59, 70, 19),
                piece(k, .payment, .after, 0, 3, 98, 32),
                piece(k, .totals, .after, 105, 3, 75, 32),
            ] + (k == .invoice ? [piece(k, .notes, .after, 0, 39, 98, 13)] : []) + [
                piece(k, .terms, .after, 0, 56, 180, 14),
            ], items(k))
        },
        Preset(key: "modern", name: "Modern", description: "The amount in large type up front, light lines, lots of air.") { k in
            doc(k, "calibri", 92, 72, [
                piece(k, .logo, .header, 135, 0, 45, 16, Over(style: PieceStyle(align: "right"))),
                piece(k, .company, .header, 0, 0, 90, 28, Over(style: PieceStyle(size: 8.5, color: "#64748b"))),
                piece(k, .title, .header, 0, 33, 120, 8,
                      Over(style: PieceStyle(size: 11, weight: 700, spacing: 0.18, color: "#64748b", align: "left"))),
                piece(k, .text, .header, 120, 33, 60, 8, Over(style: PieceStyle(size: 10, weight: 700, color: "#0f172a", align: "right"),
                                                              text: number(k))),
                piece(k, .amount, .header, 0, 43, 110, 20),
                piece(k, .status, .header, 150, 45, 30, 6),
                piece(k, .line, .header, 0, 66, 180, 0.3),
                piece(k, .customer, .header, 0, 70, 80, 22),
            ] + (k == .order ? [piece(k, .delivery, .header, 70, 70, 45, 22)] : []) + [
                piece(k, .details, .header, 115, 70, 65, 22),
                piece(k, .totals, .after, 105, 3, 75, 32, Over(style: PieceStyle(highlight: "#0f172a"))),
                piece(k, .payment, .after, 0, 3, 98, 32, Over(style: PieceStyle(bg: "", borderWidth: 0, padding: 0))),
            ] + (k == .invoice ? [piece(k, .notes, .after, 0, 39, 98, 13)] : []) + [
                piece(k, .terms, .after, 0, 56, 180, 14),
            ], items(k) { $0.headerBg = ""; $0.headerColor = "#64748b"; $0.stripe = ""; $0.lineColor = "#e2e8f0"; $0.size = 9 })
        },
        Preset(key: "bold", name: "Bold", description: "A full-width band in your colour across the top, white title on it.") { k in
            doc(k, "noto-sans", 86, 72, [
                piece(k, .box, .header, 0, 0, 180, 34, Over(style: PieceStyle(bg: "accent", radius: 6))),
                piece(k, .title, .header, 8, 7, 110, 12, Over(style: PieceStyle(size: 26, color: "#ffffff", align: "left"))),
                piece(k, .text, .header, 8, 20, 110, 7,
                      Over(style: PieceStyle(size: 11, weight: 600, color: "#ffffff", opacity: 85), text: number(k))),
                piece(k, .logo, .header, 132, 6, 40, 22, Over(style: PieceStyle(align: "right"))),
                piece(k, .company, .header, 0, 40, 80, 30),
                piece(k, .customer, .header, 85, 40, 50, 24),
            ] + (k == .order ? [piece(k, .delivery, .header, 85, 64, 50, 22)] : []) + [
                piece(k, .details, .header, 140, 40, 40, 30, Over(style: PieceStyle(size: 8))),
                piece(k, .totals, .after, 105, 3, 75, 32),
                piece(k, .payment, .after, 0, 3, 98, 32),
            ] + (k == .invoice ? [piece(k, .notes, .after, 0, 39, 98, 13)] : []) + [
                piece(k, .terms, .after, 0, 56, 180, 14),
            ], items(k) { $0.headerBg = "#0f172a" })
        },
        Preset(key: "boxed", name: "Boxed",
               description: "Customer in a box, details and totals in grids, bank details in a table. Formal and complete.") { k in
            boxed(k)
        },
    ]

    static func make(_ key: String, _ kind: BuilderKind) -> BuilderDoc { (all.first { $0.key == key } ?? all[0]).make(kind) }

    // The WorkStation invoice: boxed customer, a grid of details, a gridded items table, totals in a grid and the bank
    // details in a table, with the terms, registration and E&OE underneath.
    private static func boxed(_ k: BuilderKind) -> BuilderDoc {
        let inv = k == .invoice
        let grid = "#333333", shade = "#eeeeee"
        // The Amount column (15% of the 180 mm page width): the grids' value columns line up with it.
        let amountW = 27.0
        func T(_ y: Double, _ h: Double, _ text: String, _ style: PieceStyle = PieceStyle(), _ x: Double = 0,
               _ w: Double = 180) -> BuilderPiece {
            piece(k, .text, .after, x, y, w, h, Over(style: PieceStyle(size: 8.5, color: "#111111").merged(style), text: text))
        }
        var pieces = [
            piece(k, .logo, .header, 0, 0, 62, 20),
            piece(k, .title, .header, 0, 25, 70, 10,
                  Over(style: PieceStyle(size: 17, weight: 400, upper: true, spacing: 0, color: "#111111", align: "left"))),
            piece(k, .company, .header, 112, 0, 68, 34, Over(style: PieceStyle(size: 9, lineHeight: 1.4, color: "#111111", plain: true))),
            piece(k, .customer, .header, 0, 40, 92, 36, Over(
                style: PieceStyle(size: 8.5, color: "#111111", labelColor: "#111111", bg: shade, borderColor: grid, borderWidth: 0.75,
                                  padding: 3.5, plain: true),
                label: inv ? "Bill To :" : "Customer :")),
        ]
        if k == .order {
            pieces.append(piece(k, .delivery, .header, 0, 78, 92, 20, Over(
                style: PieceStyle(size: 8.5, color: "#111111", labelColor: "#111111", plain: true), label: "Deliver to :")))
        }
        pieces += [
            piece(k, .details, .header, 112, 40, 68, inv ? 52 : 44, Over(
                style: PieceStyle(size: 8.5, color: "#111111", labelColor: "#111111", table: "grid", gridColor: grid, labelBg: shade,
                                  valueWidth: amountW),
                names: inv
                    ? ["number": "Invoice#", "date": "Invoice Date", "due": "Due Date", "project": "Project", "by": "Order by",
                       "po": "Your ref, PO number"]
                    : ["number": "Order#", "date": "Order Date", "quote": "Quote", "po": "Your ref, PO number", "delivery": "Delivery"])),
            piece(k, .totals, .after, 112, 0, 68, 34, Over(
                style: PieceStyle(size: 8.5, color: "#111111", labelColor: "#111111", align: "right", highlight: "", table: "grid",
                                  gridColor: grid, valueWidth: amountW),
                names: inv
                    ? ["subtotal": "Subtotal (excl. VAT):", "discount": "Discount:", "vat": "VAT:", "total": "Total:", "paid": "Paid:",
                       "balance": "Balance due:"]
                    : ["subtotal": "Subtotal (excl. VAT):", "discount": "Discount:", "delivery": "Delivery:", "vat": "VAT:",
                       "balance": "Total:"])),
            T(36, 5, "Thank you for your \(inv ? "business" : "order").", PieceStyle(size: 9, weight: 700)),
            T(41, 4, "VAT number: {{ company.vat_number }}", PieceStyle(size: 7.5, weight: 700)),
            T(45, 4, "Terms of business", PieceStyle(size: 7.5, weight: 700, underline: true)),
            T(50, 9, "I certify that this claim is in all respects true, correct, supportable by available documentation, and in compliance with all the terms and conditions, laws and regulations governing its payments."),
            T(60, 5, inv ? "Please note that our payment terms for this invoice are DUE ON RECEIPT." : "Please pay for this order before it is dispatched."),
            // The BACS headings and the note belong to "How to pay": they go when there's nothing to pay.
            piece(k, .payment, .after, 0, 67, 180, 60, Over(
                style: PieceStyle(size: 8.5, color: "#111111", labelColor: "#111111", align: "left", bg: "", borderWidth: 0, padding: 0,
                                  table: "grid", gridColor: "#888888", plain: true),
                text: "Please make payment by electronic transfer to:",
                label: "Paying online by BACS or Internet Banking",
                note: "To make payment via Internet Banking, you simply need to contact your bank with the above bank details. They can advise you if you should use the SWIFT Code or BIC code depending on the payment originating country.",
                show: ["label": true, "method": false, "reference": true], names: ["reference": "Please use reference"])),
            T(129, 8, "{{ company.name }} is a registered company number: {{ company.company_number }}. VAT number: {{ company.vat_number }}. Registered in England and Wales.\nRegistered office address: {{ company.address }}."),
            T(139, 4, "Date: {{ document.printed_on }}", PieceStyle(), 0, 100),
            T(139, 4, "E&OE", PieceStyle(align: "right"), 140, 40),
        ]
        var d = doc(k, "noto-sans", 94, 145, pieces, items(k) { t in
            t.size = 8; t.color = "#111111"; t.headerBg = shade; t.headerColor = "#111111"; t.headerWeight = 700; t.upper = true
            t.headerCenter = true; t.stripe = ""; t.lineColor = grid; t.lines = "grid"; t.padding = 5; t.marginTop = 2; t.marginBottom = 0
            t.columns = inv
                ? [BuilderColumn(key: "n", label: "Item", show: true, align: "center", width: 13),
                   BuilderColumn(key: "qty", label: "Days/Hrs", show: true, align: "center", width: 13),
                   BuilderColumn(key: "description", label: "Description", show: true, align: "left"),
                   BuilderColumn(key: "vat", label: "VAT", show: false, align: "right", width: 12),
                   BuilderColumn(key: "unit", label: "Unit price", show: true, align: "right", width: 15),
                   BuilderColumn(key: "net", label: "Amount", show: true, align: "right", width: 15),
                   BuilderColumn(key: "total", label: "With VAT", show: false, align: "right", width: 15)]
                : [BuilderColumn(key: "n", label: "Item", show: true, align: "center", width: 9),
                   BuilderColumn(key: "sku", label: "Code", show: true, align: "left", width: 12),
                   BuilderColumn(key: "name", label: "Description", show: true, align: "left"),
                   BuilderColumn(key: "qty", label: "Qty", show: true, align: "center", width: 9),
                   BuilderColumn(key: "vat", label: "VAT", show: false, align: "right", width: 12),
                   BuilderColumn(key: "unit", label: "Unit price", show: true, align: "right", width: 15),
                   BuilderColumn(key: "net", label: "Amount", show: true, align: "right", width: 15),
                   BuilderColumn(key: "total", label: "With VAT", show: false, align: "right", width: 15)]
        })
        d.page.margins = .init(tb: 14, lr: 15)
        d.footer = BuilderFooter(left: "", pageNumbers: true, size: 9, color: "#111111", center: true, line: true)
        return d
    }
}

// MARK: - Compiler

/// A designer page → the HTML, CSS and page footer the server prints (compile.ts, line for line). Pieces sit
/// position:absolute inside their band, in millimetres; every piece carries data-el="<id>" and every band
/// data-band="<key>". The CSS never contains {{ … }} (the server doesn't fill CSS in), so the workspace's colour
/// travels as a CSS variable on the page's root.
enum TemplateCompiler {
    struct Compiled: Equatable, Sendable {
        var html: String
        var css: String
        var footerHTML: String
        var marginTB: String
        var marginLR: String
    }

    /// A number as JavaScript writes it in a template string (45, 8.5, 0.04).
    static func js(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// compile.ts `n`: rounded to 0.01 the way Math.round does (halves up).
    static func n(_ v: Double) -> String { js((v * 100 + 0.5).rounded(.down) / 100) }

    static func colour(_ c: String?) -> String { c == "accent" ? "var(--accent)" : c ?? "" }

    /// `a || b` for strings.
    private static func or(_ a: String, _ b: String) -> String { a.isEmpty ? b : a }

    /// The person's own words: escaped, line breaks kept; {{ details }} stay as they are, {% logic %} is defused.
    static func words(_ s: String?) -> String {
        // NSString: by UTF-16 unit, as JavaScript's replace (a String would treat "\r\n" as one character).
        var out = (s ?? "") as NSString
        for (from, to) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("{%", "{ %"), ("\n", "<br>")] {
            out = out.replacingOccurrences(of: from, with: to) as NSString
        }
        return out as String
    }

    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func truthy(_ v: Double?) -> Bool { v.map { $0 != 0 && !$0.isNaN } ?? false }
    private static func truthy(_ v: String?) -> Bool { !(v ?? "").isEmpty }

    /// The piece's box: where it sits and how it looks.
    static func pieceCSS(_ p: BuilderPiece) -> String {
        let s = p.style
        var out = ["position:absolute", "left:\(n(p.x))mm", "top:\(n(p.y))mm", "width:\(n(p.w))mm", "height:\(n(p.h))mm",
                   "box-sizing:border-box", "display:flex", "flex-direction:column"]
        let v = s.valign == "middle" ? "center" : s.valign == "bottom" ? "flex-end" : "flex-start"
        out.append("justify-content:\(v)")
        if truthy(s.font) { out.append("font-family:\(BuilderCatalog.fontStack(s.font))") }
        if truthy(s.size) { out.append("font-size:\(js(s.size!))pt") }
        if truthy(s.weight) { out.append("font-weight:\(js(s.weight!))") }
        if s.italic == true { out.append("font-style:italic") }
        if s.underline == true { out.append("text-decoration:underline") }
        if s.upper == true { out.append("text-transform:uppercase") }
        if truthy(s.spacing) { out.append("letter-spacing:\(js(s.spacing!))em") }
        if truthy(s.lineHeight) { out.append("line-height:\(js(s.lineHeight!))") }
        if truthy(s.color) { out.append("color:\(colour(s.color))") }
        if truthy(s.align) { out.append("text-align:\(s.align!)") }
        if truthy(s.bg) { out.append("background:\(colour(s.bg))") }
        if truthy(s.borderWidth) && truthy(s.borderColor) {
            out.append("border:\(js(s.borderWidth!))pt \(or(s.borderStyle ?? "", "solid")) \(colour(s.borderColor))")
        }
        if truthy(s.radius) { out.append("border-radius:\(js(s.radius!))pt") }
        if truthy(s.padding) { out.append("padding:\(js(s.padding!))mm") }
        if let o = s.opacity, o < 100 { out.append("opacity:\(js(o / 100))") }
        if truthy(s.labelColor) { out.append("--label:\(colour(s.labelColor))") }
        if s.table == "grid" {
            out.append("--grid:\(or(colour(s.gridColor), "#333333"))")
            out.append("--label-bg:\(or(colour(s.labelBg), "transparent"))")
        }
        if s.table == "grid" && truthy(s.valueWidth) { out.append("--vw:\(n(s.valueWidth!))mm") }
        if p.type == .line || p.type == .box { out.append("overflow:hidden") }
        return out.joined(separator: ";")
    }

    private static func on(_ p: BuilderPiece, _ k: String) -> Bool { p.show?[k] != false }

    /// The words beside a value: the person's own, else ours.
    private static func nm(_ p: BuilderPiece, _ k: String, _ ours: String) -> String {
        if let own = p.names?[k] { return words(own) }
        return ours
    }

    /// Wraps `body` in {% if %} for each detail the words use, so a line with an empty detail isn't printed half-empty.
    static func whenFilled(_ text: String?, _ body: String) -> String {
        var paths: [String] = []
        for match in (text ?? "").matches(of: /\{\{\s*([a-zA-Z0-9_.]+)\s*(?:\|[^}]*)?\}\}/) {
            let path = String(match.1)
            if !paths.contains(path) { paths.append(path) }
        }
        return paths.reversed().reduce(body) { inner, path in "{% if \(path) %}\(inner){% endif %}" }
    }

    private static func label(_ p: BuilderPiece, _ fallback: String) -> String {
        on(p, "label") ? "<div class=\"vb-label\">\(words(p.label ?? fallback))</div>" : ""
    }

    /// What a piece prints: template language, filled in by the server for each invoice or order.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func inner(_ p: BuilderPiece, _ kind: BuilderKind, _ editor: Bool) -> String {
        let rec = kind == .order ? "order" : "invoice"
        let s = p.style
        switch p.type {
        case .logo:
            let pos = s.align == "right" ? "right" : s.align == "center" ? "center" : "left"
            return "{% if company.logo %}<img class=\"vb-img\" src=\"{{ company.logo }}\" alt=\"\" style=\"object-position:\(pos) center\">"
                + (editor ? "{% else %}<div class=\"vb-ph\">Your logo<br><small>Add it in Invoice and order design</small></div>" : "")
                + "{% endif %}"
        case .image:
            let pos = s.align == "right" ? "right" : s.align == "center" ? "center" : "left"
            if let src = p.src, !src.isEmpty {
                return "<img class=\"vb-img\" src=\"\(attr(src))\" alt=\"\" style=\"object-position:\(pos) center\">"
            }
            return editor ? "<div class=\"vb-ph\">Add a picture<br><small>Choose one on the right</small></div>" : ""
        case .title, .text:
            // "VAT number: {{ company.vat_number }}" with no VAT number on file prints nothing, not "VAT number:".
            let body = "<div>\(words(p.text))</div>"
            return p.show?["whenFilled"] == false ? body : whenFilled(p.text, body)
        case .company:
            return [
                on(p, "name") ? "<div class=\"vb-name\">{{ company.name }}</div>" : "",
                on(p, "address") ? "{% for line in company.address_lines %}<div>{{ line }}</div>{% endfor %}" : "",
                on(p, "email") ? "{% if company.email %}<div>{{ company.email }}</div>{% endif %}" : "",
                on(p, "phone") ? "{% if company.phone %}<div>{{ company.phone }}</div>{% endif %}" : "",
                on(p, "vat") ? "{% if company.vat_number %}<div>VAT {{ company.vat_number }}</div>{% endif %}" : "",
            ].joined()
        case .customer:
            return [
                label(p, kind == .order ? "Customer" : "Billed to"),
                on(p, "name") ? "<div class=\"vb-name\">{{ customer.name }}</div>" : "",
                on(p, "email") ? "{% if customer.email %}<div>{{ customer.email }}</div>{% endif %}" : "",
                on(p, "address") ? "{% for line in customer.address_lines %}<div>{{ line }}</div>{% endfor %}" : "",
            ].joined()
        case .delivery:
            return "{% if has_delivery_address %}\(label(p, "Deliver to")){% for line in delivery_address_lines %}<div>{{ line }}</div>{% endfor %}{% endif %}"
        case .details:
            // In a grid every row shows (an empty cell is part of the form); plain, a row only shows with a value.
            let grid = s.table == "grid"
            func row(_ key: String, _ ours: String, _ value: String, _ cond: String? = nil) -> String {
                guard on(p, key) else { return "" }
                let tr = "<tr><td class=\"vb-k\">\(nm(p, key, ours))</td><td class=\"vb-v\">\(value)</td></tr>"
                if let cond, !grid { return "{% if \(cond) %}\(tr){% endif %}" }
                return tr
            }
            let rows = kind == .order
                ? [row("number", "Order number", "{{ order.number }}"), row("date", "Order date", "{{ order.date }}", "order.date"),
                   row("quote", "Quote", "{{ order.quote_number }}", "order.quote_number"),
                   row("po", "Your PO number", "{{ order.po_number }}", "order.po_number"),
                   row("delivery", "Delivery", "{{ order.delivery_date }}", "order.delivery_date")]
                : [row("number", "Invoice number", "{{ invoice.number }}"),
                   row("date", "Issue date", "{{ invoice.issue_date }}", "invoice.issue_date"),
                   row("due", "Due date", "{{ invoice.due_date }}", "invoice.due_date"),
                   row("project", "Project", "{{ invoice.project }}", "invoice.project"),
                   row("by", "Order by", "{{ invoice.ordered_by }}", "invoice.ordered_by"),
                   row("po", "Your PO number", "{{ invoice.po_number }}", "invoice.po_number")]
            return "<table class=\"vb-kv\">\(rows.joined())</table>"
        case .amount:
            if kind == .order {
                return (on(p, "label") ? "<div class=\"vb-label\">{% if order.is_paid %}Paid with thanks{% else %}Order total{% endif %}</div>" : "")
                    + "<div>{{ order.total_formatted }}</div>"
            }
            return (on(p, "label") ? "<div class=\"vb-label\">{% if invoice.is_paid %}Paid with thanks{% else %}Amount due{% endif %}</div>" : "")
                + "<div>{{ invoice.balance_due_formatted }}</div>"
                + (on(p, "due") ? "{% if invoice.due_date %}{% if invoice.is_paid %}{% else %}<div class=\"vb-sub\">Due {{ invoice.due_date }}</div>{% endif %}{% endif %}" : "")
        case .status:
            return "<div>{{ \(rec).status_label }}</div>"
        case .totals:
            func tr(_ k: String, _ ours: String, _ v: String, _ strong: Bool = false) -> String {
                on(p, k) ? "<tr\(strong ? " class=\"vb-strong\"" : "")><td class=\"vb-k\">\(nm(p, k, ours))</td><td class=\"vb-v\">\(v)</td></tr>" : ""
            }
            // The last line: a coloured bar, or (no bar colour, or a grid) a bold row like the others.
            let asBar = truthy(s.highlight) && s.table != "grid"
            func last(_ ours: String, _ v: String) -> String {
                guard on(p, "balance") else { return "" }
                return asBar
                    ? "</table><div class=\"vb-bar\" style=\"background:\(colour(s.highlight));color:\(or(colour(s.highlightText), "inherit"))\"><span>\(nm(p, "balance", ours))</span><span>\(v)</span></div><table>"
                    : tr("balance", ours, v, true)
            }
            let own = p.names?["balance"].flatMap { $0.isEmpty ? nil : $0 }
            if kind == .order {
                return "<table class=\"vb-kv\">\(tr("subtotal", "Subtotal", "{{ order.subtotal_formatted }}"))"
                    + "{% if order.discount > 0 %}\(tr("discount", "Discount", "−{{ order.discount_formatted }}")){% endif %}"
                    + "{% if order.delivery > 0 %}\(tr("delivery", "Delivery", "{{ order.delivery_formatted }}")){% endif %}"
                    + tr("vat", "VAT", "{{ order.vat_formatted }}")
                    + "\(last(own ?? "{% if order.is_paid %}Total paid{% else %}Total{% endif %}", "{{ order.total_formatted }}"))</table>"
            }
            return "<table class=\"vb-kv\">\(tr("subtotal", "Subtotal", "{{ invoice.subtotal_formatted }}"))"
                + "{% if invoice.discount > 0 %}\(tr("discount", "Discount", "−{{ invoice.discount_formatted }}")){% endif %}"
                + "\(tr("vat", "VAT", "{{ invoice.tax_total_formatted }}"))\(tr("total", "Total", "{{ invoice.total_formatted }}", true))"
                + "{% if invoice.amount_paid > 0 %}\(tr("paid", "Paid", "{{ invoice.amount_paid_formatted }}")){% endif %}"
                + "\(last(own ?? "{% if invoice.is_paid %}Paid in full{% else %}Balance due{% endif %}", "{{ invoice.balance_due_formatted }}"))</table>"
        case .payment:
            // Everything here, the words above and below included, only prints while there's something to pay.
            let intro = truthy(p.text) ? "<div class=\"vb-intro\">\(words(p.text))</div>" : ""
            return "{% if payment.label %}\(label(p, "How to pay"))\(intro)"
                + (on(p, "method") ? "<div class=\"vb-name\">{{ payment.label }}</div>" : "")
                + "<table class=\"vb-kv vb-left\">{% for row in payment.rows %}<tr><td class=\"vb-k\">{{ row.label }}</td><td class=\"vb-v\">{{ row.value }}</td></tr>{% endfor %}"
                + (on(p, "reference") ? "{% if payment.reference %}<tr><td class=\"vb-k\">\(nm(p, "reference", "Reference"))</td><td class=\"vb-v\">{{ payment.reference }}</td></tr>{% endif %}" : "")
                + "</table>{% if payment.instructions %}<div class=\"vb-sub\">{{ payment.instructions }}</div>{% endif %}"
                + (truthy(p.note) ? "<div class=\"vb-note\">\(words(p.note))</div>" : "") + "{% endif %}"
        case .vat:
            return "{% if invoice.vat_by_rate %}<table class=\"vb-kv vb-left\"><tr><td class=\"vb-k\">VAT rate</td><td class=\"vb-k\">Net</td><td class=\"vb-k\">VAT</td></tr>"
                + "{% for row in invoice.vat_breakdown %}<tr><td>{{ row.label }}</td><td>{{ row.net_formatted }}</td><td>{{ row.vat_formatted }}</td></tr>{% endfor %}</table>"
                + (editor ? "{% else %}<div class=\"vb-ph\">Shows when an invoice has more than one VAT rate</div>" : "") + "{% endif %}"
        case .notes:
            return "{% if invoice.notes %}\(label(p, "Notes"))<div>{{ invoice.notes }}</div>{% endif %}"
        case .terms:
            return label(p, "Payment terms")
                + (kind == .invoice && on(p, "days") ? "{% if invoice.payment_terms_days %}<div>Payment is due within {{ invoice.payment_terms_days }} days.</div>{% endif %}" : "")
                + "{% if document.terms_html %}<div>{{ document.terms_html | raw }}</div>{% endif %}"
        case .box, .line:
            return ""
        }
    }

    private static func cell(_ key: String, _ kind: BuilderKind) -> String {
        if kind == .order {
            switch key {
            case "n": return "{{ forloop.index }}"
            case "name": return "{{ line.name }}{% if line.detail %}<div class=\"vb-sub\">{{ line.detail }}</div>{% endif %}"
            case "sku": return "{{ line.sku }}"
            case "qty": return "{{ line.qty }}"
            case "unit": return "{{ line.unit_price_formatted }}"
            case "vat": return "{{ line.vat_formatted }}"
            case "total": return "{{ line.total_formatted }}"
            case "net": return "{{ line.net_formatted }}"
            default: return ""
            }
        }
        switch key {
        case "n": return "{{ forloop.index }}"
        case "description": return "{{ item.description }}"
        case "qty": return "{{ item.quantity }}"
        case "unit": return "{{ item.unit_price_formatted }}"
        case "vat": return "{{ item.tax_amount_formatted }}"
        case "total": return "{{ item.total_formatted }}"
        case "net": return "{{ item.net_formatted }}"
        default: return ""
        }
    }

    private static func itemsTable(_ t: BuilderItems, _ kind: BuilderKind) -> String {
        let cols = t.columns.filter(\.show)
        let loop = kind == .order ? "line in order.lines" : "item in invoice.items"
        func w(_ c: BuilderColumn) -> String { truthy(c.width) ? " style=\"width:\(js(c.width!))%\"" : "" }
        let th = cols.map { "<th class=\"vb-\(t.headerCenter == true ? "center" : $0.align)\"\(w($0))>\(words($0.label))</th>" }.joined()
        let td = cols.map {
            "<td class=\"vb-\($0.align)\($0.key == "total" || $0.key == "net" ? " vb-strong" : "")\">\(cell($0.key, kind))</td>"
        }.joined()
        return "<table class=\"vb-items\" data-band=\"items\"><thead><tr>\(th)</tr></thead><tbody>{% for \(loop) %}<tr>\(td)</tr>{% endfor %}</tbody></table>"
    }

    private static func itemsCSS(_ t: BuilderItems) -> String {
        let line = or(colour(t.lineColor), "#e2e8f0")
        return [
            ".vb-items{width:100%;border-collapse:collapse;font-size:\(js(t.size))pt;color:\(or(colour(t.color), "inherit"));margin:\(js(t.marginTop))mm 0 \(js(t.marginBottom))mm;}",
            ".vb-items th{padding:\(js(t.padding))pt \(js(t.padding + 2))pt;background:\(or(colour(t.headerBg), "transparent"));color:\(or(colour(t.headerColor), "inherit"));"
                + "font-weight:\(js(t.headerWeight));\(t.upper ? "text-transform:uppercase;letter-spacing:.06em;font-size:.88em;" : "")"
                + (truthy(t.headerBg) ? "" : "border-bottom:1pt solid \(line);") + "}",
            ".vb-items td{padding:\(js(t.padding))pt \(js(t.padding + 2))pt;vertical-align:top;\(t.lines != "none" ? "border-bottom:.6pt solid \(line);" : "")}",
            t.lines == "grid" ? ".vb-items th,.vb-items td{border:.6pt solid \(line);}" : "",
            truthy(t.stripe) ? ".vb-items tbody tr:nth-child(even) td{background:\(colour(t.stripe));}" : "",
        ].joined(separator: "\n")
    }

    static let baseCSS = """
    *{box-sizing:border-box}
    html,body{margin:0;padding:0}
    body{-webkit-print-color-adjust:exact;print-color-adjust:exact}
    .vb{position:relative}
    .vb-band{position:relative;width:100%}
    .vb-after{break-inside:avoid;page-break-inside:avoid}
    .vb-el>*{margin:0}
    .vb-img{display:block;width:100%;height:100%;object-fit:contain}
    .vb-ph{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;border:1px dashed #cbd5e1;border-radius:4pt;color:#94a3b8;font-size:8pt;line-height:1.3;background:#f8fafc}
    .vb-ph small{font-size:6.5pt}
    .vb-label{font-size:.78em;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--label,#64748b);margin-bottom:2pt}
    .vb-name{font-weight:700;font-size:1.2em}
    .vb-sub{font-size:.85em;opacity:.75}
    .vb-kv{width:100%;border-collapse:collapse}
    .vb-kv td{padding:1.2pt 0;vertical-align:top}
    .vb-kv .vb-k{color:var(--label,#64748b);padding-right:10pt}
    .vb-kv .vb-v{text-align:right;font-weight:600}
    .vb-left .vb-v{text-align:left}
    .vb-bar{display:flex;justify-content:space-between;gap:8pt;margin-top:4pt;padding:4.5pt 7pt;border-radius:4pt;font-weight:700;font-size:1.1em}
    .vb-items thead{display:table-header-group}
    .vb-items tr{break-inside:avoid;page-break-inside:avoid}
    .vb-left,th.vb-left,td.vb-left{text-align:left}
    .vb-center{text-align:center}
    .vb-right{text-align:right}
    .vb-strong{font-weight:700}
    .vb-intro{font-weight:700;margin-bottom:3pt}
    .vb-note{font-weight:700;margin-top:4pt}
    .vb-plain .vb-label{text-transform:none;letter-spacing:0;font-size:1em;font-weight:700;margin-bottom:1pt}
    .vb-plain .vb-name{font-size:1em}
    .vb-gridded .vb-kv td{border:.6pt solid var(--grid);padding:3.5pt 6pt;vertical-align:middle}
    .vb-gridded .vb-kv .vb-k{background:var(--label-bg);color:var(--label,inherit);font-weight:700;padding-right:6pt}
    .vb-gridded .vb-kv .vb-v{font-weight:400;width:var(--vw,auto)}
    .vb-gridded .vb-kv tr.vb-strong td{font-weight:700}
    .vb-gridded.vb-details .vb-v{text-align:center}
    .vb-gridded.vb-totals .vb-k{text-align:right;font-weight:400}
    .vb-gridded.vb-totals tr.vb-strong .vb-k{font-weight:700}
    .vb-gridded.vb-payment .vb-k{font-weight:400;width:50%}
    .vb-gridded.vb-payment .vb-kv{width:92mm;max-width:100%;font-size:1.1em}
    .vb-gridded.vb-payment .vb-kv td{padding:4pt 7pt}
    """

    /// The whole page. `editor` adds the placeholders a person needs while designing (an empty logo box…).
    static func compile(_ d: BuilderDoc, editor: Bool = false) -> Compiled {
        func pieces(_ band: BuilderBand) -> String {
            d.pieces.filter { $0.band == band && $0.hidden != true }.map { p in
                "<div class=\"vb-el vb-\(p.type.rawValue)\(p.style.plain == true ? " vb-plain" : "")\(p.style.table == "grid" ? " vb-gridded" : "")\" data-el=\"\(p.id)\" style=\"\(pieceCSS(p))\">\(inner(p, d.kind, editor))</div>"
            }.joined(separator: "\n")
        }
        let html = """
        <div class="vb" style="--accent:{{ theme.accent }};font-family:\(BuilderCatalog.fontStack(d.page.font));font-size:\(js(d.page.size))pt;color:\(or(colour(d.page.color), "#1e293b"));line-height:1.35;">
        <div class="vb-band" data-band="header" style="height:\(n(d.header.h))mm">
        \(pieces(.header))
        </div>
        \(itemsTable(d.items, d.kind))
        <div class="vb-band vb-after" data-band="after" style="height:\(n(d.after.h))mm">
        \(pieces(.after))
        </div>
        </div>
        """
        let css = "\(baseCSS)\n\(itemsCSS(d.items))"
        let f = d.footer
        // Chromium lays the footer out in its own box: one full-width block with the page's side space as padding.
        let rule = f.line == true ? "border-top:.75pt solid \(or(colour(f.color), "#94a3b8"));padding-top:3pt;" : ""
        let footer = """
        <html><head><style>
        html,body{margin:0;padding:0}
        body{font-family:\(BuilderCatalog.fontStack(d.page.font));font-size:\(js(f.size))pt;color:\(or(colour(f.color), "#94a3b8"));-webkit-print-color-adjust:exact}
        .f{box-sizing:border-box;width:100%;padding:0 \(js(d.page.margins.lr))mm}
        .in{\(rule)\(f.center == true ? "text-align:center" : "display:flex;justify-content:space-between;gap:12pt")}
        .in>span+span{\(f.center == true ? "margin-left:12pt" : "")}
        </style></head><body><div class="f"><div class="in">
        """ + (truthy(f.left) ? "<span>\(words(f.left))</span>" : "")
            + (f.pageNumbers ? "<span>Page <span class=\"pageNumber\"></span> of <span class=\"totalPages\"></span></span>" : "")
            + "</div></div></body></html>"
        return Compiled(html: html, css: css, footerHTML: footer, marginTB: "\(js(d.page.margins.tb))mm",
                        marginLR: "\(js(d.page.margins.lr))mm")
    }

    /// What a template made with the designer saves: its compiled parts and page, with the page itself in `config.builder`
    /// (beside whatever else the config holds).
    static func templateFields(_ d: BuilderDoc, config: [String: JSONValue] = [:]) -> [String: JSONValue] {
        let c = compile(d)
        var config = config
        config["builder"] = d.json
        return ["template_html": .string(c.html), "template_css": .string(c.css), "footer_html": .string(c.footerHTML),
                "page_size": .string(d.page.paper), "page_orientation": .string("portrait"),
                "margin_top": .string(c.marginTB), "margin_bottom": .string(c.marginTB),
                "margin_left": .string(c.marginLR), "margin_right": .string(c.marginLR), "config": .object(config)]
    }
}
