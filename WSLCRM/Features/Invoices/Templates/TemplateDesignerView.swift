import PhotosUI
import SwiftUI

/// The template designer, natively (web: the template editor's "design" mode). The page's pieces in a list you can
/// reorder, add to and remove from; a drawing of the page where pieces are dragged into place; each piece's settings;
/// the page, items table and footer; and the real PDF (`preview-pdf`) a moment after each change. Saves the page as
/// `config.builder` with the HTML, CSS and footer compiled from it (`TemplateCompiler`), exactly as the web does.
struct TemplateDesignerView: View {
    let uuid: String
    var onChange: () -> Void = {}
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var template: DocTemplate?
    @State private var loadError: APIError?
    @State private var doc: BuilderDoc?
    @State private var saved: BuilderDoc?
    @State private var name = ""
    @State private var savedName = ""
    @State private var selection: BuilderSelection = .page
    @State private var pane: Pane = .layout
    @State private var showPDF = false
    @State private var pdf: PDFState = .idle
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var inspecting = false
    @State private var confirmCode = false
    @State private var codeMode = false
    @State private var accent = Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)

    enum Pane: String, CaseIterable, Identifiable {
        case layout = "Page", pieces = "Pieces", preview = "PDF"
        var id: String { rawValue }
    }

    enum PDFState: Equatable {
        case idle, loading
        case ready(Data)
        case failed(String)
    }

    private var api: DocTemplatesAPI { DocTemplatesAPI(services) }
    private var dirty: Bool { doc != saved || name != savedName }

    var body: some View {
        Group {
            if let doc {
                if MacSupport.isMac { macBody(doc) } else { phoneBody(doc) }
            } else if let loadError {
                ErrorStateView(error: loadError) { Task { await load() } }
            } else {
                SkeletonList(rows: 5)
            }
        }
        .navigationTitle(name.isEmpty ? "Design" : name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if doc == nil { await load() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Label("Save", systemImage: "checkmark") }
                }
                .disabled(saving || !dirty || name.trimmedOrNil == nil)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save this design (⌘S)")
                .accessibilityIdentifier("designer.save")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { confirmCode = true } label: { Label("Edit the HTML yourself", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .help("Stop designing by dragging and change the HTML and CSS")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !feedback.isNone { FeedbackBar(feedback: feedback) }
        }
        .onChange(of: doc) { _, _ in if showPDF || pane == .preview { Task { await refreshPDF() } } }
        .onChange(of: showPDF) { _, on in if on { Task { await refreshPDF(now: true) } } }
        .onChange(of: pane) { _, now in if now == .preview { Task { await refreshPDF(now: true) } } }
        .sheet(isPresented: $inspecting) {
            NavigationStack {
                inspector
                    .navigationTitle(selectionTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { inspecting = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Change the HTML yourself?", isPresented: $confirmCode, titleVisibility: .visible) {
            Button("Edit the HTML", role: .destructive) { Task { await detach() } }
        } message: {
            Text("This template stops being a drag-and-drop design and the HTML is yours to edit. Earlier versions keep the design if you change your mind.")
        }
        .navigationDestination(isPresented: $codeMode) {
            DocTemplateEditorView(uuid: uuid, onChange: onChange)
        }
    }

    // MARK: Layout

    private func macBody(_ doc: BuilderDoc) -> some View {
        HStack(spacing: 0) {
            BuilderPieceList(doc: docBinding, selection: $selection, name: $name)
                .frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                Picker("Show", selection: $showPDF) {
                    Text("Arrange").tag(false)
                    Text("The real PDF").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .padding(12)
                .accessibilityIdentifier("designer.mode")
                if showPDF { pdfPane } else { canvas(doc) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            Divider()
            inspector.frame(width: 320)
        }
    }

    private func phoneBody(_ doc: BuilderDoc) -> some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            switch pane {
            case .layout:
                canvas(doc)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Button { inspecting = true } label: {
                            Label("Settings for \(selectionTitle.lowercased())", systemImage: "slider.horizontal.3")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(12)
                        .background(.bar)
                    }
            case .pieces:
                BuilderPieceList(doc: docBinding, selection: Binding<BuilderSelection>(get: { selection }, set: { chosen in
                    selection = chosen
                    inspecting = true
                }), name: $name)
            case .preview:
                pdfPane
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func canvas(_ doc: BuilderDoc) -> some View {
        ScrollView {
            BuilderCanvas(doc: doc, accent: accent, selected: selection.pieceID, onSelect: { id in
                selection = id.map(BuilderSelection.piece) ?? .page
            }, onChange: { piece in
                self.doc = self.doc.map { d in
                    var d = d
                    if let i = d.pieces.firstIndex(where: { $0.id == piece.id }) { d.pieces[i] = piece }
                    return d.clamped()
                }
            })
            .padding(MacSupport.isMac ? 24 : 12)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var pdfPane: some View {
        switch pdf {
        case .ready(let data): PDFKitView(data: data, accessibilityID: "designer.pdf")
        case .failed(let message):
            ContentUnavailableView {
                Label("No PDF to show", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again", systemImage: "arrow.clockwise") { Task { await refreshPDF(now: true) } }
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("designer.pdfProblem")
        case .idle, .loading:
            ProgressView("Making the PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let binding = docBinding.unwrapped {
            switch selection {
            case .piece(let id):
                if let index = binding.wrappedValue.pieces.firstIndex(where: { $0.id == id }) {
                    BuilderPieceInspector(doc: binding, index: index) {
                        selection = .page
                        inspecting = false
                        doc?.pieces.removeAll { $0.id == id }
                    }
                    .id(id)
                } else {
                    BuilderPageInspector(doc: binding)
                }
            case .items: BuilderItemsInspector(doc: binding)
            case .page: BuilderPageInspector(doc: binding)
            }
        }
    }

    private var selectionTitle: String {
        switch selection {
        case .page: "The page"
        case .items: "The items table"
        case .piece(let id): doc?.pieces.first { $0.id == id }.map(BuilderCatalog.name) ?? "The page"
        }
    }

    private var docBinding: Binding<BuilderDoc?> {
        Binding(get: { doc }, set: { doc = $0?.clamped() })
    }

    // MARK: Server

    private func load() async {
        do {
            let t = try await api.template(uuid)
            guard let builder = BuilderDoc.read(t.record.objectMap("config")) else {
                loadError = ResourceService.problem(422, "This template isn’t a drag-and-drop design. Open it with Edit to change its HTML.")
                return
            }
            template = t
            doc = builder
            saved = builder
            name = t.name
            savedName = t.name
            if let kind = t.kind, let set = try? await api.designs(),
               let hex = set.designs[kind.rawValue]?["accent"]?.stringValue {
                accent = DocTemplateColor.color(hex)
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func save() async {
        guard let doc, let template, let name = name.trimmedOrNil else { return }
        saving = true
        defer { saving = false }
        var fields = TemplateCompiler.templateFields(doc, config: template.record.objectMap("config"))
        fields["name"] = .string(name)
        var updated: DocTemplate?
        if await perform($feedback, done: "Saved. Each save keeps the previous version, so you can go back to it.", {
            updated = try await api.update(uuid, fields)
        }) {
            self.template = updated ?? template
            saved = doc
            savedName = name
            onChange()
        } else if case .failed(let error) = feedback, case .mistake(let text, _) = TemplatePDFProblem(error) {
            feedback = .failed(ResourceService.problem(422, text + " Check the words in your text pieces for {{ and }}."))
        }
    }

    /// Stops being a designer page: the config loses `builder` (the HTML stays), then the code editor opens.
    private func detach() async {
        guard let template else { return }
        if dirty { await save() }
        var config = template.record.objectMap("config")
        config["builder"] = nil
        if await perform($feedback, done: "This template is HTML now.", {
            _ = try await api.update(uuid, ["config": .object(config)])
        }) {
            onChange()
            codeMode = true
        }
    }

    private func refreshPDF(now: Bool = false) async {
        guard let doc, let kind = template?.kind else { return }
        if !now { try? await Task.sleep(for: .milliseconds(1200)) }
        guard !Task.isCancelled, doc == self.doc else { return }
        if case .ready = pdf {} else { pdf = .loading }
        let c = TemplateCompiler.compile(doc)
        let source = TemplatePDFSource(kind: kind, html: c.html, css: c.css, footerHTML: c.footerHTML, pageSize: doc.page.paper,
                                       orientation: "portrait", margins: [c.marginTB, c.marginTB, c.marginLR, c.marginLR])
        do {
            let data = try await api.previewPDF(source)
            guard doc == self.doc else { return }
            pdf = .ready(data)
        } catch {
            if case .cancelled = error.asAPIError { return }
            let problem = TemplatePDFProblem(error)
            pdf = .failed(problem == .serviceUnavailable
                          ? problem.explanation + " You can still arrange the page with Arrange."
                          : problem.explanation)
        }
    }
}

/// What the inspector shows: a piece, the items table, or the page (with its footer).
enum BuilderSelection: Hashable {
    case page, items
    case piece(String)

    var pieceID: String? { if case .piece(let id) = self { id } else { nil } }
}

private extension Binding where Value == BuilderDoc? {
    /// A non-optional binding while there is a page.
    var unwrapped: Binding<BuilderDoc>? {
        guard let value = wrappedValue else { return nil }
        return Binding<BuilderDoc>(get: { self.wrappedValue ?? value }, set: { self.wrappedValue = $0 })
    }
}

// MARK: - The list of pieces

/// The page's pieces by band, in drawing order (lower in the list is drawn on top). Drag to reorder, add from the
/// catalogue, hide or delete; and the page and items table, which have their own settings.
struct BuilderPieceList: View {
    @Binding var doc: BuilderDoc?
    @Binding var selection: BuilderSelection
    @Binding var name: String
    @State private var reordering = false

    var body: some View {
        List(selection: Binding<BuilderSelection?>(get: { selection }, set: { if let s = $0 { selection = s } })) {
            Section {
                TextField("Template name", text: $name).accessibilityIdentifier("designer.name")
            } header: {
                Text("Name")
            }
            Section {
                Label("Page, fonts and footer", systemImage: "doc").tag(BuilderSelection.page)
                Label("Items table", systemImage: "tablecells").tag(BuilderSelection.items)
            }
            ForEach(BuilderBand.allCases, id: \.self) { band in
                Section {
                    ForEach(pieces(band)) { piece in row(piece).tag(BuilderSelection.piece(piece.id)) }
                        .onMove { move(band, $0, $1) }
                        .onDelete { delete(band, $0) }
                    addMenu(band)
                } header: {
                    HStack {
                        Text(band == .header ? "Top of the page" : "Below the items")
                        Spacer()
                        if band == .header {
                            Button(reordering ? "Done" : "Reorder") { reordering.toggle() }
                                .font(.wsCaption.weight(.semibold))
                                .accessibilityIdentifier("designer.reorder")
                        }
                    }
                } footer: {
                    Text(band == .header ? "Lower in the list is drawn on top. Press Reorder, then drag to change the order."
                         : "These move down the page with the items table.")
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
    }

    private func pieces(_ band: BuilderBand) -> [BuilderPiece] { doc?.pieces.filter { $0.band == band } ?? [] }

    private func row(_ piece: BuilderPiece) -> some View {
        HStack(spacing: 10) {
            Image(systemName: BuilderCanvas.symbol(piece.type)).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(BuilderCatalog.name(piece)).lineLimit(1)
                .foregroundStyle(piece.hidden == true ? Color.secondaryText : Color.primary)
            Spacer()
            Button {
                update(piece.id) { $0.hidden = $0.hidden == true ? nil : true }
            } label: {
                Image(systemName: piece.hidden == true ? "eye.slash" : "eye").foregroundStyle(.secondaryText)
            }
            .buttonStyle(.borderless)
            .help(piece.hidden == true ? "Show it" : "Hide it")
            .accessibilityLabel(piece.hidden == true ? "Show \(BuilderCatalog.name(piece))" : "Hide \(BuilderCatalog.name(piece))")
        }
        .frame(minHeight: 32)
        .contextMenu {
            Button { duplicate(piece) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { remove(piece.id) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityIdentifier("designer.piece.\(piece.type.rawValue)")
    }

    private func addMenu(_ band: BuilderBand) -> some View {
        Menu {
            ForEach(BuilderCatalog.groups, id: \.self) { group in
                Section(group) {
                    ForEach(BuilderCatalog.pieces(for: doc?.kind ?? .invoice).filter { BuilderCatalog.info($0).group == group }, id: \.self) { type in
                        Button { add(type, band) } label: {
                            Label(BuilderCatalog.info(type).name, systemImage: BuilderCanvas.symbol(type))
                        }
                    }
                }
            }
        } label: {
            Label("Add a piece", systemImage: "plus.circle")
        }
        .accessibilityIdentifier("designer.add.\(band.rawValue)")
    }

    private func update(_ id: String, _ change: (inout BuilderPiece) -> Void) {
        guard var d = doc, let i = d.pieces.firstIndex(where: { $0.id == id }) else { return }
        change(&d.pieces[i])
        doc = d
    }

    private func add(_ type: PieceType, _ band: BuilderBand) {
        guard var d = doc else { return }
        let piece = BuilderCatalog.makePiece(type, kind: d.kind, band: band, x: 0, y: 0)
        d.pieces.append(piece)
        doc = d.clamped()
        selection = .piece(piece.id)
    }

    private func duplicate(_ piece: BuilderPiece) {
        guard var d = doc else { return }
        var copy = piece
        copy.id = BuilderCatalog.newID()
        copy.x += 4
        copy.y += 4
        d.pieces.append(copy)
        doc = d.clamped()
        selection = .piece(copy.id)
    }

    private func remove(_ id: String) {
        if selection == .piece(id) { selection = .page }
        doc?.pieces.removeAll { $0.id == id }
    }

    /// Moves within one band; the other band's pieces keep their places in the array.
    private func move(_ band: BuilderBand, _ from: IndexSet, _ to: Int) {
        guard var d = doc else { return }
        var mine = d.pieces.filter { $0.band == band }
        mine.move(fromOffsets: from, toOffset: to)
        var iterator = mine.makeIterator()
        d.pieces = d.pieces.map { $0.band == band ? iterator.next()! : $0 }
        doc = d
    }

    private func delete(_ band: BuilderBand, _ offsets: IndexSet) {
        let ids = offsets.map { pieces(band)[$0].id }
        for id in ids { remove(id) }
    }
}

// MARK: - The drawing of the page

/// The page at scale: the top band, the items table, the band below it and the footer, with each piece where it
/// prints. A piece is chosen with a tap and moved by dragging it (or resized from its corner) when `onChange` is set.
struct BuilderCanvas: View {
    let doc: BuilderDoc
    var accent: Color = .accentColor
    var selected: String?
    var onSelect: ((String?) -> Void)?
    var onChange: ((BuilderPiece) -> Void)?

    @State private var dragging: (id: String, start: BuilderPiece, resize: Bool)?

    static func symbol(_ type: PieceType) -> String {
        switch type {
        case .logo: "photo"
        case .image: "photo.on.rectangle"
        case .title: "textformat.size"
        case .text: "text.alignleft"
        case .company: "building.2"
        case .customer: "person"
        case .delivery: "shippingbox"
        case .details: "number"
        case .amount: "sterlingsign.circle"
        case .status: "tag"
        case .totals: "sum"
        case .payment: "banknote"
        case .notes: "note.text"
        case .terms: "scale.3d"
        case .vat: "percent"
        case .box: "square"
        case .line: "minus"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = doc.contentWidth
            let scale = geo.size.width / CGFloat(width + 2 * doc.page.margins.lr)
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: CGFloat(doc.page.margins.tb) * scale)
                band(.header, scale: scale)
                itemsTable(scale: scale)
                band(.after, scale: scale)
                Spacer(minLength: 0)
                footer(scale: scale)
            }
            .padding(.horizontal, CGFloat(doc.page.margins.lr) * scale)
            .frame(width: geo.size.width, height: geo.size.width * pageRatio, alignment: .top)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?(nil) }
        }
        .aspectRatio(1 / pageRatio, contentMode: .fit)
        .environment(\.colorScheme, .light)
    }

    private var pageRatio: CGFloat {
        let paper = BuilderCatalog.paper[doc.page.paper] ?? (210, 297)
        return CGFloat(paper.h / paper.w)
    }

    private func band(_ band: BuilderBand, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(onChange == nil ? 0 : 0.025))
                .overlay(alignment: .topTrailing) {
                    // While designing only: a picture of the page shows just the page.
                    if onChange != nil {
                        Text(band == .header ? "Top of the page" : "Below the items")
                            .font(.system(size: max(7, 2.6 * scale))).foregroundStyle(Color.black.opacity(0.3)).padding(2)
                    }
                }
            ForEach(doc.pieces.filter { $0.band == band && $0.hidden != true }) { piece in
                pieceView(piece, scale: scale)
            }
        }
        .frame(height: CGFloat(doc.height(band)) * scale, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func colour(_ c: String?) -> Color? {
        guard let c, !c.isEmpty else { return nil }
        return c == "accent" ? accent : DocTemplateColor.color(c)
    }

    private func pieceView(_ piece: BuilderPiece, scale: CGFloat) -> some View {
        let isSelected = piece.id == selected
        let s = piece.style
        let fontSize = max(5, CGFloat((s.size ?? doc.page.size) * 0.3528) * scale)
        return ZStack(alignment: s.align == "right" ? .topTrailing : s.align == "center" ? .top : .topLeading) {
            RoundedRectangle(cornerRadius: CGFloat(s.radius ?? 0) * 0.3528 * scale)
                .fill(colour(s.bg) ?? Color.clear)
                .opacity((s.opacity ?? 100) / 100)
            if piece.type != .box && piece.type != .line {
                Text(Self.sample(piece, kind: doc.kind))
                    .font(.system(size: fontSize, weight: (s.weight ?? 400) >= 700 ? .bold : (s.weight ?? 400) >= 600 ? .semibold : .regular))
                    .italic(s.italic == true)
                    .foregroundStyle(colour(s.color) ?? colour(doc.page.color) ?? Color(white: 0.15))
                    .multilineTextAlignment(s.align == "right" ? .trailing : s.align == "center" ? .center : .leading)
                    .lineLimit(nil)
                    .padding(CGFloat(s.padding ?? 0) * scale)
            }
        }
        .frame(width: CGFloat(piece.w) * scale, height: max(CGFloat(piece.h) * scale, 1), alignment: .topLeading)
        .clipped()
        .overlay {
            if onChange != nil {
                Rectangle().strokeBorder(isSelected ? accent : Color.black.opacity(0.18),
                                         style: StrokeStyle(lineWidth: isSelected ? 2 : 0.5, dash: isSelected ? [] : [3, 2]))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected && onChange != nil && piece.locked != true {
                Circle().fill(accent).frame(width: 12, height: 12).offset(x: 6, y: 6)
                    .gesture(drag(piece, scale: scale, resize: true))
                    .accessibilityLabel("Resize")
            }
        }
        .offset(x: CGFloat(piece.x) * scale, y: CGFloat(piece.y) * scale)
        .onTapGesture { onSelect?(piece.id) }
        .gesture(drag(piece, scale: scale, resize: false),
                 including: onChange == nil || piece.locked == true ? .subviews : .all)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BuilderCatalog.name(piece))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func drag(_ piece: BuilderPiece, scale: CGFloat, resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragging?.id != piece.id || dragging?.resize != resize {
                    dragging = (piece.id, piece, resize)
                    onSelect?(piece.id)
                }
                guard let start = dragging?.start else { return }
                var p = start
                let dx = Double(value.translation.width / scale), dy = Double(value.translation.height / scale)
                // Half-millimetre steps.
                func snap(_ v: Double) -> Double { (v * 2).rounded() / 2 }
                if resize {
                    p.w = snap(start.w + dx)
                    p.h = piece.type == .line ? start.h : snap(start.h + dy)
                } else {
                    p.x = snap(start.x + dx)
                    p.y = snap(start.y + dy)
                }
                onChange?(p)
            }
            .onEnded { _ in dragging = nil }
    }

    private func itemsTable(scale: CGFloat) -> some View {
        let cols = doc.items.columns.filter(\.show)
        let size = max(5, CGFloat(doc.items.size * 0.3528) * scale)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(cols) { c in
                    Text(doc.items.upper ? c.label.uppercased() : c.label)
                        .font(.system(size: size, weight: .bold))
                        .frame(maxWidth: c.width == nil ? .infinity : CGFloat(c.width! / 100 * doc.contentWidth) * scale,
                               alignment: c.align == "right" ? .trailing : c.align == "center" ? .center : .leading)
                        .padding(2)
                }
            }
            .foregroundStyle(colour(doc.items.headerColor) ?? .black)
            .background(colour(doc.items.headerBg) ?? Color.clear)
            ForEach(0..<2, id: \.self) { i in
                Rectangle().fill(i == 1 ? (colour(doc.items.stripe) ?? .clear) : .clear)
                    .frame(height: size * 2.2)
                    .overlay(alignment: .bottom) { Rectangle().fill(colour(doc.items.lineColor) ?? .gray.opacity(0.3)).frame(height: 0.5) }
            }
        }
        .padding(.top, CGFloat(doc.items.marginTop) * scale)
        .padding(.bottom, CGFloat(doc.items.marginBottom) * scale)
        .overlay(alignment: .center) {
            if onChange != nil {
                Text("Items table: grows with the document").font(.system(size: max(7, 2.6 * scale)))
                    .foregroundStyle(Color.black.opacity(0.35)).offset(y: size)
            }
        }
        .contentShape(Rectangle())
    }

    private func footer(scale: CGFloat) -> some View {
        HStack {
            Text(Self.plain(doc.footer.left))
            if !doc.footer.left.isEmpty || doc.footer.center != true { Spacer() }
            if doc.footer.pageNumbers { Text("Page 1 of 1") }
        }
        .font(.system(size: max(5, CGFloat(doc.footer.size * 0.3528) * scale)))
        .foregroundStyle(colour(doc.footer.color) ?? .gray)
        .frame(maxWidth: .infinity, alignment: doc.footer.center == true ? .center : .leading)
        .padding(.bottom, 6 * scale)
    }

    /// The words a piece shows on the drawing: its own words with details as their names, or what it prints.
    static func sample(_ p: BuilderPiece, kind: BuilderKind) -> String {
        let order = kind == .order
        switch p.type {
        case .title: return plain(p.text ?? "{{ document.title }}").uppercased()
        case .text: return plain(p.text ?? "")
        case .logo: return "Logo"
        case .image: return p.src == nil ? "Picture" : ""
        case .company: return "Your business\n1 High Street\nhello@yourbusiness.example"
        case .customer: return "\(p.label ?? (order ? "Customer" : "Billed to"))\nThe customer\ncustomer@example.com"
        case .delivery: return "\(p.label ?? "Deliver to")\n2 Market Square"
        case .details: return order ? "Order number  ORD-1042\nOrder date  25 Nov 2026" : "Invoice number  INV-0042\nIssue date  25 Nov 2026\nDue date  25 Dec 2026"
        case .amount: return order ? "Order total\n£1,540.80" : "Amount due\n£12,840.00"
        case .status: return order ? "AWAITING PAYMENT" : "SENT"
        case .totals: return "Subtotal  £10,700.00\nVAT  £2,140.00\nTotal  £12,840.00"
        case .payment: return "\(p.label ?? "How to pay")\nSort code  20-00-00\nAccount  12345678"
        case .notes: return "\(p.label ?? "Notes")\nThe invoice’s notes"
        case .terms: return "\(p.label ?? "Payment terms")\nPayment is due within 30 days."
        case .vat: return "VAT rate  Net  VAT"
        case .box, .line: return ""
        }
    }

    /// Example values for details on the drawing ("{{ invoice.number }}" → "INV-0042"); others show their name.
    static let examples = [
        "document.title": "Invoice", "invoice.number": "INV-0042", "order.number": "ORD-1042", "company.name": "Your business",
        "company.vat_number": "GB123456789", "company.company_number": "01234567", "company.email": "hello@yourbusiness.example",
        "company.phone": "020 7946 0000", "company.address": "1 High Street, London", "customer.name": "The customer",
        "invoice.issue_date": "25 Nov 2026", "invoice.due_date": "25 Dec 2026", "order.date": "25 Nov 2026",
        "document.printed_on": "27 Nov 2026", "invoice.balance_due_formatted": "£12,840.00", "order.total_formatted": "£1,540.80",
    ]

    static func plain(_ s: String) -> String {
        var out = s
        for match in s.matches(of: /\{\{\s*([a-zA-Z0-9_.]+)[^}]*\}\}/).reversed() {
            let path = String(match.1)
            let name = path.split(separator: ".").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? path
            out.replaceSubrange(match.range, with: examples[path] ?? "[\(name)]")
        }
        return out
    }
}

// MARK: - Settings

/// A number in a settings row: typed, or stepped.
private struct NumberRow: View {
    let label: String
    @Binding var value: Double
    var unit = "mm"
    var step = 0.5
    var range: ClosedRange<Double> = 0...500

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: $value, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .keyboardType(.decimalPad)
                Text(unit).foregroundStyle(.secondaryText).font(.wsCaption)
                Stepper(label, value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}

/// A colour setting: the workspace's own colour, none, or one picked.
private struct ColourRow: View {
    let label: String
    @Binding var value: String?
    var allowNone = true

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Menu {
                    Button("Your colour") { value = "accent" }
                    if allowNone { Button("None") { value = "" } }
                    Divider()
                    ForEach(BuilderCatalog.swatches, id: \.self) { hex in
                        Button { value = hex } label: { Label(hex, systemImage: "circle.fill").tint(DocTemplateColor.color(hex)) }
                    }
                } label: {
                    Text(value == "accent" ? "Your colour" : (value ?? "").isEmpty ? "None" : (value ?? ""))
                        .font(.wsCaption.monospaced())
                }
                .fixedSize()
                if let hex = value, hex != "accent", !hex.isEmpty {
                    ColorPicker(label, selection: Binding(get: { DocTemplateColor.color(hex) },
                                                          set: { value = DocTemplateColor.hex($0) }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
    }
}

/// One piece's settings: where it is, its words, which lines it prints and how it looks.
struct BuilderPieceInspector: View {
    @Binding var doc: BuilderDoc
    let index: Int
    /// Deletes this piece (the screen first stops showing it).
    let onDelete: () -> Void
    @State private var pickedImage: PhotosPickerItem?

    /// Safe while the piece is being deleted: SwiftUI may draw this once more before the screen moves on.
    private var piece: Binding<BuilderPiece> {
        let fallback = doc.pieces.indices.contains(index) ? doc.pieces[index]
            : BuilderCatalog.makePiece(.text, kind: doc.kind, band: .header, x: 0, y: 0)
        return Binding(get: { doc.pieces.indices.contains(index) ? doc.pieces[index] : fallback },
                       set: { if doc.pieces.indices.contains(index) { doc.pieces[index] = $0 } })
    }
    private var info: PieceInfo { BuilderCatalog.info(piece.wrappedValue.type) }
    private var style: Binding<PieceStyle> { piece.style }

    var body: some View {
        Form {
            Section {
                Text(info.help).font(.wsSubheadline).foregroundStyle(.secondaryText)
            } header: {
                Text(info.name)
            }
            Section("Where") {
                Picker("Part of the page", selection: piece.band) {
                    Text("Top of the page").tag(BuilderBand.header)
                    Text("Below the items").tag(BuilderBand.after)
                }
                NumberRow(label: "From the left", value: piece.x)
                NumberRow(label: "From the top", value: piece.y)
                NumberRow(label: "Width", value: piece.w)
                if piece.wrappedValue.type != .line { NumberRow(label: "Height", value: piece.h) }
                Toggle("Lock in place", isOn: Binding(get: { piece.wrappedValue.locked == true },
                                                      set: { piece.wrappedValue.locked = $0 ? true : nil }))
            }
            words
            lines
            looks
            Section {
                Button("Bring to the front", systemImage: "square.3.layers.3d.top.filled") { reorder(toFront: true) }
                Button("Send to the back", systemImage: "square.3.layers.3d.bottom.filled") { reorder(toFront: false) }
                Button("Delete this piece", systemImage: "trash", role: .destructive, action: onDelete)
                .accessibilityIdentifier("designer.piece.delete")
            }
        }
        .onChange(of: pickedImage) { _, item in Task { await pick(item) } }
    }

    @ViewBuilder
    private var words: some View {
        let type = piece.wrappedValue.type
        if type == .title || type == .text {
            Section {
                TextField("Words", text: Binding(get: { piece.wrappedValue.text ?? "" }, set: { piece.wrappedValue.text = $0 }),
                          axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("designer.piece.text")
                Menu {
                    ForEach(BuilderCatalog.placeholders(doc.kind), id: \.1) { label, value in
                        Button(label) { piece.wrappedValue.text = (piece.wrappedValue.text ?? "") + value }
                    }
                } label: {
                    Label("Add a detail", systemImage: "curlybraces")
                }
                if type == .text {
                    Toggle("Leave out when a detail is empty", isOn: Binding(
                        get: { piece.wrappedValue.show?["whenFilled"] != false },
                        set: { on in
                            var show = piece.wrappedValue.show ?? [:]
                            show["whenFilled"] = on ? nil : false
                            piece.wrappedValue.show = show.isEmpty ? nil : show
                        }))
                }
            } header: {
                Text("Words")
            } footer: {
                Text("Details like {{ invoice.number }} are filled in for each \(doc.kind == .order ? "order" : "invoice").")
            }
        }
        if type == .payment {
            Section("Words") {
                TextField("Above the bank details (optional)", text: optionalText(\.text), axis: .vertical)
                TextField("Under the bank details (optional)", text: optionalText(\.note), axis: .vertical)
            }
        }
        if type == .image {
            Section("Picture") {
                if let src = piece.wrappedValue.src, let image = DocumentDesign.logoData(src).flatMap(UIImage.init(data:)) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 80)
                }
                PhotosPicker(selection: $pickedImage, matching: .images) {
                    Label(piece.wrappedValue.src == nil ? "Choose a picture" : "Change the picture", systemImage: "photo")
                }
            }
        }
    }

    @ViewBuilder
    private var lines: some View {
        let p = piece.wrappedValue
        if info.label != nil || info.lines != nil {
            Section {
                if info.label != nil {
                    TextField("Small heading", text: Binding(get: { p.label ?? info.label?(doc.kind) ?? "" },
                                                             set: { piece.wrappedValue.label = $0 }))
                }
                ForEach(info.lines?(doc.kind) ?? [], id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { piece.wrappedValue.show?[key] != false }, set: { on in
                        var show = piece.wrappedValue.show ?? [:]
                        show[key] = on
                        piece.wrappedValue.show = show
                    }))
                    if BuilderCatalog.renamable.contains(p.type), key != "label", key != "method", piece.wrappedValue.show?[key] != false {
                        TextField("Printed as “\(label)”", text: Binding(
                            get: { piece.wrappedValue.names?[key] ?? "" },
                            set: { text in
                                var names = piece.wrappedValue.names ?? [:]
                                names[key] = text.isEmpty ? nil : text
                                piece.wrappedValue.names = names.isEmpty ? nil : names
                            }))
                        .font(.wsSubheadline)
                        .padding(.leading, 16)
                    }
                }
            } header: {
                Text("What it shows")
            }
        }
    }

    @ViewBuilder
    private var looks: some View {
        let type = piece.wrappedValue.type
        let shape = type == .box || type == .line
        Section("Look") {
            if !shape {
                Picker("Font", selection: Binding(get: { style.wrappedValue.font ?? "" }, set: { style.wrappedValue.font = $0.isEmpty ? nil : $0 })) {
                    Text("The page’s font").tag("")
                    ForEach(BuilderCatalog.fonts, id: \.key) { Text($0.label).tag($0.key) }
                }
                NumberRow(label: "Text size", value: double(\.size, doc.page.size), unit: "pt", range: 4...72)
                Picker("Weight", selection: double(\.weight, 400)) {
                    Text("Regular").tag(400.0)
                    Text("Semi-bold").tag(600.0)
                    Text("Bold").tag(700.0)
                    Text("Heavy").tag(800.0)
                }
                Toggle("Italic", isOn: flag(\.italic))
                Toggle("Underline", isOn: flag(\.underline))
                Toggle("Capitals", isOn: flag(\.upper))
                ColourRow(label: "Text colour", value: style.color)
                if [.customer, .delivery, .details, .amount, .totals, .payment, .notes, .terms, .vat].contains(type) {
                    ColourRow(label: "Small headings", value: style.labelColor)
                }
                Picker("Line up", selection: Binding(get: { style.wrappedValue.align ?? "left" }, set: { style.wrappedValue.align = $0 })) {
                    Text("Left").tag("left")
                    Text("Centre").tag("center")
                    Text("Right").tag("right")
                }
                .pickerStyle(.segmented)
                Picker("Up and down", selection: Binding(get: { style.wrappedValue.valign ?? "top" },
                                                         set: { style.wrappedValue.valign = $0 == "top" ? nil : $0 })) {
                    Text("Top").tag("top")
                    Text("Middle").tag("middle")
                    Text("Bottom").tag("bottom")
                }
                .pickerStyle(.segmented)
            }
            ColourRow(label: type == .line ? "Colour" : "Background", value: style.bg)
            if type != .line {
                ColourRow(label: "Border", value: style.borderColor)
                NumberRow(label: "Border width", value: double(\.borderWidth, 0), unit: "pt", step: 0.25, range: 0...6)
                NumberRow(label: "Rounded corners", value: double(\.radius, 0), unit: "pt", step: 1, range: 0...99)
                NumberRow(label: "Space inside", value: double(\.padding, 0), unit: "mm", step: 0.5, range: 0...20)
            }
            LabeledContent("See-through") {
                Slider(value: double(\.opacity, 100), in: 10...100, step: 5).frame(maxWidth: 180)
            }
        }
        if [.details, .totals, .payment].contains(type) {
            Section {
                Picker("Rows", selection: Binding(get: { style.wrappedValue.table ?? "plain" },
                                                  set: { style.wrappedValue.table = $0 == "plain" ? nil : $0 })) {
                    Text("Plain").tag("plain")
                    Text("In a grid").tag("grid")
                }
                .pickerStyle(.segmented)
                if style.wrappedValue.table == "grid" {
                    ColourRow(label: "Grid lines", value: style.gridColor)
                    ColourRow(label: "Behind the labels", value: style.labelBg)
                }
                if type == .totals && style.wrappedValue.table != "grid" {
                    ColourRow(label: "Last line’s bar", value: style.highlight)
                    if !(style.wrappedValue.highlight ?? "").isEmpty { ColourRow(label: "Bar text", value: style.highlightText) }
                }
                Toggle("Headings in normal case", isOn: flag(\.plain))
            } header: {
                Text("Rows")
            }
        }
    }

    private func optionalText(_ path: WritableKeyPath<BuilderPiece, String?>) -> Binding<String> {
        Binding(get: { piece.wrappedValue[keyPath: path] ?? "" }, set: { piece.wrappedValue[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func double(_ path: WritableKeyPath<PieceStyle, Double?>, _ fallback: Double) -> Binding<Double> {
        Binding(get: { style.wrappedValue[keyPath: path] ?? fallback }, set: { style.wrappedValue[keyPath: path] = $0 })
    }

    private func flag(_ path: WritableKeyPath<PieceStyle, Bool?>) -> Binding<Bool> {
        Binding(get: { style.wrappedValue[keyPath: path] == true }, set: { style.wrappedValue[keyPath: path] = $0 ? true : nil })
    }

    private func reorder(toFront: Bool) {
        guard doc.pieces.indices.contains(index) else { return }
        let p = doc.pieces.remove(at: index)
        if toFront { doc.pieces.append(p) } else { doc.pieces.insert(p, at: 0) }
    }

    private func pick(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let url = DocumentLookView.logoDataURL(image) else { return }
        pickedImage = nil
        piece.wrappedValue.src = url
    }
}

/// The page: fonts, paper and margins, the two bands' heights, and the footer on every page.
struct BuilderPageInspector: View {
    @Binding var doc: BuilderDoc

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $doc.page.font) {
                    ForEach(BuilderCatalog.fonts, id: \.key) { Text($0.label).tag($0.key) }
                }
                NumberRow(label: "Text size", value: $doc.page.size, unit: "pt", range: 6...16)
                ColourRow(label: "Text colour", value: Binding(get: { doc.page.color }, set: { doc.page.color = $0 ?? "" }))
            }
            Section("Paper") {
                Picker("Size", selection: $doc.page.paper) {
                    Text("A4").tag("A4")
                    Text("US Letter").tag("Letter")
                }
                .pickerStyle(.segmented)
                NumberRow(label: "Margin top and bottom", value: $doc.page.margins.tb, range: 0...50)
                NumberRow(label: "Margin left and right", value: $doc.page.margins.lr, range: 0...50)
                NumberRow(label: "Top of the page height", value: $doc.header.h, step: 1, range: 10...250)
                NumberRow(label: "Below the items height", value: $doc.after.h, step: 1, range: 0...250)
            }
            Section {
                TextField("Words at the bottom of every page", text: $doc.footer.left, axis: .vertical)
                    .lineLimit(1...3)
                Menu {
                    ForEach(BuilderCatalog.placeholders(doc.kind), id: \.1) { label, value in
                        Button(label) { doc.footer.left += value }
                    }
                } label: { Label("Add a detail", systemImage: "curlybraces") }
                Toggle("Page numbers", isOn: $doc.footer.pageNumbers)
                Toggle("In the middle", isOn: Binding(get: { doc.footer.center == true }, set: { doc.footer.center = $0 ? true : nil }))
                Toggle("A line above it", isOn: Binding(get: { doc.footer.line == true }, set: { doc.footer.line = $0 ? true : nil }))
                NumberRow(label: "Text size", value: $doc.footer.size, unit: "pt", range: 5...14)
                ColourRow(label: "Colour", value: Binding(get: { doc.footer.color }, set: { doc.footer.color = $0 ?? "" }))
            } header: {
                Text("Page footer")
            }
        }
    }
}

/// The items table: which columns show and what they're called, and how the table looks.
struct BuilderItemsInspector: View {
    @Binding var doc: BuilderDoc

    var body: some View {
        Form {
            Section {
                ForEach($doc.items.columns) { $column in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $column.show) { TextField("Heading", text: $column.label) }
                        if column.show {
                            Picker("Line up", selection: $column.align) {
                                Text("Left").tag("left")
                                Text("Centre").tag("center")
                                Text("Right").tag("right")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Columns")
            }
            Section("Look") {
                NumberRow(label: "Text size", value: $doc.items.size, unit: "pt", range: 5...14)
                ColourRow(label: "Text colour", value: Binding(get: { doc.items.color }, set: { doc.items.color = $0 ?? "" }))
                ColourRow(label: "Heading background", value: Binding(get: { doc.items.headerBg }, set: { doc.items.headerBg = $0 ?? "" }))
                ColourRow(label: "Heading text", value: Binding(get: { doc.items.headerColor }, set: { doc.items.headerColor = $0 ?? "" }))
                Toggle("Headings in capitals", isOn: $doc.items.upper)
                Toggle("Headings in the middle", isOn: Binding(get: { doc.items.headerCenter == true },
                                                               set: { doc.items.headerCenter = $0 ? true : nil }))
                ColourRow(label: "Every other row", value: Binding(get: { doc.items.stripe }, set: { doc.items.stripe = $0 ?? "" }))
                Picker("Lines", selection: $doc.items.lines) {
                    Text("Between rows").tag("rows")
                    Text("A full grid").tag("grid")
                    Text("None").tag("none")
                }
                ColourRow(label: "Line colour", value: Binding(get: { doc.items.lineColor }, set: { doc.items.lineColor = $0 ?? "" }))
                NumberRow(label: "Space in each row", value: $doc.items.padding, unit: "pt", step: 0.5, range: 0...12)
                NumberRow(label: "Space above", value: $doc.items.marginTop, range: 0...30)
                NumberRow(label: "Space below", value: $doc.items.marginBottom, range: 0...30)
            }
        }
    }
}
