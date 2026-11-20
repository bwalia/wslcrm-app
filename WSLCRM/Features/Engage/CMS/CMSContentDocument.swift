import Foundation

/// The body of a post or page as blocks a person can change one at a time, read from and written
/// back to the HTML the web editor (TipTap) stores in `content_html`.
///
/// Nothing is lost: a block keeps the exact HTML it was read from and writes that back until it is
/// changed, and anything the blocks can't describe (a layout `<div>`, a styled section, a form) stays
/// as an HTML block that is edited as source.
struct CMSContentDocument: Equatable {
    var blocks: [CMSBlock]

    init(blocks: [CMSBlock]) { self.blocks = blocks }

    init(html: String) {
        blocks = CMSContentDocument.chunks(html).compactMap { chunk in
            CMSContentDocument.block(from: chunk.html, gap: chunk.gap)
        }
    }

    var html: String { blocks.map(\.html).joined() }

    /// Whether this body has anything in it.
    var isEmpty: Bool { blocks.isEmpty }

    // MARK: Reading

    /// Void elements: they never have a closing tag.
    private static let void: Set<String> = ["br", "hr", "img", "input", "meta", "link", "source", "wbr", "col",
                                            "area", "embed", "param", "track", "base"]

    /// The top-level pieces of an HTML fragment, each with the whitespace before it.
    static func chunks(_ html: String) -> [(gap: String, html: String)] {
        var result: [(String, String)] = []
        var index = html.startIndex
        var gap = ""
        while index < html.endIndex {
            let character = html[index]
            if character.isWhitespace {
                gap.append(character)
                index = html.index(after: index)
                continue
            }
            let start = index
            if character != "<" {
                // Loose text at the top level runs to the next tag.
                let end = html[index...].firstIndex(of: "<") ?? html.endIndex
                var text = String(html[start..<end])
                // Keep trailing whitespace as the next piece's gap.
                var trailing = ""
                while let last = text.last, last.isWhitespace { trailing.insert(last, at: trailing.startIndex); text.removeLast() }
                result.append((gap, text))
                gap = trailing
                index = end
                continue
            }
            if html[index...].hasPrefix("<!--") {
                let end = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                result.append((gap, String(html[start..<end])))
                gap = ""
                index = end
                continue
            }
            let end = elementEnd(html, from: index)
            result.append((gap, String(html[start..<end])))
            gap = ""
            index = end
        }
        if !gap.isEmpty, var last = result.popLast() {
            last.1 += gap
            result.append(last)
        }
        return result.map { (gap: $0.0, html: $0.1) }
    }

