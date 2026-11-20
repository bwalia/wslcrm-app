import SwiftUI
import UIKit

// Inline formatting (bold, italic, underline, strikethrough, code, highlight, colour, links, sub- and
// superscript) edited natively in a UITextView and written back as the same HTML the web editor
// (TipTap) writes. What a run *means* is kept in the cms* attributes below; fonts and colours are
// only how it looks, and are rebuilt from the meaning after every change.

extension NSAttributedString.Key {
    static let cmsBold = NSAttributedString.Key("cms.bold")
    static let cmsItalic = NSAttributedString.Key("cms.italic")
    static let cmsUnderline = NSAttributedString.Key("cms.underline")
    static let cmsStrike = NSAttributedString.Key("cms.strike")
    static let cmsCode = NSAttributedString.Key("cms.code")
    static let cmsHighlight = NSAttributedString.Key("cms.highlight")
    /// `#rrggbb` text colour.
    static let cmsColor = NSAttributedString.Key("cms.color")
    /// Link address.
    static let cmsLink = NSAttributedString.Key("cms.link")
    static let cmsSub = NSAttributedString.Key("cms.sub")
    static let cmsSup = NSAttributedString.Key("cms.sup")
}

enum CMSInline {
    static let semanticKeys: [NSAttributedString.Key] = [.cmsBold, .cmsItalic, .cmsUnderline, .cmsStrike, .cmsCode,
                                                         .cmsHighlight, .cmsColor, .cmsLink, .cmsSub, .cmsSup]

    /// Tags (and the attributes on them) this editor can change without losing anything.
    private static let supported: [String: Set<String>] = [
        "b": [], "strong": [], "i": [], "em": [], "u": [], "s": [], "strike": [], "del": [], "code": [],
        "mark": ["data-color", "style"], "a": ["href", "target", "rel"], "span": ["style"], "br": [],
        "sub": [], "sup": [], "p": [],
    ]

    /// Whether this inline HTML can be edited here and written back without losing anything.
    static func isEditable(_ html: String) -> Bool {
        for token in RichHTMLParser.tokenize(html) {
            guard case .open(let name, let attributes, _) = token else { continue }
            guard let allowed = supported[name], Set(attributes.keys).isSubset(of: allowed) else { return false }
            if attributes["style"] != nil {
                let css = Set(RichHTMLParser.style(attributes).keys)
                let ok: Set<String> = name == "mark" ? ["background-color", "color"] : ["color"]
                if !css.isSubset(of: ok) { return false }
            }
        }
        return true
    }

    // MARK: HTML → attributed

    static func attributed(_ html: String, font: UIFont = .preferredFont(forTextStyle: .body)) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var stack: [(name: String, attributes: [NSAttributedString.Key: Any])] = [("", [:])]
        var paragraphs = 0
        for token in RichHTMLParser.tokenize(html) {
            switch token {
            case .text(let raw):
                var text = raw.replacingOccurrences(of: #"[ \t\n\r\f]+"#, with: " ", options: .regularExpression)
                if out.length == 0 || out.string.hasSuffix("\n") { text = String(text.drop { $0 == " " }) }
                guard !text.isEmpty else { continue }
                out.append(NSAttributedString(string: text, attributes: stack.last?.attributes ?? [:]))
            case .open(let name, let attributes, let selfClosing):
                if name == "br" { out.append(NSAttributedString(string: "\n", attributes: stack.last?.attributes ?? [:])); continue }
                if name == "p" {
                    if paragraphs > 0 { out.append(NSAttributedString(string: "\n")) }
                    paragraphs += 1
                    continue
                }
                if selfClosing { continue }
                var current = stack.last?.attributes ?? [:]
                let css = RichHTMLParser.style(attributes)
                switch name {
                case "b", "strong": current[.cmsBold] = true
                case "i", "em": current[.cmsItalic] = true
                case "u": current[.cmsUnderline] = true
                case "s", "strike", "del": current[.cmsStrike] = true
                case "code": current[.cmsCode] = true
                case "sub": current[.cmsSub] = true
                case "sup": current[.cmsSup] = true
                case "mark": current[.cmsHighlight] = attributes["data-color"] ?? css["background-color"] ?? ""
                case "a": current[.cmsLink] = attributes["href"] ?? ""
                case "span", "font":
                    if let color = css["color"] ?? attributes["color"], let hex = hex(fromCSS: color) { current[.cmsColor] = hex }
                default: break
                }
                stack.append((name, current))
            case .close(let name):
                if name == "p" { continue }
                if let index = stack.lastIndex(where: { $0.name == name }), index > 0 { stack.removeSubrange(index...) }
            }
        }
        restyle(out, font: font)
        return out
    }

