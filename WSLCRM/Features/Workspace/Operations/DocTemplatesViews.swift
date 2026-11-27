import SwiftUI

// MARK: - Screen

/// `/dashboard/templates`: document templates (invoices, timesheets) and layouts & formats (page layouts,
/// WSL Proxy JSON formats).
struct DocTemplatesScreen: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case documents, layouts
        var id: String { rawValue }
        var title: String { self == .documents ? "Document templates" : "Layouts & formats" }
    }

    @State private var tab = Tab.documents

    var body: some View {
        Group {
            switch tab {
            case .documents: DocumentTemplatesLibrary()
            case .layouts: RenderTemplatesList()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SectionTabs(tabs: Tab.allCases, selection: $tab) { $0.title }
        }
        .navigationTitle("Templates")
    }
}

// MARK: - Document templates

enum DocTemplateStyle {
    static let types: [Choice] = [Choice("invoice", "Invoice"), Choice("timesheet", "Timesheet")]
    static let pageSizes = ["A4", "Letter", "Legal"]
    static let fonts = [
        "Inter, sans-serif", "Arial, sans-serif", "Helvetica, sans-serif", "Georgia, serif",
        "'Times New Roman', serif", "'Courier New', monospace", "Roboto, sans-serif",
    ]

    static func typeLabel(_ type: String?) -> String {
        types.first { $0.value == type }?.label ?? Formatters.humanize(type)
    }

    static func fontLabel(_ font: String) -> String {
        font.split(separator: ",").first.map { $0.replacingOccurrences(of: "'", with: "") } ?? font
    }

    /// The web's ready-made blocks of template HTML.
    static let snippets: [(name: String, detail: String, html: String)] = [
        ("Table row loop", "Loop over line items in a table", """
        {% for item in items %}
        <tr>
          <td>{{item.description}}</td>
          <td>{{item.quantity}}</td>
          <td>{{item.unit_price}}</td>
          <td>{{item.total}}</td>
        </tr>
        {% endfor %}
        """),
        ("Conditional block", "Show content only when there is some", """
        {% if notes %}
        <div class="notes">
          <h4>Notes</h4>
          <p>{{notes}}</p>
        </div>
        {% endif %}
        """),
        ("Company header", "Your company’s name, address and the invoice number", """
        <div class="header" style="display:flex;justify-content:space-between;align-items:center;margin-bottom:30px;">
          <div>
            <h1 style="margin:0;font-size:24px;color:{{theme.primary_color}};">{{company.name}}</h1>
            <p style="margin:4px 0 0;color:#666;">{{company.address}}</p>
            <p style="margin:2px 0 0;color:#666;">{{company.email}} | {{company.phone}}</p>
          </div>
          <div style="text-align:right;">
            <h2 style="margin:0;font-size:28px;color:{{theme.primary_color}};">INVOICE</h2>
            <p style="margin:4px 0 0;">#{{invoice.number}}</p>
            <p style="margin:2px 0 0;">Date: {{invoice.date}}</p>
          </div>
        </div>
        """),
        ("Line items table", "A full table of line items with a header", """
        <table style="width:100%;border-collapse:collapse;margin:20px 0;">
          <thead>
            <tr style="background:{{theme.primary_color}};color:#fff;">
              <th style="padding:10px;text-align:left;">Description</th>
              <th style="padding:10px;text-align:right;width:80px;">Qty</th>
              <th style="padding:10px;text-align:right;width:100px;">Rate</th>
              <th style="padding:10px;text-align:right;width:100px;">Amount</th>
            </tr>
          </thead>
          <tbody>
            {% for item in items %}
            <tr style="border-bottom:1px solid #eee;">
              <td style="padding:10px;">{{item.description}}</td>
              <td style="padding:10px;text-align:right;">{{item.quantity}}</td>
              <td style="padding:10px;text-align:right;">{{item.unit_price}}</td>
              <td style="padding:10px;text-align:right;">{{item.total}}</td>
            </tr>
            {% endfor %}
          </tbody>
        </table>
        """),
        ("Totals section", "Subtotal, tax and total", """
        <div style="display:flex;justify-content:flex-end;margin-top:20px;">
          <table style="width:250px;">
            <tr>
              <td style="padding:6px 10px;color:#666;">Subtotal:</td>
              <td style="padding:6px 10px;text-align:right;">{{invoice.subtotal}}</td>
            </tr>
            <tr>
              <td style="padding:6px 10px;color:#666;">Tax:</td>
              <td style="padding:6px 10px;text-align:right;">{{invoice.tax_total}}</td>
            </tr>
            <tr style="border-top:2px solid {{theme.primary_color}};font-weight:bold;font-size:1.1em;">
              <td style="padding:10px;">Total:</td>
              <td style="padding:10px;text-align:right;color:{{theme.primary_color}};">{{invoice.total}}</td>
            </tr>
          </table>
        </div>
        """),
    ]