    /// Where the element starting at `start` ends (just after its matching close tag).
    private static func elementEnd(_ html: String, from start: String.Index) -> String.Index {
        var depth = 0
        var index = start
        while index < html.endIndex {
            guard html[index] == "<" else {
                index = html[index...].firstIndex(of: "<") ?? html.endIndex
                continue
            }
            if html[index...].hasPrefix("<!--") {
                index = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                continue
            }
            guard let close = tagEnd(html, from: index) else { return html.endIndex }
            let inner = html[html.index(after: index)..<html.index(before: close)]
            let closing = inner.hasPrefix("/")
            let name = inner.drop { $0 == "/" }.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }.lowercased()
            let selfClosing = inner.hasSuffix("/") || void.contains(name) || inner.hasPrefix("!")
            index = close
            if closing {
                depth -= 1
            } else if !selfClosing {
                depth += 1
                // Script and style text is never markup.
                if name == "script" || name == "style",
                   let end = html.range(of: "</\(name)", options: .caseInsensitive, range: index..<html.endIndex) {
                    index = end.lowerBound
                }
            }
            if depth <= 0 { return index }
        }
        return html.endIndex
    }

    /// The index just after the `>` closing the tag that starts at `start` (quotes respected).
    private static func tagEnd(_ html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let character = html[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return html.index(after: index)
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// The opening tag's name and attributes, and the HTML between it and its close tag.
    static func parts(_ element: String) -> (name: String, attributes: [String: String], inner: String)? {
        guard element.hasPrefix("<"), let close = tagEnd(element, from: element.startIndex),
              case .open(let name, let attributes, _)? = RichHTMLParser.tokenize(String(element[..<close])).first else {
            return nil
        }
        var inner = String(element[close...])
        if let range = inner.range(of: "</\(name)", options: [.caseInsensitive, .backwards]) {
            inner = String(inner[..<range.lowerBound])
        }
        return (name, attributes, inner)
    }

    /// The pieces of an element's inner HTML that are elements named `name` (list items, cells, rows).
    static func children(_ inner: String, named names: Set<String>) -> [(attributes: [String: String], inner: String)]? {
        var out: [([String: String], String)] = []
        for chunk in chunks(inner) {
            guard let part = parts(chunk.html), names.contains(part.name) else {
                if chunk.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                return nil
            }
            out.append((part.attributes, part.inner))
        }
        return out.map { (attributes: $0.0, inner: $0.1) }
    }

    static func block(from chunk: String, gap: String) -> CMSBlock? {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let kind = kind(of: trimmed) {
            return CMSBlock(kind: kind, original: chunk, gap: gap)
        }
        return CMSBlock(kind: .html(chunk), original: chunk, gap: gap)
    }

    private static func align(_ attributes: [String: String]) -> CMSAlign? {
        let extra = Set(attributes.keys).subtracting(["style"])
        guard extra.isEmpty else { return nil }
        let css = RichHTMLParser.style(attributes)
        guard Set(css.keys).isSubset(of: ["text-align"]) else { return nil }
        return CMSAlign(rawValue: (css["text-align"] ?? "left").lowercased()) ?? .left
    }

    /// The `<p>` pieces of a list item or quote joined with line breaks, if that is all there is.
    private static func paragraphsInline(_ inner: String) -> String? {
        if CMSInline.isEditable(inner), !inner.lowercased().contains("<p") { return inner }
        guard let paragraphs = children(inner, named: ["p"]), !paragraphs.isEmpty,
              paragraphs.allSatisfy({ $0.attributes.isEmpty && CMSInline.isEditable($0.inner) }) else { return nil }
        return paragraphs.map(\.inner).joined(separator: "<br>")
    }

    private static func kind(of element: String) -> CMSBlock.Kind? {
        guard element.hasPrefix("<") else {
            // Loose text becomes a paragraph.
            return .paragraph(html: CMSInline.escape(RichHTMLParser.decodeEntities(element), quotes: false), align: .left)
        }
        guard let part = parts(element) else { return nil }
        switch part.name {
        case "p":
            guard let align = align(part.attributes), CMSInline.isEditable(part.inner) else { return nil }
            return .paragraph(html: part.inner, align: align)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard let align = align(part.attributes), CMSInline.isEditable(part.inner) else { return nil }
            return .heading(level: Int(part.name.dropFirst()) ?? 2, html: part.inner, align: align)
        case "ul", "ol":
            guard part.attributes.isEmpty, let items = children(part.inner, named: ["li"]), !items.isEmpty else { return nil }
            var htmls: [String] = []
            for item in items {
                guard item.attributes.isEmpty, let inline = paragraphsInline(item.inner) else { return nil }
                htmls.append(inline)
            }
            return .list(ordered: part.name == "ol", items: htmls)
        case "blockquote":
            guard part.attributes.isEmpty, let inline = paragraphsInline(part.inner) else { return nil }
            return .quote(html: inline)
        case "pre":
            var code = part.inner
            if let inner = parts(code.trimmingCharacters(in: .whitespacesAndNewlines)), inner.name == "code" {
                code = inner.inner
            }
            guard !code.contains("<") else { return nil }
            return .code(RichHTMLParser.decodeEntities(code))
        case "img":
            guard Set(part.attributes.keys).isSubset(of: ["src", "alt", "title"]), let src = part.attributes["src"] else {
                return nil
            }
            return .image(src: src, alt: part.attributes["alt"] ?? "", title: part.attributes["title"] ?? "")
        case "hr":
            return part.attributes.isEmpty ? .divider : nil
        case "iframe":
            guard let src = part.attributes["src"], CMSVideo.isTrustedHost(src) else { return nil }
            return .video(src: src)
        case "div":
            // The web editor's video embed: <div class="academy-video"><iframe src="…"></iframe></div>.
            guard part.attributes["class"] == "academy-video", part.attributes.count == 1,
                  let frame = parts(part.inner.trimmingCharacters(in: .whitespacesAndNewlines)), frame.name == "iframe",
                  let src = frame.attributes["src"], CMSVideo.isTrustedHost(src) else { return nil }
            return .video(src: src)
        case "table":
            return table(part.inner)
        default:
            return nil
        }
    }

    /// A table of plain words (TipTap's `<table><tbody><tr><th><p>…</p></th>…`); nil when cells hold more.
    private static func table(_ inner: String) -> CMSBlock.Kind? {
        var body = inner
        if let colgroup = body.range(of: #"<colgroup>[\s\S]*?</colgroup>"#, options: [.regularExpression, .caseInsensitive]) {
            body.removeSubrange(colgroup)
        }
        var rowsHTML: [(attributes: [String: String], inner: String)] = []
        guard let sections = children(body, named: ["tbody", "thead", "tr"]) else { return nil }
        // Either rows directly, or rows inside tbody/thead.
        let direct = children(body, named: ["tr"])
        if let direct { rowsHTML = direct } else {
            for section in sections {
                guard let rows = children(section.inner, named: ["tr"]) else { return nil }
                rowsHTML += rows
            }
        }
        guard !rowsHTML.isEmpty else { return nil }
        var rows: [[String]] = []
        var header = false
        for (index, row) in rowsHTML.enumerated() {
            var cells: [String] = []
            for chunk in chunks(row.inner) {
                guard let cell = parts(chunk.html), cell.name == "td" || cell.name == "th" else { return nil }
                guard Set(cell.attributes.keys).isSubset(of: ["colspan", "rowspan", "colwidth"]),
                      (cell.attributes["colspan"] ?? "1") == "1", (cell.attributes["rowspan"] ?? "1") == "1" else {
                    return nil
                }
                if cell.name == "th" {
                    if index == 0 { header = true } else { return nil }
                }
                var text = cell.inner
                if let paragraphs = children(text, named: ["p"]) {
                    guard paragraphs.count <= 1, paragraphs.allSatisfy({ $0.attributes.isEmpty }) else { return nil }
                    text = paragraphs.first?.inner ?? ""
                }
                guard !text.contains("<") else { return nil }
                cells.append(RichHTMLParser.decodeEntities(text))
            }
            rows.append(cells)
        }
        let width = rows.map(\.count).max() ?? 0
        guard width > 0, rows.allSatisfy({ $0.count == width }) else { return nil }
        return .table(rows: rows, header: header)
    }
}

enum CMSAlign: String, CaseIterable, Identifiable, Sendable {
    case left, center, right, justify
    var id: String { rawValue }
    var label: String { rawValue.capitalizedFirst }
    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justify: "text.justify"
        }
    }
}

