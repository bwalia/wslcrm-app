import UIKit

/// How a workspace's invoices and orders look: logo, colours, font, heading, which parts show, and its own
/// intro, terms and footer (`GET /api/v2/document-designs`, set on the web dashboard under Workspace →
/// Invoice and order design). The PDFs are drawn here on the device, unless the workspace chose an HTML
/// template for them: then the server makes them (`WorkspacePDF`).
struct DocumentDesign: Sendable, Equatable {
    enum Kind: String, Sendable { case invoice, order }
    enum Style: String, Sendable { case band, clean, minimal }
    enum Typeface: String, Sendable { case helvetica, times, courier }

    var style: Style = .band
    var accent = UIColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
    var header = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
    var typeface: Typeface = .helvetica
    var title: String
    var billToLabel: String
    var logoOnRight = false
    var logoHeight: CGFloat = 44
    /// Parts switched off (normalised keys: "companyaddress", "taxcolumn" …); everything else shows.
    var hidden: Set<String> = []
    var intro: RichNode?
    var terms: RichNode?
    var footer: RichNode?
    var logo: Data?
    /// The workspace chose an HTML template (`source: "template"`): the server makes this kind's PDF.
    var usesTemplate = false

    /// The standard design: what a workspace that never changed it gets.
    static func standard(_ kind: Kind) -> DocumentDesign {
        DocumentDesign(title: kind == .invoice ? "INVOICE" : "ORDER", billToLabel: kind == .invoice ? "BILLED TO" : "CUSTOMER")
    }

    func shows(_ part: String) -> Bool { !hidden.contains(Self.key(part)) }

    static func key(_ part: String) -> String { part.replacingOccurrences(of: "_", with: "").lowercased() }

    var logoImage: UIImage? { logo.flatMap(UIImage.init(data:)) }

    /// "#rrggbb" → colour; anything else nil.
    static func color(_ hex: String?) -> UIColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// The bytes of a `data:image/png|jpeg;base64,…` logo.
    static func logoData(_ url: String?) -> Data? {
        guard let url, url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// One design as the server sends it. Anything missing or odd keeps the standard value.
    init(kind: Kind, raw: Raw) {
        self = Self.standard(kind)
        if let s = raw.style.flatMap(Style.init(rawValue:)) { style = s }
        if let c = Self.color(raw.accent) { accent = c }
        if let c = Self.color(raw.header) { header = c }
        if let f = raw.font.flatMap(Typeface.init(rawValue:)) { typeface = f }
        if let t = raw.title?.trimmedOrNil { title = t }
        if let t = raw.billToLabel?.trimmedOrNil { billToLabel = t }
        logoOnRight = raw.logoPosition == "right"
        logoHeight = ["small": 28, "medium": 44, "large": 64][raw.logoSize ?? ""] ?? 44
        hidden = Set((raw.show ?? [:]).filter { !$0.value }.map { Self.key($0.key) })
        intro = raw.intro
        terms = raw.terms
        footer = raw.footer
        logo = Self.logoData(raw.logo)
        usesTemplate = raw.source == "template"
    }

    init(title: String, billToLabel: String) {
        self.title = title
        self.billToLabel = billToLabel
    }

    struct Raw: Decodable, Sendable {
        var style, accent, header, font, title, billToLabel, logoPosition, logoSize, logo, source: String?
        var show: [String: Bool]?
        var intro, terms, footer: RichNode?

        enum CodingKeys: String, CodingKey {
            case style, accent, header, font, title, billToLabel, logoPosition, logoSize, logo, show, intro, terms, footer, source
        }

        // Field by field: one bad value doesn't lose the rest of the design.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
            style = s(.style); accent = s(.accent); header = s(.header); font = s(.font); title = s(.title)
            billToLabel = s(.billToLabel); logoPosition = s(.logoPosition); logoSize = s(.logoSize); logo = s(.logo)
            source = s(.source)
            show = try? c.decodeIfPresent([String: Bool].self, forKey: .show)
            intro = try? c.decodeIfPresent(RichNode.self, forKey: .intro)
            terms = try? c.decodeIfPresent(RichNode.self, forKey: .terms)
            footer = try? c.decodeIfPresent(RichNode.self, forKey: .footer)
        }
    }

