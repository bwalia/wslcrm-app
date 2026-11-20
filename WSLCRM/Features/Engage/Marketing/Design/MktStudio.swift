import SwiftUI

/// The message studio and the templates list: reusable email and SMS templates, made from
/// ready-made designs, with AI, or from scratch, then published for campaigns.
struct MktTemplatesListView: View {
    enum Mode { case studio, templates }

    let mode: Mode
    /// Opened from inside another sheet (the design gallery): links to other marketing screens are hidden there.
    var embedded = false
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: PagedListModel<MktTemplate>?
    @State private var filters = MktTemplateFilters()
    @State private var opening: MktTemplate?
    @State private var choosingDesign = false
    @State private var notice: EngageNotice?
    @State private var busy = false
    @State private var deleting: MktTemplate?
    @State private var hasAppeared = false
    @State private var showingMergeFields = false

    private func can(_ action: Action) -> Bool { session.permissions.can(action, moduleName: Marketing.RBAC.templates) }

    var body: some View {
        Group {
            if let model {
                list(model)
            } else {
                SkeletonList()
            }
        }
        .navigationTitle(mode == .studio ? "Message studio" : "Templates")
        .onAppear {
            if model == nil {
                let source = filters
                let api = services.marketingDesign
                model = PagedListModel { search, page in
                    try await api.templates(search: search, page: page, channel: source.channel, status: source.status)
                }
            } else if hasAppeared {
                Task { await model?.load() }
            }
            hasAppeared = true
        }
    }

