import Foundation

// The email body as blocks a person edits natively: headings, text, lists, pictures, buttons,
// dividers, space, and HTML kept exactly as written (table layouts, anything else). A block that
// isn't changed is written back byte for byte, so opening and saving never alters a design.

/// CSS declarations in their order (`margin:0;text-align:center`), changed one property at a time.
struct MktEmailCSS: Hashable, Sendable {
    struct Declaration: Hashable, Sendable {
        var property: String
        var value: String
    }

    var declarations: [Declaration] = []

    init(_ style: String? = nil) {
        for part in (style ?? "").split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let property = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !property.isEmpty { declarations.append(Declaration(property: property, value: value)) }
        }
    }

    subscript(_ property: String) -> String? {
        get { declarations.last { $0.property == property }?.value }
        set {
            if let newValue, !newValue.isEmpty {
                if let index = declarations.lastIndex(where: { $0.property == property }) {
                    declarations[index].value = newValue
                } else {
                    declarations.append(Declaration(property: property, value: newValue))
                }
            } else {
                declarations.removeAll { $0.property == property }
            }
        }
    }

    var isEmpty: Bool { declarations.isEmpty }

    /// `margin:0;text-align:center`
    var text: String { declarations.map { "\($0.property):\($0.value)" }.joined(separator: ";") }

    /// ` style="…"`, or nothing when there is no style.
    var attribute: String { isEmpty ? "" : " style=\"\(MktEmailHTML.escapeAttribute(text))\"" }

    /// `background` or `background-color`, as written.
    var background: String? { self["background-color"] ?? self["background"] }

    var align: RichAlign {
        switch self["text-align"]?.lowercased() {
        case "center": .center
        case "right", "end": .trailing
        default: .leading
        }
    }

    mutating func setAlign(_ align: RichAlign) {
        switch align {
        case .leading: self["text-align"] = nil
        case .center: self["text-align"] = "center"
        case .trailing: self["text-align"] = "right"
        }
    }
}

/// Small HTML helpers for the email editor.
enum MktEmailHTML {
    static let voidTags: Set<String> = ["br", "hr", "img", "meta", "link", "input", "source", "col", "wbr", "area", "base"]

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
    }

    static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Visible words only (`<b>Hi</b>&nbsp;Ann` → `Hi Ann`).
    static func plainText(_ html: String) -> String {
        RichHTMLParser.tokenize(html).compactMap { token -> String? in
            switch token {
            case .text(let text): return text
            case .open("br", _, _): return " "
            default: return nil
            }
        }.joined()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Where a link may go: a web page, an email address, a phone, an anchor or a merge field
    /// (`{{unsubscribe_url}}`). nil when fine, else what to tell the person.
    static func hrefProblem(_ value: String) -> String? {
        let pattern = #"^(https?://\S+|mailto:\S+|tel:[+\d][\d\s-]*|#\S*|\{\{\s*[\w.]+\s*\}\})$"#
        return value.trimmingCharacters(in: .whitespaces)
            .range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil
            ? "Start it with https:// (a website), mailto: (an email address) or tel: (a phone number)." : nil
    }

    /// The colours offered for buttons (the web studio's).
    static let buttonColours = ["#111827", "#e11d48", "#2563eb", "#16a34a", "#ea580c", "#7c3aed", "#0891b2", "#ca8a04"]

    /// White words on dark buttons, dark words on light ones (the web studio's rule).
    static func textOn(_ background: String) -> String {
        guard let rgb = hexComponents(background) else { return "#ffffff" }
        return 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2 > 0.6 ? "#111827" : "#ffffff"
    }

    /// `#abc`, `#aabbcc` or `rgb(1, 2, 3)` → `#aabbcc` (lower case), else nil.
    static func hex(_ css: String?) -> String? {
        guard let css else { return nil }
        let value = css.trimmingCharacters(in: .whitespaces).lowercased()
        if value.range(of: #"^#[0-9a-f]{6}$"#, options: .regularExpression) != nil { return value }
        if value.range(of: #"^#[0-9a-f]{3}$"#, options: .regularExpression) != nil {
            return "#" + value.dropFirst().map { "\($0)\($0)" }.joined()
        }
        if let color = RichColor(css: value), value.hasPrefix("rgb") {
            return String(format: "#%02x%02x%02x", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()),
                          Int((color.blue * 255).rounded()))
        }
        return nil
    }

    static func hexComponents(_ css: String) -> (Double, Double, Double)? {
        guard let hex = hex(css), let number = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }
}