    /// `{ invoice?, order? }`
    struct Payload: Decodable, Sendable {
        var invoice: Raw?
        var order: Raw?

        enum CodingKeys: String, CodingKey { case invoice, order }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            invoice = try? c.decodeIfPresent(Raw.self, forKey: .invoice)
            order = try? c.decodeIfPresent(Raw.self, forKey: .order)
        }
    }
}

extension DocumentDesign.Typeface {
    func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let names = switch self {
        case .helvetica: ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"]
        case .times: ["TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "TimesNewRomanPS-ItalicMT", "TimesNewRomanPS-BoldItalicMT"]
        case .courier: ["Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"]
        }
        return UIFont(name: names[(bold ? 1 : 0) + (italic ? 2 : 0)], size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

/// The workspace's designs, fetched when a PDF is made and kept for five minutes. A failure (offline, an
/// older server) gives the standard design: a PDF is never held up by its design.
@MainActor
enum DocumentDesigns {
    private static var cache: [String: (at: Date, payload: DocumentDesign.Payload)] = [:]

    static func get(_ kind: DocumentDesign.Kind, services: Services, workspace: String?) async -> DocumentDesign {
        let key = workspace ?? ""
        var payload = cache[key].flatMap { Date().timeIntervalSince($0.at) < 300 ? $0.payload : nil }
        if payload == nil, let fetched = try? await services.client.send(
            .get("/api/v2/document-designs"), as: Envelope.Standard<DocumentDesign.Payload>.self).data {
            payload = fetched
            if workspace != nil { cache[key] = (Date(), fetched) }
        }
        let raw = kind == .invoice ? payload?.invoice : payload?.order
        return raw.map { DocumentDesign(kind: kind, raw: $0) } ?? .standard(kind)
    }
}

// MARK: - Rich text

/// A TipTap (ProseMirror) node as the server keeps it: paragraphs, headings, lists, line breaks and
/// bold / italic / underline / colour text.
struct RichNode: Decodable, Sendable, Equatable {
    var type: String
    var text: String?
    var marks: [Mark] = []
    var align: String?
    var level: Int?
    var content: [RichNode] = []

    struct Mark: Decodable, Sendable, Equatable {
        var type: String
        var color: String?

        enum CodingKeys: String, CodingKey { case type, attrs }
        struct Attrs: Decodable { var color: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? c.decode(String.self, forKey: .type)) ?? ""
            color = (try? c.decodeIfPresent(Attrs.self, forKey: .attrs))?.color
        }
    }

    enum CodingKeys: String, CodingKey { case type, text, marks, attrs, content }
    struct Attrs: Decodable {
        var textAlign: String?
        var level: Int?
        enum CodingKeys: String, CodingKey { case textAlign, level }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            textAlign = try? c.decodeIfPresent(String.self, forKey: .textAlign)
            level = try? c.decodeIfPresent(Int.self, forKey: .level)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        marks = (try? c.decodeIfPresent([Mark].self, forKey: .marks)) ?? []
        let attrs = try? c.decodeIfPresent(Attrs.self, forKey: .attrs)
        align = attrs?.textAlign
        level = attrs?.level
        content = (try? c.decodeIfPresent([RichNode].self, forKey: .content)) ?? []
    }
}

enum DocumentRichText {
    /// The document as styled text, walked by hand (no HTML, no web view). Paragraphs end with "\n";
    /// a line break inside one is U+2028.
    static func attributed(_ doc: RichNode, typeface: DocumentDesign.Typeface, size: CGFloat, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func inline(_ nodes: [RichNode], size: CGFloat, bold: Bool) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for n in nodes {
                if n.type == "hardBreak" {
                    s.append(NSAttributedString(string: "\u{2028}", attributes: [.font: typeface.font(size)]))
                    continue
                }
                guard n.type == "text", let text = n.text else { continue }
                let types = Set(n.marks.map(\.type))
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: typeface.font(size, bold: bold || types.contains("bold"), italic: types.contains("italic")),
                    .foregroundColor: n.marks.compactMap { DocumentDesign.color($0.color) }.first ?? color,
                ]
                if types.contains("underline") { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                s.append(NSAttributedString(string: text, attributes: attrs))
            }
            return s
        }
        func paragraph(_ body: NSAttributedString, align: String?, indent: CGFloat, prefix: String? = nil, size: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.alignment = align == "center" ? .center : align == "right" ? .right : .left
            style.paragraphSpacing = size * 0.35
            style.firstLineHeadIndent = indent
            style.headIndent = indent + (prefix == nil ? 0 : 14)
            if prefix != nil { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 14)] }
            let line = NSMutableAttributedString()
            if let prefix { line.append(NSAttributedString(string: prefix + "\t", attributes: [.font: typeface.font(size), .foregroundColor: color])) }
            line.append(body)
            line.append(NSAttributedString(string: "\n", attributes: [.font: typeface.font(size)]))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        func blocks(_ nodes: [RichNode], indent: CGFloat) {
            for n in nodes {
                switch n.type {
                case "paragraph":
                    paragraph(inline(n.content, size: size, bold: false), align: n.align, indent: indent, size: size)
                case "heading":
                    let scale: CGFloat = [1: 1.5, 2: 1.3, 3: 1.15][n.level ?? 2] ?? 1.3
                    paragraph(inline(n.content, size: size * scale, bold: true), align: n.align, indent: indent, size: size * scale)
                case "bulletList", "orderedList":
                    for (i, item) in n.content.enumerated() where item.type == "listItem" {
                        let prefix = n.type == "bulletList" ? "•" : "\(i + 1)."
                        for (j, child) in item.content.enumerated() {
                            if child.type == "paragraph" {
                                paragraph(inline(child.content, size: size, bold: false), align: nil, indent: indent,
                                          prefix: j == 0 ? prefix : "", size: size)
                            } else {
                                blocks([child], indent: indent + 14)
                            }
                        }
                    }
                default:
                    blocks(n.content, indent: indent)
                }
            }
        }
        blocks(doc.content, indent: 0)
        // No trailing newline: it would add an empty line to the measured height.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}

// MARK: - Drawing

/// The company printed in a document's header. The workspace's own letterhead and logo when the phone has
/// them (`Brand.current` with a logo is the workspace's brand; without one it is the house brand, whose
/// address must never be printed on someone else's invoice).
struct DocumentLetterhead {
    var name: String
    var lines: [(part: String, text: String)] = []
    var logo: UIImage?

    @MainActor
    static func current(name: String?) -> DocumentLetterhead {
        let brand = Brand.current
        let own = brand.logoFile != nil
        var head = DocumentLetterhead(name: name?.trimmedOrNil ?? (own ? brand.name : ""))
        if own {
            let c = brand.company
            head.lines = [("company_address", c.address), ("company_email", c.email), ("company_phone", c.phone),
                          ("tax_id", c.vatNumber.map { "VAT No \($0)" })].compactMap { p in p.1.map { (p.0, $0) } }
            head.logo = brand.logoFile.flatMap { UIImage(contentsOfFile: $0.path) }
        }
        return head
    }
}

/// An A4 page drawn to a design: a cursor (`y`) down the page, the header, rich blocks and the footer.
/// Shared by the invoice and the order so they stay one family.
@MainActor
final class DesignedPage {
    static let size = CGSize(width: 595, height: 842)
    let margin: CGFloat = 44
    var right: CGFloat { Self.size.width - margin }
    var width: CGFloat { right - margin }
    let design: DocumentDesign
    private let context: UIGraphicsPDFRendererContext
    var y: CGFloat = 44

    static let dark = UIColor(red: 30 / 255, green: 41 / 255, blue: 59 / 255, alpha: 1)
    static let muted = UIColor(red: 100 / 255, green: 116 / 255, blue: 139 / 255, alpha: 1)
    static let faint = UIColor(red: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 1)
    static let line = UIColor(red: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 1)
    static let soft = UIColor(red: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)

    init(design: DocumentDesign, context: UIGraphicsPDFRendererContext) {
        self.design = design
        self.context = context
    }

    /// Bottom of the area content may use (the footer sits below it on the last page).
    var bottom: CGFloat { Self.size.height - 70 }

    func newPage() {
        context.beginPage()
        y = margin
    }

    /// A new page when `height` doesn't fit below the cursor.
    func ensure(_ height: CGFloat) {
        if y + height > bottom { newPage() }
    }

    func font(_ size: CGFloat, bold: Bool = false) -> UIFont { design.typeface.font(size, bold: bold) }

    private func attributes(_ size: CGFloat, bold: Bool, color: UIColor, align: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        return [.font: font(size, bold: bold), .foregroundColor: color, .paragraphStyle: style]
    }

    func measure(_ s: String, width: CGFloat, size: CGFloat, bold: Bool = false) -> CGFloat {
        ceil((s as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                                          attributes: attributes(size, bold: bold, color: .black, align: .left), context: nil).height)
    }

    /// Draws text with its top at `top` (default: the cursor) and returns its height.
    @discardableResult
    func text(_ s: String, x: CGFloat, top: CGFloat? = nil, width: CGFloat, size: CGFloat, bold: Bool = false,
              color: UIColor = DesignedPage.dark, align: NSTextAlignment = .left) -> CGFloat {
        let h = measure(s, width: width, size: size, bold: bold)
        (s as NSString).draw(in: CGRect(x: x, y: top ?? y, width: width, height: h),
                             withAttributes: attributes(size, bold: bold, color: color, align: align))
        return h
    }

    func fill(_ rect: CGRect, _ color: UIColor, radius: CGFloat = 0) {
        color.setFill()
        (radius > 0 ? UIBezierPath(roundedRect: rect, cornerRadius: radius) : UIBezierPath(rect: rect)).fill()
    }

    func hairline(at yy: CGFloat, from x: CGFloat? = nil, color: UIColor = DesignedPage.line, width w: CGFloat = 0.5) {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: x ?? margin, y: yy))
        p.addLine(to: CGPoint(x: right, y: yy))
        color.setStroke()
        p.lineWidth = w
        p.stroke()
    }