/// One block of a post's or page's body.
struct CMSBlock: Identifiable, Equatable {
    let id: UUID
    var kind: Kind
    /// The HTML the block was read from: written back untouched until the block is changed.
    var original: String?
    /// Whitespace that came before the block.
    var gap: String

    init(kind: Kind, original: String? = nil, gap: String = "", id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.original = original
        self.gap = gap
    }

    enum Kind: Equatable {
        case paragraph(html: String, align: CMSAlign)
        case heading(level: Int, html: String, align: CMSAlign)
        case list(ordered: Bool, items: [String])
        case quote(html: String)
        case code(String)
        case image(src: String, alt: String, title: String)
        case video(src: String)
        case divider
        case table(rows: [[String]], header: Bool)
        /// Anything else, kept and edited as HTML source.
        case html(String)
    }

    /// The block changed: from now on it is written from its kind.
    func changed(to kind: Kind) -> CMSBlock {
        CMSBlock(kind: kind, original: nil, gap: gap, id: id)
    }

    var html: String { gap + (original ?? Self.html(kind)) }

    static func html(_ kind: Kind) -> String {
        func style(_ align: CMSAlign) -> String { align == .left ? "" : " style=\"text-align: \(align.rawValue)\"" }
        func attribute(_ text: String) -> String { CMSInline.escape(text, quotes: true) }
        switch kind {
        case .paragraph(let html, let align):
            return "<p\(style(align))>\(html)</p>"
        case .heading(let level, let html, let align):
            let tag = "h\(min(max(level, 1), 6))"
            return "<\(tag)\(style(align))>\(html)</\(tag)>"
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            return "<\(tag)>" + items.map { "<li><p>\($0)</p></li>" }.joined() + "</\(tag)>"
        case .quote(let html):
            let lines = html.components(separatedBy: "<br>")
            return "<blockquote>" + lines.map { "<p>\($0)</p>" }.joined() + "</blockquote>"
        case .code(let code):
            return "<pre><code>\(CMSInline.escape(code, quotes: false))</code></pre>"
        case .image(let src, let alt, let title):
            var out = "<img src=\"\(attribute(src))\""
            if !alt.isEmpty { out += " alt=\"\(attribute(alt))\"" }
            if !title.isEmpty { out += " title=\"\(attribute(title))\"" }
            return out + ">"
        case .video(let src):
            return "<div class=\"academy-video\"><iframe src=\"\(attribute(src))\" title=\"Video\" frameborder=\"0\" "
                + "allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture\" "
                + "allowfullscreen=\"true\"></iframe></div>"
        case .divider:
            return "<hr>"
        case .table(let rows, let header):
            let body = rows.enumerated().map { index, row in
                let tag = header && index == 0 ? "th" : "td"
                return "<tr>" + row.map { "<\(tag)><p>\(CMSInline.escape($0, quotes: false))</p></\(tag)>" }.joined() + "</tr>"
            }.joined()
            return "<table><tbody>\(body)</tbody></table>"
        case .html(let raw):
            return raw
        }
    }

