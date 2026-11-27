import SwiftUI

/// One template: its first page with sample figures (tap for the whole PDF), what uses it, and everything that can
/// be done with it. Opened from the library and from Invoice and order design.
struct TemplateOverviewView: View {
    let uuid: String
    var onChange: () -> Void = {}
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var template: LoadState<DocTemplate> = .idle
    @State private var designs: DocumentDesignSet?
    @State private var preview: Preview = .idle
    @State private var feedback: Feedback = .none
    @State private var naming: TemplateNaming?
    @State private var confirmDelete = false
    @State private var using: TemplateKind?
    @State private var showingVersions = false
    @State private var editing = false
    @State private var fullPreview: PDFPreviewItem?
    @State private var openedCopy: DocTemplate?
    @State private var redesigning: (key: String, kind: BuilderKind)?

    enum Preview {
        case idle, loading
        case ready(Data, UIImage, URL)
        case failed(TemplatePDFProblem)
    }

    private var api: DocTemplatesAPI { DocTemplatesAPI(services) }
    private var p: PermissionSet { session.permissions }
    private var wide: Bool { MacSupport.isMac || sizeClass == .regular }

    var body: some View {
        Group {
            switch template {
            case .idle, .loading: SkeletonList(rows: 4)
            case .failed(let error):
                RecordUnavailableView(noun: "template", systemImage: "doc.richtext", error: error) { Task { await load() } }
            case .loaded(let t): content(t)
            }
        }
        .navigationTitle(template.value?.name ?? "Template")
        .navigationBarTitleDisplayMode(.inline)
        .task { if template.value == nil { await load() } }
        .wsRefreshable { await load() }
        .navigationDestination(isPresented: $editing) {
            if let t = template.value { TemplateEditorRoute(template: t) { Task { await load(); onChange() } } }
        }
        .navigationDestination(item: $openedCopy) { copy in
            TemplateOverviewView(uuid: copy.id, onChange: onChange)
        }
        .sheet(item: $fullPreview) { item in PDFPreviewSheet(item: item) }
        .sheet(item: $naming) { naming in
            TemplateNameSheet(naming: naming) { name in await named(naming, name) }
        }
        .sheet(isPresented: $showingVersions) {
            NavigationStack {
                DocTemplateVersionsView(uuid: uuid, current: template.value?.version ?? 1, canRestore: TemplateAccess.update(p)) { message in
                    feedback = .done(message)
                    Task { await load(); onChange() }
                }
            }
        }
        .confirmationDialog("Delete “\(template.value?.name ?? "this template")”?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete template", role: .destructive) { Task { await delete() } }
        } message: {
            if let t = template.value { Text(DocumentTemplatesLibrary.deleteMessage(t, inUse: designs?.inUse(t.id) ?? [])) }
        }
        .confirmationDialog("Design this template by dragging?", isPresented: Binding(
            get: { redesigning != nil }, set: { if !$0 { redesigning = nil } }), titleVisibility: .visible) {
            if let (key, kind) = redesigning {
                Button("Start designing") { Task { await redesign(key, kind) } }
            }
        } message: {
            Text("The page is replaced by a ready-made design you can move around and restyle. Your current HTML stays in Earlier versions.")
        }
        .confirmationDialog(using.map { "Use this template for your \($0.plural)?" } ?? "",
                            isPresented: Binding(get: { using != nil }, set: { if !$0 { using = nil } }),
                            titleVisibility: .visible) {
            if let kind = using { Button("Use it for \(kind.plural)") { Task { await use(for: kind) } } }
        } message: {
            Text("Every \(using == .order ? "order" : "invoice") PDF is made with it from now on, including the ones you email.")
        }
    }

    // MARK: Layout

    private func content(_ t: DocTemplate) -> some View {
        ScrollView {
            if wide {
                HStack(alignment: .top, spacing: 24) {
                    page(t).frame(maxWidth: 620)
                    side(t).frame(width: 330)
                }
                .padding(24)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    side(t)
                    page(t)
                }
                .padding(16)
            }
        }
        .background(Palette.canvas)
    }

    /// The first page, filled with this workspace's sample figures.
    @ViewBuilder
    private func page(_ t: DocTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch preview {
            case .ready(_, let image, let url):
                Button {
                    fullPreview = PDFPreviewItem(url: url, title: t.name, subtitle: "Filled with example figures")
                } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hairline))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                }
                .buttonStyle(.pressableCard)
                .accessibilityLabel("Open the whole preview")
                .accessibilityIdentifier("template.preview")
                Text("Filled with example figures. Tap the page to see the whole PDF.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            case .failed(let problem):
                TemplatePageSketch(kind: t.kind ?? .invoice)
                    .aspectRatio(210 / 297, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hairline))
                    .overlay { problemCard(problem, t) }
            case .idle, .loading:
                TemplatePageSketch(kind: t.kind ?? .invoice)
                    .aspectRatio(210 / 297, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hairline))
                    .overlay { if t.kind?.isDocument == true { ProgressView("Making the preview…") } }
            }
        }
    }

    private func problemCard(_ problem: TemplatePDFProblem, _ t: DocTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(problem == .serviceUnavailable ? "No picture of this template yet" : "This template can’t be printed yet",
                  systemImage: problem == .serviceUnavailable ? "photo.badge.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.wsHeadline)
                .foregroundStyle(problem == .serviceUnavailable ? Color.primary : Tone.warning.textColor)
            Text(problem.explanation).font(.wsSubheadline).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if case .mistake = problem, TemplateAccess.update(p) {
                    Button("Fix it", systemImage: "pencil") { editing = true }.buttonStyle(.borderedProminent)
                }
                Button("Try again", systemImage: "arrow.clockwise") {
                    TemplateThumbnails.shared.retry()
                    Task { await makePreview(t) }
                }
                .buttonStyle(.bordered)
            }
        }
        .brandCard(radius: 12)
        .padding(16)
        .accessibilityIdentifier("template.previewProblem")
    }

    private func side(_ t: DocTemplate) -> some View {
        let used = designs?.inUse(t.id) ?? []
        let usable = (t.kind?.isDocument == true) ? [t.kind!].filter { designs?.kinds.contains($0) == true } : []
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: t.kind?.systemImage ?? "doc.richtext")
                        .font(.title2).foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.wsTitle2.bold()).fixedSize(horizontal: false, vertical: true)
                        Text("\(t.kind?.label ?? Formatters.humanize(t.typeName)) template").font(.wsSubheadline)
                            .foregroundStyle(.secondaryText)
                    }
                }
                FlowBadges(t: t, used: used)
                if let detail = t.detail { Text(detail).font(.wsSubheadline).foregroundStyle(.secondaryText).lineSpacing(3) }
            }
            FeedbackRow(feedback: feedback)
            actions(t, used: used, usable: usable)
            VStack(alignment: .leading, spacing: 10) {
                fact("Version", "\(t.version)")
                if let changed = Formatters.dateTime(t.updatedAt) { fact("Last changed", changed) }
                fact("Page", [t.record.string("page_size") ?? "A4",
                              t.record.string("page_orientation") == "landscape" ? "landscape" : "portrait"].joined(separator: ", "))
                fact("Made with", t.isDesigned ? "The designer" : "HTML and CSS")
            }
            .brandCard(padding: MacSupport.isMac ? 20 : 16, radius: 12)
            if !usable.isEmpty, TemplateAccess.readDesigns(p) {
                NavigationLink {
                    DocumentLookView(initialKind: usable[0])
                } label: {
                    Label("Change how your \(usable[0].plural) look", systemImage: "paintpalette")
                }
                .font(.wsSubheadline)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value).font(.wsBody)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ t: DocTemplate, used: [TemplateKind], usable: [TemplateKind]) -> some View {
        let canUse = usable.filter { !used.contains($0) && TemplateAccess.changeDesign($0, p) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(canUse) { kind in
                Button { using = kind } label: {
                    Label("Use for \(kind.plural)", systemImage: "checkmark.circle").frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("template.use.\(kind.rawValue)")
            }
            HStack(spacing: 8) {
                if TemplateAccess.update(p) {
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 28) }
                        .accessibilityIdentifier("template.edit")
                }
                if case .ready(_, _, let url) = preview {
                    Button {
                        fullPreview = PDFPreviewItem(url: url, title: t.name, subtitle: "Filled with example figures")
                    } label: {
                        Label("Preview", systemImage: "eye").frame(maxWidth: .infinity, minHeight: 28)
                    }
                }
                Menu {
                    if TemplateAccess.create(p) {
                        Button { naming = .duplicate(t) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    }
                    if TemplateAccess.update(p) {
                        Button { naming = .rename(t) } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
                    }
                    if t.kind == .timesheet, !t.isDefault, TemplateAccess.update(p) {
                        Button { Task { await makeDefault(t) } } label: { Label("Make it the default", systemImage: "star") }
                    }
                    Button { showingVersions = true } label: { Label("Earlier versions", systemImage: "clock.arrow.circlepath") }
                    if let kind = t.builderKind, !t.isDesigned, TemplateAccess.update(p) {
                        Menu {
                            ForEach(BuilderPresets.all, id: \.key) { preset in
                                Button(preset.name) { redesigning = (preset.key, kind) }
                            }
                        } label: {
                            Label("Design it by dragging instead", systemImage: "square.on.square.dashed")
                        }
                    }
                    if TemplateAccess.delete(p) {
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle").frame(minHeight: 28)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("template.more")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    // MARK: Server

    private func load() async {
        do {
            let t = try await api.template(uuid)
            template = .loaded(t)
            if TemplateAccess.readDesigns(p) { designs = try? await api.designs() }
            await makePreview(t)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if template.value == nil { template = .failed(apiError) } else { feedback = .failed(apiError) }
        }
    }

    private func makePreview(_ t: DocTemplate) async {
        guard let source = t.pdfSource else {
            preview = .idle
            return
        }
        preview = .loading
        do {
            let data = try await api.previewPDF(source)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(t.name) preview.pdf")
            try data.write(to: url, options: .atomic)
            guard let image = PDFThumbnail.image(data, width: 1000) else { throw ResourceService.problem(502, "Not a PDF") }
            preview = .ready(data, image, url)
        } catch {
            if case .cancelled = error.asAPIError { return }
            preview = .failed(TemplatePDFProblem(error))
        }
    }

    private func named(_ naming: TemplateNaming, _ name: String) async -> Bool {
        switch naming {
        case .rename:
            let ok = await perform($feedback, done: "Renamed to “\(name)”.") { _ = try await api.update(uuid, ["name": .string(name)]) }
            if ok { await load(); onChange() }
            return ok
        case .duplicate:
            var copy: DocTemplate?
            let ok = await perform($feedback, done: "Copied as “\(name)”.") { copy = try await api.duplicate(uuid, name: name) }
            if ok { onChange(); openedCopy = copy }
            return ok
        }
    }

    private func delete() async {
        let used = designs?.inUse(uuid) ?? []
        if await perform($feedback, done: "Deleted.", { try await api.delete(uuid) }) {
            if !used.isEmpty { DocumentDesigns.forget() }
            onChange()
            dismiss()
        }
    }

    private func use(for kind: TemplateKind) async {
        guard let designs else { return }
        if await perform($feedback, done: "Your \(kind.plural) now use this template.", {
            try await api.saveDesign(kind, designs.choosing(kind, template: uuid))
        }) {
            self.designs = try? await api.designs()
            onChange()
        }
    }

    private func redesign(_ key: String, _ kind: BuilderKind) async {
        guard let t = template.value else { return }
        let fields = TemplateCompiler.templateFields(BuilderPresets.make(key, kind), config: t.record.objectMap("config"))
        if await perform($feedback, done: "Now a drag-and-drop design. Move and restyle anything.", {
            _ = try await api.update(uuid, fields)
        }) {
            await load()
            onChange()
            editing = true
        }
    }

    private func makeDefault(_ t: DocTemplate) async {
        if await perform($feedback, done: "This is now the default timesheet template.", { try await api.makeDefault(t.id) }) {
            await load()
            onChange()
        }
    }
}

/// The badges under a template's name: what uses it, how it was made, whether it's switched off.
private struct FlowBadges: View {
    let t: DocTemplate
    let used: [TemplateKind]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badges }
            VStack(alignment: .leading, spacing: 6) { badges }
        }
    }

    @ViewBuilder
    private var badges: some View {
        ForEach(used) { kind in
            StatusBadge(text: "Used for \(kind.plural)", systemImage: "checkmark.circle.fill", tone: .success)
        }
        if t.isDefault && t.kind == .timesheet { StatusBadge(text: "Default", systemImage: "star.fill", tone: .brand) }
        if !t.isActive { StatusBadge(text: "Switched off", systemImage: "pause.circle", tone: .neutral) }
    }
}

/// Where Edit goes: the designer for a page made with it, else the HTML and CSS editor.
struct TemplateEditorRoute: View {
    let template: DocTemplate
    let onChange: () -> Void

    var body: some View {
        if template.isDesigned {
            TemplateDesignerView(uuid: template.id, onChange: onChange)
        } else {
            DocTemplateEditorView(uuid: template.id, onChange: onChange)
        }
    }
}