    /// The logo scaled to `logoHeight` (at most 160 wide), keeping its shape.
    private func logoSize(_ image: UIImage) -> CGSize {
        let h = design.logoHeight
        let w = min(160, h * image.size.width / max(image.size.height, 1))
        return CGSize(width: w, height: w * image.size.height / max(image.size.width, 1))
    }

    /// The header: company (with logo) on one side, the title, number and status on the other, in the
    /// design's style. Leaves the cursor under it.
    func header(_ head: DocumentLetterhead, number: String, status: (String, UIColor)?) {
        let band = design.style == .band
        let nameColor = band ? UIColor.white : DesignedPage.dark
        let subColor = band ? DesignedPage.faint : DesignedPage.muted
        let titleColor = band ? UIColor.white : design.style == .clean ? design.accent : DesignedPage.dark
        let logo = design.logoImage ?? head.logo
        let top: CGFloat = 32
        let half = width / 2 - 8
        let lines = head.lines.filter { design.shows($0.part) }.map(\.text)

        // Measure both sides first: the band is filled before anything is drawn on it.
        var left = top
        let logoBox = logo.map(logoSize)
        if let logoBox, !design.logoOnRight { left += logoBox.height + 10 }
        let nameH = head.name.isEmpty ? 0 : measure(head.name, width: half, size: 17, bold: true)
        left += nameH + (nameH > 0 ? 4 : 0)
        let linesText = lines.joined(separator: "\n")
        let linesH = linesText.isEmpty ? 0 : measure(linesText, width: half, size: 8.5)
        left += linesH

        var rightY = top
        if let logoBox, design.logoOnRight { rightY += logoBox.height + 10 }
        let titleH = measure(design.title, width: half, size: 26, bold: true)
        rightY += titleH + 2
        let numberH = measure(number, width: half, size: 11)
        rightY += numberH + 6
        if status != nil { rightY += 22 }
        let bottomY = max(left, rightY) + 18

        if band {
            fill(CGRect(x: 0, y: 0, width: Self.size.width, height: bottomY), design.header)
            fill(CGRect(x: 0, y: bottomY, width: Self.size.width, height: 4), design.accent)
        }

        var ly = top
        if let logo, let logoBox, !design.logoOnRight {
            logo.draw(in: CGRect(x: margin, y: ly, width: logoBox.width, height: logoBox.height))
            ly += logoBox.height + 10
        }
        if nameH > 0 { ly += text(head.name, x: margin, top: ly, width: half, size: 17, bold: true, color: nameColor) + 4 }
        if linesH > 0 { text(linesText, x: margin, top: ly, width: half, size: 8.5, color: subColor) }

        var ry = top
        if let logo, let logoBox, design.logoOnRight {
            logo.draw(in: CGRect(x: right - logoBox.width, y: ry, width: logoBox.width, height: logoBox.height))
            ry += logoBox.height + 10
        }
        ry += text(design.title, x: right - half, top: ry, width: half, size: 26, bold: true, color: titleColor, align: .right) + 2
        ry += text(number, x: right - half, top: ry, width: half, size: 11, color: subColor, align: .right) + 6
        if let (label, color) = status {
            let w = (label as NSString).size(withAttributes: [.font: font(8.5, bold: true)]).width + 18
            fill(CGRect(x: right - w, y: ry, width: w, height: 17), color, radius: 8.5)
            text(label, x: right - w, top: ry + 3, width: w, size: 8.5, bold: true, color: .white, align: .center)
        }

        switch design.style {
        case .band: y = bottomY + 4 + 26
        case .clean:
            hairline(at: bottomY, color: design.accent, width: 2)
            y = bottomY + 24
        case .minimal:
            hairline(at: bottomY)
            y = bottomY + 24
        }
    }

