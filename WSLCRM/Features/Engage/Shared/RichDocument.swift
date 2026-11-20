import SwiftUI

/// Rich content from the server (a blog post, a lesson, an email design) as native blocks.
///
/// The app never shows a web page, so HTML and Markdown are read here into headings, paragraphs,
/// lists, quotes, code, images, buttons, rules and tables, and `RichTextView` draws them with
/// SwiftUI. What can't be drawn natively (scripts, embedded videos and frames, forms inside the
/// content) is left out or shown as a plain line saying what it was.
struct RichDocument: Hashable {
    var blocks: [RichBlock]

    init(blocks: [RichBlock]) { self.blocks = blocks }

    static let empty = RichDocument(blocks: [])

    var isEmpty: Bool { blocks.isEmpty }

    /// HTML (a CMS post, an email, a lesson written in the rich editor).
    static func html(_ html: String) -> RichDocument { RichHTMLParser(html).parse() }

    /// Markdown (headings, lists, quotes, code fences, images, links, bold and italic).
    static func markdown(_ text: String) -> RichDocument { RichMarkdownParser(text).parse() }

    /// Whatever the text looks like: HTML when it has tags, else Markdown.
    static func auto(_ text: String) -> RichDocument {
        RichHTMLParser.looksLikeHTML(text) ? html(text) : markdown(text)
    }

    /// The words only (list subtitles, previews, search).
    var plainText: String {
        blocks.compactMap(\.plainText).joined(separator: "\n")
    }

    /// The words of some HTML, without tags (`<p>Hi <b>Ann</b></p>` → `Hi Ann`).
    static func plainText(fromHTML html: String) -> String {
        RichDocument.html(html).plainText
    }
}

enum RichAlign: Hashable {
    case leading, center, trailing

    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// One block of rich content.
enum RichBlock: Hashable {
    case heading(level: Int, text: AttributedString, align: RichAlign)
    case paragraph(AttributedString, align: RichAlign, background: RichColor?)
    case listItem(ordered: Bool, number: Int, depth: Int, text: AttributedString)
    case quote(AttributedString)
    case code(String)
    case image(url: URL?, alt: String?, width: Double?, align: RichAlign)
    /// A call-to-action link drawn as a button (email designs).
    case button(label: String, url: URL?, background: RichColor?, foreground: RichColor?, align: RichAlign)
    case rule
    case table(rows: [[AttributedString]], hasHeader: Bool)
    /// Something that can't be shown natively (an embedded video, a frame): what it was and its address.
    case embed(kind: String, url: URL?)

    var plainText: String? {
        switch self {
        case .heading(_, let text, _), .paragraph(let text, _, _), .quote(let text):
            return String(text.characters)
        case .listItem(let ordered, let number, _, let text):
            return (ordered ? "\(number). " : "• ") + String(text.characters)
        case .code(let code): return code
        case .image(_, let alt, _, _): return alt
        case .button(let label, _, _, _, _): return label
        case .rule: return nil
        case .table(let rows, _):
            return rows.map { $0.map { String($0.characters) }.joined(separator: " | ") }.joined(separator: "\n")
        case .embed(let kind, _): return kind
        }
    }
}

/// A colour from CSS (`#1a73e8`, `#fff`, `rgb(0, 0, 0)`, `white`).
struct RichColor: Hashable {
    let red: Double, green: Double, blue: Double, alpha: Double

    var color: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }

