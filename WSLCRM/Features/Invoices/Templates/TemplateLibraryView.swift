import SwiftUI

// MARK: - Library

/// The workspace's document templates (web `/dashboard/templates`): what invoices and orders use now, every template
/// as a picture of its first page, and a gallery of ready-made looks to start a new one from.
struct DocumentTemplatesLibrary: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var filter: TemplateKind?
    @State private var search = ""
    @State private var templates: LoadState<[DocTemplate]> = .idle
    @State private var designs: DocumentDesignSet?
    @State private var feedback: Feedback = .none
    @State private var creating = false
    @State private var naming: TemplateNaming?
    @State private var deleting: DocTemplate?
    @State private var using: (DocTemplate, TemplateKind)?
    @State private var versionsOf: DocTemplate?
    @State private var opened: DocTemplate?
    private var thumbnails = TemplateThumbnails.shared

    private var api: DocTemplatesAPI { DocTemplatesAPI(services) }
    private var p: PermissionSet { session.permissions }
    private var kinds: [TemplateKind] { (designs?.kinds ?? [.invoice]) + [.timesheet] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacSupport.isMac ? 24 : 20) {
                if let designs, !designs.kinds.isEmpty, TemplateAccess.readDesigns(p) { inUse(designs) }
                FeedbackRow(feedback: feedback)
                if thumbnails.serviceDown { serviceBanner }
                Picker("Show", selection: $filter) {
                    Text("All").tag(TemplateKind?.none)
                    ForEach(kinds) { Text($0 == .order ? "Orders" : $0.label + "s").tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                .accessibilityIdentifier("templates.type")
                grid
            }
            .padding(.horizontal, MacSupport.isMac ? 24 : 16)
            .padding(.vertical, 16)
        }
        .wsReadableWidth(1040)
        .background(Palette.canvas)
        .navigationTitle("Templates")
        .searchable(text: $search, prompt: "Search by name")
        .wsRefreshable { await load() }
        .task(id: "\(filter?.rawValue ?? "all")|\(search)") {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            if TemplateAccess.create(p) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New template", systemImage: "plus") }
                        .help("Start a new template from a ready-made look")
                        .accessibilityIdentifier("templates.add")
                }
            }
        }
        .navigationDestination(item: $opened) { template in
            TemplateOverviewView(uuid: template.id) { Task { await load() } }
        }
        .sheet(isPresented: $creating) {
            NewTemplateSheet(kinds: kinds, initialKind: filter ?? .invoice, workspace: session.workspace?.uuid) { made in
                feedback = .done("“\(made.name)” is ready. Check it, then choose it for your \(made.kind?.plural ?? "documents").")
                Task { await load() }
                opened = made
            }
        }
        .sheet(item: $naming) { naming in
            TemplateNameSheet(naming: naming) { name in
                await nameDone(naming, name)
            }
        }
        .sheet(item: $versionsOf) { template in
            NavigationStack {
                DocTemplateVersionsView(uuid: template.id, current: template.version, canRestore: TemplateAccess.update(p)) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { template in
            Button("Delete template", role: .destructive) { Task { await delete(template) } }
        } message: { template in
            Text(Self.deleteMessage(template, inUse: designs?.inUse(template.id) ?? []))
        }
        .confirmationDialog(using.map { "Use “\($0.0.name)” for your \($0.1.plural)?" } ?? "", isPresented: Binding(
            get: { using != nil }, set: { if !$0 { using = nil } }), titleVisibility: .visible) {
            if let (template, kind) = using {
                Button("Use it for \(kind.plural)") { Task { await use(template, for: kind) } }
            }
        } message: {
            Text("Every \(using?.1 == .order ? "order" : "invoice") PDF is made with it from now on, including the ones you email.")
        }
    }

    // MARK: Parts

    private func inUse(_ designs: DocumentDesignSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In use now").font(.wsHeadline)
            ForEach(designs.kinds) { kind in
                NavigationLink {
                    DocumentLookView(initialKind: kind)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.systemImage).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind == .order ? "Order confirmations" : "Invoices").font(.wsSubheadline).foregroundStyle(.secondaryText)
                            Text(designs.usesTemplate(kind) ? "Your template “\(designs.templateName(kind) ?? "Template")”"
                                 : "Your quick layout")
                                .font(.wsHeadline).foregroundStyle(.primary)
                        }
                        Spacer()
                        Text("Change").font(.wsSubheadline).foregroundStyle(Color.accentColor)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondaryText)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("templates.inUse.\(kind.rawValue)")
            }
        }
        .brandCard(padding: MacSupport.isMac ? 20 : 16, radius: 12)
    }

    private var serviceBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Tone.warning.textColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pictures of your templates need the PDF service, which isn’t switched on here yet.")
                    .font(.wsSubheadline.weight(.semibold))
                Text("Until it is, your invoices and orders are made with the quick layout. Ask whoever runs your system to turn on the PDF service.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                Button("Try again", systemImage: "arrow.clockwise") { thumbnails.retry() }
                    .buttonStyle(.bordered)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .brandCard(padding: MacSupport.isMac ? 20 : 16, radius: 12)
        .accessibilityIdentifier("templates.serviceDown")
    }

    @ViewBuilder
    private var grid: some View {
        switch templates {
        case .failed(let error):
            InlineErrorRow(error: error) { Task { await load() } }.brandCard(radius: 12)
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView {
                Label(search.isEmpty ? "No templates yet" : "No matching templates", systemImage: "doc.richtext")
            } description: {
                Text(search.isEmpty
                     ? "A template decides how your invoices and orders look. Start from a ready-made one and change it as you like."
                     : "Try another search.")
            } actions: {
                if search.isEmpty && TemplateAccess.create(p) {
                    Button("New template", systemImage: "plus") { creating = true }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
        case .loaded(let list):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MacSupport.isMac ? 200 : 150), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 20) {
                ForEach(list) { template in card(template) }
            }
        case .idle, .loading:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MacSupport.isMac ? 200 : 150), spacing: 16)], spacing: 20) {
                ForEach(0..<4, id: \.self) { _ in TemplatePageSketch().aspectRatio(210 / 297, contentMode: .fit).redacted(reason: .placeholder) }
            }
        }
    }

    private func card(_ template: DocTemplate) -> some View {
        let used = designs?.inUse(template.id) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Button { opened = template } label: {
                TemplateThumbnail(key: thumbnailKey(template), kind: template.kind ?? .invoice,
                                  make: template.kind?.isDocument == true ? thumbnailMaker(template) : nil)
            }
            .buttonStyle(.pressableCard)
            .accessibilityLabel("Open \(template.name)")
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name).font(.wsHeadline).lineLimit(2).foregroundStyle(.primary)
                    Text(Self.caption(template)).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(2)
                    ForEach(used) { kind in
                        Label("Used for \(kind.plural)", systemImage: "checkmark.circle.fill")
                            .font(.wsCaption.weight(.semibold)).foregroundStyle(Tone.success.textColor)
                    }
                    if !template.isActive {
                        Label("Switched off", systemImage: "pause.circle").font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                Menu { actions(template) } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 32, minHeight: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for this template")
                .accessibilityLabel("More for \(template.name)")
                .accessibilityIdentifier("templates.more.\(template.id)")
            }
        }
        .contextMenu { actions(template) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("templates.card.\(template.id)")
    }

    @ViewBuilder
    private func actions(_ template: DocTemplate) -> some View {
        Button { opened = template } label: { Label("Open", systemImage: "doc.text.magnifyingglass") }
        if let kind = template.kind, kind.isDocument, designs?.kinds.contains(kind) == true,
           designs?.templateUUID(kind) != template.id, TemplateAccess.changeDesign(kind, p) {
            Button { using = (template, kind) } label: { Label("Use for \(kind.plural)", systemImage: "checkmark.circle") }
        }
        if template.kind == .timesheet, !template.isDefault, TemplateAccess.update(p) {
            Button { Task { await makeDefault(template) } } label: { Label("Make it the default", systemImage: "star") }
        }
        if TemplateAccess.create(p) {
            Button { naming = .duplicate(template) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        }
        if TemplateAccess.update(p) {
            Button { naming = .rename(template) } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
        }
        Button { versionsOf = template } label: { Label("Earlier versions", systemImage: "clock.arrow.circlepath") }
        if TemplateAccess.delete(p) {
            Divider()
            Button(role: .destructive) { deleting = template } label: { Label("Delete", systemImage: "trash") }
        }
    }

    static func caption(_ template: DocTemplate) -> String {
        [template.kind?.label ?? Formatters.humanize(template.typeName), "version \(template.version)",
         Formatters.relative(template.updatedAt).map { "changed \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static func deleteMessage(_ template: DocTemplate, inUse: [TemplateKind]) -> String {
        guard let kind = inUse.first else { return "It will be gone for good. Documents already sent keep their look." }
        return "Your \(kind.plural) use this template. Delete it and they go back to the quick layout."
    }

    private func thumbnailKey(_ template: DocTemplate) -> String {
        "\(template.id)-v\(template.version)-\(template.kind.map { designs?.stamp($0) ?? "" } ?? "")"
    }

    private func thumbnailMaker(_ template: DocTemplate) -> @Sendable () async throws -> Data {
        let api = api
        let uuid = template.id
        return {
            guard let source = try await api.template(uuid).pdfSource else { throw ResourceService.problem(422, "No preview") }
            return try await api.previewPDF(source)
        }
    }

    // MARK: Server

    private func load() async {
        if templates.value == nil { templates = .loading }
        if TemplateAccess.readDesigns(p) { designs = try? await api.designs() }
        do {
            templates = .loaded(try await api.list(kind: filter, search: search))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            templates = .failed(apiError)
        }
    }

    private func nameDone(_ naming: TemplateNaming, _ name: String) async -> Bool {
        switch naming {
        case .rename(let template):
            let ok = await perform($feedback, done: "Renamed to “\(name)”.") { _ = try await api.update(template.id, ["name": .string(name)]) }
            if ok { await load() }
            return ok
        case .duplicate(let template):
            var copy: DocTemplate?
            let ok = await perform($feedback, done: "Copied as “\(name)”.") { copy = try await api.duplicate(template.id, name: name) }
            if ok { await load(); opened = copy }
            return ok
        }
    }

    private func delete(_ template: DocTemplate) async {
        if await perform($feedback, done: "“\(template.name)” was deleted.", { try await api.delete(template.id) }) {
            if !(designs?.inUse(template.id).isEmpty ?? true) { DocumentDesigns.forget() }
            await load()
        }
    }

    private func makeDefault(_ template: DocTemplate) async {
        await perform($feedback, done: "“\(template.name)” is now the default timesheet template.") { try await api.makeDefault(template.id) }
        await load()
    }

    private func use(_ template: DocTemplate, for kind: TemplateKind) async {
        guard let designs else { return }
        if await perform($feedback, done: "Your \(kind.plural) now use “\(template.name)”.", {
            try await api.saveDesign(kind, designs.choosing(kind, template: template.id))
        }) { await load() }
    }
}

// MARK: - Naming (rename, duplicate)

enum TemplateNaming: Identifiable {
    case rename(DocTemplate)
    case duplicate(DocTemplate)

    var id: String {
        switch self {
        case .rename(let t): "rename-\(t.id)"
        case .duplicate(let t): "copy-\(t.id)"
        }
    }
}

/// A name for a template: its new name, or the copy's.
struct TemplateNameSheet: View {
    let naming: TemplateNaming
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false

    init(naming: TemplateNaming, save: @escaping (String) async -> Bool) {
        self.naming = naming
        self.save = save
        switch naming {
        case .rename(let t): _name = State(initialValue: t.name)
        case .duplicate(let t): _name = State(initialValue: "\(t.name) (copy)")
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).accessibilityIdentifier("templates.name.field")
                        .onSubmit { Task { await done() } }
                } footer: {
                    if case .duplicate = naming {
                        Text("The copy is a new template. Nothing uses it until you choose it.")
                    }
                }
            }
            .navigationTitle(isRename ? "Rename template" : "Duplicate template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRename ? "Rename" : "Duplicate") { Task { await done() } }
                        .disabled(saving || trimmed.isEmpty)
                        .accessibilityIdentifier("templates.name.save")
                }
            }
        }
        .frame(minWidth: MacSupport.isMac ? 480 : nil, minHeight: MacSupport.isMac ? 220 : nil)
        .presentationDetents([.medium])
    }

    private var isRename: Bool { if case .rename = naming { true } else { false } }

    private func done() async {
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        defer { saving = false }
        if await save(trimmed) { dismiss() }
    }
}

