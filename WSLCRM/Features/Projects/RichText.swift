import Foundation

/// The web dashboard writes descriptions and comments with a rich-text editor, so they arrive as
/// small pieces of HTML (`<p>`, `<ul><li>`, `<strong>`, mention spans). The app shows them as plain
/// text and writes plain text back as the same simple HTML, so both sides read each other's words.
enum RichText {
    /// HTML → readable text: paragraphs and list items on their own lines, tags dropped, entities
    /// decoded, a mention span reduced to its "@Name".
    static func plain(_ html: String?) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        guard text.contains("<") || text.contains("&") else { return text }
        let breaks: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"), ("(?i)</p\\s*>", "\n"), ("(?i)</h[1-6]\\s*>", "\n"),
            ("(?i)<li[^>]*>", "• "), ("(?i)</li\\s*>", "\n"), ("(?i)</(ul|ol|blockquote|div|pre)\\s*>", "\n"),
        ]
        for (pattern, replacement) in breaks {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) { collapsed.append(line) }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text → the web editor's HTML: one paragraph per line, characters escaped.
    static func html(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        return lines.map { line in
            line.isEmpty ? "<p></p>" : "<p>\(escape(line))</p>"
        }.joined()
    }

    /// A comment with mentions: each `@Name` of a picked person becomes the web editor's mention
    /// span, so the web shows it highlighted and the server notifies them.
    static func html(_ text: String, mentions: [Mention]) -> String {
        var body = html(text)
        for mention in mentions {
            let plain = escape("@\(mention.name)")
            let span = "<span data-type=\"mention\" class=\"mention\" data-id=\"\(escape(mention.userUuid))\" "
                + "data-label=\"\(escape(mention.name))\">@\(escape(mention.name))</span>"
            body = body.replacingOccurrences(of: plain, with: span)
        }
        return body
    }

    struct Mention: Sendable, Hashable {
        let userUuid: String
        let name: String
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"]
        for (entity, value) in named where entity != "&amp;" { out = out.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let scalar = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                result += scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
