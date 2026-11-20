import SwiftUI
import UIKit

// The words of an email block, edited natively: inline HTML (bold, italic, underline, links,
// colours, highlights) is read into styled text for a UITextView and written back as email-safe
// HTML. Built by hand — no web view and no HTML importer.

extension NSAttributedString.Key {
    /// Where a link goes (kept as written: `{{unsubscribe_url}}` is not a valid URL).
    static let mktEmailHref = NSAttributedString.Key("mktEmailHref")
    /// The link's own style attribute (`color:#6b7280`), kept as it was.
    static let mktEmailLinkStyle = NSAttributedString.Key("mktEmailLinkStyle")
    /// A colour the person chose (`#e11d48`); text without one follows the email's own colour.
    static let mktEmailColour = NSAttributedString.Key("mktEmailColour")
    /// A highlight: "" for the standard marker, or a colour.
    static let mktEmailHighlight = NSAttributedString.Key("mktEmailHighlight")
}

enum MktEmailInline {
    static var highlightColour: UIColor { UIColor(red: 1, green: 0.94, blue: 0.54, alpha: 1) }

    /// Whether `html` uses only the formatting the text editor keeps.
    static func isSupported(_ html: String) -> Bool {
        for token in RichHTMLParser.tokenize(html) {
            guard case .open(let name, let attributes, _) = token else { continue }
            switch name {
            case "strong", "b", "em", "i", "u", "s", "strike", "del", "br":
                if !attributes.isEmpty { return false }
            case "a":
                if !Set(attributes.keys).isSubset(of: ["href", "style", "target", "rel", "title"]) { return false }
            case "span":
                guard Set(attributes.keys).isSubset(of: ["style"]) else { return false }
                let css = MktEmailCSS(attributes["style"])
                if !css.declarations.allSatisfy({ ["color", "background-color"].contains($0.property) }) { return false }
            case "mark":
                guard Set(attributes.keys).isSubset(of: ["style", "data-color"]) else { return false }
            default:
                return false
            }
        }
        return true
    }

    // MARK: HTML → styled text

