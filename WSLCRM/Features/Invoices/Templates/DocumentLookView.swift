import PhotosUI
import SwiftUI

/// Workspace → Invoice and order design (web `/dashboard/namespace/documents`): how invoices and order confirmations
/// look. Either the quick layout (a style, a colour, a logo, the words and which parts show, drawn by the app) or one
/// of the workspace's templates (printed by the server). Pick one, then Save.
struct DocumentLookView: View {
    var initialKind: TemplateKind?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var kind: TemplateKind = .invoice
    @State private var designs: LoadState<DocumentDesignSet> = .idle
    @State private var templates: [DocTemplate] = []
    @State private var draft: [String: JSONValue] = [:]
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var creating = false
    @State private var confirmReset = false
    @State private var confirmLeaveKind: TemplateKind?
    @State private var preview: LookPreview = .none
    @State private var fullPreview: PDFPreviewItem?
    @State private var logoItem: PhotosPickerItem?
    @State private var openedTemplate: DocTemplate?
    @State private var prepared = false

    enum LookPreview {
        case none, loading
        case ready(URL, Data)
        case failed(String)
    }

    private var api: DocTemplatesAPI { DocTemplatesAPI(services) }
    private var p: PermissionSet { session.permissions }
    private var canEdit: Bool { TemplateAccess.changeDesign(kind, p) }
    private var saved: [String: JSONValue] { designs.value?.designs[kind.rawValue] ?? [:] }
    private var dirty: Bool { Self.comparable(draft) != Self.comparable(saved) }
    private var useTemplate: Bool { draft["source"]?.stringValue == "template" }
    private var chosenTemplate: String? { useTemplate ? draft["template_uuid"]?.stringValue : nil }