// MARK: - Scanning

/// One top-level piece of HTML, with its exact source kept.
enum MktEmailHTMLNode: Hashable {
    case element(MktEmailHTMLElement)
    case text(String)
    case comment(String)

    var source: String {
        switch self {
        case .element(let element): element.outer
        case .text(let text), .comment(let text): text
        }
    }
}

struct MktEmailHTMLElement: Hashable {
    let name: String
    let attributes: [String: String]
    /// The source between the open and close tags.
    let inner: String
    /// The open tag as written (`<div style="…">`).
    let openTag: String
    /// The whole element as written.
    let outer: String

    var style: MktEmailCSS { MktEmailCSS(attributes["style"]) }
}

/// Splits HTML into its top-level elements and text, keeping each piece's source exactly.
enum MktEmailHTMLScanner {
    static func nodes(_ html: String) -> [MktEmailHTMLNode] {
        var nodes: [MktEmailHTMLNode] = []
        var index = html.startIndex
        var textStart = index
        func flushText(upTo end: String.Index) {
            if textStart < end { nodes.append(.text(String(html[textStart..<end]))) }
        }
        while index < html.endIndex {
            guard html[index] == "<" else { index = html.index(after: index); continue }
            let rest = html[index...]
            if rest.hasPrefix("<!--") {
                flushText(upTo: index)
                let end = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                nodes.append(.comment(String(html[index..<end])))
                index = end
                textStart = index
                continue
            }
            let next = html.index(after: index)
            guard next < html.endIndex, html[next].isLetter, let tagEnd = tagEnd(html, from: index) else {
                index = next
                continue
            }
            flushText(upTo: index)
            let openTag = String(html[index...tagEnd])
            let (name, attributes, selfClosing) = parseOpenTag(openTag)
            let afterOpen = html.index(after: tagEnd)
            if selfClosing || voidLike(name) {
                nodes.append(.element(MktEmailHTMLElement(name: name, attributes: attributes, inner: "", openTag: openTag,
                                                     outer: openTag)))
                index = afterOpen
            } else if let (innerEnd, closeEnd) = matchingClose(html, name: name, from: afterOpen) {
                nodes.append(.element(MktEmailHTMLElement(name: name, attributes: attributes,
                                                     inner: String(html[afterOpen..<innerEnd]), openTag: openTag,
                                                     outer: String(html[index..<closeEnd]))))
                index = closeEnd
            } else {
                // Never closed: the rest is its content.
                nodes.append(.element(MktEmailHTMLElement(name: name, attributes: attributes,
                                                     inner: String(html[afterOpen...]), openTag: openTag,
                                                     outer: String(html[index...]))))
                index = html.endIndex
            }
            textStart = index
        }
        flushText(upTo: html.endIndex)
        return nodes
    }

    private static func voidLike(_ name: String) -> Bool { MktEmailHTML.voidTags.contains(name) || name.hasPrefix("!") }