    static func attributed(_ html: String, font: UIFont = .preferredFont(forTextStyle: .body)) -> NSAttributedString {
        struct Style {
            var bold = false, italic = false, underline = false, strike = false
            var href: String?, linkStyle: String?, colour: String?, highlight: String?
        }
        let result = NSMutableAttributedString()
        var stack: [(String, Style)] = [("", Style())]
        func current() -> Style { stack.last?.1 ?? Style() }
        func attributes(for style: Style, font: UIFont) -> [NSAttributedString.Key: Any] {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if style.bold { traits.insert(.traitBold) }
            if style.italic { traits.insert(.traitItalic) }
            var out: [NSAttributedString.Key: Any] = [
                .font: font.mktEmailWithTraits(traits),
                .foregroundColor: style.colour.flatMap(uiColour) ?? UIColor.label,
            ]
            if style.underline || style.href != nil { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strike { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let href = style.href {
                out[.mktEmailHref] = href
                if style.colour == nil { out[.foregroundColor] = UIColor.link }
            }
            if let linkStyle = style.linkStyle { out[.mktEmailLinkStyle] = linkStyle }
            if let colour = style.colour { out[.mktEmailColour] = colour }
            if let highlight = style.highlight {
                out[.mktEmailHighlight] = highlight
                out[.backgroundColor] = uiColour(highlight) ?? highlightColour
            }
            return out
        }
        func append(_ text: String) {
            guard !text.isEmpty else { return }
            result.append(NSAttributedString(string: text, attributes: attributes(for: current(), font: font)))
        }

        for token in RichHTMLParser.tokenize(html) {
            switch token {
            case .text(let text):
                var collapsed = text.replacingOccurrences(of: #"[ \t\n\r\f]+"#, with: " ", options: .regularExpression)
                if result.string.isEmpty || result.string.hasSuffix("\n") || result.string.hasSuffix(" ") {
                    while collapsed.hasPrefix(" ") { collapsed.removeFirst() }
                }
                append(collapsed)
            case .open(let name, let attrs, let selfClosing):
                if name == "br" { append("\n"); continue }
                if selfClosing { continue }
                var style = current()
                switch name {
                case "strong", "b": style.bold = true
                case "em", "i": style.italic = true
                case "u": style.underline = true
                case "s", "strike", "del": style.strike = true
                case "a":
                    style.href = attrs["href"] ?? ""
                    style.linkStyle = attrs["style"]
                    if let colour = MktEmailHTML.hex(MktEmailCSS(attrs["style"])["color"]) { style.colour = colour }
                case "span":
                    let css = MktEmailCSS(attrs["style"])
                    if let colour = MktEmailHTML.hex(css["color"]) { style.colour = colour }
                    if let background = MktEmailHTML.hex(css["background-color"]) { style.highlight = background }
                case "mark":
                    style.highlight = MktEmailHTML.hex(MktEmailCSS(attrs["style"])["background-color"]) ?? ""
                default: break
                }
                stack.append((name, style))
            case .close(let name):
                if let index = stack.lastIndex(where: { $0.0 == name }), index > 0 { stack.removeSubrange(index...) }
            }
        }
        // Trailing spaces from the source's line breaks are not words.
        while result.string.hasSuffix(" ") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    // MARK: Styled text → HTML

    static func html(_ text: NSAttributedString) -> String {
        struct Run: Equatable {
            var text: String
            var bold = false, italic = false, underline = false, strike = false
            var href: String?, linkStyle: String?, colour: String?, highlight: String?
        }
        var runs: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let words = (text.string as NSString).substring(with: range)
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let href = attributes[.mktEmailHref] as? String
            runs.append(Run(text: words, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic),
                            underline: href == nil && (attributes[.underlineStyle] as? Int ?? 0) != 0,
                            strike: (attributes[.strikethroughStyle] as? Int ?? 0) != 0, href: href,
                            linkStyle: attributes[.mktEmailLinkStyle] as? String, colour: attributes[.mktEmailColour] as? String,
                            highlight: attributes[.mktEmailHighlight] as? String))
        }
        var out = ""
        var index = 0
        while index < runs.count {
            // Consecutive runs going to the same place are one link.
            let href = runs[index].href
            let linkStyle = runs[index].linkStyle
            var end = index
            while end + 1 < runs.count, runs[end + 1].href == href, runs[end + 1].linkStyle == linkStyle, href != nil {
                end += 1
            }
            var inner = ""
            for run in runs[index...end] {
                var piece = MktEmailHTML.escapeText(run.text).replacingOccurrences(of: "\n", with: "<br>")
                if run.strike { piece = "<s>\(piece)</s>" }
                if run.underline { piece = "<u>\(piece)</u>" }
                if run.italic { piece = "<em>\(piece)</em>" }
                if run.bold { piece = "<strong>\(piece)</strong>" }
                if let highlight = run.highlight {
                    piece = highlight.isEmpty ? "<mark>\(piece)</mark>"
                        : "<mark style=\"background-color:\(highlight)\">\(piece)</mark>"
                }
                // A link's colour lives in its own style.
                if let colour = run.colour, !(href != nil && MktEmailCSS(linkStyle)["color"] != nil) {
                    piece = "<span style=\"color:\(colour)\">\(piece)</span>"
                }
                inner += piece
            }
            if let href {
                let style = linkStyle.map { " style=\"\(MktEmailHTML.escapeAttribute($0))\"" } ?? ""
                out += "<a href=\"\(MktEmailHTML.escapeAttribute(href))\"\(style)>\(inner)</a>"
            } else {
                out += inner
            }
            index = end + 1
        }
        return out
    }

    static func uiColour(_ hex: String) -> UIColor? {
        guard let rgb = MktEmailHTML.hexComponents(hex) else { return nil }
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    static func hex(_ colour: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02x%02x%02x", Int((min(max(red, 0), 1) * 255).rounded()),
                      Int((min(max(green, 0), 1) * 255).rounded()), Int((min(max(blue, 0), 1) * 255).rounded()))
    }
}

extension UIFont {
    func mktEmailWithTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - The editor

/// Runs formatting commands on the text view the person is typing in.
@MainActor
final class MktEmailTextController {
    weak var textView: UITextView?
    var onChange: ((NSAttributedString) -> Void)?

    var hasSelection: Bool { (textView?.selectedRange.length ?? 0) > 0 }

    /// Where the cursor's link goes, if it is in one.
    var currentLink: String? {
        guard let textView, textView.attributedText.length > 0 else { return nil }
        let location = min(textView.selectedRange.location, textView.attributedText.length - 1)
        return textView.attributedText.attribute(.mktEmailHref, at: max(location, 0), effectiveRange: nil) as? String
    }

    func toggleBold() { toggleTrait(.traitBold) }
    func toggleItalic() { toggleTrait(.traitItalic) }

    func toggleUnderline() { toggle(.underlineStyle, on: NSUnderlineStyle.single.rawValue) }
    func toggleStrike() { toggle(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue) }

    func setColour(_ hex: String?) {
        edit { storage, range in
            if let hex, let colour = MktEmailInline.uiColour(hex) {
                storage.addAttribute(.mktEmailColour, value: hex, range: range)
                storage.addAttribute(.foregroundColor, value: colour, range: range)
            } else {
                storage.removeAttribute(.mktEmailColour, range: range)
                storage.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        } typing: { attributes in
            if let hex, let colour = MktEmailInline.uiColour(hex) {
                attributes[.mktEmailColour] = hex
                attributes[.foregroundColor] = colour
            } else {
                attributes[.mktEmailColour] = nil
                attributes[.foregroundColor] = UIColor.label
            }
        }
    }

    func toggleHighlight() {
        guard let textView else { return }
        let range = textView.selectedRange
        let on = range.length > 0
            ? textView.attributedText.attribute(.mktEmailHighlight, at: range.location, effectiveRange: nil) == nil
            : textView.typingAttributes[.mktEmailHighlight] == nil
        edit { storage, range in
            if on {
                storage.addAttribute(.mktEmailHighlight, value: "", range: range)
                storage.addAttribute(.backgroundColor, value: MktEmailInline.highlightColour, range: range)
            } else {
                storage.removeAttribute(.mktEmailHighlight, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            }
        } typing: { attributes in
            attributes[.mktEmailHighlight] = on ? "" : nil
            attributes[.backgroundColor] = on ? MktEmailInline.highlightColour : nil
        }
    }

    /// Links the selected words (or the whole link the cursor is in) to `href`.
    func setLink(_ href: String) {
        guard let textView else { return }
        let range = linkRange() ?? textView.selectedRange
        guard range.length > 0 else { return }
        let storage = textView.textStorage
        storage.beginEditing()
        storage.addAttribute(.mktEmailHref, value: href, range: range)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        storage.enumerateAttribute(.mktEmailColour, in: range) { value, part, _ in
            if value == nil { storage.addAttribute(.foregroundColor, value: UIColor.link, range: part) }
        }
        storage.endEditing()
        changed()
    }

    func removeLink() {
        guard let textView, let range = linkRange() else { return }
        let storage = textView.textStorage
        storage.beginEditing()
        storage.removeAttribute(.mktEmailHref, range: range)
        storage.removeAttribute(.mktEmailLinkStyle, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.enumerateAttribute(.mktEmailColour, in: range) { value, part, _ in
            if value == nil { storage.addAttribute(.foregroundColor, value: UIColor.label, range: part) }
        }
        storage.endEditing()
        changed()
    }

    /// Puts text (a merge field) where the cursor is.
    func insert(_ text: String) {
        guard let textView else { return }
        let range = textView.selectedRange
        let inserted = NSAttributedString(string: text, attributes: textView.typingAttributes)
        textView.textStorage.replaceCharacters(in: range, with: inserted)
        textView.selectedRange = NSRange(location: range.location + inserted.length, length: 0)
        changed()
    }

    // MARK: Internals

    private func linkRange() -> NSRange? {
        guard let textView, textView.attributedText.length > 0 else { return nil }
        let location = min(textView.selectedRange.location, textView.attributedText.length - 1)
        var range = NSRange()
        guard textView.attributedText.attribute(.mktEmailHref, at: max(location, 0), longestEffectiveRange: &range,
                                                in: NSRange(location: 0, length: textView.attributedText.length)) != nil
        else { return nil }
        return range
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let textView else { return }
        let range = textView.selectedRange
        let base = UIFont.preferredFont(forTextStyle: .body)
        func has(_ font: UIFont?) -> Bool { font?.fontDescriptor.symbolicTraits.contains(trait) ?? false }
        var allOn = true
        if range.length > 0 {
            textView.attributedText.enumerateAttribute(.font, in: range) { value, _, _ in
                if !has(value as? UIFont) { allOn = false }
            }
        } else {
            allOn = has(textView.typingAttributes[.font] as? UIFont)
        }
        func flipped(_ font: UIFont?) -> UIFont {
            let font = font ?? base
            var traits = font.fontDescriptor.symbolicTraits
            if allOn { traits.remove(trait) } else { traits.insert(trait) }
            return base.mktEmailWithTraits(traits.intersection([.traitBold, .traitItalic]))
        }
        edit { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                storage.addAttribute(.font, value: flipped(value as? UIFont), range: part)
            }
        } typing: { attributes in
            attributes[.font] = flipped(attributes[.font] as? UIFont)
        }
    }

    private func toggle(_ key: NSAttributedString.Key, on value: Int) {
        guard let textView else { return }
        let range = textView.selectedRange
        let isOn = range.length > 0
            ? ((textView.attributedText.attribute(key, at: range.location, effectiveRange: nil) as? Int) ?? 0) != 0
            : ((textView.typingAttributes[key] as? Int) ?? 0) != 0
        edit { storage, range in
            if isOn { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: value, range: range) }
        } typing: { attributes in
            attributes[key] = isOn ? nil : value
        }
    }

    private func edit(_ change: (NSTextStorage, NSRange) -> Void,
                      typing: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let textView else { return }
        let range = textView.selectedRange
        if range.length > 0 {
            textView.textStorage.beginEditing()
            change(textView.textStorage, range)
            textView.textStorage.endEditing()
            changed()
        } else {
            var attributes = textView.typingAttributes
            typing(&attributes)
            textView.typingAttributes = attributes
        }
    }

    private func changed() {
        guard let textView else { return }
        onChange?(NSAttributedString(attributedString: textView.attributedText))
    }
}

/// A text view for styled words (UIKit's own; no web view).
struct MktEmailTextView: UIViewRepresentable {
    @Binding var text: NSAttributedString
    let controller: MktEmailTextController
    var accessibilityLabel = "Words"

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.attributedText = text
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = "mkt.richText"
        view.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        controller.textView = view
        controller.onChange = { [binding = $text] in binding.wrappedValue = $0 }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        controller.textView = view
        if !view.attributedText.isEqual(to: text) {
            let selection = view.selectedRange
            view.attributedText = text
            if selection.location + selection.length <= text.length { view.selectedRange = selection }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<NSAttributedString>

        init(text: Binding<NSAttributedString>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = NSAttributedString(attributedString: textView.attributedText)
        }
    }
}