    /// A rich block across the page at the cursor.
    func rich(_ node: RichNode?, size: CGFloat = 9.5) {
        guard let node else { return }
        let s = DocumentRichText.attributed(node, typeface: design.typeface, size: size, color: DesignedPage.dark)
        guard s.length > 0 else { return }
        let h = ceil(s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: .usesLineFragmentOrigin, context: nil).height)
        ensure(h)
        // ponytail: a block taller than a page is cut at the page end; the server caps blocks at 3000 characters.
        s.draw(with: CGRect(x: margin, y: y, width: width, height: min(h, bottom - y)), options: .usesLineFragmentOrigin, context: nil)
        y += h + 14
    }

    /// The footer at the bottom of the (last) page: the design's own text, else `fallback`; `rightLines` opposite.
    func footer(fallback: String, note: String?, rightLines: [String]) {
        let leftWidth = width * 0.62
        var leftH: CGFloat
        var drawLeft: (CGFloat) -> Void
        if let node = design.footer {
            let s = DocumentRichText.attributed(node, typeface: design.typeface, size: 8.5, color: DesignedPage.dark)
            leftH = ceil(s.boundingRect(with: CGSize(width: leftWidth, height: .greatestFiniteMagnitude),
                                        options: .usesLineFragmentOrigin, context: nil).height)
            drawLeft = { top in s.draw(with: CGRect(x: self.margin, y: top, width: leftWidth, height: leftH), options: .usesLineFragmentOrigin, context: nil) }
        } else {
            let lines = [fallback] + (note.map { [$0] } ?? [])
            leftH = measure(lines.joined(separator: "\n"), width: leftWidth, size: 9)
            drawLeft = { top in
                let h = self.text(fallback, x: self.margin, top: top, width: leftWidth, size: 9.5, bold: true)
                if let note { self.text(note, x: self.margin, top: top + h + 2, width: leftWidth, size: 8.5, color: DesignedPage.muted) }
            }
        }
        let rightText = rightLines.joined(separator: "\n")
        let rightH = measure(rightText, width: width - leftWidth, size: 8.5)
        let h = max(leftH + 4, rightH)
        let top = Self.size.height - 30 - h
        if y > top - 16 { newPage() }
        hairline(at: top - 10)
        drawLeft(top)
        text(rightText, x: margin + leftWidth, top: top, width: width - leftWidth, size: 8.5, color: DesignedPage.muted, align: .right)
    }

    /// A table header row in the design's colour.
    func tableHead(_ columns: [(String, CGFloat, NSTextAlignment)]) {
        let headColor = design.style == .band ? design.header : design.accent
        fill(CGRect(x: margin, y: y, width: width, height: 24), headColor)
        var x = margin
        for (label, w, align) in columns {
            text(label, x: x + 8, top: y + 7, width: w - 16, size: 8.5, bold: true, color: .white, align: align)
            x += w
        }
        y += 24
    }

    /// One table row (zebra on odd rows); the head is drawn again on a new page.
    func tableRow(_ cells: [(String, CGFloat, NSTextAlignment, Bool)], index: Int, head: [(String, CGFloat, NSTextAlignment)]) {
        let h = cells.map { measure($0.0, width: $0.1 - 16, size: 9.5, bold: $0.3) }.max() ?? 12
        let rowH = h + 16
        if y + rowH > bottom {
            newPage()
            tableHead(head)
        }
        if index % 2 == 1 { fill(CGRect(x: margin, y: y, width: width, height: rowH), DesignedPage.soft) }
        var x = margin
        for (value, w, align, bold) in cells {
            text(value, x: x + 8, top: y + 8, width: w - 16, size: 9.5, bold: bold, align: align)
            x += w
        }
        y += rowH
        hairline(at: y)
    }

    /// Label / value lines in a box on the right, then a filled call-out for the last figure.
    func totals(_ rows: [(String, String, Bool)], callout: (String, String)) {
        let boxW: CGFloat = 250
        let x = right - boxW
        ensure(CGFloat(rows.count) * 20 + 44)
        for (label, value, strong) in rows {
            if strong { hairline(at: y - 3, from: x) }
            text(label, x: x, width: boxW / 2, size: strong ? 11 : 10, bold: strong, color: strong ? DesignedPage.dark : DesignedPage.muted)
            text(value, x: x + boxW / 2, width: boxW / 2, size: strong ? 11 : 10, bold: strong, align: .right)
            y += strong ? 22 : 17
        }
        y += 2
        fill(CGRect(x: x, y: y, width: boxW, height: 30), design.accent, radius: 5)
        text(callout.0, x: x + 12, top: y + 8, width: boxW / 2, size: 11, bold: true, color: .white)
        text(callout.1, x: x + boxW / 2, top: y + 8, width: boxW / 2 - 12, size: 12, bold: true, color: .white, align: .right)
        y += 30 + 20
    }
}