    /// The `>` that ends the tag starting at `start`, skipping quoted attribute values.
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
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// End of the content and end of the close tag that matches an open `name`.
    private static func matchingClose(_ html: String, name: String,
                                      from start: String.Index) -> (String.Index, String.Index)? {
        if name == "script" || name == "style" {
            guard let close = html.range(of: "</\(name)", options: .caseInsensitive, range: start..<html.endIndex),
                  let end = html[close.upperBound...].firstIndex(of: ">") else { return nil }
            return (close.lowerBound, html.index(after: end))
        }
        var depth = 1
        var index = start
        while index < html.endIndex {
            guard html[index] == "<" else { index = html.index(after: index); continue }
            let rest = html[index...]
            if rest.hasPrefix("<!--") {
                index = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                continue
            }
            let afterBracket = html.index(after: index)
            let closing = afterBracket < html.endIndex && html[afterBracket] == "/"
            let nameStart = closing ? html.index(after: afterBracket) : afterBracket
            if matchesName(html, at: nameStart, name: name), let end = tagEnd(html, from: index) {
                if closing {
                    depth -= 1
                    if depth == 0 { return (index, html.index(after: end)) }
                } else if html[html.index(before: end)] != "/" {
                    depth += 1
                }
                index = html.index(after: end)
                continue
            }
            index = afterBracket
        }
        return nil
    }

    private static func matchesName(_ html: String, at start: String.Index, name: String) -> Bool {
        guard let end = html.index(start, offsetBy: name.count, limitedBy: html.endIndex),
              html[start..<end].lowercased() == name else { return false }
        guard end < html.endIndex else { return true }
        let after = html[end]
        return after.isWhitespace || after == ">" || after == "/"
    }

    /// `<a href="x" style='y'>` → ("a", ["href": "x", "style": "y"], false). Values are entity-decoded.
    static func parseOpenTag(_ tag: String) -> (String, [String: String], Bool) {
        var body = Substring(tag.dropFirst().dropLast())
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body = body.dropLast() }
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        var rest = body.dropFirst(name.count)
        var attributes: [String: String] = [:]
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            guard !rest.isEmpty else { break }
            let key = rest.prefix { !$0.isWhitespace && $0 != "=" }.lowercased()
            rest = rest.dropFirst(key.count).drop { $0.isWhitespace }
            guard !key.isEmpty else { rest = rest.dropFirst(); continue }
            if rest.first == "=" {
                rest = rest.dropFirst().drop { $0.isWhitespace }
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let value = rest.dropFirst().prefix { $0 != quote }
                    attributes[key] = RichHTMLParser.decodeEntities(String(value))
                    rest = rest.dropFirst(min(rest.count, value.count + 2))
                } else {
                    let value = rest.prefix { !$0.isWhitespace }
                    attributes[key] = RichHTMLParser.decodeEntities(String(value))
                    rest = rest.dropFirst(value.count)
                }
            } else {
                attributes[key] = ""
            }
        }
        return (name, attributes, selfClosing)
    }
}

// MARK: - Blocks

/// One block of an email.
struct MktEmailBlock: Identifiable, Hashable {
    enum Kind: String, Hashable, CaseIterable {
        case heading, paragraph, list, image, button, divider, spacer, html
    }

    var id = UUID()
    var kind: Kind
    /// The source as it was read; written back unchanged until the block is edited (then nil).
    var original: String?

    /// Heading level (1 big heading, 2 heading, 3 small heading).
    var level = 2
    /// Heading and text: the words, as inline HTML (bold, links, colours). Button: its plain words.
    var text = ""
    /// List items, each inline HTML.
    var items: [String] = []
    var ordered = false
    /// List items written `<li><p>…</p></li>` (the editor's own lists) rather than `<li>…</li>`.
    var itemsInParagraphs = true
    /// The block element's own style (the `<p>`, `<h2>`, `<ul>`, `<hr>`; the paragraph around a picture or button).
    var style = MktEmailCSS()
    /// Button: where it goes, and the `<a>`'s style (colours, padding).
    var href = ""
    var linkStyle = MktEmailCSS()
    /// Picture.
    var src = ""
    var alt = ""
    var imageStyle = MktEmailCSS()
    /// The picture sits in a paragraph (so it can be centred).
    var imageWrapped = false
    /// Space, in pixels.
    var height = 24
    /// HTML block: the source as written.
    var raw = ""
    /// The words carry formatting the text editor can't keep (font sizes, inline pictures): editing
    /// them simplifies it, so the editor says so and offers the HTML instead.
    var simplified = false