    var body: some View {
        Group {
            switch designs {
            case .idle, .loading: SkeletonList(rows: 5)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let set) where set.kinds.isEmpty:
                ContentUnavailableView("Nothing to design here", systemImage: "doc.text",
                                       description: Text("Invoices and the shop aren’t switched on for this workspace."))
            case .loaded(let set): content(set)
            }
        }
        .navigationTitle("Invoice and order design")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !prepared else { return }
            prepared = true
            if let initialKind { kind = initialKind }
            await load()
        }
        .onChange(of: draftPreviewKey) { Task { await refreshPreview() } }
        .onChange(of: logoItem) { _, item in Task { await pickLogo(item) } }
        .sheet(isPresented: $creating) {
            NewTemplateSheet(kinds: designs.value?.kinds ?? [kind], initialKind: kind, workspace: session.workspace?.uuid) { made in
                Task {
                    await loadTemplates()
                    if made.kind == kind { choose(made.id) }
                    feedback = .done("“\(made.name)” is ready and picked below. Press Save to use it.")
                }
            }
        }
        .sheet(item: $fullPreview) { item in PDFPreviewSheet(item: item) }
        .navigationDestination(item: $openedTemplate) { t in
            TemplateOverviewView(uuid: t.id) { Task { await loadTemplates() } }
        }
        .confirmationDialog("Go back to the standard design?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Use the standard design", role: .destructive) { Task { await reset() } }
        } message: {
            Text("Your \(kind.label.lowercased()) logo, colours and words here will be removed.")
        }
        .confirmationDialog("Leave without saving?", isPresented: Binding(
            get: { confirmLeaveKind != nil }, set: { if !$0 { confirmLeaveKind = nil } }), titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                if let next = confirmLeaveKind { switchKind(next, force: true) }
            }
        } message: {
            Text("Your changes to the \(kind.label.lowercased()) design will be lost.")
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ set: DocumentDesignSet) -> some View {
        if MacSupport.isMac {
            HStack(spacing: 0) {
                form(set).frame(minWidth: 380, idealWidth: 460, maxWidth: 520)
                Divider()
                previewPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        } else {
            form(set).safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        }
    }

    private func form(_ set: DocumentDesignSet) -> some View {
        Form {
            if set.kinds.count > 1 {
                Section {
                    Picker("Document", selection: Binding(get: { kind }, set: { switchKind($0) })) {
                        ForEach(set.kinds) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("look.kind")
                }
            }
            if !canEdit {
                Section {
                    Label("You can look, but changing the \(kind.label.lowercased()) design needs permission to update \(kind == .order ? "the shop" : "invoices"). Ask a workspace owner.",
                          systemImage: "lock")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            FeedbackSection(feedback: feedback)
            choiceSection
            if !MacSupport.isMac {
                Section {
                    Button { Task { await openFullPreview() } } label: {
                        Label("See a preview", systemImage: "eye")
                    }
                    .accessibilityIdentifier("look.preview")
                } footer: {
                    Text(useTemplate ? "Made from your template with example figures." : "The real PDF, with example figures.")
                }
            }
            if useTemplate {
                Section {
                    Text("Your template prints your logo and colour from the quick layout below, so set them once and every \(kind == .order ? "order" : "invoice") uses them.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            lookSections
            if set.isCustom(kind) && canEdit {
                Section {
                    Button("Use the standard design", systemImage: "arrow.uturn.backward", role: .destructive) { confirmReset = true }
                        .accessibilityIdentifier("look.reset")
                }
            }
        }
        .disabled(saving)
    }

    /// 1. How they look: the quick layout or one of the templates.
    private var choiceSection: some View {
        Section {
            choiceRow(selected: !useTemplate, title: "Quick layout",
                      detail: "Choose a style, your colour, logo and words below. Nothing else to set up.",
                      icon: "paintpalette", id: "quick") { choose(nil) }
            ForEach(templates) { t in
                choiceRow(selected: chosenTemplate == t.id, title: t.name,
                          detail: t.isDesigned ? "Your drag-and-drop layout." : "Your layout from Templates.",
                          icon: "doc.richtext", id: t.id) { choose(t.id) }
                    .contextMenu {
                        Button { openedTemplate = t } label: { Label("Open the template", systemImage: "doc.text.magnifyingglass") }
                    }
            }
            if TemplateAccess.create(p) {
                Button { creating = true } label: {
                    Label("Make a new layout", systemImage: "plus.circle")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("look.newTemplate")
            }
            if TemplateAccess.read(p) {
                NavigationLink { DocumentTemplatesLibrary() } label: {
                    Label("All templates", systemImage: "square.grid.2x2")
                }
            }
        } header: {
            Text("How your \(kind.plural) look")
        } footer: {
            Text(dirty ? "Not saved yet. Press Save to use it." : "Pick one, then press Save.")
        }
    }

    private func choiceRow(selected: Bool, title: String, detail: String, icon: String, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.wsHeadline).foregroundStyle(.primary)
                    Text(detail).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondaryText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("look.choice.\(id)")
    }

    // MARK: The quick layout's settings

    @ViewBuilder
    private var lookSections: some View {
        Section(useTemplate ? "Your colour and logo" : "Look") {
            if !useTemplate {
                Picker("Style", selection: binding("style", "band")) {
                    Text("Band").tag("band")
                    Text("Clean").tag("clean")
                    Text("Minimal").tag("minimal")
                }
                .pickerStyle(.segmented)
                Text(Self.styleHint(draft["style"]?.stringValue ?? "band")).font(.wsCaption).foregroundStyle(.secondaryText)
            }
            ColorPicker("Your colour", selection: colour("accent", "#2563eb"), supportsOpacity: false)
            if !useTemplate && (draft["style"]?.stringValue ?? "band") == "band" {
                ColorPicker("Band colour", selection: colour("header", "#0f172a"), supportsOpacity: false)
            }
            if !useTemplate {
                Picker("Font", selection: binding("font", "helvetica")) {
                    Text("Sans serif").tag("helvetica")
                    Text("Serif").tag("times")
                    Text("Typewriter").tag("courier")
                }
            }
            logoRow
            if draft["logo"]?.stringValue != nil {
                Picker("Logo size", selection: binding("logo_size", "medium")) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                if !useTemplate {
                    Picker("Logo on the", selection: binding("logo_position", "left")) {
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                }
            }
        }
        .disabled(!canEdit)
        if !useTemplate {
            Section("Words") {
                LabeledContent("Heading") {
                    TextField(kind == .order ? "ORDER" : "INVOICE", text: text("title")).multilineTextAlignment(.trailing)
                }
                LabeledContent(kind == .order ? "Customer label" : "Billed-to label") {
                    TextField(kind == .order ? "CUSTOMER" : "BILLED TO", text: text("bill_to_label")).multilineTextAlignment(.trailing)
                }
            }
            .disabled(!canEdit)
            Section("What to show") {
                ForEach(Self.parts(kind), id: \.0) { key, label in
                    Toggle(label, isOn: show(key))
                }
            }
            .disabled(!canEdit)
        }
    }

    private var logoRow: some View {
        let hasLogo = draft["logo"]?.stringValue != nil
        return HStack(spacing: 12) {
            if let logo = DocumentDesign.logoData(draft["logo"]?.stringValue).flatMap(UIImage.init(data:)) {
                Image(uiImage: logo).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 40)
                    .accessibilityLabel("Your logo")
            } else {
                Text("Logo").foregroundStyle(.primary)
            }
            Spacer()
            PhotosPicker(selection: $logoItem, matching: .images) {
                Text(hasLogo ? "Change" : "Add a logo")
            }
            .accessibilityIdentifier("look.logo")
            if hasLogo {
                Button("Remove", role: .destructive) { draft["logo"] = .null }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview").font(.wsHeadline)
                Text(useTemplate ? "Made from your template with example figures" : "The real PDF, with example figures")
                    .font(.wsCaption).foregroundStyle(.secondaryText)
                Spacer()
                if case .ready(let url, _) = preview {
                    Button {
                        fullPreview = PDFPreviewItem(url: url, title: "\(kind.label) preview", subtitle: "Filled with example figures")
                    } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.bordered)
                    .help("Open the preview with Share, Print and Save")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            switch preview {
            case .ready(_, let data): PDFKitView(data: data, accessibilityID: "look.previewPDF")
            case .failed(let message):
                ContentUnavailableView {
                    Label("No preview", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await refreshPreview() } }
                }
                .frame(maxHeight: .infinity)
            case .none, .loading:
                ProgressView("Making the preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private var saveBar: some View {
        Group {
            if dirty && canEdit {
                HStack(spacing: 12) {
                    Label("Not saved yet", systemImage: "circle.fill").font(.wsSubheadline)
                        .foregroundStyle(Tone.warning.textColor).labelStyle(.titleOnly)
                    Spacer()
                    Button("Undo changes") { draft = saved }.buttonStyle(.bordered)
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Label("Save the \(kind.label.lowercased()) design", systemImage: "checkmark") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || (useTemplate && chosenTemplate == nil))
                    .accessibilityIdentifier("look.save")
                }
                .controlSize(.large)
                .padding(.horizontal, MacSupport.isMac ? 20 : 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    // MARK: Editing

    private func binding(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { draft[key]?.stringValue ?? fallback }, set: { draft[key] = .string($0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft[key]?.stringValue ?? "" }, set: { draft[key] = $0.isEmpty ? .null : .string($0) })
    }

    private func colour(_ key: String, _ fallback: String) -> Binding<Color> {
        Binding(get: { DocTemplateColor.color(draft[key]?.stringValue ?? fallback) },
                set: { draft[key] = .string(DocTemplateColor.hex($0)) })
    }

    private func show(_ part: String) -> Binding<Bool> {
        Binding(get: { draft["show"]?[part]?.boolValue ?? true }, set: { on in
            var show = draft["show"]?.objectValue ?? [:]
            show[part] = .bool(on)
            draft["show"] = .object(show)
        })
    }

    private func choose(_ template: String?) {
        draft["source"] = .string(template == nil ? "design" : "template")
        if let template { draft["template_uuid"] = .string(template) }
    }

    private func switchKind(_ next: TemplateKind, force: Bool = false) {
        guard next != kind else { return }
        if dirty && !force {
            confirmLeaveKind = next
            return
        }
        kind = next
        draft = saved
        feedback = .none
        Task { await loadTemplates() }
    }

    private func pickLogo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { logoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let url = Self.logoDataURL(image) else {
            feedback = .failed(ResourceService.problem(422, "That picture couldn’t be used. Try a PNG or JPEG under 300 KB."))
            return
        }
        draft["logo"] = .string(url)
    }

    /// A picture as the PNG data URL the server keeps (under its 400 000 characters), shrunk to at most 600 pt wide.
    static func logoDataURL(_ image: UIImage) -> String? {
        let scale = min(1, 600 / max(image.size.width, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for (mime, data) in [("png", small.pngData()), ("jpeg", small.jpegData(compressionQuality: 0.85))] {
            guard let data else { continue }
            let url = "data:image/\(mime);base64," + data.base64EncodedString()
            if url.count <= 400 * 1024 { return url }
        }
        return nil
    }

    static func styleHint(_ style: String) -> String {
        switch style {
        case "clean": "White, with a line in your colour."
        case "minimal": "Just the words."
        default: "A coloured band across the top."
        }
    }

    /// The parts a quick layout can hide (lib/document-design.lua SHOW), in plain words.
    static func parts(_ kind: TemplateKind) -> [(String, String)] {
        var list = [("company_address", "Your address"), ("company_email", "Your email"), ("company_phone", "Your phone number"),
                    ("tax_id", "Your VAT number"), ("status", "Status badge (Paid, Sent …)"), ("item_numbers", "Line numbers"),
                    ("tax_column", "Tax column")]
        list += kind == .order ? [("delivery_address", "Delivery address"), ("payment_details", "How to pay (bank details)")]
            : [("payment_details", "How to pay (bank details)"), ("notes", "The invoice’s notes")]
        return list
    }

    /// The fields that matter when deciding whether there are unsaved changes (the server's own ones left out).
    static func comparable(_ design: [String: JSONValue]) -> [String: JSONValue] {
        var d = design
        for key in ["is_custom", "updated_at", "template_name"] { d[key] = nil }
        for (key, value) in d where value == .null { d[key] = nil }
        return d
    }

    // MARK: Server

    private func load() async {
        do {
            let set = try await api.designs()
            designs = .loaded(set)
            if !set.kinds.contains(kind), let first = set.kinds.first { kind = first }
            draft = set.designs[kind.rawValue] ?? [:]
            await loadTemplates()
            await refreshPreview()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            designs = .failed(apiError)
        }
    }

    private func loadTemplates() async {
        templates = ((try? await api.list(kind: kind)) ?? []).filter(\.isActive)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let name = templates.first { $0.id == chosenTemplate }?.name
        let done = useTemplate ? "Saved. New \(kind.plural) use the template “\(name ?? "you picked")”."
            : "\(kind.label) design saved. New PDFs use it now."
        if await perform($feedback, done: done, { try await api.saveDesign(kind, .object(draft)) }) {
            if let set = try? await api.designs() {
                designs = .loaded(set)
                draft = set.designs[kind.rawValue] ?? draft
            }
        }
    }

    private func reset() async {
        saving = true
        defer { saving = false }
        if await perform($feedback, done: "Back to the standard design.", { try await api.resetDesign(kind) }) {
            await load()
        }
    }

    /// Changes whenever what the preview shows changes.
    private var draftPreviewKey: String {
        (try? JSONEncoder.sorted.encode(JSONValue.object(Self.comparable(draft)))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func refreshPreview() async {
        guard MacSupport.isMac else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        preview = .loading
        preview = await makePreview()
    }

    private func openFullPreview() async {
        switch await makePreview() {
        case .ready(let url, _):
            fullPreview = PDFPreviewItem(url: url, title: "\(kind.label) preview", subtitle: "Filled with example figures")
        case .failed(let message):
            feedback = .failed(ResourceService.problem(422, message))
        case .none, .loading:
            break
        }
    }

    /// The template's PDF from the server, or the quick layout drawn here, filled with example figures.
    private func makePreview() async -> LookPreview {
        if useTemplate {
            guard let uuid = chosenTemplate else { return .failed("Pick a template above to see your \(kind.label.lowercased()) here.") }
            do {
                guard let source = try await api.template(uuid).pdfSource else { return .failed("This template has nothing to print.") }
                let data = try await api.previewPDF(source)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(kind.label) preview.pdf")
                try data.write(to: url, options: .atomic)
                return .ready(url, data)
            } catch {
                let problem = TemplatePDFProblem(error)
                return .failed(problem == .serviceUnavailable
                               ? problem.explanation + " Until then, your \(kind.plural) are made with the quick layout."
                               : problem.explanation)
            }
        }
        var set = designs.value ?? DocumentDesignSet(.null)
        set.designs[kind.rawValue] = draft
        let design = set.design(kind)
        let company = session.workspace?.name
        let url = kind == .order ? DocumentSamples.orderPDF(design: design, company: company)
            : DocumentSamples.invoicePDF(design: design, company: company)
        guard let url, let data = try? Data(contentsOf: url) else { return .failed("The preview couldn’t be drawn.") }
        return .ready(url, data)
    }
}

/// Example figures for previews of the quick layout (the web's samples on Invoice and order design).
@MainActor
enum DocumentSamples {
    static let invoiceJSON = """
    {"id":"sample","invoice_number":"INV-0042","status":"sent","customer_name":"Harbour VFX Ltd",
     "customer_email":"accounts@harbourvfx.example","customer_address":"4 Dock Street, Bristol BS2 0AA",
     "issue_date":"2026-11-25","due_date":"2026-12-25","currency":"GBP","po_number":"PO-778",
     "subtotal":"10700.00","tax_amount":"2140.00","total_amount":"12840.00","amount_paid":"0","balance_due":"12840.00",
     "notes":"Delivered with both cards fitted and tested.","payment_terms_days":30,
     "payment_method":{"uuid":"pm","kind":"bank_transfer","label":"Business account","account_name":"Your business",
                       "sort_code":"200000","account_number":"12345678"},
     "line_items":[{"id":"1","description":"GPU workstation, 64-core, 256 GB memory","quantity":"1","unit_price":"8500.00",
                    "tax_amount":"1700.00","line_total":"10200.00"},
                   {"id":"2","description":"On-site installation (hours)","quantity":"2","unit_price":"1100.00",
                    "tax_amount":"440.00","line_total":"2640.00"}],
     "payments":[]}
    """

    static let orderJSON = """
    {"uuid":"sample","order_number":"ORD-1042","status":"pending_payment","email":"priya@harbourvfx.example",
     "customer":{"name":"Priya Shah","company":"Harbour VFX","phone":"07700 900123"},
     "lines":[{"uuid":"l1","product_name":"RTX 6000 Ada 48GB","sku":"RTX6000","qty":2,"unit_price_minor":642000,
               "line_subtotal_minor":1284000,"line_vat_minor":256800,"line_total_minor":1540800}],
     "subtotal_minor":1284000,"vat_minor":256800,"shipping_minor":0,"total_minor":1540800,"currency":"GBP",
     "created_at":"2026-11-25T10:00:00Z"}
    """

    static let orderExtrasJSON = """
    {"payment_method":"bank_transfer","payment_reference":"ORD-1042",
     "payment_methods":[{"uuid":"pm","kind":"bank_transfer","label":"Business account","sort_code":"20-00-00","account_number":"12345678"}]}
    """

    static func invoicePDF(design: DocumentDesign, company: String?) -> URL? {
        guard let invoice = try? JSONDecoder.opsAPI().decode(Invoice.self, from: Data(invoiceJSON.utf8)) else { return nil }
        return InvoicePDFRenderer.render(invoice, company: company, design: design)
    }

    static func orderPDF(design: DocumentDesign, company: String?) -> URL? {
        guard let order = try? JSONDecoder.opsAPI().decode(ShopOrder.self, from: Data(orderJSON.utf8)),
              let extras = try? JSONDecoder.opsAPI().decode(ShopOrderExtras.self, from: Data(orderExtrasJSON.utf8)) else { return nil }
        return ShopOrderPrint.file(order: order, extras: extras, company: company, design: design)
    }
}