    // MARK: Describing

    var title: String {
        switch kind {
        case .paragraph: "Text"
        case .heading(let level, _, _): "Heading \(level)"
        case .list(let ordered, _): ordered ? "Numbered list" : "Bullet list"
        case .quote: "Quote"
        case .code: "Code"
        case .image: "Picture"
        case .video: "Video"
        case .divider: "Divider"
        case .table: "Table"
        case .html: "HTML"
        }
    }

    var symbol: String {
        switch kind {
        case .paragraph: "text.alignleft"
        case .heading: "textformat.size"
        case .list(let ordered, _): ordered ? "list.number" : "list.bullet"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .video: "play.rectangle"
        case .divider: "minus"
        case .table: "tablecells"
        case .html: "curlybraces"
        }
    }

    /// A short line of what's in it, for the block list.
    var summary: String {
        switch kind {
        case .paragraph(let html, _), .heading(_, let html, _), .quote(let html):
            return RichDocument.plainText(fromHTML: "<p>\(html)</p>")
        case .list(_, let items):
            return items.map { "• " + RichDocument.plainText(fromHTML: "<p>\($0)</p>") }.joined(separator: "\n")
        case .code(let code):
            return code
        case .image(let src, let alt, _):
            return alt.isEmpty ? src : alt
        case .video(let src):
            return src
        case .divider:
            return "A line across the page"
        case .table(let rows, _):
            return "\(rows.count) rows × \(rows.first?.count ?? 0) columns"
        case .html(let raw):
            let words = RichDocument.plainText(fromHTML: raw)
            return words.isEmpty ? raw.prefix(120).description : words
        }
    }

    /// A new, empty block of a kind.
    static func new(_ template: Template) -> CMSBlock {
        switch template {
        case .paragraph: CMSBlock(kind: .paragraph(html: "", align: .left))
        case .heading(let level): CMSBlock(kind: .heading(level: level, html: "", align: .left))
        case .bullets: CMSBlock(kind: .list(ordered: false, items: [""]))
        case .numbers: CMSBlock(kind: .list(ordered: true, items: [""]))
        case .quote: CMSBlock(kind: .quote(html: ""))
        case .code: CMSBlock(kind: .code(""))
        case .divider: CMSBlock(kind: .divider)
        case .table: CMSBlock(kind: .table(rows: Array(repeating: Array(repeating: "", count: 3), count: 3), header: true))
        case .html: CMSBlock(kind: .html(""))
        }
    }

    enum Template: Hashable {
        case paragraph, heading(Int), bullets, numbers, quote, code, divider, table, html

        static let all: [(Template, String, String)] = [
            (.paragraph, "Text", "text.alignleft"), (.heading(2), "Heading", "textformat.size"),
            (.heading(3), "Smaller heading", "textformat.size.smaller"), (.bullets, "Bullet list", "list.bullet"),
            (.numbers, "Numbered list", "list.number"), (.quote, "Quote", "text.quote"),
            (.code, "Code", "chevron.left.forwardslash.chevron.right"), (.table, "Table", "tablecells"),
            (.divider, "Divider", "minus"), (.html, "HTML", "curlybraces"),
        ]
    }
}

/// Makes a body ready to show in the app: site paths (`/img/x.jpg`) become full addresses.
enum CMSPreview {
    static func resolve(_ html: String, siteURL: String?) -> String {
        guard var site = siteURL?.trimmedOrNil else { return html }
        while site.hasSuffix("/") { site.removeLast() }
        return html.replacingOccurrences(of: #"(src|href)="/(?!/)"#, with: "$1=\"\(site)/", options: .regularExpression)
    }
}