    /// What each common variable means, for the variables list.
    static let variableHelp: [String: String] = [
        "company.name": "Your company’s name", "company.address": "Your company’s address",
        "company.email": "Your company’s email", "company.phone": "Your company’s phone",
        "invoice.number": "Invoice number", "invoice.date": "Issue date", "invoice.due_date": "Due date",
        "invoice.subtotal": "Subtotal", "invoice.tax_total": "Tax", "invoice.total": "Total",
        "invoice.notes": "Notes on the invoice", "client.name": "Customer’s name", "client.email": "Customer’s email",
        "client.address": "Customer’s address", "timesheet.period_start": "First day of the period",
        "timesheet.period_end": "Last day of the period", "timesheet.total_hours": "Total hours",
        "timesheet.total_amount": "Total amount", "employee.name": "Employee’s name", "employee.email": "Employee’s email",
        "employee.role": "Employee’s role", "theme.primary_color": "Main colour", "theme.secondary_color": "Second colour",
        "theme.font_family": "Font",
    ]

    /// Example values so a preview shows real-looking words instead of blanks.
    static func sampleData(theme: [String: JSONValue]) -> JSONValue {
        let item1: JSONValue = .object(["description": .string("Website design"), "quantity": .string("1"),
                                        "unit_price": .string("£1,000.00"), "total": .string("£1,000.00")])
        let item2: JSONValue = .object(["description": .string("Hosting (12 months)"), "quantity": .string("12"),
                                        "unit_price": .string("£10.00"), "total": .string("£120.00")])
        return .object([
            "title": .string("Example document"),
            "company": .object(["name": .string("Acme Ltd"), "address": .string("1 High Street, London"),
                                "email": .string("hello@acme.example"), "phone": .string("020 7946 0000")]),
            "invoice": .object(["number": .string("INV-001"), "date": .string("15 Jan 2026"),
                                "due_date": .string("15 Feb 2026"), "subtotal": .string("£1,120.00"),
                                "tax_total": .string("£224.00"), "total": .string("£1,344.00"),
                                "notes": .string("Thank you for your business."),
                                "items": .array([item1, item2])]),
            "client": .object(["name": .string("Jane Customer"), "email": .string("jane@example.com"),
                               "address": .string("2 Market Square, Leeds")]),
            "timesheet": .object(["period_start": .string("1 Jan 2026"), "period_end": .string("15 Jan 2026"),
                                  "total_hours": .string("80.00"), "total_amount": .string("£4,000.00")]),
            "employee": .object(["name": .string("Sam Smith"), "email": .string("sam@acme.example"),
                                 "role": .string("Engineer")]),
            "items": .array([item1, item2]),
            "notes": .string("Thank you for your business."),
            "theme": .object(theme),
        ])
    }
}

private struct DocTemplateRoute: Hashable, Identifiable {
    let uuid: String
    var id: String { uuid }
}

/// Copies a template under a new name.
private struct DocTemplateCloneView: View {
    let template: Record
    let onCopied: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var feedback: Feedback = .none
    @State private var saving = false

    init(template: Record, onCopied: @escaping (String) -> Void) {
        self.template = template
        self.onCopied = onCopied
        _name = State(initialValue: "\(template.string("name") ?? "Template") (Copy)")
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("templates.clone.name")
            } header: {
                Text("Name of the copy")
            } footer: {
                Text("The copy starts at version 1 and isn’t the default.")
            }
        }
        .navigationTitle("Copy template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Copy") { Task { await copy() } }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("templates.clone.save")
            }
        }
    }

    private func copy() async {
        saving = true
        defer { saving = false }
        var uuid: String?
        if await perform($feedback, done: "Copied.", {
            let json = try await services.workspace().send(.post, "/api/v2/templates/\(template.id)/clone",
                                                           body: .object(["name": .string(name.trimmingCharacters(in: .whitespaces))]))
            uuid = WorkspaceAPI.record(json)?.string("uuid")
        }), let uuid {
            onCopied(uuid)
            dismiss()
        }
    }
}

// MARK: - Editor

/// What the template editor holds, and the body it saves (kept apart so it can be tested).
struct DocTemplateDraft: Equatable {
    var name = ""
    var description = ""
    var html = ""
    var css = ""
    var pageSize = "A4"
    var orientation = "portrait"
    var marginTop = "20mm"
    var marginBottom = "20mm"
    var marginLeft = "15mm"
    var marginRight = "15mm"
    var primaryColor = "#2563eb"
    var secondaryColor = "#64748b"
    var fontFamily = "Inter, sans-serif"
    var footerText = ""
    var advanced = "{}"
    /// Not edited here (a designer template's page footer); kept so the server preview prints it.
    var footerHTML: String?
    var headerHTML: String?

    init() {}

