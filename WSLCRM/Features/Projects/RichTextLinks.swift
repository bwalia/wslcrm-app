import Foundation

/// Descriptions and comments with their links kept: the web editor's `<a href>` links and any bare
/// web address or email in the text become tappable. They open in their own apps
/// (Safari, Mail, Phone); nothing is shown inside this app.
extension RichText {
    private static let open = "\u{E000}", middle = "\u{E001}", close = "\u{E002}"

    /// HTML (or plain text) → readable text with tappable links.
    static func attributed(_ html: String?) -> AttributedString {
        guard let html, !html.isEmpty else { return AttributedString() }
        // Mark each link before the tags go, so its address survives `plain`.
        let marked = html.replacingOccurrences(
            of: "(?is)<a\\s[^>]*?href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a\\s*>",
            with: "\(open)$2\(middle)$1\(close)", options: .regularExpression)
        let text = plain(marked)
        var out = AttributedString()
        var rest = Substring(text)
        while let start = rest.range(of: open), let mid = rest[start.upperBound...].range(of: middle),
              let end = rest[mid.upperBound...].range(of: close) {
            out += detected(String(rest[..<start.lowerBound]))
            let href = String(rest[mid.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            let label = String(rest[start.upperBound..<mid.lowerBound])
            var piece = AttributedString(label.isEmpty ? href : label)
            if let url = safeURL(href) { piece.link = url }
            out += piece
            rest = rest[end.upperBound...]
        }
        out += detected(String(rest))
        return out
    }

    /// Only links that open another app: web pages, email and phone. Never `javascript:` and the like.
    static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else { return nil }
        return url
    }

    /// Formatting the app's plain editor can't keep: saving there would drop it.
    static func formattingLostOnEdit(_ html: String?) -> [String] {
        guard let html, html.contains("<") else { return [] }
        let kinds: [(String, String)] = [
            ("(?i)<a\\s", "links"), ("(?i)<table", "tables"), ("(?i)<pre", "code blocks"), ("(?i)<img", "pictures"),
        ]
        return kinds.filter { html.range(of: $0.0, options: .regularExpression) != nil }.map(\.1)
    }

    private static func detected(_ text: String) -> AttributedString {
        var out = AttributedString()
        guard !text.isEmpty else { return out }
        // Web addresses and emails only: phone detection also catches dates and amounts.
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(text)
        }
        let ns = text as NSString
        var last = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let safe = safeURL(url.absoluteString) else { continue }
            out += AttributedString(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            var piece = AttributedString(ns.substring(with: match.range))
            piece.link = safe
            out += piece
            last = match.range.location + match.range.length
        }
        out += AttributedString(ns.substring(from: last))
        return out
    }
}