    // MARK: Attributed → HTML

    static func html(_ text: NSAttributedString) -> String {
        var out = ""
        // Tags open now, outermost first: a run only closes and opens what differs from the one before,
        // so "<strong>bold <em>both</em></strong>" stays one <strong>.
        var open: [(name: String, attributes: String)] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let wanted = wraps(attributes)
            var shared = 0
            while shared < open.count, shared < wanted.count, open[shared] == wanted[shared] { shared += 1 }
            for tag in open[shared...].reversed() { out += "</\(tag.name)>" }
            for tag in wanted[shared...] { out += "<\(tag.name)\(tag.attributes)>" }
            open = wanted
            let piece = (text.string as NSString).substring(with: range)
            out += piece.components(separatedBy: "\n").map { escape($0, quotes: false) }.joined(separator: "<br>")
        }
        for tag in open.reversed() { out += "</\(tag.name)>" }
        return out
    }

    /// The tags a run of text is wrapped in, outermost first (the order TipTap nests them).
    private static func wraps(_ attributes: [NSAttributedString.Key: Any]) -> [(name: String, attributes: String)] {
        var tags: [(String, String)] = []
        if let link = attributes[.cmsLink] as? String, !link.isEmpty {
            tags.append(("a", " target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"\(escape(link, quotes: true))\""))
        }
        if attributes[.cmsBold] != nil { tags.append(("strong", "")) }
        if attributes[.cmsItalic] != nil { tags.append(("em", "")) }
        if attributes[.cmsUnderline] != nil { tags.append(("u", "")) }
        if attributes[.cmsStrike] != nil { tags.append(("s", "")) }
        if attributes[.cmsCode] != nil { tags.append(("code", "")) }
        if let mark = attributes[.cmsHighlight] as? String {
            let value = escape(mark, quotes: true)
            tags.append(("mark", mark.isEmpty ? "" : " data-color=\"\(value)\" style=\"background-color: \(value)\""))
        }
        if let color = attributes[.cmsColor] as? String, !color.isEmpty {
            tags.append(("span", " style=\"color: \(escape(color, quotes: true))\""))
        }
        if attributes[.cmsSub] != nil { tags.append(("sub", "")) }
        if attributes[.cmsSup] != nil { tags.append(("sup", "")) }
        return tags.map { (name: $0.0, attributes: $0.1) }
    }

    static func escape(_ text: String, quotes: Bool) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
        if quotes { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }

    // MARK: Looks (rebuilt from meaning)

    static func restyle(_ text: NSMutableAttributedString, font base: UIFont = .preferredFont(forTextStyle: .body),
                        range: NSRange? = nil) {
        let whole = range ?? NSRange(location: 0, length: text.length)
        guard whole.length > 0 else { return }
        text.enumerateAttributes(in: whole) { attributes, run, _ in
            var looks: [NSAttributedString.Key: Any] = [:]
            var font = base
            if attributes[.cmsCode] != nil {
                font = UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
            }
            var traits: UIFontDescriptor.SymbolicTraits = []
            if attributes[.cmsBold] != nil { traits.insert(.traitBold) }
            if attributes[.cmsItalic] != nil { traits.insert(.traitItalic) }
            if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            if attributes[.cmsSub] != nil || attributes[.cmsSup] != nil {
                font = font.withSize(font.pointSize * 0.75)
                looks[.baselineOffset] = attributes[.cmsSup] != nil ? base.pointSize * 0.35 : -base.pointSize * 0.15
            } else {
                looks[.baselineOffset] = 0
            }
            looks[.font] = font
            looks[.underlineStyle] = (attributes[.cmsUnderline] != nil || attributes[.cmsLink] != nil)
                ? NSUnderlineStyle.single.rawValue : 0
            looks[.strikethroughStyle] = attributes[.cmsStrike] != nil ? NSUnderlineStyle.single.rawValue : 0
            if let link = attributes[.cmsLink] as? String, !link.isEmpty {
                looks[.foregroundColor] = UIColor.link
            } else if let hex = attributes[.cmsColor] as? String, let color = uiColor(hex) {
                looks[.foregroundColor] = color
            } else {
                looks[.foregroundColor] = UIColor.label
            }
            if let mark = attributes[.cmsHighlight] as? String {
                looks[.backgroundColor] = uiColor(mark)?.withAlphaComponent(0.45) ?? UIColor.systemYellow.withAlphaComponent(0.45)
            } else if attributes[.cmsCode] != nil {
                looks[.backgroundColor] = UIColor.secondarySystemFill
            } else {
                looks[.backgroundColor] = UIColor.clear
            }
            text.addAttributes(looks, range: run)
        }
    }

    // MARK: Colours

    /// `#e11d48`, `rgb(…)`, `red` → `#e11d48` (nil when it isn't a colour).
    static func hex(fromCSS css: String) -> String? {
        guard let color = RichColor(css: css) else { return nil }
        return String(format: "#%02x%02x%02x", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()),
                      Int((color.blue * 255).rounded()))
    }

    /// A colour as `#rrggbb`.
    static func hex(_ colour: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }

    static func uiColor(_ css: String) -> UIColor? {
        guard let color = RichColor(css: css) else { return nil }
        return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Colours offered for text and highlights (the web editor's palette), with plain names.
    static let palette: [(name: String, hex: String)] = [
        ("Black", "#111827"), ("Red", "#e11d48"), ("Blue", "#2563eb"), ("Green", "#16a34a"), ("Orange", "#ea580c"),
        ("Purple", "#7c3aed"), ("Teal", "#0891b2"), ("Gold", "#ca8a04"),
    ]
}

/// Changes the formatting of what is selected in a `CMSTextView` (or of what is typed next).
@MainActor
final class CMSTextController {
    weak var textView: UITextView?
    var onChange: (() -> Void)?
    /// The block's own font (a heading is larger): formatting is drawn on top of it.
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)

    var hasSelection: Bool { (textView?.selectedRange.length ?? 0) > 0 }

    func toggle(_ key: NSAttributedString.Key, value: Any = true) {
        guard let view = textView else { return }
        let range = view.selectedRange
        if range.length == 0 {
            var typing = view.typingAttributes
            if typing[key] != nil { typing.removeValue(forKey: key) } else { typing[key] = value }
            view.typingAttributes = restyled(typing)
            return
        }
        let storage = view.textStorage
        var everywhere = true
        storage.enumerateAttribute(key, in: range) { existing, _, stop in
            if existing == nil { everywhere = false; stop.pointee = true }
        }
        if everywhere { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: value, range: range) }
        // Sub- and superscript can't both apply.
        if key == .cmsSub, !everywhere { storage.removeAttribute(.cmsSup, range: range) }
        if key == .cmsSup, !everywhere { storage.removeAttribute(.cmsSub, range: range) }
        finish(range)
    }

    func set(_ key: NSAttributedString.Key, to value: String?) {
        guard let view = textView else { return }
        let range = view.selectedRange
        if range.length == 0 {
            var typing = view.typingAttributes
            typing[key] = value
            view.typingAttributes = restyled(typing)
            return
        }
        if let value { view.textStorage.addAttribute(key, value: value, range: range) } else {
            view.textStorage.removeAttribute(key, range: range)
        }
        finish(range)
    }

    /// The link on the selection (or at the cursor), to show when changing it.
    var currentLink: String? {
        guard let view = textView, view.textStorage.length > 0 else { return nil }
        let location = min(view.selectedRange.location, view.textStorage.length - 1)
        return view.textStorage.attribute(.cmsLink, at: max(0, location), effectiveRange: nil) as? String
    }

    /// Removes every kind of formatting from the selection.
    func clearFormatting() {
        guard let view = textView else { return }
        let range = view.selectedRange
        guard range.length > 0 else {
            view.typingAttributes = restyled([:])
            return
        }
        for key in CMSInline.semanticKeys { view.textStorage.removeAttribute(key, range: range) }
        finish(range)
    }

    /// Types text at the cursor (a personal detail, a symbol).
    func insert(_ text: String) {
        guard let view = textView else { return }
        view.insertText(text)
    }

    private func restyled(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let sample = NSMutableAttributedString(string: " ", attributes: attributes)
        CMSInline.restyle(sample, font: baseFont)
        return sample.attributes(at: 0, effectiveRange: nil)
    }

    private func finish(_ range: NSRange) {
        guard let view = textView else { return }
        CMSInline.restyle(view.textStorage, font: baseFont, range: range)
        view.selectedRange = range
        onChange?()
    }
}

