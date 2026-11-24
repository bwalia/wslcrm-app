import SwiftUI

/// Write or change a blog post.
struct CMSPostEditorView: View {
    let uuid: String?
    /// After a save or delete, what to say on the screen below.
    var onSaved: (String) -> Void = { _ in }

    var body: some View {
        CMSEntryEditorView(kind: .post, uuid: uuid, onSaved: onSaved)
    }
}

/// Write or change a website page.
struct CMSPageEditorView: View {
    let uuid: String?
    /// After a save or delete, what to say on the screen below.
    var onSaved: (String) -> Void = { _ in }

    var body: some View {
        CMSEntryEditorView(kind: .page, uuid: uuid, onSaved: onSaved)
    }
}

/// The editor for a post or a page: words, content, publishing, categories and tags (posts), menu and
/// layout (pages), featured image and search engine settings. Mirrors the web's PostEditor/PageEditor.
struct CMSEntryEditorView: View {
    let kind: CMSDraft.Kind
    let uuid: String?
    let onSaved: (String) -> Void

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var record: Record?
    @State private var loadError: APIError?
    @State private var draft: CMSDraft
    @State private var saved: CMSDraft?
    @State private var categories: [Record] = []
    @State private var layouts: [Record] = []
    @State private var layoutsFailed = false
    @State private var webhooks: [Record] = []
    @State private var siteURL: String?
    @State private var saving = false
    @State private var notice: EngageNotice?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    @State private var askingCategory = false
    @State private var newCategory = ""
    @State private var websiteUpdate: CMSPublished?
    @State private var showingPreview = false

    init(kind: CMSDraft.Kind, uuid: String?, onSaved: @escaping (String) -> Void = { _ in }) {
        self.kind = kind
        self.uuid = uuid
        self.onSaved = onSaved
        _draft = State(initialValue: CMSDraft(kind: kind))
    }

    private var isNew: Bool { uuid == nil }
    private var noun: String { kind == .post ? "post" : "page" }
    private var canWrite: Bool {
        session.permissions.can(isNew ? .create : .update, moduleName: CMS.module)
    }
    private var canDelete: Bool { !isNew && session.permissions.can(.delete, moduleName: CMS.module) }
    private var dirty: Bool { saved.map { $0 != draft } ?? false }

