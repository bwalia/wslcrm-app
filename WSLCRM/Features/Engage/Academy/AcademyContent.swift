import Foundation

// A lesson's content as blocks a person can edit natively: read from the lesson's HTML (what the
// web's rich editor saves) and written back as the same kind of HTML. Anything the blocks can't
// hold without losing something stays as an HTML block, untouched; blocks nobody changed are
// written back exactly as they were read.

enum AcademyTextStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
    case paragraph = "p", h1, h2, h3, h4
    var id: String { rawValue }

    var label: String {
        switch self {
        case .paragraph: "Normal text"
        case .h1: "Heading 1"
        case .h2: "Heading 2"
        case .h3: "Heading 3"
        case .h4: "Heading 4"
        }
    }

    var tag: String { rawValue }
}

enum AcademyAlign: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none = "", left, center, right, justify
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Default"
        case .left: "Left"
        case .center: "Centre"
        case .right: "Right"
        case .justify: "Justify"
        }
    }

    var systemImage: String {
        switch self {
        case .none, .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justify: "text.justify"
        }
    }
}

enum AcademyBlockKind: Hashable, Sendable {
    /// A paragraph or heading; `html` is its inline HTML (bold, links, colours…).
    case text(AcademyTextStyle, html: String, align: AcademyAlign)
    /// Each item is inline HTML.
    case list(ordered: Bool, items: [String])
    case quote(html: String)
    case code(text: String, language: String?)
    case rule
    case image(src: String, alt: String)
    /// A YouTube or Vimeo embed address.
    case video(src: String)
    /// Plain-text cells; the first row is the header when `header` is on.
    case table(rows: [[String]], header: Bool)
    /// Anything else, kept exactly as written.
    case html(String)
}

struct AcademyBlock: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: AcademyBlockKind
    /// The HTML this block was read from; written back unchanged until the block is edited.
    var source: String?

    init(_ kind: AcademyBlockKind, source: String? = nil) {
        self.kind = kind
        self.source = source
    }

    /// What it writes: the original HTML if untouched, else freshly built.
    var html: String { source ?? AcademyContent.build(kind) }

    /// A short name for the block's kind (rows, accessibility).
    var kindName: String {
        switch kind {
        case .text(let style, _, _): style == .paragraph ? "Text" : style.label
        case .list(let ordered, _): ordered ? "Numbered list" : "Bullet list"
        case .quote: "Quote"
        case .code: "Code"
        case .rule: "Divider"
        case .image: "Picture"
        case .video: "Video"
        case .table: "Table"
        case .html: "HTML"
        }
    }

    var systemImage: String {
        switch kind {
        case .text(let style, _, _): style == .paragraph ? "text.alignleft" : "textformat.size"
        case .list(let ordered, _): ordered ? "list.number" : "list.bullet"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .rule: "minus"
        case .image: "photo"
        case .video: "play.rectangle"
        case .table: "tablecells"
        case .html: "curlybraces"
        }
    }
}

struct AcademyContent: Hashable, Sendable {
    var blocks: [AcademyBlock]

    init(blocks: [AcademyBlock] = []) { self.blocks = blocks }

    /// The lesson HTML for these blocks.
    var html: String { blocks.map(\.html).joined() }

    // MARK: Reading

    static func parse(_ html: String) -> AcademyContent {
        AcademyContent(blocks: topLevel(html).compactMap(block))
    }

    /// The top-level pieces of some HTML: each element whole, and runs of loose text/inline tags.
    static func topLevel(_ html: String) -> [String] {
        var pieces: [String] = []
        var loose = ""
        var index = html.startIndex
        func flushLoose() {
            if !loose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(loose) }
            loose = ""
        }
        while index < html.endIndex {
            guard html[index] == "<" else {
                loose.append(html[index])
                index = html.index(after: index)
                continue
            }
            if html[index...].hasPrefix("<!--") {
                flushLoose()
                let end = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                pieces.append(String(html[index..<end]))
                index = end
                continue
            }
            let next = html.index(after: index)
            let name = tagName(html, at: index)
            if next == html.endIndex || name.isEmpty || inlineTags.contains(name) || html[next] == "/" {
                // Inline markup (or a stray closing tag) belongs to the loose run.
                let close = html[index...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                loose += html[index..<close]
                index = close
                continue
            }
            flushLoose()
            let end = elementEnd(html, from: index, name: name)
            pieces.append(String(html[index..<end]))
            index = end
        }
        flushLoose()
        return pieces
    }