    static let defaultButtonStyle = "display:inline-block;background:#111827;color:#ffffff;padding:12px 22px;"
        + "border-radius:6px;text-decoration:none;font-weight:600"

    // MARK: New blocks

    static func newParagraph(_ text: String = "") -> MktEmailBlock { MktEmailBlock(kind: .paragraph, text: text) }

    static func newHeading(_ text: String = "", level: Int = 2) -> MktEmailBlock {
        MktEmailBlock(kind: .heading, level: level, text: text)
    }

    static func newList(ordered: Bool = false) -> MktEmailBlock {
        MktEmailBlock(kind: .list, items: [""], ordered: ordered)
    }

    static func newButton(label: String = "", href: String = "https://", colour: String = MktEmailHTML.buttonColours[0])
        -> MktEmailBlock {
        var block = MktEmailBlock(kind: .button, text: label, style: MktEmailCSS("margin:24px 0;text-align:center"),
                                  href: href, linkStyle: MktEmailCSS(defaultButtonStyle))
        block.setButtonColour(colour)
        return block
    }

    static func newImage(src: String, alt: String = "") -> MktEmailBlock {
        MktEmailBlock(kind: .image, src: src, alt: alt, imageStyle: MktEmailCSS("max-width:100%;height:auto;display:block"))
    }

    static func newDivider() -> MktEmailBlock { MktEmailBlock(kind: .divider) }

    static func newSpacer(height: Int = 24) -> MktEmailBlock { MktEmailBlock(kind: .spacer, height: height) }

    static func newHTML(_ raw: String) -> MktEmailBlock { MktEmailBlock(kind: .html, raw: raw) }

    /// The unsubscribe and preferences links the web studio adds.
    static let unsubscribeHTML = "<p style=\"font-size:12px;color:#666\"><a href=\"{{unsubscribe_url}}\">Unsubscribe</a>"
        + " · <a href=\"{{preferences_url}}\">Preferences</a></p>"

    // MARK: Button colours

    /// The button's background as `#rrggbb`.
    var buttonColour: String { MktEmailHTML.hex(linkStyle.background) ?? "#111827" }

    mutating func setButtonColour(_ colour: String) {
        if linkStyle["background-color"] != nil { linkStyle["background-color"] = colour } else { linkStyle["background"] = colour }
        linkStyle["color"] = MktEmailHTML.textOn(colour)
    }

    // MARK: Picture size

    /// The web studio's sizes: small, medium, full width.
    static let imageWidths: [(label: String, value: String)] = [("Small", "200px"), ("Medium", "400px"), ("Full width", "100%")]

    var imageWidth: String? { imageStyle["width"] }

    mutating func setImageWidth(_ width: String) {
        imageStyle = MktEmailCSS("width:\(width);max-width:100%;height:auto;display:block")
    }

    // MARK: Writing

    /// The block as email HTML: its source when unchanged, else written from its parts.
    var html: String {
        if let original { return original }
        switch kind {
        case .heading:
            let tag = "h\(min(max(level, 1), 6))"
            return "<\(tag)\(style.attribute)>\(text)</\(tag)>"
        case .paragraph:
            return "<p\(style.attribute)>\(text)</p>"
        case .list:
            let tag = ordered ? "ol" : "ul"
            let lis = items.map { itemsInParagraphs ? "<li><p>\($0)</p></li>" : "<li>\($0)</li>" }.joined()
            return "<\(tag)\(style.attribute)>\(lis)</\(tag)>"
        case .image:
            let image = "<img src=\"\(MktEmailHTML.escapeAttribute(src))\" alt=\"\(MktEmailHTML.escapeAttribute(alt))\"\(imageStyle.attribute)>"
            return imageWrapped ? "<p\(style.attribute)>\(image)</p>" : image
        case .button:
            return "<p\(style.attribute)><a href=\"\(MktEmailHTML.escapeAttribute(href.trimmingCharacters(in: .whitespaces)))\""
                + "\(linkStyle.attribute)>\(MktEmailHTML.escapeText(text.trimmingCharacters(in: .whitespaces)))</a></p>"
        case .divider:
            return "<hr\(style.attribute)>"
        case .spacer:
            return "<div style=\"height:\(height)px;line-height:\(height)px;font-size:1px\">&nbsp;</div>"
        case .html:
            return raw
        }
    }