    init(_ template: Record) {
        name = template.string("name") ?? ""
        description = template.string("description") ?? ""
        html = template.string("template_html") ?? ""
        css = template.string("template_css") ?? ""
        pageSize = template.string("page_size") ?? "A4"
        orientation = template.string("page_orientation") ?? "portrait"
        marginTop = template.string("margin_top") ?? "20mm"
        marginBottom = template.string("margin_bottom") ?? "20mm"
        marginLeft = template.string("margin_left") ?? "15mm"
        marginRight = template.string("margin_right") ?? "15mm"
        let config = template.objectMap("config")
        primaryColor = config["primary_color"]?.stringValue ?? "#2563eb"
        secondaryColor = config["secondary_color"]?.stringValue ?? "#64748b"
        fontFamily = config["font_family"]?.stringValue ?? "Inter, sans-serif"
        footerText = config["footer_text"]?.stringValue ?? ""
        advanced = Self.pretty(.object(config))
        footerHTML = template.string("footer_html")
        headerHTML = template.string("header_html")
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    var theme: [String: JSONValue] {
        ["primary_color": .string(primaryColor), "secondary_color": .string(secondaryColor),
         "font_family": .string(fontFamily), "footer_text": .string(footerText)]
    }

    /// The whole `config` (it replaces the stored one): the advanced JSON with the theme fields on top.
    /// nil when the advanced JSON isn't a JSON object.
    func config() -> [String: JSONValue]? {
        let text = advanced.trimmingCharacters(in: .whitespacesAndNewlines)
        var base: [String: JSONValue] = [:]
        if !text.isEmpty {
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            switch decoded {
            case .object(let fields): base = fields
            case .array(let items) where items.isEmpty: base = [:]
            default: return nil
            }
        }
        return base.merging(theme) { _, themed in themed }
    }

    func body() -> JSONValue? {
        guard let config = config() else { return nil }
        return .object([
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "description": .string(description),
            "template_html": .string(html),
            "template_css": .string(css),
            "page_size": .string(pageSize),
            "page_orientation": .string(orientation),
            "margin_top": .string(marginTop),
            "margin_bottom": .string(marginBottom),
            "margin_left": .string(marginLeft),
            "margin_right": .string(marginRight),
            "config": .object(config),
        ])
    }

    /// What `POST /api/v2/templates/preview-pdf` prints for this draft.
    func pdfSource(_ kind: TemplateKind) -> TemplatePDFSource {
        TemplatePDFSource(kind: kind, html: html, css: css, footerHTML: footerHTML, headerHTML: headerHTML, pageSize: pageSize,
                          orientation: orientation, margins: [marginTop, marginBottom, marginLeft, marginRight])
    }

    /// The body for `POST /api/v2/templates/preview-raw`.
    func previewBody() -> JSONValue {
        .object(["template_html": .string(html), "template_css": .string(css),
                 "data": DocTemplateStyle.sampleData(theme: theme)])
    }
}

/// The template builder: HTML and CSS, variables, snippets, page setup, theme, preview, PDF, versions.
struct DocTemplateEditorView: View {
    let uuid: String
    let onChange: () -> Void
    @Environment(\.services) private var services
    @State private var template: Record?
    @State private var loadError: APIError?
    @State private var draft = DocTemplateDraft()
    @State private var saved = DocTemplateDraft()
    @State private var variables: [String] = []
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var choosingVariable = false
    @State private var showingVersions = false
    @State private var cloning = false
    @State private var previewing = false
    @State private var openedCopy: DocTemplateRoute?

    private var dirty: Bool { template != nil && draft != saved }
    private var type: String { template?.string("type") ?? "invoice" }