    static let inlineTags: Set<String> = ["a", "b", "strong", "i", "em", "u", "s", "strike", "del", "code", "mark", "span",
                                          "sub", "sup", "br", "small", "font", "abbr", "q", "cite", "kbd", "label"]
    static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "source", "col", "wbr", "area",
                                        "base", "embed", "param", "track"]

    private static func tagName(_ html: String, at index: String.Index) -> String {
        html[html.index(after: index)...].prefix { $0.isLetter || $0.isNumber }.lowercased()
    }

    /// Where the element opened at `start` ends (just past its closing tag).
    private static func elementEnd(_ html: String, from start: String.Index, name: String) -> String.Index {
        guard let firstClose = html[start...].firstIndex(of: ">") else { return html.endIndex }
        let openTag = html[start...firstClose]
        if voidTags.contains(name) || openTag.hasSuffix("/>") { return html.index(after: firstClose) }
        var depth = 1
        var index = html.index(after: firstClose)
        while index < html.endIndex {
            guard let lt = html[index...].firstIndex(of: "<") else { break }
            guard let gt = html[lt...].firstIndex(of: ">") else { break }
            let tag = html[lt...gt]
            let isClose = tag.hasPrefix("</")
            let tagName = tag.dropFirst(isClose ? 2 : 1).prefix { $0.isLetter || $0.isNumber }.lowercased()
            if tagName == name {
                if isClose { depth -= 1 } else if !tag.hasSuffix("/>") { depth += 1 }
                if depth == 0 { return html.index(after: gt) }
            }
            index = html.index(after: gt)
        }
        return html.endIndex
    }

    private typealias Token = RichHTMLParser.Token

    /// One top-level piece as a block (an HTML block when nothing else fits).
    static func block(_ piece: String) -> AcademyBlock? {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = RichHTMLParser.tokenize(trimmed)
        guard case .open(let name, let attributes, _)? = tokens.first else {
            // Loose text and inline markup: a paragraph.
            if AcademyInline.isSupported(trimmed) { return AcademyBlock(.text(.paragraph, html: trimmed, align: .none), source: piece) }
            return AcademyBlock(.html(piece), source: piece)
        }
        let kind: AcademyBlockKind?
        switch name {
        case "p", "h1", "h2", "h3", "h4":
            kind = textBlock(name, attributes, trimmed)
        case "ul", "ol":
            kind = listBlock(ordered: name == "ol", attributes, tokens, trimmed)
        case "blockquote":
            kind = quoteBlock(attributes, trimmed)
        case "pre":
            kind = codeBlock(tokens)
        case "hr":
            kind = attributes.isEmpty ? .rule : nil
        case "img":
            kind = imageBlock(attributes)
        case "div":
            kind = videoBlock(tokens, divAttributes: attributes)
        case "iframe":
            kind = attributes["src"].flatMap(AcademyVideo.embedURL).map { .video(src: $0) }
        case "table":
            kind = tableBlock(tokens)
        default:
            kind = nil
        }
        if inlineTags.contains(name), AcademyInline.isSupported(trimmed) {
            return AcademyBlock(.text(.paragraph, html: trimmed, align: .none), source: piece)
        }
        return AcademyBlock(kind ?? .html(piece), source: piece)
    }

    /// The HTML between an element's opening and closing tags.
    static func inner(_ element: String) -> String {
        guard let open = element.firstIndex(of: ">"), let close = element.range(of: "</", options: .backwards) else {
            return ""
        }
        let start = element.index(after: open)
        return start <= close.lowerBound ? String(element[start..<close.lowerBound]) : ""
    }

    private static func align(_ attributes: [String: String]) -> AcademyAlign? {
        let css = RichHTMLParser.style(attributes)
        guard Set(attributes.keys).isSubset(of: ["style"]), Set(css.keys).isSubset(of: ["text-align"]) else { return nil }
        return AcademyAlign(rawValue: css["text-align"]?.lowercased() ?? "") ?? nil
    }

    private static func textBlock(_ name: String, _ attributes: [String: String], _ element: String) -> AcademyBlockKind? {
        guard let align = align(attributes), let style = AcademyTextStyle(rawValue: name) else { return nil }
        let content = inner(element)
        guard AcademyInline.isSupported(content) else { return nil }
        return .text(style, html: content, align: align)
    }

    private static func listBlock(ordered: Bool, _ attributes: [String: String], _ tokens: [Token],
                                  _ element: String) -> AcademyBlockKind? {
        guard attributes.isEmpty || (ordered && attributes == ["start": "1"]) else { return nil }
        // No list inside a list: those stay as HTML.
        let lists = tokens.filter { if case .open(let n, _, _) = $0 { n == "ul" || n == "ol" } else { false } }
        guard lists.count == 1 else { return nil }
        var items: [String] = []
        for piece in topLevel(inner(element)) {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .open("li", let liAttributes, _)? = RichHTMLParser.tokenize(item).first, liAttributes.isEmpty else {
                return nil
            }
            guard let text = itemHTML(inner(item)) else { return nil }
            items.append(text)
        }
        return items.isEmpty ? nil : .list(ordered: ordered, items: items)
    }

    /// A list item's words: one plain paragraph, or loose inline markup. nil when it holds more.
    private static func itemHTML(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = topLevel(trimmed)
        if parts.isEmpty { return "" }
        if parts.count == 1, let only = parts.first, only.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<p"),
           case .text(.paragraph, let html, .none)? = block(only)?.kind {
            return html
        }
        if parts.count == 1, AcademyInline.isSupported(trimmed), !trimmed.lowercased().contains("<p") { return trimmed }
        return nil
    }

    private static func quoteBlock(_ attributes: [String: String], _ element: String) -> AcademyBlockKind? {
        guard attributes.isEmpty else { return nil }
        guard let html = itemHTML(inner(element)), !html.isEmpty else { return nil }
        return .quote(html: html)
    }

    private static func codeBlock(_ tokens: [Token]) -> AcademyBlockKind? {
        // <pre><code class="language-x">text</code></pre>
        var language: String?
        var text = ""
        var opens = 0
        for token in tokens {
            switch token {
            case .open("pre", let a, _): opens += 1; if !a.isEmpty { return nil }
            case .open("code", let a, _):
                opens += 1
                if let cls = a["class"], cls.hasPrefix("language-") { language = String(cls.dropFirst(9)) }
                if a.keys.contains(where: { $0 != "class" }) { return nil }
            case .open: return nil
            case .text(let t): text += t
            case .close: break
            }
        }
        return opens == 2 ? .code(text: text, language: language) : nil
    }

    private static func imageBlock(_ attributes: [String: String]) -> AcademyBlockKind? {
        guard let src = attributes["src"]?.trimmedOrNil,
              Set(attributes.keys).isSubset(of: ["src", "alt", "class", "title"]),
              (attributes["class"] ?? AcademyContent.imageClass) == AcademyContent.imageClass else { return nil }
        return .image(src: src, alt: attributes["alt"] ?? "")
    }

    private static func videoBlock(_ tokens: [Token], divAttributes: [String: String]) -> AcademyBlockKind? {
        guard divAttributes == ["class": "academy-video"] else { return nil }
        let frames = tokens.compactMap { token -> [String: String]? in
            if case .open("iframe", let a, _) = token { return a }
            return nil
        }
        let others = tokens.filter { token in
            if case .open(let n, _, _) = token { return n != "div" && n != "iframe" }
            if case .text(let t) = token { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
        guard frames.count == 1, others.isEmpty, let src = frames[0]["src"], AcademyVideo.isAllowed(src) else { return nil }
        return .video(src: src)
    }

    private static func tableBlock(_ tokens: [Token]) -> AcademyBlockKind? {
        let allowed: Set<String> = ["table", "colgroup", "col", "tbody", "thead", "tr", "th", "td", "p", "br"]
        var rows: [[String]] = []
        var row: [String]?
        var cell: String?
        var headerCells = 0
        var firstRowCells = 0
        var paragraphsInCell = 0
        for token in tokens {
            switch token {
            case .open(let name, let attributes, _):
                guard allowed.contains(name) else { return nil }
                if name == "table", Set(attributes.keys).subtracting(["style"]).count > 0 { return nil }
                if name == "th" || name == "td" {
                    if (attributes["colspan"] ?? "1") != "1" || (attributes["rowspan"] ?? "1") != "1" { return nil }
                    cell = ""
                    paragraphsInCell = 0
                    if rows.isEmpty { firstRowCells += 1; if name == "th" { headerCells += 1 } }
                } else if name == "tr" {
                    row = []
                } else if name == "p" {
                    paragraphsInCell += 1
                    if paragraphsInCell > 1 { return nil }
                } else if name == "br", cell != nil {
                    cell! += " "
                }
            case .close(let name):
                if name == "th" || name == "td" {
                    row?.append((cell ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    cell = nil
                } else if name == "tr", let finished = row {
                    rows.append(finished)
                    row = nil
                }
            case .text(let text):
                if cell != nil { cell! += text } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
            }
        }
        guard !rows.isEmpty else { return nil }
        return .table(rows: rows, header: firstRowCells > 0 && headerCells == firstRowCells)
    }

    // MARK: Writing

    static let imageClass = "academy-img"

    static func build(_ kind: AcademyBlockKind) -> String {
        switch kind {
        case .text(let style, let html, let align):
            let alignAttribute = align == .none ? "" : " style=\"text-align: \(align.rawValue)\""
            return "<\(style.tag)\(alignAttribute)>\(html)</\(style.tag)>"
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            return "<\(tag)>" + items.map { "<li><p>\($0)</p></li>" }.joined() + "</\(tag)>"
        case .quote(let html):
            return "<blockquote><p>\(html)</p></blockquote>"
        case .code(let text, let language):
            let cls = language?.trimmedOrNil.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
            return "<pre><code\(cls)>\(escapeText(text))</code></pre>"
        case .rule:
            return "<hr>"
        case .image(let src, let alt):
            let altAttribute = alt.trimmedOrNil.map { " alt=\"\(escapeAttribute($0))\"" } ?? ""
            return "<img src=\"\(escapeAttribute(src))\"\(altAttribute) class=\"\(imageClass)\">"
        case .video(let src):
            return "<div class=\"academy-video\"><iframe src=\"\(escapeAttribute(src))\" title=\"Lesson video\" "
                + "frameborder=\"0\" allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; "
                + "picture-in-picture\" allowfullscreen=\"true\"></iframe></div>"
        case .table(let rows, let header):
            var out = "<table><tbody>"
            for (index, row) in rows.enumerated() {
                let tag = header && index == 0 ? "th" : "td"
                out += "<tr>" + row.map { "<\(tag)><p>\(escapeText($0))</p></\(tag)>" }.joined() + "</tr>"
            }
            return out + "</tbody></table>"
        case .html(let html):
            return html
        }
    }

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Lesson videos: YouTube and Vimeo only, as the web's editor allows.
enum AcademyVideo {
    private static let allowedHosts = #"^(https:)?//(www\.)?(youtube\.com|youtube-nocookie\.com|player\.vimeo\.com)/"#

    static func isAllowed(_ src: String) -> Bool {
        src.range(of: allowedHosts, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A pasted YouTube or Vimeo link as its embeddable address, or nil when it isn't one.
    static func embedURL(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let id = firstMatch(#"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([\w-]{6,})"#, in: url) {
            return "https://www.youtube.com/embed/\(id)"
        }
        if let id = firstMatch(#"vimeo\.com/(?:video/)?(\d+)"#, in: url) {
            return "https://player.vimeo.com/video/\(id)"
        }
        return isAllowed(url) ? url : nil
    }

    /// The address a person can open in the YouTube or Vimeo app (`…/embed/ID` → `youtube.com/watch?v=ID`).
    static func watchURL(_ embed: String) -> URL? {
        if let id = firstMatch(#"youtube(?:-nocookie)?\.com/embed/([\w-]{6,})"#, in: embed) {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        if let id = firstMatch(#"player\.vimeo\.com/video/(\d+)"#, in: embed) {
            return URL(string: "https://vimeo.com/\(id)")
        }
        return URL(string: embed.hasPrefix("//") ? "https:" + embed : embed)
    }

    static func provider(_ embed: String) -> String {
        embed.lowercased().contains("vimeo") ? "Vimeo" : "YouTube"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