    /// Perceived lightness, to pick readable text on a coloured background.
    var isLight: Bool { (0.299 * red + 0.587 * green + 0.114 * blue) > 0.6 }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(css raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
            let shift = hex.count == 8 ? 8 : 0
            self.init(red: Double((number >> (16 + shift)) & 0xFF) / 255, green: Double((number >> (8 + shift)) & 0xFF) / 255,
                      blue: Double((number >> shift) & 0xFF) / 255,
                      alpha: hex.count == 8 ? Double(number & 0xFF) / 255 : 1)
            return
        }
        if value.hasPrefix("rgb") {
            let inner = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard parts.count >= 3 else { return nil }
            self.init(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts.count > 3 ? parts[3] : 1)
            return
        }
        let named: [String: (Double, Double, Double)] = [
            "white": (1, 1, 1), "black": (0, 0, 0), "red": (0.86, 0.15, 0.15), "green": (0.0, 0.5, 0.0),
            "blue": (0.0, 0.0, 1.0), "navy": (0.0, 0.0, 0.5), "grey": (0.5, 0.5, 0.5), "gray": (0.5, 0.5, 0.5),
            "orange": (1.0, 0.65, 0.0), "purple": (0.5, 0.0, 0.5), "teal": (0.0, 0.5, 0.5), "yellow": (1, 1, 0),
            "silver": (0.75, 0.75, 0.75), "maroon": (0.5, 0, 0),
        ]
        guard let rgb = named[value] else { return nil }
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - HTML

/// A small, forgiving HTML reader: enough for what editors and email designers produce.
struct RichHTMLParser {
    private let source: String

    init(_ source: String) { self.source = source }

    static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"<\s*(p|div|h[1-6]|br|ul|ol|li|table|img|a|strong|em|b|i|span|blockquote|pre|hr)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Tokens