    var body: some View {
        Form {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            if let template {
                Section {
                    LabeledContent("Name") {
                        TextField("Template name", text: $draft.name).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("templates.editor.name")
                    }
                    TextField("Description (optional)", text: $draft.description, axis: .vertical).lineLimit(1...4)
                    LabeledContent("Type", value: DocTemplateStyle.typeLabel(template.string("type")))
                    LabeledContent("Version", value: "v\(template.int("version") ?? 1)")
                    HStack(spacing: 8) {
                        StatusBadge(text: template.bool("is_active") == false ? "Not in use" : "In use",
                                    systemImage: template.bool("is_active") == false ? "pause.circle" : "checkmark.circle",
                                    tone: template.bool("is_active") == false ? .neutral : .success)
                        if template.bool("is_default") == true {
                            StatusBadge(text: "Default", systemImage: "star.fill", tone: .brand)
                        }
                        Spacer()
                        Text(dirty ? "Unsaved changes" : "Saved").font(.wsCaption)
                            .foregroundStyle(dirty ? Tone.warning.textColor : Color.secondaryText)
                            .accessibilityIdentifier("templates.editor.state")
                    }
                }
                FeedbackSection(feedback: feedback)
                Section {
                    TextEditor(text: $draft.html)
                        .font(.wsFootnote.monospaced())
                        .frame(minHeight: 260)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("templates.editor.html")
                    Button { choosingVariable = true } label: { Label("Add a variable", systemImage: "curlybraces") }
                    Menu {
                        ForEach(DocTemplateStyle.snippets, id: \.name) { snippet in
                            Button {
                                append(snippet.html)
                            } label: {
                                Text(snippet.name)
                                Text(snippet.detail)
                            }
                        }
                    } label: {
                        Label("Add a ready-made block", systemImage: "square.stack.3d.down.right")
                    }
                } header: {
                    Text("HTML")
                } footer: {
                    Text("Variables and blocks are added at the end. Use {{name}} for a value, {% for item in items %}…{% endfor %} to repeat and {% if notes %}…{% endif %} to show something only when it has a value.")
                }
                Section("CSS") {
                    TextEditor(text: $draft.css)
                        .font(.wsFootnote.monospaced())
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("templates.editor.css")
                }
                Section("Page") {
                    Picker("Size", selection: $draft.pageSize) {
                        ForEach(DocTemplateStyle.pageSizes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Orientation", selection: $draft.orientation) {
                        Text("Portrait").tag("portrait")
                        Text("Landscape").tag("landscape")
                    }
                    marginField("Top margin", $draft.marginTop)
                    marginField("Bottom margin", $draft.marginBottom)
                    marginField("Left margin", $draft.marginLeft)
                    marginField("Right margin", $draft.marginRight)
                }
                Section {
                    DocTemplateColorRow(label: "Main colour", hex: $draft.primaryColor)
                    DocTemplateColorRow(label: "Second colour", hex: $draft.secondaryColor)
                    Picker("Font", selection: $draft.fontFamily) {
                        ForEach(DocTemplateStyle.fonts, id: \.self) { Text(DocTemplateStyle.fontLabel($0)).tag($0) }
                        if !DocTemplateStyle.fonts.contains(draft.fontFamily) {
                            Text(draft.fontFamily).tag(draft.fontFamily)
                        }
                    }
                    TextField("Footer text (optional)", text: $draft.footerText, axis: .vertical).lineLimit(1...3)
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Use them in the HTML as {{theme.primary_color}}, {{theme.secondary_color}} and {{theme.font_family}}.")
                }
                Section {
                    TextEditor(text: $draft.advanced)
                        .font(.wsFootnote.monospaced())
                        .frame(minHeight: 100)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("templates.editor.config")
                } header: {
                    Text("Advanced settings (JSON)")
                } footer: {
                    Text(draft.config() == nil ? "This isn’t valid JSON yet — fix it before saving."
                         : "Saved as the template’s config. The theme above replaces the same keys here.")
                }
                Section {
                    NavigationLink {
                        DocTemplatePreviewView(draft: draft, type: type)
                    } label: {
                        Label("Preview with example data", systemImage: "eye")
                    }
                    .accessibilityIdentifier("templates.editor.preview")
                    Button {
                        Task { await save() }
                    } label: {
                        Label(saving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(saving || !dirty)
                    if template.bool("is_default") != true {
                        Button { Task { await makeDefault() } } label: {
                            Label("Make it the default \(DocTemplateStyle.typeLabel(type).lowercased()) template", systemImage: "star")
                        }
                    }
                    Button { cloning = true } label: { Label("Make a copy", systemImage: "plus.square.on.square") }
                    Button { showingVersions = true } label: {
                        Label("Earlier versions", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("templates.editor.versions")
                } footer: {
                    Text("Each save keeps the previous version, so you can go back to it.")
                }
            } else if loadError == nil {
                Section { SkeletonRow(); SkeletonRow() }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "Template" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || !dirty)
                    .accessibilityIdentifier("templates.editor.save")
            }
        }
        .sheet(isPresented: $choosingVariable) {
            NavigationStack {
                DocTemplateVariablesView(variables: variables) { path in append("{{\(path)}}") }
            }
        }
        .sheet(isPresented: $showingVersions) {
            NavigationStack {
                DocTemplateVersionsView(uuid: uuid, current: template?.int("version") ?? 1) { message in
                    feedback = .done(message)
                    Task { await load() }
                    onChange()
                }
            }
        }
        .sheet(isPresented: $cloning) {
            if let template {
                NavigationStack {
                    DocTemplateCloneView(template: template) { copy in
                        feedback = .done("Copied. You’re now editing the copy.")
                        onChange()
                        openedCopy = DocTemplateRoute(uuid: copy)
                    }
                }
            }
        }
        .navigationDestination(item: $openedCopy) { route in
            DocTemplateEditorView(uuid: route.uuid, onChange: onChange)
        }
    }

    private func marginField(_ label: String, _ value: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("20mm", text: value).multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    private func append(_ text: String) {
        if draft.html.isEmpty || draft.html.hasSuffix("\n") { draft.html += text } else { draft.html += "\n" + text }
        feedback = .done("Added at the end of the HTML.")
    }

    private func load() async {
        let api = services.workspace()
        do {
            let json = try await api.get("/api/v2/templates/\(uuid)")
            guard let record = WorkspaceAPI.record(json) else { return }
            template = record
            let fresh = DocTemplateDraft(record)
            draft = fresh
            saved = fresh
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if variables.isEmpty, let type = template?.string("type"),
           let json = try? await api.get("/api/v2/templates/variables/\(type)") {
            variables = WorkspaceAPI.record(json)?.array("variables").compactMap(\.stringValue) ?? []
        }
        if variables.isEmpty { variables = DocTemplateStyle.variableHelp.keys.sorted() }
    }

    private func save() async {
        guard let body = draft.body() else {
            feedback = .failed(ResourceService.problem(422, "The advanced settings aren’t valid JSON. Fix them, then save."))
            return
        }
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            feedback = .failed(ResourceService.problem(422, "Give the template a name."))
            return
        }
        saving = true
        defer { saving = false }
        var version: Int?
        if await perform($feedback, done: "Saved.", {
            let json = try await services.workspace().send(.put, "/api/v2/templates/\(uuid)", body: body)
            if let record = WorkspaceAPI.record(json) {
                template = record
                version = record.int("version")
            }
            saved = draft
        }) {
            if let version { feedback = .done("Saved as version \(version). The previous version is kept.") }
            onChange()
        }
    }

    private func makeDefault() async {
        if await perform($feedback, done: "This is now the default \(DocTemplateStyle.typeLabel(type).lowercased()) template.", {
            try await services.workspace().send(.post, "/api/v2/templates/\(uuid)/set-default", body: .object([:]))
        }) {
            let unsaved = dirty ? draft : nil
            await load()
            if let unsaved { draft = unsaved }
            onChange()
        }
    }
}

/// A colour as a hex string (`#2563eb`), picked with the system colour picker or typed.
private struct DocTemplateColorRow: View {
    let label: String
    @Binding var hex: String

    var body: some View {
        HStack {
            ColorPicker(label, selection: Binding(
                get: { DocTemplateColor.color(hex) },
                set: { hex = DocTemplateColor.hex($0) }), supportsOpacity: false)
            TextField("#2563eb", text: $hex)
                .font(.wsFootnote.monospaced())
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

enum DocTemplateColor {
    static func color(_ hex: String) -> Color {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return .gray }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func part(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", part(red), part(green), part(blue))
    }
}

/// The variables a template can use, grouped by what they belong to. Tapping one adds it to the HTML.
private struct DocTemplateVariablesView: View {
    let variables: [String]
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(String, [String])] {
        let shown = variables.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for path in shown {
            let prefix = path.split(separator: ".").first.map(String.init) ?? "Other"
            let group = Formatters.humanize(prefix.replacingOccurrences(of: "[]", with: ""))
            if grouped[group] == nil { order.append(group) }
            grouped[group, default: []].append(path)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(groups, id: \.0) { group, paths in
                Section(group) {
                    ForEach(paths, id: \.self) { path in
                        Button {
                            choose(path)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("{{\(path)}}").font(.wsBody.monospaced()).foregroundStyle(.primary)
                                if let help = DocTemplateStyle.variableHelp[path] {
                                    Text(help).font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                            }
                        }
                        .accessibilityIdentifier("templates.variable.\(path)")
                    }
                }
            }
        }
        .navigationTitle("Variables")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a variable")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
    }
}

/// Earlier versions of a template, each with Restore (for people who may change templates).
struct DocTemplateVersionsView: View {
    let uuid: String
    let current: Int
    var canRestore = true
    let onRestored: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var versions: LoadState<[Record]> = .idle
    @State private var restoring: Record?
    @State private var feedback: Feedback = .none

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch versions {
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView("No earlier versions", systemImage: "clock.arrow.circlepath",
                                           description: Text("A version is kept each time the template is saved."))
                }
                ForEach(rows) { version in
                    let number = version.int("version") ?? 0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Version \(number)").font(.wsHeadline)
                            if number == current { Text("Now in use").font(.wsCaption).foregroundStyle(Tone.success.textColor) }
                            Spacer()
                            Text(Formatters.dateTime(version.date("created_at")) ?? "").font(.wsCaption)
                                .foregroundStyle(.secondaryText)
                        }
                        if let notes = version.string("change_notes") {
                            Text(notes).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                        if number != current && canRestore {
                            Button("Restore this version") { restoring = version }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("templates.version.restore.\(number)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                SkeletonRow()
            }
        }
        .navigationTitle("Earlier versions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .confirmationDialog("Restore this version?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            if let version = restoring {
                Button("Restore version \(version.int("version") ?? 0)") { Task { await restore(version) } }
            }
        } message: {
            Text("Its HTML, CSS and settings come back as a new version. What you have now is kept as a version too.")
        }
    }

    private func load() async {
        if versions.value == nil { versions = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/templates/\(uuid)/versions")
            versions = .loaded(WorkspaceAPI.records(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            versions = .failed(apiError)
        }
    }

    private func restore(_ version: Record) async {
        let number = version.int("version") ?? 0
        if await perform($feedback, done: "Restored.", {
            try await DocTemplatesAPI(services).restore(uuid, version: number)
        }) {
            onRestored("Version \(number) restored. It’s now the latest version.")
            dismiss()
        }
    }
}

// MARK: - Preview and PDF

/// The draft as a PDF with example figures: an invoice or order template exactly as the server prints it
/// (`preview-pdf`); a timesheet, or when there's no PDF service, laid out on the device from the server's filled-in HTML.
struct DocTemplatePreviewView: View {
    let draft: DocTemplateDraft
    var type = "invoice"
    @Environment(\.services) private var services
    @State private var pdf: Data?
    @State private var problem: String?
    @State private var note: String?
    @State private var error: APIError?
    @State private var shareURL: URL?

    var body: some View {
        Group {
            if let problem {
                ContentUnavailableView {
                    Label("This template can’t be printed yet", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await render() } }
                }
                .accessibilityIdentifier("templates.preview.problem")
            } else if let pdf {
                PDFKitView(data: pdf, accessibilityID: "templates.preview.pdf")
            } else if let error {
                List { InlineErrorRow(error: error) { Task { await render() } } }
            } else {
                ProgressView("Making the preview…")
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .task { await render() }
        .toolbar {
            if let shareURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareURL) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("templates.preview.share")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text(note ?? "Filled with example figures. Your real documents use your own details.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.bar)
        }
    }

    private func render() async {
        error = nil
        problem = nil
        let name = draft.name.isEmpty ? "template" : draft.name
        if let kind = TemplateKind(rawValue: type), kind.isDocument {
            do {
                let data = try await DocTemplatesAPI(services).previewPDF(draft.pdfSource(kind))
                pdf = data
                note = nil
                shareURL = OperationsFile.write(data, named: "\(name) preview.pdf")
                return
            } catch {
                switch TemplatePDFProblem(error) {
                case .mistake(let text, _):
                    problem = text
                    return
                case .serviceUnavailable:
                    note = "The PDF service isn’t set up here, so this page is laid out on this device and may differ a little."
                default:
                    if case .cancelled = error.asAPIError { return }
                    self.error = error.asAPIError
                    return
                }
            }
        }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/templates/preview-raw", body: draft.previewBody())
            let rendered = WorkspaceAPI.record(json)?.string("rendered_html") ?? ""
            let data = DocTemplatePDF.make(html: rendered, pageSize: draft.pageSize,
                                           landscape: draft.orientation == "landscape",
                                           margins: DocTemplatePDF.Margins(top: draft.marginTop, bottom: draft.marginBottom,
                                                                           left: draft.marginLeft, right: draft.marginRight))
            pdf = data
            shareURL = OperationsFile.write(data, named: "\(name) preview.pdf")
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }
}

/// Lays out rendered template HTML on real pages (size, orientation, margins) as a PDF, on the device.
@MainActor
enum DocTemplatePDF {
    struct Margins {
        var top: String
        var bottom: String
        var left: String
        var right: String
    }

    /// Page size in points (1/72 inch).
    static func pageSize(_ name: String, landscape: Bool) -> CGSize {
        let portrait: CGSize = switch name.lowercased() {
        case "letter": CGSize(width: 612, height: 792)
        case "legal": CGSize(width: 612, height: 1008)
        default: CGSize(width: 595.28, height: 841.89)
        }
        return landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
    }

    /// "20mm", "1in", "12pt", "16px" or a bare number (millimetres) in points.
    static func points(_ text: String) -> CGFloat {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = Double(value.filter { $0.isNumber || $0 == "." }) ?? 0
        if value.hasSuffix("in") { return CGFloat(number * 72) }
        if value.hasSuffix("pt") { return CGFloat(number) }
        if value.hasSuffix("px") { return CGFloat(number * 0.75) }
        if value.hasSuffix("cm") { return CGFloat(number * 72 / 2.54) }
        return CGFloat(number * 72 / 25.4)
    }

    static func make(html: String, pageSize name: String, landscape: Bool, margins: Margins) -> Data {
        let size = pageSize(name, landscape: landscape)
        let paper = CGRect(origin: .zero, size: size)
        let printable = paper.inset(by: UIEdgeInsets(top: points(margins.top), left: points(margins.left),
                                                     bottom: points(margins.bottom), right: points(margins.right)))
        let renderer = PageRenderer(paper: paper, printable: printable)
        renderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        let pdf = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdf, paper, nil)
        let pages = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for page in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return pdf as Data
    }

    private final class PageRenderer: UIPrintPageRenderer {
        private let paper: CGRect
        private let printable: CGRect

        init(paper: CGRect, printable: CGRect) {
            self.paper = paper
            self.printable = printable
            super.init()
        }

        override var paperRect: CGRect { paper }
        override var printableRect: CGRect { printable }
    }
}

// MARK: - Layouts & formats (render templates)

enum RenderTemplateStyle {
    static let types: [Choice] = [
        Choice("cms_page", "Page layout"), Choice("domain_wslproxy", "Domain server (WSL Proxy JSON)"),
        Choice("domain_rule", "Domain rule (WSL Proxy JSON)"),
    ]

    static let filters: [Choice] = [
        Choice("cms_page", "Page layouts"), Choice("domain_wslproxy", "Domain server (JSON)"),
        Choice("domain_rule", "Domain rule (JSON)"),
    ]

    static func label(_ type: String?) -> String {
        types.first { $0.value == type }?.label ?? Formatters.humanize(type)
    }

    /// nil when the sample data is fine (blank, or a JSON object), else what's wrong.
    static func sampleProblem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else {
            return "The sample data must be a JSON object, like {\"title\": \"Hello\"}."
        }
        return nil
    }

    static func sampleObject(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else { return .object([:]) }
        return value
    }
}

/// Named layouts and JSON formats that pages and domains are rendered with (`/api/v2/render-templates`).
struct RenderTemplatesList: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var type = ""
    @State private var search = ""
    @State private var templates: LoadState<[Record]> = .idle
    @State private var feedback: Feedback = .none
    @State private var editing: RenderTemplateEdit?
    @State private var deleting: Record?

    private var permissions: PermissionSet { session.permissions }

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $type) {
                    Text("All types").tag("")
                    ForEach(RenderTemplateStyle.filters) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("templates.layouts.type")
            } footer: {
                Text("Layouts shape CMS pages; the JSON formats shape the WSL Proxy files made for each domain. Use {{name}} placeholders.")
            }
            FeedbackSection(feedback: feedback)
            switch templates {
            case .loaded(let rows):
                Section {
                    if rows.isEmpty {
                        Text(search.isEmpty ? "No layouts or formats yet. The built-in ones are used until you add your own."
                             : "Nothing matches “\(search)”.")
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(rows) { template in
                        Button {
                            if OperationsAccess.renderTemplates(permissions, .update) {
                                editing = RenderTemplateEdit(record: template)
                            }
                        } label: {
                            RenderTemplateRow(template: template)
                        }
                        .disabled(!OperationsAccess.renderTemplates(permissions, .update))
                        .swipeActions(allowsFullSwipe: false) {
                            if OperationsAccess.renderTemplates(permissions, .delete) {
                                Button("Delete", role: .destructive) { deleting = template }
                            }
                        }
                        .accessibilityIdentifier("templates.layout.\(template.id)")
                    }
                } footer: {
                    if !rows.isEmpty, OperationsAccess.renderTemplates(permissions, .update) {
                        Text("Tap one to change it. Swipe to delete.")
                    }
                }
            case .failed(let error):
                Section {
                    InlineErrorRow(error: error) { Task { await load() } }
                } footer: {
                    if error.serverError?.status == 403 {
                        Text("Layouts & formats need the Templates permission in this workspace. Ask an administrator.")
                    }
                }
            default:
                Section { SkeletonRow(); SkeletonRow() }
            }
        }
        .searchable(text: $search, prompt: "Search name or slug")
        .wsRefreshable { await load() }
        .task(id: "\(type)|\(search)") {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            if OperationsAccess.renderTemplates(permissions, .create) {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = RenderTemplateEdit(record: nil) } label: { Label("New layout", systemImage: "plus") }
                        .accessibilityIdentifier("templates.layouts.add")
                }
            }
        }
        .sheet(item: $editing) { edit in
            NavigationStack {
                RenderTemplateEditorView(existing: edit.record, initialType: type.isEmpty ? "cms_page" : type) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete this template?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let template = deleting {
                Button("Delete \(template.string("name") ?? "template")", role: .destructive) {
                    Task { await delete(template) }
                }
            }
        } message: {
            Text("Pages and domains using it fall back to the default or the built-in layout.")
        }
    }

    private func load() async {
        if templates.value == nil { templates = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/render-templates", query: ["type": type, "search": search])
            templates = .loaded(WorkspaceAPI.records(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            templates = .failed(apiError)
        }
    }

    private func delete(_ template: Record) async {
        await perform($feedback, done: "\(template.string("name") ?? "The template") was deleted.") {
            try await services.workspace().send(.delete, "/api/v2/render-templates/\(template.string("uuid") ?? template.id)")
        }
        await load()
    }
}

private struct RenderTemplateEdit: Identifiable {
    let id = UUID()
    let record: Record?
}

private struct RenderTemplateRow: View {
    let template: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(template.string("name") ?? "Template").font(.wsHeadline).foregroundStyle(.primary)
                if template.bool("is_default") == true {
                    StatusBadge(text: "Default", systemImage: "star.fill", tone: .success)
                }
            }
            Text("\(RenderTemplateStyle.label(template.string("template_type"))) · /\(template.string("slug") ?? "")")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            if let description = template.string("description") {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
            let placeholders = template.array("placeholders").compactMap(\.stringValue)
            if !placeholders.isEmpty {
                Text(placeholders.prefix(8).map { "{{\($0)}}" }.joined(separator: " ")
                     + (placeholders.count > 8 ? " +\(placeholders.count - 8)" : ""))
                    .font(.wsCaption.monospaced()).foregroundStyle(.secondaryText).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Create or change a layout or format, with a preview of what it renders.
struct RenderTemplateEditorView: View {
    let existing: Record?
    let initialType: String
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "cms_page"
    @State private var content = ""
    @State private var sample = ""
    @State private var detail = ""
    @State private var isDefault = false
    @State private var preview: Record?
    @State private var feedback: Feedback = .none
    @State private var working = false
    @State private var prepared = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                LabeledContent("Name (needed)") {
                    TextField("e.g. Landing layout", text: $name).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("templates.layout.name")
                }
                if existing == nil {
                    Picker("Type", selection: $type) {
                        ForEach(RenderTemplateStyle.types) { Text($0.label).tag($0.value) }
                    }
                } else {
                    LabeledContent("Type", value: RenderTemplateStyle.label(type))
                    if let slug = existing?.string("slug") { LabeledContent("Slug", value: "/\(slug)") }
                }
                TextField("Description (optional)", text: $detail, axis: .vertical).lineLimit(1...3)
                Toggle("Default for its type", isOn: $isDefault)
            } footer: {
                if existing != nil { Text("The type can’t change once it’s made.") }
            }
            Section {
                TextEditor(text: $content)
                    .font(.wsFootnote.monospaced())
                    .frame(minHeight: 220)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("templates.layout.content")
                Button("Start from the example") { Task { await useExample() } }
                    .accessibilityIdentifier("templates.layout.example")
            } header: {
                Text("Template")
            } footer: {
                Text("Put {{slot}} where a value goes. Starting from the example replaces what’s here.")
            }
            Section {
                TextEditor(text: $sample)
                    .font(.wsFootnote.monospaced())
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("templates.layout.sample")
                if let problem = RenderTemplateStyle.sampleProblem(sample) {
                    Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote)
                        .foregroundStyle(Tone.danger.textColor)
                }
            } header: {
                Text("Sample data (JSON)")
            } footer: {
                Text("Used for the preview, and as a guide to what the placeholders mean.")
            }
            Section {
                Button {
                    Task { await runPreview() }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .disabled(working || RenderTemplateStyle.sampleProblem(sample) != nil)
                .accessibilityIdentifier("templates.layout.preview")
                if let preview {
                    OperationsCodeBlock(text: preview.string("rendered") ?? "")
                    let placeholders = preview.array("placeholders").compactMap(\.stringValue)
                    if !placeholders.isEmpty {
                        Text("Placeholders: " + placeholders.map { "{{\($0)}}" }.joined(separator: ", "))
                            .font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                    }
                }
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle(existing == nil ? "New layout or format" : "Edit layout or format")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || RenderTemplateStyle.sampleProblem(sample) != nil)
                    .accessibilityIdentifier("templates.layout.save")
            }
        }
        .task {
            guard !prepared else { return }
            prepared = true
            if let existing {
                name = existing.string("name") ?? ""
                type = existing.string("template_type") ?? "cms_page"
                content = existing.string("content") ?? ""
                sample = existing.string("sample_data") ?? ""
                detail = existing.string("description") ?? ""
                isDefault = existing.bool("is_default") ?? false
            } else {
                type = initialType
                await useExample()
                feedback = .none
            }
        }
    }

    private func useExample() async {
        do {
            let json = try await services.workspace().get("/api/v2/render-templates/defaults")
            let example = WorkspaceAPI.record(json)?.object(type)
            content = example?.string("content") ?? content
            sample = example?.string("sample_data") ?? (example?["sample_data"].map(DocTemplateDraft.pretty) ?? sample)
            feedback = .done("The example is in. Change it to suit you.")
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func runPreview() async {
        working = true
        defer { working = false }
        await perform($feedback, done: "Preview ready.") {
            let json = try await services.workspace().send(.post, "/api/v2/render-templates/preview", body: .object([
                "content": .string(content), "data": RenderTemplateStyle.sampleObject(sample),
            ]))
            preview = WorkspaceAPI.record(json)
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        var fields: [String: JSONValue?] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "content": .string(content),
            "sample_data": .string(sample),
            "description": .string(detail),
            "is_default": .bool(isDefault),
        ]
        if existing == nil { fields["template_type"] = .string(type) }
        let body = JSONValue.fields(fields)
        let worked = await perform($feedback, done: "Saved.") {
            if let existing {
                try await services.workspace().send(.put, "/api/v2/render-templates/\(existing.string("uuid") ?? existing.id)",
                                                    body: body)
            } else {
                try await services.workspace().send(.post, "/api/v2/render-templates", body: body)
            }
        }
        if worked {
            onSaved(existing == nil ? "\(name) was created." : "\(name) was saved.")
            dismiss()
        }
    }
}