    /// The words of the block, for its row and for accessibility.
    var summary: String {
        switch kind {
        case .heading, .paragraph: return MktEmailHTML.plainText(text)
        case .list: return items.map(MktEmailHTML.plainText).joined(separator: " · ")
        case .button: return text
        case .image: return alt.isEmpty ? src : alt
        case .divider: return ""
        case .spacer: return "\(height) px"
        case .html: return MktEmailHTML.plainText(raw)
        }
    }

    var kindLabel: String {
        switch kind {
        case .heading: return level == 1 ? "Big heading" : level == 2 ? "Heading" : "Small heading"
        case .paragraph: return "Text"
        case .list: return ordered ? "Numbered list" : "Bullet list"
        case .image: return "Picture"
        case .button: return "Button"
        case .divider: return "Divider line"
        case .spacer: return "Space"
        case .html: return "HTML"
        }
    }

    var systemImage: String {
        switch kind {
        case .heading: "textformat.size.larger"
        case .paragraph: "text.alignleft"
        case .list: ordered ? "list.number" : "list.bullet"
        case .image: "photo"
        case .button: "rectangle.and.hand.point.up.left"
        case .divider: "minus"
        case .spacer: "arrow.up.and.down"
        case .html: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// An email body: an optional card around the content (the ready-made designs' white card) and its blocks.
struct MktEmailDocument: Hashable {
    /// The card's open tag (`<div style="…">`); its content is the blocks.
    var frameOpen: String?
    var blocks: [MktEmailBlock]

    init(frameOpen: String? = nil, blocks: [MktEmailBlock]) {
        self.frameOpen = frameOpen
        self.blocks = blocks
    }

    /// A whole HTML document (doctype, `<html>`, `<body>`) is edited as HTML source only.
    static func isWholeDocument(_ html: String) -> Bool {
        html.range(of: #"<(html|body|head)\b|<!doctype"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A table layout (hand-coded or imported emails): kept as HTML blocks, shown as written.
    static func hasTableLayout(_ html: String) -> Bool {
        html.range(of: #"<(table|tbody|tr|td|center)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    var html: String {
        let inner = blocks.map(\.html).joined(separator: "\n")
        guard let frameOpen else { return inner }
        return "\(frameOpen)\n\(inner)\n</div>"
    }

    // MARK: Reading

    static func parse(_ html: String) -> MktEmailDocument {
        let nodes = significant(MktEmailHTMLScanner.nodes(html))
        if nodes.count == 1, case .element(let card) = nodes[0], card.name == "div", spacerHeight(card) == nil,
           MktEmailHTMLScanner.nodes(card.inner).contains(where: { if case .element = $0 { true } else { false } }) {
            return MktEmailDocument(frameOpen: card.openTag, blocks: blocks(card.inner))
        }
        return MktEmailDocument(blocks: blocks(html))
    }

    static func blocks(_ html: String) -> [MktEmailBlock] {
        var result: [MktEmailBlock] = []
        var loose: [MktEmailHTMLNode] = []
        func flushLoose() {
            let source = loose.map(\.source).joined()
            loose = []
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var block = MktEmailBlock(kind: .paragraph, original: source.trimmingCharacters(in: .whitespacesAndNewlines),
                                      text: source.trimmingCharacters(in: .whitespacesAndNewlines))
            block.simplified = !MktEmailInline.isSupported(block.text)
            result.append(block)
        }
        for node in MktEmailHTMLScanner.nodes(html) {
            switch node {
            case .text:
                loose.append(node)
            case .comment(let comment):
                flushLoose()
                result.append(MktEmailBlock(kind: .html, original: comment, raw: comment))
            case .element(let element):
                if inlineTags.contains(element.name) {
                    loose.append(node)
                } else {
                    flushLoose()
                    result.append(block(element))
                }
            }
        }
        flushLoose()
        return result
    }

    static let inlineTags: Set<String> = ["a", "b", "strong", "i", "em", "u", "s", "strike", "del", "span", "br", "mark",
                                          "small", "sup", "sub", "font", "code"]

    static func block(_ element: MktEmailHTMLElement) -> MktEmailBlock {
        let source = element.outer
        let html = MktEmailBlock(kind: .html, original: source, raw: source)
        switch element.name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            var block = MktEmailBlock(kind: .heading, original: source, level: Int(element.name.dropFirst()) ?? 2,
                                      text: element.inner, style: element.style)
            block.simplified = !MktEmailInline.isSupported(element.inner)
            return block
        case "p":
            let inside = significant(MktEmailHTMLScanner.nodes(element.inner))
            if inside.count == 1, case .element(let only) = inside[0] {
                if only.name == "a", isButton(only) {
                    return MktEmailBlock(kind: .button, original: source, text: MktEmailHTML.plainText(only.inner),
                                         style: element.style, href: only.attributes["href"] ?? "",
                                         linkStyle: only.style)
                }
                if only.name == "img" {
                    return MktEmailBlock(kind: .image, original: source, style: element.style,
                                         src: only.attributes["src"] ?? "", alt: only.attributes["alt"] ?? "",
                                         imageStyle: only.style, imageWrapped: true)
                }
            }
            var block = MktEmailBlock(kind: .paragraph, original: source, text: element.inner, style: element.style)
            block.simplified = !MktEmailInline.isSupported(element.inner)
            return block
        case "ul", "ol":
            var items: [String] = []
            var inParagraphs = true
            for node in significant(MktEmailHTMLScanner.nodes(element.inner)) {
                guard case .element(let li) = node, li.name == "li" else { return html }
                let inside = significant(MktEmailHTMLScanner.nodes(li.inner))
                if inside.count == 1, case .element(let p) = inside[0], p.name == "p", p.attributes.isEmpty {
                    items.append(p.inner)
                } else if inside.allSatisfy({ node in
                    if case .element(let e) = node { return inlineTags.contains(e.name) }
                    return true
                }) {
                    items.append(li.inner.trimmingCharacters(in: .whitespacesAndNewlines))
                    inParagraphs = false
                } else {
                    return html  // nested lists or blocks inside an item: kept as written
                }
            }
            var block = MktEmailBlock(kind: .list, original: source, items: items, ordered: element.name == "ol",
                                      itemsInParagraphs: inParagraphs, style: element.style)
            block.simplified = items.contains { !MktEmailInline.isSupported($0) }
            return block
        case "img":
            return MktEmailBlock(kind: .image, original: source, src: element.attributes["src"] ?? "",
                                 alt: element.attributes["alt"] ?? "", imageStyle: element.style)
        case "hr":
            return MktEmailBlock(kind: .divider, original: source, style: element.style)
        case "div":
            if let height = spacerHeight(element) {
                return MktEmailBlock(kind: .spacer, original: source, height: height)
            }
            return html
        default:
            return html
        }
    }

    /// A link drawn as a button: it has a background colour (the web studio's rule).
    static func isButton(_ element: MktEmailHTMLElement) -> Bool {
        element.style.background != nil
    }

    /// `<div style="height:24px…">&nbsp;</div>` → 24.
    static func spacerHeight(_ element: MktEmailHTMLElement) -> Int? {
        guard element.name == "div", let height = element.style["height"],
              let value = Int(height.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let content = element.inner.replacingOccurrences(of: "&nbsp;", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? value : nil
    }

    /// Nodes without the whitespace between them.
    static func significant(_ nodes: [MktEmailHTMLNode]) -> [MktEmailHTMLNode] {
        nodes.filter { node in
            if case .text(let text) = node { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }
}