    @ViewBuilder
    private func list(_ model: PagedListModel<MktTemplate>) -> some View {
        PagedList(model: model, searchPrompt: "Search templates", emptyTitle: "No templates yet",
                  emptySystemImage: "paintpalette",
                  emptyDescription: can(.create) ? "Press + to add the ready-made templates, create one with AI, or start "
                      + "from a blank page." : "Templates your team makes appear here.") { template in
            NavigationLink {
                MktTemplateEditorView(initial: template) { _ in Task { await model.load() } }
            } label: {
                MktTemplateRow(template: template)
            }
            .accessibilityIdentifier("mkt.template.\(template.uuid)")
            .swipeActions(edge: .trailing) {
                if can(.delete) {
                    Button(role: .destructive) { deleting = template } label: { Label("Delete", systemImage: "trash") }
                }
                if can(.create) {
                    Button { Task { await copy(template, model) } } label: { Label("Copy", systemImage: "plus.square.on.square") }
                        .tint(.indigo)
                }
            }
            .swipeActions(edge: .leading) {
                if can(.update), template.status != "published" {
                    Button { Task { await publish(template, model) } } label: { Label("Publish", systemImage: "paperplane") }
                        .tint(.green)
                }
            }
            .contextMenu {
                if can(.update), template.status != "published" {
                    Button { Task { await publish(template, model) } } label: { Label("Publish", systemImage: "paperplane") }
                }
                if can(.create) {
                    Button { Task { await copy(template, model) } } label: { Label("Make a copy", systemImage: "plus.square.on.square") }
                }
                if can(.update) {
                    if template.status == "archived" {
                        Button { Task { await setStatus(template, "draft", model) } } label: {
                            Label("Bring back as a draft", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button { Task { await setStatus(template, "archived", model) } } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                }
                if can(.delete) {
                    Button(role: .destructive) { deleting = template } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        // New filters make a new list (its first page loads when it appears).
        .id(filters)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if notice == nil {
                    HStack(alignment: .top) {
                        EngageIntro(text: mode == .studio
                                    ? "Design templates you can reuse. Change the words like a normal document, add "
                                        + "pictures, then Publish."
                                    : "Your saved email and text message templates. Open one to change it in the studio.")
                        if !embedded {
                            Spacer(minLength: 8)
                            NavigationLink(value: NativeScreenRoute(Marketing.Screen.guide)) {
                                Label("Help", systemImage: "questionmark.circle").font(.wsSubheadline)
                            }
                            .accessibilityIdentifier("mkt.studio.help")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
                EngageNoticeBar(notice: notice)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu(model) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingMergeFields = true } label: {
                    Label("Personalisation fields", systemImage: "person.text.rectangle")
                }
                .accessibilityIdentifier("mkt.studio.mergeFields")
            }
            if can(.create) {
                ToolbarItem(placement: .primaryAction) { newMenu(model) }
            }
        }
        .navigationDestination(isPresented: $showingMergeFields) { MktTemplateMergeFieldsView() }
        .navigationDestination(item: $opening) { template in
            MktTemplateEditorView(initial: template) { _ in Task { await model.load() } }
        }
        .sheet(isPresented: $choosingDesign) {
            NavigationStack {
                MktDesignGallery(channel: "email") { design in
                    opening = MktTemplate(name: design.name, channel: "email", subject: design.subject,
                                          previewText: design.previewText, bodyHTML: design.bodyHTML,
                                          bodyText: design.bodyText)
                }
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete template", role: .destructive) {
                if let template = deleting { Task { await delete(template, model) } }
            }
        } message: {
            Text("Campaigns that already used it keep their own copy of the words. This can’t be undone.")
        }
    }

    private func newMenu(_ model: PagedListModel<MktTemplate>) -> some View {
        Menu {
            Button { opening = MktTemplate(bodyHTML: "<p>Hi {{contact.first_name}},</p><p></p>",
                                           bodyText: "Hi {{contact.first_name}},") } label: {
                Label("New email template", systemImage: "envelope")
            }
            Button { opening = MktTemplate(channel: "sms", bodyText: "Hi {{contact.first_name}}, … Reply STOP to opt out.") } label: {
                Label("New text message template", systemImage: "message")
            }
            Button { choosingDesign = true } label: {
                Label("Start from a design or with AI", systemImage: "wand.and.stars")
            }
            Button { Task { await seed(model) } } label: {
                Label("Add ready-made templates", systemImage: "sparkles")
            }
            .disabled(busy)
        } label: {
            Label("New template", systemImage: "plus")
        }
        .accessibilityIdentifier("mkt.studio.new")
    }

    private func filterMenu(_ model: PagedListModel<MktTemplate>) -> some View {
        Menu {
            Picker("Channel", selection: Binding(get: { filters.channel ?? "" }, set: { value in
                filters.channel = value.isEmpty ? nil : value
                reload(model)
            })) {
                Text("All channels").tag("")
                Text("Email").tag("email")
                Text("Text message").tag("sms")
            }
            Picker("Status", selection: Binding(get: { filters.status ?? "" }, set: { value in
                filters.status = value.isEmpty ? nil : value
                reload(model)
            })) {
                Text("Any status").tag("")
                Text("Draft").tag("draft")
                Text("Published").tag("published")
                Text("Archived").tag("archived")
            }
        } label: {
            Label("Filter", systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("mkt.studio.filter")
    }

    private func reload(_ old: PagedListModel<MktTemplate>) {
        let source = filters
        let api = services.marketingDesign
        let fresh = PagedListModel { search, page in
            try await api.templates(search: search, page: page, channel: source.channel, status: source.status)
        }
        fresh.search = old.search
        model = fresh
    }

    private func run(_ work: () async throws -> String, _ model: PagedListModel<MktTemplate>) async {
        busy = true
        defer { busy = false }
        do {
            notice = .done(try await work())
            await model.load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func seed(_ model: PagedListModel<MktTemplate>) async {
        await run({
            let added = try await services.marketingDesign.seed()
            return added > 0 ? "\(added) ready-made template\(added == 1 ? "" : "s") added."
                : "You already have all the ready-made templates."
        }, model)
    }

    private func publish(_ template: MktTemplate, _ model: PagedListModel<MktTemplate>) async {
        do {
            _ = try await services.marketingDesign.publish(template.uuid)
            notice = .done("“\(template.name)” is published.")
            await model.load()
        } catch {
            let apiError = error.asAPIError
            if let message = apiError.serverError.flatMap({ MktTemplateWarnings.publishProblem($0.message) }) {
                notice = .info(message)
            } else {
                notice = .failed(apiError)
            }
        }
    }

    private func copy(_ template: MktTemplate, _ model: PagedListModel<MktTemplate>) async {
        await run({
            let copy = try await services.marketingDesign.clone(template.uuid, name: nil)
            return "Copied as “\(copy?.name ?? "\(template.name) (copy)")”."
        }, model)
    }

    private func setStatus(_ template: MktTemplate, _ status: String, _ model: PagedListModel<MktTemplate>) async {
        await run({
            _ = try await services.marketingDesign.update(template.uuid, ["status": .string(status)])
            return status == "archived" ? "“\(template.name)” archived." : "“\(template.name)” is a draft again."
        }, model)
    }

    private func delete(_ template: MktTemplate, _ model: PagedListModel<MktTemplate>) async {
        await run({
            try await services.marketingDesign.delete(template.uuid)
            return "“\(template.name)” deleted."
        }, model)
    }
}

struct MktTemplateFilters: Hashable {
    var channel: String?
    var status: String?
    var isEmpty: Bool { channel == nil && status == nil }
}

struct MktTemplateRow: View {
    let template: MktTemplate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: template.isEmail ? "envelope" : "message")
                .foregroundStyle(.secondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name).font(.wsHeadline).lineLimit(2)
                Text(subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                StatusBadge(text: MktTemplate.statusStyle.label(for: template.status),
                            systemImage: MktTemplate.statusStyle.symbol(for: template.status),
                            tone: MktTemplate.statusStyle.tone(for: template.status))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [template.isEmail ? "Email" : "Text message"]
        if let version = template.version, version > 1 { parts.append("version \(version)") }
        if !template.subject.isEmpty { parts.append(MktEmailSample.fill(template.subject)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - One template

/// A template in the studio: its words, design, plain-text version and checks; save, preview, publish.
struct MktTemplateEditorView: View {
    let onChanged: (MktTemplate?) -> Void

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var template: MktTemplate
    @State private var saved: MktTemplate
    @State private var warnings: [String] = []
    @State private var notice: EngageNotice?
    @State private var busy = false
    @State private var preview: MktTemplatePreview?
    @State private var mergeFields: [MktTemplateMergeField] = MktEmailBlockEditor.builtInMergeFields
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false

    init(initial: MktTemplate, onChanged: @escaping (MktTemplate?) -> Void = { _ in }) {
        self.onChanged = onChanged
        _template = State(initialValue: initial)
        _saved = State(initialValue: initial)
    }

    private var isNew: Bool { saved.uuid.isEmpty }
    private var hasChanges: Bool { isNew || template != saved }
    private func can(_ action: Action) -> Bool { session.permissions.can(action, moduleName: Marketing.RBAC.templates) }
    private var canWrite: Bool { isNew ? can(.create) : can(.update) }

    var body: some View {
        Form {
            if !isNew {
                Section {
                    HStack {
                        StatusBadge(text: MktTemplate.statusStyle.label(for: saved.status),
                                    systemImage: MktTemplate.statusStyle.symbol(for: saved.status),
                                    tone: MktTemplate.statusStyle.tone(for: saved.status))
                        Spacer()
                        if let version = saved.version { Text("Version \(version)").font(.wsFootnote).foregroundStyle(.secondaryText) }
                    }
                    if let published = EngageFormat.dateTime(saved.publishedAt) {
                        LabeledContent("Published", value: published)
                    }
                    if let updated = EngageFormat.dateTime(saved.updatedAt) {
                        LabeledContent("Last changed", value: updated)
                    }
                }
            }
            Section {
                TextField("Name", text: $template.name)
                    .accessibilityIdentifier("mkt.template.name")
                Picker("Channel", selection: $template.channel) {
                    Text("Email").tag("email")
                    Text("Text message (SMS)").tag("sms")
                }
                .accessibilityIdentifier("mkt.template.channel")
            } header: {
                Text("Template")
            }
            if template.isEmail { emailSections } else { smsSections }
            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label(MktTemplateWarnings.describe(warning), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tone.warning.textColor)
                    }
                } header: {
                    Text("Things to check")
                }
            }
            actionsSection
        }
        .disabled(busy)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle(isNew ? "New template" : template.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges && canWrite)
        .toolbar {
            if hasChanges && canWrite {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmingLeave = true } label: { Label("Back", systemImage: "chevron.backward") }
                        .accessibilityIdentifier("mkt.template.back")
                }
            }
            if canWrite {
                ToolbarItem(placement: .primaryAction) {
                    Button(busy ? "Saving…" : "Save draft") { Task { await save() } }
                        .accessibilityIdentifier("mkt.template.save")
                }
            }
        }
        .task {
            if let fields = try? await services.marketingDesign.mergeFields(), !fields.isEmpty { mergeFields = fields }
        }
        .sheet(item: $preview) { preview in
            NavigationStack { MktTemplatePreviewView(preview: preview) }
        }
        .confirmationDialog("Leave without saving?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Save draft and leave") { Task { if await save() { dismiss() } } }
            Button("Leave without saving", role: .destructive) { dismiss() }
        } message: {
            Text("Your changes to this template aren’t saved yet.")
        }
        .confirmationDialog("Delete “\(saved.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete template", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Campaigns that already used it keep their own copy of the words. This can’t be undone.")
        }
    }

    // MARK: Email

    @ViewBuilder
    private var emailSections: some View {
        Section {
            TextField("{{contact.first_name}}, your update", text: $template.subject, axis: .vertical)
                .accessibilityIdentifier("mkt.template.subject")
            TextField("Preview text (shown after the subject in the inbox)", text: $template.previewText, axis: .vertical)
                .accessibilityIdentifier("mkt.template.previewText")
            personaliseMenu
        } header: {
            Text("Subject")
        } footer: {
            Text("\(template.subject.count) characters. Inboxes show about 78.")
        }
        Section {
            NavigationLink {
                MktEmailEditor(html: $template.bodyHTML, readOnly: !canWrite)
            } label: {
                Label(canWrite ? "Change the design" : "See the design", systemImage: "paintbrush")
            }
            .accessibilityIdentifier("mkt.template.design")
            if MktEmailHTML.plainText(template.bodyHTML).isEmpty {
                Text("The email is empty.").foregroundStyle(.secondaryText)
            } else {
                RichTextView(html: MktEmailSample.fill(template.bodyHTML), appearance: .email, linksOpen: false)
                    .frame(maxHeight: 360, alignment: .top)
                    .clipped()
                    .allowsHitTesting(false)
            }
        } header: {
            Text("Design")
        }
        Section {
            TextField("The words without the design", text: $template.bodyText, axis: .vertical)
                .lineLimit(3...10)
                .font(.system(.footnote, design: .monospaced))
                .accessibilityIdentifier("mkt.template.bodyText")
            if canWrite {
                Button { template.bodyText = Self.plainVersion(of: template.bodyHTML) } label: {
                    Label("Make it from the design", systemImage: "text.badge.plus")
                }
            }
        } header: {
            Text("Plain-text version")
        } footer: {
            Text("Shown by mail apps that don’t show designs.")
        }
    }

    // MARK: SMS

    @ViewBuilder
    private var smsSections: some View {
        Section {
            TextField("Hi {{contact.first_name}}… Reply STOP to opt out.", text: $template.bodyText, axis: .vertical)
                .lineLimit(4...12)
                .onChange(of: template.bodyText) { _, value in
                    if value.count > 1600 { template.bodyText = String(value.prefix(1600)) }
                }
                .accessibilityIdentifier("mkt.template.sms")
            personaliseMenu
        } header: {
            Text("Text message")
        } footer: {
            Text(template.bodyText.count > 160
                 ? "\(template.bodyText.count)/1600. Over 160 characters, so it is sent as more than one text."
                 : "\(template.bodyText.count)/1600.")
        }
    }

    private var personaliseMenu: some View {
        Menu {
            ForEach(mergeFields) { field in
                Menu("Insert \(field.label.lowercased())") {
                    if template.isEmail {
                        Button("Into the subject") { template.subject += field.token }
                        Button("Into the email’s last paragraph") { template.bodyHTML = Self.appendToLastParagraph(template.bodyHTML, field.token) }
                        Button("Into the plain-text version") { template.bodyText += field.token }
                    } else {
                        Button("Into the message") { template.bodyText += field.token }
                    }
                }
            }
        } label: {
            Label("Personalise", systemImage: "person.text.rectangle")
        }
        .disabled(!canWrite)
        .accessibilityIdentifier("mkt.template.personalise")
    }

    // MARK: Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button { Task { await runPreview() } } label: { Label("Preview", systemImage: "eye") }
                .accessibilityIdentifier("mkt.template.preview")
            Button { Task { await check() } } label: { Label("Check for problems", systemImage: "checkmark.shield") }
                .accessibilityIdentifier("mkt.template.check")
            if canWrite {
                Button { Task { await save() } } label: { Label("Save draft", systemImage: "square.and.arrow.down") }
            }
            if (isNew && can(.create)) || (!isNew && can(.update)) {
                Button { Task { await publish() } } label: { Label("Publish", systemImage: "paperplane") }
                    .accessibilityIdentifier("mkt.template.publish")
            }
            if !isNew, can(.create) {
                Button { Task { await copy() } } label: { Label("Make a copy", systemImage: "plus.square.on.square") }
            }
            if !isNew, can(.update) {
                if saved.status == "archived" {
                    Button { Task { await setStatus("draft") } } label: {
                        Label("Bring back as a draft", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button { Task { await setStatus("archived") } } label: { Label("Archive", systemImage: "archivebox") }
                }
            }
            if !isNew, can(.delete) {
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete template", systemImage: "trash") }
            }
        } footer: {
            Text("Saving makes it a draft. Publish it when it’s ready: publishing checks it and makes it safe for email.")
        }
    }

    // MARK: Work

    @discardableResult
    private func save() async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let api = services.marketingDesign
            if isNew {
                let created = try await api.create(template)
                saved = created
                template = created
                warnings = (try? await api.analyse(created)) ?? []
            } else {
                if template.channel != saved.channel {
                    _ = try await api.update(template.uuid, ["channel": .string(template.channel)])
                }
                let (result, found) = try await api.saveStudio(template, status: "draft")
                saved = result
                template = result
                warnings = found
            }
            notice = .done("Saved as a draft.")
            onChanged(saved)
            return true
        } catch {
            notice = .failed(error.asAPIError)
            return false
        }
    }

    private func publish() async {
        guard await save() else { return }
        busy = true
        defer { busy = false }
        do {
            if let published = try await services.marketingDesign.publish(saved.uuid) {
                saved = published
                template = published
            }
            notice = .done("Published. It’s ready to use in campaigns.")
            onChanged(saved)
        } catch {
            let apiError = error.asAPIError
            if let message = apiError.serverError.flatMap({ MktTemplateWarnings.publishProblem($0.message) }) {
                notice = .info(message)
                warnings = (try? await services.marketingDesign.analyse(template)) ?? warnings
            } else {
                notice = .failed(apiError)
            }
        }
    }

    private func runPreview() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await services.marketingDesign.preview(template)
            if result.isEmpty {
                notice = .info("The preview came back empty. Save the draft, then preview again.")
                return
            }
            warnings = result.warnings
            preview = result
            notice = nil
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func check() async {
        busy = true
        defer { busy = false }
        do {
            warnings = try await services.marketingDesign.analyse(template)
            notice = warnings.isEmpty ? .done("No problems found.") : .info("Some things to check are listed below.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func copy() async {
        do {
            let copy = try await services.marketingDesign.clone(saved.uuid, name: nil)
            notice = .done("Copied as “\(copy?.name ?? "\(saved.name) (copy)")”. Find it in the list.")
            onChanged(copy)
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func setStatus(_ status: String) async {
        do {
            if let updated = try await services.marketingDesign.update(saved.uuid, ["status": .string(status)]) {
                saved.status = updated.status
                template.status = updated.status
            }
            notice = .done(status == "archived" ? "Archived." : "It’s a draft again.")
            onChanged(saved)
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        do {
            try await services.marketingDesign.delete(saved.uuid)
            onChanged(nil)
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    // MARK: Helpers (tested)

    /// Adds a merge field to the end of the email's last paragraph (a new paragraph when there is none).
    static func appendToLastParagraph(_ html: String, _ token: String) -> String {
        var document = MktEmailDocument.parse(html)
        if let index = document.blocks.lastIndex(where: { $0.kind == .paragraph && !$0.simplified }) {
            var block = document.blocks[index]
            block.text += " \(token)"
            block.original = nil
            document.blocks[index] = block
        } else {
            document.blocks.append(.newParagraph(token))
        }
        return document.html
    }

    /// The words of the design, one block per paragraph (for the plain-text version).
    static func plainVersion(of html: String) -> String {
        MktEmailDocument.parse(html).blocks.compactMap { block -> String? in
            switch block.kind {
            case .list:
                return block.items.enumerated().map { index, item in
                    (block.ordered ? "\(index + 1). " : "- ") + MktEmailHTML.plainText(item)
                }.joined(separator: "\n")
            case .button:
                return "\(block.text): \(block.href)"
            case .image, .divider, .spacer:
                return nil
            default:
                let text = block.summary
                return text.isEmpty ? nil : text
            }
        }.joined(separator: "\n\n")
    }
}

/// The server's preview of a template, as Alex Example would get it.
struct MktTemplatePreviewView: View {
    let preview: MktTemplatePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Sample recipient: Alex Example. Personal details are filled with example data; nothing is sent.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                LabeledContent("Subject", value: preview.subject.trimmingCharacters(in: .whitespaces).isEmpty ? "(none)"
                               : preview.subject)
                if preview.opensEstimated {
                    Text("Opens are estimated for email: some mail apps block the tracking picture.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Section("Message") {
                if !preview.html.isEmpty {
                    RichTextView(html: preview.html, appearance: .email, linksOpen: false)
                } else {
                    Text(preview.text.isEmpty ? "(empty)" : preview.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if !preview.warnings.isEmpty {
                Section("Things to check") {
                    ForEach(preview.warnings, id: \.self) { warning in
                        Label(MktTemplateWarnings.describe(warning), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tone.warning.textColor)
                    }
                }
            }
            if !preview.html.isEmpty {
                Section { MktEmailPreviewLimits() }
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

extension MktTemplatePreview: Identifiable {
    var id: Int { hashValue }
}

// MARK: - Personalisation fields

/// The personal details messages can include, and adding the workspace's own.
struct MktTemplateMergeFieldsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var fields: [Record]?
    @State private var error: APIError?
    @State private var adding = false
    @State private var notice: EngageNotice?

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Put these in a subject or message, like {{contact.first_name}}: each person gets "
                            + "their own. Only these may be used.")
            }
            if let error, fields == nil {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            if let fields {
                Section("Fields") {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.string("label") ?? field.id).font(.wsHeadline)
                            Text("{{\(field.string("key") ?? "")}}").font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            let details = [field.string("field_type").map(Formatters.humanize),
                                           field.string("default_value").map { "If missing: \($0)" },
                                           field.bool("allow_html") == true ? "Can hold formatting" : nil].compactMap { $0 }
                            if !details.isEmpty {
                                Text(details.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .contextMenu {
                            Button { UIPasteboard.general.string = "{{\(field.string("key") ?? "")}}" } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            } else if error == nil {
                Section { ProgressView() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle("Personalisation fields")
        .toolbar {
            if session.permissions.can(.create, moduleName: Marketing.RBAC.templates) {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add a field", systemImage: "plus") }
                        .accessibilityIdentifier("mkt.mergeFields.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                MktTemplateMergeFieldForm { message in
                    notice = .done(message)
                    Task { await load() }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            fields = try await services.engage.get(Marketing.path("/merge-fields")).engageRecords
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }
}

/// A new personal detail (`POST /merge-fields`).
private struct MktTemplateMergeFieldForm: View {
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @State private var key = "custom."
    @State private var label = ""
    @State private var type = "string"
    @State private var source = ""
    @State private var fallback = ""
    @State private var allowHTML = false
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                TextField("e.g. custom.loyalty_tier", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.mergeField.key")
                TextField("Name people see, e.g. Loyalty tier", text: $label)
                    .accessibilityIdentifier("mkt.mergeField.label")
                Picker("Kind", selection: $type) {
                    Text("Words").tag("string")
                    Text("Number").tag("number")
                    Text("Date").tag("date")
                    Text("Yes or no").tag("boolean")
                    Text("Money").tag("currency")
                }
            } footer: {
                Text("The key is what goes between {{ and }} in a message.")
            }
            Section {
                TextField("Where the value comes from (leave empty to use the key)", text: $source)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Used when a person has no value", text: $fallback)
                Toggle("Can hold formatting (HTML)", isOn: $allowHTML)
            }
        }
        .navigationTitle("Add a field")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(saving || key.trimmingCharacters(in: .whitespaces).isEmpty || label.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("mkt.mergeField.save")
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = [
            "key": .string(key.trimmingCharacters(in: .whitespaces)), "label": .string(label.trimmingCharacters(in: .whitespaces)),
            "field_type": .string(type), "allow_html": .bool(allowHTML),
        ]
        if let source = source.trimmedOrNil { body["source_path"] = .string(source) }
        if let fallback = fallback.trimmedOrNil { body["default_value"] = .string(fallback) }
        do {
            try await services.engage.post(Marketing.path("/merge-fields"), .object(body))
            done("“\(label)” added. Use it as {{\(key)}}.")
            dismiss()
        } catch {
            let apiError = error.asAPIError
            switch apiError.serverError?.message {
            case "invalid key":
                self.error = ResourceService.problem(422, "Use only letters, numbers, dots and underscores in the key.")
            case "forbidden field":
                self.error = ResourceService.problem(422, "That key looks like private information (a password, an ID "
                                                     + "or medical details), so it can’t be used in messages.")
            default:
                self.error = apiError
            }
        }
    }
}