// MARK: - New template gallery

/// "New template": what it's for, then a ready-made look (each shown as its real first page), a name, and Create.
struct NewTemplateSheet: View {
    let kinds: [TemplateKind]
    var initialKind: TemplateKind = .invoice
    /// The workspace, for the pictures' cache.
    var workspace: String?
    let onCreated: (DocTemplate) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var kind: TemplateKind = .invoice
    @State private var starters: LoadState<[TemplateStarter]> = .idle
    @State private var stamp = ""
    @State private var choice: Choice?
    @State private var name = ""
    @State private var busy = false
    @State private var error: APIError?
    @State private var prepared = false

    enum Choice: Hashable {
        case preset(String)
        case starter(TemplateStarter)
        case fromDesign
        case blank
    }

    private var api: DocTemplatesAPI { DocTemplatesAPI(services) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if kinds.count > 1 {
                        Picker("What is it for?", selection: $kind) {
                            ForEach(kinds) { Text($0 == .order ? "Orders" : $0.label + "s").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("newTemplate.kind")
                    }
                    if let error { InlineErrorRow(error: error).brandCard(radius: 12) }
                    gallery
                }
                .padding(MacSupport.isMac ? 24 : 16)
            }
            .background(Palette.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { nameBar }
            .navigationTitle("New template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
            .task(id: kind) { await loadStarters() }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                kind = kinds.contains(initialKind) ? initialKind : kinds.first ?? .invoice
            }
            .onChange(of: kind) { choice = nil; name = "" }
        }
        .frame(minWidth: MacSupport.isMac ? 760 : nil, idealWidth: MacSupport.isMac ? 900 : nil,
               minHeight: MacSupport.isMac ? 620 : nil, idealHeight: MacSupport.isMac ? 760 : nil)
        .interactiveDismissDisabled(busy)
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: MacSupport.isMac ? 190 : 150), spacing: 16, alignment: .top)] }

    @ViewBuilder
    private var gallery: some View {
        if let builderKind = kind.builderKind {
            VStack(alignment: .leading, spacing: 10) {
                Text("Design by dragging").font(.wsHeadline)
                Text("Move, resize and restyle every piece: your logo, details, totals and bank details.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(BuilderPresets.all, id: \.key) { preset in
                        let doc = BuilderPresets.make(preset.key, builderKind)
                        option(.preset(preset.key), title: preset.name, text: preset.description) {
                            TemplateThumbnail(key: "preset-\(workspace ?? "")-\(kind.rawValue)-\(preset.key)-\(stamp)",
                                              kind: kind, doc: doc, make: { [api, source = Self.source(doc, kind)] in try await api.previewPDF(source) })
                        }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(kind.isDocument ? "More ways to start" : "Start").font(.wsHeadline)
            Text("Pick a starting point. You can change everything afterwards.")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                switch starters {
                case .loaded(let list):
                    ForEach(list) { starter in
                        option(.starter(starter), title: starter.name, text: starter.description) {
                            TemplateThumbnail(key: "starter-\(workspace ?? "")-\(kind.rawValue)-\(starter.key)-\(stamp)",
                                              kind: kind, make: { [api, source = starter.source] in try await api.previewPDF(source) })
                        }
                    }
                case .idle, .loading:
                    ForEach(0..<2, id: \.self) { _ in
                        TemplatePageSketch(kind: kind).aspectRatio(210 / 297, contentMode: .fit).redacted(reason: .placeholder)
                    }
                case .failed:
                    EmptyView()
                }
                if kind.isDocument {
                    option(.fromDesign, title: "Start from my current design",
                           text: "Your colours, logo and wording from your quick layout, ready to change further.") {
                        iconPage("paintpalette")
                    }
                }
                option(.blank, title: "Blank (for people who know HTML)", text: "An empty page to write your own HTML and CSS.") {
                    iconPage("chevron.left.forwardslash.chevron.right")
                }
            }
            if case .failed = starters {
                Text("The ready-made looks couldn’t be loaded just now. You can still start from your design or a blank page.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    private func iconPage(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(210 / 297, contentMode: .fit)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.hairline))
    }

    private func option<Preview: View>(_ value: Choice, title: String, text: String,
                                       @ViewBuilder preview: () -> Preview) -> some View {
        let selected = choice == value
        return Button {
            choice = value
            name = defaultName(value)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                preview()
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.title2)
                                .foregroundStyle(.white, Color.accentColor).padding(6)
                        }
                    }
                Text(title).font(.wsHeadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Text(text).font(.wsCaption).foregroundStyle(.secondaryText).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.10) : Palette.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : Palette.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("newTemplate.option.\(Self.id(value))")
    }

    /// A designer page's preview: compiled with the designer's placeholders (an empty logo box …).
    static func source(_ doc: BuilderDoc, _ kind: TemplateKind) -> TemplatePDFSource {
        let c = TemplateCompiler.compile(doc, editor: true)
        return TemplatePDFSource(kind: kind, html: c.html, css: c.css, footerHTML: c.footerHTML, pageSize: doc.page.paper,
                                 orientation: "portrait", margins: [c.marginTB, c.marginTB, c.marginLR, c.marginLR])
    }

    static func id(_ choice: Choice) -> String {
        switch choice {
        case .preset(let key): "preset.\(key)"
        case .starter(let s): "starter.\(s.key)"
        case .fromDesign: "fromDesign"
        case .blank: "blank"
        }
    }

    private var noun: String { kind == .order ? "order" : kind.rawValue }

    func defaultName(_ value: Choice) -> String {
        switch value {
        case .preset(let key): "\(BuilderPresets.all.first { $0.key == key }?.name ?? "My") \(noun)"
        case .starter(let s): "\(s.name) \(noun)"
        case .fromDesign: "My \(noun) design"
        case .blank: "My \(noun) template"
        }
    }

    private var nameBar: some View {
        HStack(spacing: 12) {
            if choice == nil {
                Text("Pick a look above.").font(.wsSubheadline).foregroundStyle(.secondaryText)
            } else {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("newTemplate.name")
            }
            Spacer(minLength: 0)
            Button {
                Task { await create() }
            } label: {
                if busy { ProgressView() } else { Label("Create", systemImage: "plus").lineLimit(1) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || choice == nil || name.trimmedOrNil == nil)
            .accessibilityIdentifier("newTemplate.create")
        }
        .padding(.horizontal, MacSupport.isMac ? 24 : 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func loadStarters() async {
        starters = .loading
        if kind.isDocument, let designs = try? await api.designs() { stamp = designs.stamp(kind) }
        do {
            starters = .loaded(try await api.starters(kind))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            starters = .failed(apiError)
        }
    }

    private func create() async {
        guard let choice, let name = name.trimmedOrNil else { return }
        busy = true
        defer { busy = false }
        do {
            let made: DocTemplate = switch choice {
            case .preset(let key):
                try await api.create(TemplateCompiler.templateFields(BuilderPresets.make(key, kind.builderKind ?? .invoice))
                    .merging(["name": .string(name), "type": .string(kind.rawValue)]) { _, new in new })
            case .starter(let s): try await api.fromStarter(kind, starter: s.key, name: name)
            case .fromDesign: try await api.fromDesign(kind, name: name)
            case .blank: try await api.createBlank(kind, name: name)
            }
            onCreated(made)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