extension DesignedPage {
    /// Who it's for on the left (label, name, lines); label / value rows and a highlighted figure on the right.
    func parties(label: String, name: String, lines: [String], meta: [(String, String)], callout: (String, String)) {
        let leftW = width - 220
        let metaX = right - 200
        var ly = y
        ly += text(label.uppercased(), x: margin, top: ly, width: leftW, size: 8.5, bold: true, color: DesignedPage.muted) + 6
        ly += text(name, x: margin, top: ly, width: leftW, size: 13, bold: true) + 4
        if !lines.isEmpty { ly += text(lines.joined(separator: "\n"), x: margin, top: ly, width: leftW, size: 9.5, color: DesignedPage.muted) }
        var ry = y
        for (k, v) in meta {
            text(k, x: metaX, top: ry, width: 96, size: 9.5, color: DesignedPage.muted)
            ry += max(text(v, x: metaX + 96, top: ry, width: 104, size: 9.5, bold: true, align: .right), 12) + 5
        }
        fill(CGRect(x: metaX - 12, y: ry, width: 212, height: 30), design.accent.withAlphaComponent(0.12), radius: 5)
        text(callout.0, x: metaX, top: ry + 9, width: 96, size: 9, color: DesignedPage.muted)
        text(callout.1, x: metaX + 80, top: ry + 8, width: 112, size: 12, bold: true, color: design.accent, align: .right)
        ry += 30
        y = max(ly, ry) + 22
    }