    var body: some View {
        Group {
            if let loadError, saved == nil {
                ErrorStateView(error: loadError) { Task { await load() } }
            } else if saved == nil {
                SkeletonList()
            } else {
                form
            }
        }
        .navigationTitle(isNew ? "New \(noun)" : (canWrite ? "Edit \(noun)" : noun.capitalizedFirst))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty)
        .toolbar { toolbar }
        .task { await load() }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .confirmationDialog("Delete \(noun)", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text(kind == .post ? "Delete “\(draft.title)”? It will disappear from your site. Support can recover it."
                               : "Delete “\(draft.title)”?")
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("What you changed since you last saved will be lost.")
        }
        .alert("New category", isPresented: $askingCategory) {
            TextField("Name, e.g. Announcements", text: $newCategory)
            Button("Add category") { Task { await addCategory() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $websiteUpdate, onDismiss: { dismiss() }) { published in
            NavigationStack {
                CMSWebsiteUpdateSheet(webhooks: webhooks, post: (published.uuid, published.slug)) {}
            }
        }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                CMSEntryPreview(draft: draft, siteURL: siteURL)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPreview = false } } }
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            if !canWrite {
                Section {
                    EngageIntro(text: "You can read this \(noun). Changing it needs permission to "
                                + "\(isNew ? "add" : "change") website content.", systemImage: "lock")
                }
            }
            Section {
                TextField(kind == .post ? "Your post title" : "e.g. About us",
                          text: Binding(get: { draft.title }, set: { draft.setTitle($0) }), axis: .vertical)
                    .font(.wsHeadline)
                    .accessibilityIdentifier("cms.editor.title")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("web-address-of-this-\(noun)", text: Binding(get: { draft.slug }, set: { draft.setSlug($0) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { draft.slug = CMSSlug.make(draft.slug) }
                        .accessibilityIdentifier("cms.editor.slug")
                    Text("The end of its web address (/\(CMSSlug.make(draft.slug).isEmpty ? "…" : CMSSlug.make(draft.slug))). "
                         + "Made from the title until you change it.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                TextField("Short summary shown in lists and search results", text: $draft.excerpt, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("cms.editor.excerpt")
            } header: {
                Text("Title")
            }
            .disabled(!canWrite)
            contentSection
            publishSection
            if kind == .post {
                categoriesSection
                CMSTagsSection(draft: $draft, readOnly: !canWrite)
            } else {
                layoutSection
            }
            CMSFeaturedImageField(url: $draft.featuredImageURL, siteURL: siteURL, readOnly: !canWrite)
            if kind == .post {
                Section {
                    TextField("Defaults to you", text: $draft.authorName)
                        .accessibilityIdentifier("cms.editor.author")
                } header: {
                    Text("Author")
                }
                .disabled(!canWrite)
            }
            CMSSEOSection(draft: $draft, readOnly: !canWrite)
            factsSection
            if canDelete {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete \(noun)", systemImage: "trash")
                    }
                    .accessibilityIdentifier("cms.editor.delete")
                }
            }
        }
    }

    private var contentSection: some View {
        Section {
            NavigationLink {
                CMSContentEditorView(html: $draft.contentHTML, readOnly: !canWrite, siteURL: siteURL)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(canWrite ? "Write the content" : "Read the content").font(.wsHeadline)
                    let words = RichDocument.plainText(fromHTML: draft.contentHTML)
                    Text(words.isEmpty ? "Nothing written yet." : words)
                        .font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(3)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("cms.editor.content")
            Button { showingPreview = true } label: { Label("Preview", systemImage: "eye") }
                .accessibilityIdentifier("cms.editor.preview")
        } header: {
            Text("Content")
        }
    }

    private var publishSection: some View {
        Section {
            Picker("Status", selection: $draft.status) {
                ForEach(kind == .post ? CMSPostStatus.allCases : CMSPostStatus.pageCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("cms.editor.status")
            if kind == .post, draft.status == .scheduled {
                DatePicker("Publish on", selection: Binding(get: { draft.scheduledAt ?? Date().addingTimeInterval(3600) },
                                                            set: { draft.scheduledAt = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("cms.editor.scheduled")
            }
            if kind == .post {
                Picker("Who can read it", selection: $draft.visibility) {
                    ForEach(CMSVisibility.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("cms.editor.visibility")
                Toggle(isOn: $draft.isFeatured) { Label("Featured post", systemImage: "star") }
                    .accessibilityIdentifier("cms.editor.featured")
            } else {
                Toggle("Show in the website’s menu", isOn: $draft.showInNav)
                    .accessibilityIdentifier("cms.editor.nav")
                Stepper("Menu order: \(draft.menuOrder)", value: $draft.menuOrder, in: -999...999)
                    .accessibilityIdentifier("cms.editor.order")
            }
        } header: {
            Text("Publish")
        } footer: {
            Text(kind == .post ? "Published posts show on your website. Scheduled ones go live at the time you choose."
                               : "Pages with a lower menu order come first in the menu.")
        }
        .disabled(!canWrite)
    }

    private var categoriesSection: some View {
        Section {
            if categories.isEmpty {
                Text("No categories yet.").foregroundStyle(.secondaryText)
            }
            ForEach(categories) { category in
                Toggle(category.string("name") ?? "Category", isOn: Binding(
                    get: { draft.categoryUUIDs.contains(category.id) },
                    set: { on in
                        if on { draft.categoryUUIDs.append(category.id) } else { draft.categoryUUIDs.removeAll { $0 == category.id } }
                    }))
                .accessibilityIdentifier("cms.editor.category.\(category.id)")
            }
            if canWrite, session.permissions.can(.create, moduleName: CMS.module) {
                Button {
                    newCategory = ""
                    askingCategory = true
                } label: {
                    Label("Add a category", systemImage: "plus")
                }
                .accessibilityIdentifier("cms.editor.addCategory")
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("A post can belong to several categories.")
        }
        .disabled(!canWrite)
    }

    private var layoutSection: some View {
        Section {
            Picker("Layout", selection: $draft.template) {
                Text("Default (the content as written)").tag("default")
                ForEach(layouts) { layout in
                    let slug = layout.string("slug") ?? layout.id
                    Text((layout.string("name") ?? slug) + ((layout.bool("is_default") ?? false) ? " (default)" : ""))
                        .tag(slug)
                }
                if draft.template != "default", !layouts.contains(where: { $0.string("slug") == draft.template }) {
                    Text(draft.template).tag(draft.template)
                }
            }
            .accessibilityIdentifier("cms.editor.layout")
        } header: {
            Text("Layout")
        } footer: {
            Text(layoutsFailed ? "The page layouts couldn’t be listed (that needs permission to see templates). The page "
                                 + "keeps the layout it has."
                               : "The layout the public website shows this page in.")
        }
        .disabled(!canWrite)
    }

    @ViewBuilder
    private var factsSection: some View {
        if let record, !isNew {
            Section("About this \(noun)") {
                if kind == .post {
                    DetailRow(label: "Views", value: record.int("view_count").map { $0.formatted() })
                    DetailRow(label: "Reading time", value: record.int("reading_minutes").map { "\($0) min" })
                    DetailRow(label: "Written by", value: record.string("author_name"))
                }
                DetailRow(label: "Published", value: EngageFormat.dateTime(record.string("published_at")))
                if kind == .post, record.string("status") == "scheduled" {
                    DetailRow(label: "Scheduled for", value: EngageFormat.dateTime(record.string("scheduled_at")))
                }
                DetailRow(label: "Created", value: EngageFormat.dateTime(record.string("created_at")))
                DetailRow(label: "Last changed", value: EngageFormat.dateTime(record.string("updated_at")))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if dirty {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { confirmingDiscard = true }
                    .accessibilityIdentifier("cms.editor.cancel")
            }
        }
        if canWrite, saved != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : (draft.status == .published ? "Publish" : "Save")) {
                    Task { await save(status: nil) }
                }
                .disabled(saving)
                .accessibilityIdentifier("cms.editor.save")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await save(status: .draft) } } label: { Label("Save as draft", systemImage: "tray.and.arrow.down") }
                        .accessibilityIdentifier("cms.editor.saveDraft")
                    Button { showingPreview = true } label: { Label("Preview", systemImage: "eye") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(saving)
            }
        }
    }

    // MARK: Work

    private func load() async {
        async let config = try? services.cms.mediaConfig()
        if kind == .post {
            async let cats = try? services.cms.categories()
            async let hooks = try? services.cms.webhooks()
            categories = await cats ?? []
            webhooks = await hooks ?? []
        } else {
            do { layouts = try await services.cms.pageLayouts() } catch { layoutsFailed = true }
        }
        let mediaConfig = await config
        siteURL = mediaConfig?.string("site_url")
        guard saved == nil else { return }
        guard let uuid else {
            saved = draft
            return
        }
        do {
            let loaded = kind == .post ? try await services.cms.post(uuid) : try await services.cms.page(uuid)
            record = loaded
            draft = CMSDraft(kind: kind, record: loaded)
            saved = draft
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func save(status override: CMSPostStatus?) async {
        let effective = override ?? draft.status
        if let problem = draft.problem(saving: effective) {
            notice = .info(problem)
            return
        }
        saving = true
        defer { saving = false }
        let contentChanged = saved.map { $0.contentHTML != draft.contentHTML } ?? true
        let body = draft.body(status: override, isNew: isNew, contentChanged: contentChanged)
        do {
            let result: Record
            switch (kind, uuid) {
            case (.post, nil): result = try await services.cms.createPost(body)
            case (.post, let uuid?): result = try await services.cms.updatePost(uuid, body)
            case (.page, nil): result = try await services.cms.createPage(body)
            case (.page, let uuid?): result = try await services.cms.updatePage(uuid, body)
            }
            record = result
            if let override { draft.status = override }
            saved = draft
            let message = effective == .published ? "\(noun.capitalizedFirst) published."
                : (isNew ? "\(noun.capitalizedFirst) created." : "\(noun.capitalizedFirst) saved.")
            onSaved(message)
            notice = .done(message)
            // On publish, offer to update the website (never automatic), as the web does.
            // Sending a website update is cms.update (routes/cms-webhooks.lua trigger).
            if kind == .post, effective == .published, !webhooks.isEmpty, session.permissions.can(.update, moduleName: CMS.module) {
                websiteUpdate = CMSPublished(uuid: result.string("uuid"), slug: result.string("slug"))
            } else {
                dismiss()
            }
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        guard let uuid else { return }
        do {
            if kind == .post { try await services.cms.deletePost(uuid) } else { try await services.cms.deletePage(uuid) }
            onSaved("\(noun.capitalizedFirst) deleted.")
            saved = draft
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func addCategory() async {
        guard let name = newCategory.trimmedOrNil else { return }
        do {
            let category = try await services.cms.createCategory(name: name)
            categories = (try? await services.cms.categories()) ?? (categories + [category])
            draft.categoryUUIDs.append(category.id)
            notice = .done("Category “\(name)” added and ticked.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// A post that was just published, for the "update your website" question.
struct CMSPublished: Identifiable, Equatable {
    let uuid: String?
    let slug: String?
    var id: String { (uuid ?? "") + (slug ?? "") }
}

/// How the post or page reads: title, summary, featured image and content, drawn natively.
struct CMSEntryPreview: View {
    let draft: CMSDraft
    let siteURL: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url = CMSMedia.displayURL(draft.featuredImageURL, siteURL: siteURL) {
                    RichImage(url: url, alt: "Featured image")
                }
                Text(draft.title.isEmpty ? "Untitled" : draft.title).font(.wsTitle).accessibilityAddTraits(.isHeader)
                if !draft.excerpt.isEmpty {
                    Text(draft.excerpt).font(.wsCallout).foregroundStyle(.secondaryText)
                }
                if draft.kind == .post, !draft.tags.isEmpty {
                    Text(draft.tags.map { "#\($0)" }.joined(separator: "  ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                Divider()
                if draft.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing written yet.").foregroundStyle(.secondaryText)
                } else {
                    RichTextView(html: CMSPreview.resolve(draft.contentHTML, siteURL: siteURL), linksOpen: false)
                }
                Text("Drawn by the app. Your website uses its own fonts, colours and layout, so it may look different there.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .padding()
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }
}