/// A native rich text field (UITextView) bound to an attributed string.
struct CMSTextView: UIViewRepresentable {
    @Binding var text: NSAttributedString
    let controller: CMSTextController
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var accessibilityLabel: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.attributedText = text
        view.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = "cms.richText"
        controller.textView = view
        controller.baseFont = font
        controller.onChange = { [weak view] in
            guard let view else { return }
            context.coordinator.push(view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        controller.textView = view
        if controller.baseFont != font {
            // The block became a heading (or back): redraw the words at the new size.
            controller.baseFont = font
            let restyled = NSMutableAttributedString(attributedString: text)
            CMSInline.restyle(restyled, font: font)
            view.attributedText = restyled
            view.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
            context.coordinator.push(view)
            return
        }
        if !view.attributedText.isEqual(to: text) {
            let selection = view.selectedRange
            view.attributedText = text
            if NSMaxRange(selection) <= view.textStorage.length { view.selectedRange = selection }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(size.height, 88))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<NSAttributedString>

        init(text: Binding<NSAttributedString>) {
            self.text = text
        }

        @MainActor
        func push(_ view: UITextView) {
            text.wrappedValue = NSAttributedString(attributedString: view.attributedText)
        }

        func textViewDidChange(_ textView: UITextView) {
            MainActor.assumeIsolated { push(textView) }
        }
    }
}

/// The formatting buttons for a `CMSTextView`.
struct CMSFormatBar: View {
    let controller: CMSTextController
    var allowsLinks = true
    @State private var askingLink = false
    @State private var link = "https://"
    @State private var problem: String?
    @State private var custom = Color.red

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                button("Bold", "bold") { controller.toggle(.cmsBold) }
                button("Italic", "italic") { controller.toggle(.cmsItalic) }
                button("Underline", "underline") { controller.toggle(.cmsUnderline) }
                button("Strikethrough", "strikethrough") { controller.toggle(.cmsStrike) }
                button("Code", "chevron.left.forwardslash.chevron.right") { controller.toggle(.cmsCode) }
                Menu {
                    Button("Yellow highlight") { controller.set(.cmsHighlight, to: "") }
                    ForEach(CMSInline.palette, id: \.hex) { colour in
                        Button("\(colour.name) highlight") { controller.set(.cmsHighlight, to: colour.hex) }
                    }
                    Button("No highlight", role: .destructive) { controller.set(.cmsHighlight, to: nil) }
                } label: { icon("highlighter") }
                    .accessibilityLabel("Highlight")
                    .accessibilityIdentifier("cms.format.highlight")
                Menu {
                    ForEach(CMSInline.palette, id: \.hex) { colour in
                        Button(colour.name) { controller.set(.cmsColor, to: colour.hex) }
                    }
                    Button("Normal colour", role: .destructive) { controller.set(.cmsColor, to: nil) }
                } label: { icon("paintpalette") }
                    .accessibilityLabel("Text colour")
                    .accessibilityIdentifier("cms.format.colour")
                ColorPicker("Any colour", selection: Binding(get: { custom }, set: { colour in
                    custom = colour
                    controller.set(.cmsColor, to: CMSInline.hex(UIColor(colour)))
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40, height: 40)
                .accessibilityLabel("Any text colour")
                .accessibilityIdentifier("cms.format.anyColour")
                if allowsLinks {
                    button("Link", "link") {
                        link = controller.currentLink ?? "https://"
                        problem = nil
                        askingLink = true
                    }
                    button("Remove link", "link.badge.plus") { controller.set(.cmsLink, to: nil) }
                }
                button("Subscript", "textformat.subscript") { controller.toggle(.cmsSub) }
                button("Superscript", "textformat.superscript") { controller.toggle(.cmsSup) }
                button("Clear formatting", "eraser") { controller.clearFormatting() }
            }
            .padding(.vertical, 4)
        }
        .alert("Link", isPresented: $askingLink) {
            TextField("https://…", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add link") {
                let address = link.trimmingCharacters(in: .whitespaces)
                if address.isEmpty || address == "https://" { controller.set(.cmsLink, to: nil) } else {
                    controller.set(.cmsLink, to: address)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(controller.hasSelection ? "Where should the selected words go? Leave it empty to remove the link."
                                         : "Select some words first, then add the link.")
        }
    }

    private func button(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol) }
            .accessibilityLabel(label)
            .accessibilityIdentifier("cms.format.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: 40, height: 40)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