    /// A small labelled block ("DELIVER TO", the address) across the page.
    func labelled(_ label: String, _ value: String) {
        let h = measure(value, width: width, size: 9.5) + 20
        ensure(h)
        text(label, x: margin, width: width, size: 8.5, bold: true, color: DesignedPage.muted)
        y += 14
        y += text(value, x: margin, width: width, size: 9.5) + 16
    }

    /// "HOW TO PAY": each way to pay with its details, then the reference to use.
    func howToPay(_ methods: [PaymentMethodInfo], reference: String) {
        guard !methods.isEmpty else { return }
        let inner = width - 24
        var h: CGFloat = 30
        for m in methods {
            h += measure(m.heading, width: inner, size: 10, bold: true) + 4 + CGFloat(m.rows.count) * 14
            if let i = m.instructions?.trimmedOrNil { h += measure(i, width: inner, size: 9) + 4 }
            h += 6
        }
        h += 24
        ensure(h + 8)
        let top = y
        fill(CGRect(x: margin, y: top, width: width, height: h), DesignedPage.soft, radius: 5)
        DesignedPage.line.setStroke()
        let border = UIBezierPath(roundedRect: CGRect(x: margin, y: top, width: width, height: h), cornerRadius: 5)
        border.lineWidth = 0.5
        border.stroke()
        text("HOW TO PAY", x: margin + 12, top: top + 12, width: inner, size: 8.5, bold: true, color: DesignedPage.muted)
        var yy = top + 30
        for m in methods {
            yy += text(m.heading, x: margin + 12, top: yy, width: inner, size: 10, bold: true) + 4
            for (label, value) in m.rows {
                text(label, x: margin + 12, top: yy, width: 96, size: 9.5, color: DesignedPage.muted)
                text(value, x: margin + 110, top: yy, width: inner - 98, size: 9.5, bold: true)
                yy += 14
            }
            if let i = m.instructions?.trimmedOrNil { yy += text(i, x: margin + 12, top: yy, width: inner, size: 9, color: DesignedPage.muted) + 4 }
            yy += 6
        }
        text("Reference", x: margin + 12, top: yy, width: 96, size: 9.5)
        text(reference, x: margin + 110, top: yy, width: inner - 98, size: 9.5, bold: true)
        y = top + h + 18
    }

