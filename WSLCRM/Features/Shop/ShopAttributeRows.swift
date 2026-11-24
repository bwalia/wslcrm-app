import SwiftUI

/// A product's attributes (`attributes`, a JSON object the pricing rules and the assistant read) as
/// "name / value" rows. Numbers and yes/no stay numbers and booleans. Anything nested (a list, an
/// object) can't be shown as rows, so it is edited as text instead.
struct ShopAttributeRow: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var value: String

    static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.value == b.value }

    /// The rows of an attributes text, or nil when it holds something rows can't show.
    static func rows(_ json: String) -> [ShopAttributeRow]? {
        guard case let (value?, nil) = ShopJSON.object(json), case .object(let o) = value else { return nil }
        var rows: [ShopAttributeRow] = []
        for key in o.keys.sorted() {
            switch o[key] {
            case .string(let s)?: rows.append(ShopAttributeRow(name: key, value: s))
            case .number?, .bool?: rows.append(ShopAttributeRow(name: key, value: o[key]?.stringValue ?? ""))
            case .null?: rows.append(ShopAttributeRow(name: key, value: ""))
            default: return nil
            }
        }
        return rows
    }

    /// Rows back to the JSON text the product saves ("4" → 4, "yes"/"true" → true; blank names are left out).
    static func json(_ rows: [ShopAttributeRow]) -> String {
        var o: [String: JSONValue] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let text = row.value.trimmingCharacters(in: .whitespaces)
            switch text.lowercased() {
            case "true", "yes": o[name] = .bool(true)
            case "false", "no": o[name] = .bool(false)
            default:
                if let number = Double(text), text.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil {
                    o[name] = .number(number)
                } else {
                    o[name] = .string(text)
                }
            }
        }
        return ShopJSON.pretty(.object(o))
    }
}

struct ShopAttributesSection: View {
    @Binding var json: String
    @State private var rows: [ShopAttributeRow] = []
    @State private var asText = false
    @State private var loaded = false

    var body: some View {
        Section {
            if asText {
                TextEditor(text: $json).font(.wsFootnote.monospaced()).frame(minHeight: 100)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let error = ShopJSON.object(json).1 {
                    Label("The attributes \(error).", systemImage: "exclamationmark.triangle").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
                if ShopAttributeRow.rows(json) != nil {
                    Button("Edit as rows") { rows = ShopAttributeRow.rows(json) ?? []; asText = false }
                }
            } else {
                ForEach($rows) { $row in
                    HStack {
                        TextField("Name, e.g. colour", text: $row.name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Divider()
                        TextField("Value, e.g. Blue", text: $row.value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }
                Button("Add an attribute", systemImage: "plus.circle") { rows.append(ShopAttributeRow(name: "", value: "")) }
                    .accessibilityIdentifier("shopProductEditor.addAttribute")
            }
        } header: {
            // On the header (one view): on the Section these would run for every row.
            Text("Attributes")
                .onAppear {
                    guard !loaded else { return }
                    loaded = true
                    if let parsed = ShopAttributeRow.rows(json) { rows = parsed } else { asText = true }
                }
                .onChange(of: rows) { _, new in
                    if !asText { json = ShopAttributeRow.json(new) }
                }
        } footer: {
            Text(asText ? "This product's attributes hold lists or groups, so they're edited as text."
                 : "Facts the pricing rules and the shop assistant use, e.g. colour Blue or size Large. "
                     + "Rules refer to the names. Swipe a row to remove it.")
        }
    }
}