    enum Token: Equatable {
        case open(String, [String: String], selfClosing: Bool)
        case close(String)
        case text(String)
    }

    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var index = html.startIndex
        var text = ""
        func flushText() {
            if !text.isEmpty { tokens.append(.text(decodeEntities(text))); text = "" }
        }
        while index < html.endIndex {
            let character = html[index]
            guard character == "<" else {
                text.append(character)
                index = html.index(after: index)
                continue
            }
            // Comments and doctype.
            if html[index...].hasPrefix("<!--") {
                flushText()
                if let end = html.range(of: "-->", range: index..<html.endIndex) { index = end.upperBound } else { break }
                continue
            }
            guard let close = html[index...].firstIndex(of: ">") else {
                text.append(contentsOf: html[index...])
                break
            }
            let inner = html[html.index(after: index)..<close]
            index = html.index(after: close)
            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }
            flushText()
            if inner.hasPrefix("/") {
                let name = inner.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                tokens.append(.close(name))
                continue
            }
            let (name, attributes, selfClosing) = parseTag(String(inner))
            guard !name.isEmpty else { continue }
            tokens.append(.open(name, attributes, selfClosing: selfClosing))
            // The text of these is never content.
            if ["script", "style", "title", "head", "svg", "noscript", "template"].contains(name), !selfClosing,
               let end = html.range(of: "</\(name)", options: .caseInsensitive, range: index..<html.endIndex) {
                index = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                tokens.append(.close(name))
            }
        }
        flushText()
        return tokens
    }

    private static func parseTag(_ inner: String) -> (String, [String: String], Bool) {
        var body = Substring(inner.trimmingCharacters(in: .whitespacesAndNewlines))
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body = body.dropLast() }
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        var rest = body.dropFirst(name.count)
        var attributes: [String: String] = [:]
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            guard !rest.isEmpty else { break }
            let key = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != ">" }.lowercased()
            rest = rest.dropFirst(key.count).drop { $0.isWhitespace }
            guard !key.isEmpty else { rest = rest.dropFirst(); continue }
            if rest.first == "=" {
                rest = rest.dropFirst().drop { $0.isWhitespace }
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let value = rest.dropFirst().prefix { $0 != quote }
                    attributes[key] = decodeEntities(String(value))
                    rest = rest.dropFirst(value.count + 2)
                } else {
                    let value = rest.prefix { !$0.isWhitespace }
                    attributes[key] = decodeEntities(String(value))
                    rest = rest.dropFirst(value.count)
                }
            } else {
                attributes[key] = ""
            }
        }
        return (name, attributes, selfClosing || ["br", "hr", "img", "meta", "link", "input", "source"].contains(name))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
            "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”",
            "ldquo": "“", "pound": "£", "euro": "€", "bull": "•", "middot": "·", "times": "×", "deg": "°",
            "zwnj": "", "zwj": "", "shy": "",
        ]
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semi = text[index...].prefix(12).firstIndex(of: ";") {
                let entity = text[text.index(after: index)..<semi]
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    replacement = named[entity.lowercased()]
                }
                if let replacement {
                    out += replacement
                    index = text.index(after: semi)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    /// `color: #fff; text-align:center` → ["color": "#fff", "text-align": "center"].
    static func style(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in (attributes["style"] ?? "").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: Building blocks

    private struct Inline {
        var bold = false, italic = false, underline = false, strike = false, code = false
        var link: URL?
        var color: RichColor?
    }

    private struct Container {
        var name: String
        var align: RichAlign?
        var background: RichColor?
    }

    private enum Pending {
        case paragraph, heading(Int), listItem, quote
    }

    func parse() -> RichDocument {
        let tokens = Self.tokenize(source)
        var builder = Builder()
        var index = 0
        while index < tokens.count {
            index = builder.consume(tokens, at: index)
        }
        builder.flush()
        return RichDocument(blocks: builder.blocks)
    }

    private struct Builder {
        var blocks: [RichBlock] = []
        var inline = AttributedString()
        var styles: [Inline] = [Inline()]
        var containers: [Container] = []
        var lists: [(ordered: Bool, counter: Int)] = []
        var pending: Pending = .paragraph
        var preDepth = 0
        var preText = ""
        var skipDepth = 0
        var quoteDepth = 0

        var align: RichAlign { containers.last { $0.align != nil }?.align ?? .leading }
        var background: RichColor? { containers.last { $0.background != nil }?.background }

        mutating func consume(_ tokens: [Token], at index: Int) -> Int {
            switch tokens[index] {
            case .text(let text):
                if skipDepth > 0 { return index + 1 }
                if preDepth > 0 { preText += text; return index + 1 }
                appendText(text)
            case .open(let name, let attributes, let selfClosing):
                if skipDepth > 0 {
                    if !selfClosing, Self.skipping.contains(name) { skipDepth += 1 }
                    return index + 1
                }
                return open(name, attributes, selfClosing: selfClosing, tokens: tokens, index: index)
            case .close(let name):
                if skipDepth > 0 {
                    if Self.skipping.contains(name) { skipDepth -= 1 }
                    return index + 1
                }
                close(name)
            }
            return index + 1
        }

        static let skipped: Set<String> = ["script", "style", "title", "head", "svg", "noscript", "template", "select",
                                           "textarea", "button", "form", "object"]
        static let embeds: Set<String> = ["iframe", "video", "audio", "embed"]
        /// Tags whose content is passed over (counted so nested ones close properly).
        static let skipping = skipped.union(embeds)
        static let blockContainers: Set<String> = ["div", "section", "article", "header", "footer", "main", "aside",
                                                   "nav", "figure", "figcaption", "center", "table", "tbody", "thead",
                                                   "tfoot", "tr", "td", "th", "body", "html", "dl", "dt", "dd",
                                                   "details", "summary", "address"]

        mutating func open(_ name: String, _ attributes: [String: String], selfClosing: Bool, tokens: [Token],
                           index: Int) -> Int {
            let css = RichHTMLParser.style(attributes)
            switch name {
            case _ where Self.embeds.contains(name):
                flush()
                let kind = name == "audio" ? "Audio" : "Video"
                blocks.append(.embed(kind: kind, url: URL(string: attributes["src"] ?? "")))
                if !selfClosing { skipDepth = 1 }
            case _ where Self.skipped.contains(name):
                if !selfClosing { skipDepth = 1 }
            case "br":
                if preDepth > 0 { preText += "\n" } else { inline += AttributedString("\n") }
            case "p":
                flush()
                containers.append(container(name, attributes, css))
                pending = quoteDepth > 0 ? .quote : .paragraph
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                containers.append(container(name, attributes, css))
                pending = .heading(Int(name.dropFirst()) ?? 2)
            case "ul", "ol":
                flush()
                let start = Int(attributes["start"] ?? "") ?? 1
                lists.append((ordered: name == "ol", counter: start - 1))
            case "li":
                flush()
                if lists.isEmpty { lists.append((ordered: false, counter: 0)) }
                lists[lists.count - 1].counter += 1
                pending = .listItem
            case "blockquote":
                flush()
                quoteDepth += 1
                pending = .quote
            case "pre":
                flush()
                preDepth += 1
            case "hr":
                flush()
                blocks.append(.rule)
            case "img":
                let src = attributes["src"] ?? ""
                let width = Double(attributes["width"]?.replacingOccurrences(of: "px", with: "") ?? "")
                    ?? Double(css["width"]?.replacingOccurrences(of: "px", with: "") ?? "")
                let height = Double(attributes["height"]?.replacingOccurrences(of: "px", with: "") ?? "")
                // Tracking pixels and spacers are not content.
                if let width, width <= 2 { break }
                if let height, height <= 2 { break }
                flush()
                blocks.append(.image(url: URL(string: src), alt: attributes["alt"]?.trimmedOrNil, width: width,
                                     align: align))
            case "table":
                flush()
                if let (table, next) = dataTable(tokens, from: index) {
                    blocks.append(table)
                    return next
                }
                containers.append(container(name, attributes, css))
            case "a":
                if isButton(attributes, css) {
                    // A call to action: its words, drawn as a button.
                    flush()
                    var label = ""
                    var cursor = index + 1
                    var depth = 1
                    while cursor < tokens.count, depth > 0 {
                        switch tokens[cursor] {
                        case .text(let text): label += text
                        case .open(let inner, _, let closed) where inner == "a" && !closed: depth += 1
                        case .close(let inner) where inner == "a": depth -= 1
                        default: break
                        }
                        cursor += 1
                    }
                    let collapsed = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    blocks.append(.button(label: collapsed.isEmpty ? "Open" : collapsed,
                                          url: URL(string: attributes["href"] ?? ""),
                                          background: (css["background-color"] ?? css["background"]).flatMap(RichColor.init(css:)),
                                          foreground: css["color"].flatMap(RichColor.init(css:)), align: align))
                    return cursor
                }
                var style = styles.last ?? Inline()
                style.link = URL(string: attributes["href"] ?? "")
                apply(css, to: &style)
                styles.append(style)
            case "b", "strong":
                push { $0.bold = true }
            case "i", "em", "cite":
                push { $0.italic = true }
            case "u", "ins":
                push { $0.underline = true }
            case "s", "strike", "del":
                push { $0.strike = true }
            case "code", "kbd", "samp":
                push { $0.code = true }
            case "span", "font", "small", "mark", "sup", "sub", "abbr", "label", "q":
                var style = styles.last ?? Inline()
                apply(css, to: &style)
                if let color = attributes["color"].flatMap(RichColor.init(css:)) { style.color = color }
                styles.append(style)
            default:
                if Self.blockContainers.contains(name) {
                    if ["div", "tr", "section", "article", "header", "footer", "td", "th", "center", "figure",
                        "figcaption", "dd", "dt"].contains(name) {
                        flush()
                    }
                    containers.append(container(name, attributes, css))
                }
            }
            return index + 1
        }

        mutating func close(_ name: String) {
            switch name {
            case "p", "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                popContainer(name)
                pending = quoteDepth > 0 ? .quote : .paragraph
            case "li":
                flush()
                pending = quoteDepth > 0 ? .quote : .paragraph
            case "ul", "ol":
                flush()
                if !lists.isEmpty { lists.removeLast() }
                pending = quoteDepth > 0 ? .quote : .paragraph
            case "blockquote":
                flush()
                quoteDepth = max(0, quoteDepth - 1)
                pending = quoteDepth > 0 ? .quote : .paragraph
            case "pre":
                preDepth = max(0, preDepth - 1)
                if preDepth == 0 {
                    let code = preText.trimmingCharacters(in: .newlines)
                    if !code.isEmpty { blocks.append(.code(code)) }
                    preText = ""
                }
            case "a", "b", "strong", "i", "em", "cite", "u", "ins", "s", "strike", "del", "code", "kbd", "samp",
                 "span", "font", "small", "mark", "sup", "sub", "abbr", "label", "q":
                if styles.count > 1 { styles.removeLast() }
            default:
                if Self.blockContainers.contains(name) {
                    flush()
                    popContainer(name)
                }
            }
        }

        mutating func push(_ change: (inout Inline) -> Void) {
            var style = styles.last ?? Inline()
            change(&style)
            styles.append(style)
        }

        mutating func popContainer(_ name: String) {
            if let last = containers.lastIndex(where: { $0.name == name }) { containers.removeSubrange(last...) }
        }

        func container(_ name: String, _ attributes: [String: String], _ css: [String: String]) -> Container {
            var align: RichAlign?
            switch (css["text-align"] ?? attributes["align"] ?? (name == "center" ? "center" : "")).lowercased() {
            case "center": align = .center
            case "right", "end": align = .trailing
            case "left", "start", "justify": align = .leading
            default: align = nil
            }
            let background = (css["background-color"] ?? css["background"] ?? attributes["bgcolor"])
                .flatMap { RichColor(css: String($0.split(separator: " ").first ?? "")) }
            return Container(name: name, align: align, background: background)
        }

        func apply(_ css: [String: String], to style: inout Inline) {
            if let color = css["color"].flatMap(RichColor.init(css:)) { style.color = color }
            if let weight = css["font-weight"], weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600 {
                style.bold = true
            }
            if css["font-style"] == "italic" { style.italic = true }
            if let decoration = css["text-decoration"] {
                if decoration.contains("underline") { style.underline = true }
                if decoration.contains("line-through") { style.strike = true }
            }
        }

        func isButton(_ attributes: [String: String], _ css: [String: String]) -> Bool {
            let classes = (attributes["class"] ?? "").lowercased()
            if classes.contains("button") || classes.contains("btn") || attributes["role"] == "button" { return true }
            let hasBackground = css["background-color"] != nil || css["background"] != nil
            return hasBackground && (css["padding"] != nil || css["display"]?.contains("inline-block") == true)
        }

        mutating func appendText(_ raw: String) {
            // HTML collapses runs of whitespace into one space (a non-breaking space stays).
            var text = raw.replacingOccurrences(of: #"[ \t\n\r\f]+"#, with: " ", options: .regularExpression)
            if text == " ", inline.characters.isEmpty || inline.characters.last == "\n" || inline.characters.last == " " {
                return
            }
            if inline.characters.isEmpty || inline.characters.last == "\n" {
                text = String(text.drop { $0 == " " })
            }
            guard !text.isEmpty else { return }
            var piece = AttributedString(text)
            let style = styles.last ?? Inline()
            var intent: InlinePresentationIntent = []
            if style.bold { intent.insert(.stronglyEmphasized) }
            if style.italic { intent.insert(.emphasized) }
            if style.code { intent.insert(.code) }
            if style.strike { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if style.underline { piece.swiftUI.underlineStyle = .single }
            if let link = style.link { piece.link = link }
            if let color = style.color { piece.swiftUI.foregroundColor = color.color }
            inline += piece
        }

        mutating func flush() {
            var text = inline
            inline = AttributedString()
            // Trim spaces and line breaks at both ends.
            while let first = text.characters.first, first.isWhitespace {
                text.removeSubrange(text.startIndex..<text.index(afterCharacter: text.startIndex))
            }
            while let last = text.characters.last, last.isWhitespace {
                text.removeSubrange(text.index(beforeCharacter: text.endIndex)..<text.endIndex)
            }
            guard !text.characters.isEmpty else { return }
            switch pending {
            case .heading(let level):
                blocks.append(.heading(level: level, text: text, align: align))
            case .listItem:
                let list = lists.last ?? (ordered: false, counter: 1)
                blocks.append(.listItem(ordered: list.ordered, number: list.counter, depth: max(0, lists.count - 1),
                                        text: text))
            case .quote:
                blocks.append(.quote(text))
            case .paragraph:
                if quoteDepth > 0 { blocks.append(.quote(text)) } else {
                    blocks.append(.paragraph(text, align: align, background: background))
                }
            }
        }

        /// A table with header cells is data (shown as a grid); any other table is page layout.
        func dataTable(_ tokens: [Token], from start: Int) -> (RichBlock, Int)? {
            var depth = 0
            var end = start
            var hasHeader = false
            var nested = false
            for cursor in start..<tokens.count {
                switch tokens[cursor] {
                case .open("table", _, false): depth += 1; if depth > 1 { nested = true }
                case .close("table"): depth -= 1
                case .open("th", _, _): hasHeader = true
                default: break
                }
                if depth == 0 { end = cursor; break }
            }
            guard hasHeader, !nested, end > start else { return nil }
            var rows: [[AttributedString]] = []
            var row: [AttributedString]?
            var cell: String?
            for cursor in start...end {
                switch tokens[cursor] {
                case .open("tr", _, _): row = []
                case .close("tr"): if let row { rows.append(row) }; row = nil
                case .open("td", _, _), .open("th", _, _): cell = ""
                case .close("td"), .close("th"):
                    let words = (cell ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    row?.append(AttributedString(words))
                    cell = nil
                case .text(let text): if cell != nil { cell! += text }
                case .open("br", _, _): if cell != nil { cell! += " " }
                default: break
                }
            }
            return rows.isEmpty ? nil : (.table(rows: rows, hasHeader: true), end + 1)
        }
    }
}

// MARK: - Markdown

/// A small Markdown reader: block structure here, inline styling by Foundation's own parser.
struct RichMarkdownParser {
    private let source: String

    init(_ source: String) { self.source = source }

    func parse() -> RichDocument {
        var blocks: [RichBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var counters: [Int: Int] = [:]

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(Self.inline(paragraph.joined(separator: "\n")), align: .leading, background: nil))
            paragraph = []
        }

        for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") { flushParagraph(); code = []; continue }
            if line.isEmpty { flushParagraph(); counters = [:]; continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if level <= 6, line.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: level, text: Self.inline(String(line.dropFirst(level + 1))), align: .leading))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" { flushParagraph(); blocks.append(.rule); continue }
            if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(Self.inline(String(line.dropFirst().drop { $0 == " " }))))
                continue
            }
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count / 2
            if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
                flushParagraph()
                blocks.append(.listItem(ordered: false, number: 0, depth: indent, text: Self.inline(String(line.dropFirst(2)))))
                continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), let number = Int(line[..<dot]),
               line[line.index(after: dot)...].first == " " {
                flushParagraph()
                counters[indent, default: 0] += 1
                blocks.append(.listItem(ordered: true, number: counters[indent] ?? number, depth: indent,
                                        text: Self.inline(String(line[line.index(dot, offsetBy: 2)...]))))
                continue
            }
            if line.hasPrefix("!["), let close = line.firstIndex(of: "]"), line[line.index(after: close)...].hasPrefix("("),
               line.hasSuffix(")") {
                flushParagraph()
                let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
                let url = String(line[line.index(close, offsetBy: 2)..<line.index(before: line.endIndex)])
                    .split(separator: " ").first.map(String.init) ?? ""
                blocks.append(.image(url: URL(string: url), alt: alt.trimmedOrNil, width: nil, align: .leading))
                continue
            }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return RichDocument(blocks: blocks)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