    /// A side note beside the totals (left column), drawn at `top`; returns its bottom.
    func sideNote(_ label: String, _ value: String, top: CGFloat) -> CGFloat {
        let w = width - 274
        var yy = top
        yy += text(label, x: margin, top: yy, width: w, size: 8.5, bold: true, color: DesignedPage.muted) + 4
        let h = min(measure(value, width: w, size: 9.5), bottom - yy)
        (value as NSString).draw(in: CGRect(x: margin, y: yy, width: w, height: h),
                                 withAttributes: [.font: font(9.5), .foregroundColor: DesignedPage.dark])
        return yy + h
    }
}

/// Draws a designed document to a temporary PDF file.
@MainActor
enum DesignedPDF {
    static func file(named name: String, design: DocumentDesign, _ draw: (DesignedPage) -> Void) -> URL? {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: DesignedPage.size))
        let data = renderer.pdfData { context in
            let page = DesignedPage(design: design, context: context)
            page.newPage()
            draw(page)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

/// An invoice's or order's PDF, the one every download, preview, share and email uses: from the workspace's HTML
/// template on the server when it chose one (`GET /api/v2/invoices/:uuid/pdf`, `GET /api/v2/shop/admin/orders/:uuid/pdf`),
/// otherwise drawn here to its design. If the server can't make it, it is drawn here, so a PDF is never blocked
/// (the web does the same, `lib/document-output.ts`).
@MainActor
enum WorkspacePDF {
    struct Result {
        let url: URL?
        /// Said to the person when the template was chosen but the simple design was used.
        let notice: String?
    }

    static func make(_ kind: DocumentDesign.Kind, uuid: String, design: DocumentDesign, client: APIClient,
                     filename: String, draw: () -> URL?) async -> Result {
        guard design.usesTemplate else { return Result(url: draw(), notice: nil) }
        do {
            let path = kind == .invoice ? "/api/v2/invoices/\(uuid)/pdf" : "/api/v2/shop/admin/orders/\(uuid)/pdf"
            var endpoint = Endpoint.get(path)
            endpoint.headers["Accept"] = "application/pdf"
            let (data, _) = try await client.sendRaw(endpoint)
            if data.starts(with: Data("%PDF".utf8)) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try data.write(to: url, options: .atomic)
                return Result(url: url, notice: nil)
            }
            return Result(url: draw(), notice: fallbackNotice(nil))
        } catch {
            return Result(url: draw(), notice: fallbackNotice(error))
        }
    }

    /// Why the simple design was used, in plain words; nothing when there's nothing to say: the workspace went back
    /// to the designer since the design was read (409 `DESIGN_NOT_TEMPLATE`), or an older server has no PDF route (404).
    nonisolated static func fallbackNotice(_ error: Error?) -> String? {
        switch error as? APIError {
        case .notFound: nil
        case .validation(let e) where e.status == 409: nil
        case .server(let e) where e.status == 503: "The PDF service isn't available, so this uses the simple design."
        default: "The template's PDF couldn't be made, so this uses the simple design."
        }
    }
}
