import SwiftUI

/// Forms (`/dashboard/forms`): every form of the workspace — search, status filter, and per form: edit,
/// copy or share its link, fill it in, duplicate, close or reopen, delete. New forms start blank, from a
/// template, or from an AI draft. Owners of the module also set the custom domain and spam protection.
struct WebFormsHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var forms: [WebFormDetail] = []
    @State private var next: String?
    @State private var state: LoadState<Void> = .idle
    @State private var loadingMore = false
    @State private var search = ""
    @State private var status = ""
    @State private var notice: EngageNotice?
    @State private var creating = false
    @State private var opened: WebFormOpenRoute?
    @State private var filling: WebFormDetail?
    @State private var deleting: WebFormDetail?
    @State private var showingDomain = false
    @State private var showingSpam = false
    @State private var hasAppeared = false

    private var api: WebFormsAPI { services.webForms }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: WebFormsAPI.module) }
    private var canUpdate: Bool { session.permissions.can(.update, moduleName: WebFormsAPI.module) }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: WebFormsAPI.module) }
    private var canManage: Bool { session.permissions.can(.manage, moduleName: WebFormsAPI.module) }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Build a form, share its link, and turn every response into a customer, lead or "
                            + "teammate.")
            }
            ForEach(forms) { form in
                NavigationLink {
                    WebFormEditorView(uuid: form.uuid)
                } label: {
                    WebFormRow(form: form)
                }
                .accessibilityIdentifier("forms.row.\(form.uuid)")
                .contextMenu { menu(form) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canDelete {
                        Button(role: .destructive) { deleting = form } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { copy(form) } label: { Label("Copy link", systemImage: "link") }.tint(.blue)
                }
                .task { await loadMoreIfNeeded(form) }
            }
            if loadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
        }
        .listStyle(.plain)
        .overlay { overlay }
        .navigationTitle("Forms")
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .searchable(text: $search, prompt: "Search forms")
        .refreshable { await load() }
        .task(id: "\(search)|\(status)") {
            if hasAppeared { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .onAppear {
            // Back from a form: it may have changed there.
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
        .toolbar { toolbar }
        .sheet(isPresented: $creating) {
            NavigationStack {
                WebFormNewFormView { created in
                    opened = WebFormOpenRoute(uuid: created.uuid)
                    Task { await load() }
                }
            }
        }
        .sheet(item: $filling) { form in
            NavigationStack { WebFormLiveFillView(publicID: form.publicID, title: form.title) }
        }
        .sheet(isPresented: $showingDomain) {
            NavigationStack { WebFormDomainView { Task { await load() } } }
        }
        .sheet(isPresented: $showingSpam) {
            NavigationStack { WebFormSpamProtectionView() }
        }
        .navigationDestination(item: $opened) { route in WebFormEditorView(uuid: route.uuid) }
        .confirmationDialog("Delete form", isPresented: Binding(get: { deleting != nil },
                                                                set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            if let form = deleting {
                Button("Delete", role: .destructive) { Task { await delete(form) } }
            }
        } message: {
            Text("Delete “\(deleting?.title ?? "")”? Its link stops working at once; its responses are removed after "
                 + "30 days.")
        }
    }

    // MARK: Pieces

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Show", selection: $status) {
                    Text("All forms").tag("")
                    Text("Live").tag("published")
                    Text("Drafts").tag("draft")
                    Text("Closed").tag("closed")
                }
                if canManage {
                    Divider()
                    Button { showingDomain = true } label: { Label("Custom domain", systemImage: "globe") }
                    Button { showingSpam = true } label: { Label("Spam protection", systemImage: "checkmark.shield") }
                }
            } label: {
                Label("More", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                           : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityIdentifier("forms.more")
        }
        if canCreate {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New form", systemImage: "plus") }
                    .accessibilityIdentifier("forms.new")
            }
        }
    }

    @ViewBuilder
    private func menu(_ form: WebFormDetail) -> some View {
        Button { copy(form) } label: { Label("Copy link", systemImage: "link") }
        if let url = URL(string: form.publicLink) {
            ShareLink(item: url, subject: Text(form.title)) { Label("Share link", systemImage: "square.and.arrow.up") }
        }
        if form.isLive {
            Button { filling = form } label: { Label("Fill it in now", systemImage: "square.and.pencil") }
        }
        if canCreate {
            Button { Task { await duplicate(form) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        }
        if canUpdate && form.status == .published {
            Button { Task { await setOpen(form, open: false) } } label: { Label("Close", systemImage: "lock") }
        }
        if canUpdate && form.status == .closed {
            Button { Task { await setOpen(form, open: true) } } label: { Label("Reopen", systemImage: "lock.open") }
        }
        if canDelete {
            Button(role: .destructive) { deleting = form } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch state {
        case .idle:
            SkeletonList()
        case .loading where forms.isEmpty:
            SkeletonList()
        case .failed(let error) where forms.isEmpty:
            ErrorStateView(error: error) { Task { await load() } }
        case .loaded where forms.isEmpty:
            ContentUnavailableView {
                Label(search.isEmpty && status.isEmpty ? "No forms yet" : "No forms match", systemImage: "list.clipboard")
            } description: {
                if search.isEmpty && status.isEmpty {
                    Text("Contact forms, quote requests, sign-ups, applications — share the link and responses arrive here.")
                }
            } actions: {
                if canCreate && search.isEmpty && status.isEmpty {
                    Button("Create your first form") { creating = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("forms.createFirst")
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Work

    private func load() async {
        if forms.isEmpty { state = .loading }
        do {
            let page = try await api.list(status: status.trimmedOrNil, query: search.trimmedOrNil, cursor: nil)
            forms = page.items
            next = page.next
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if forms.isEmpty { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func loadMoreIfNeeded(_ form: WebFormDetail) async {
        guard form.id == forms.last?.id, let cursor = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await api.list(status: status.trimmedOrNil, query: search.trimmedOrNil, cursor: cursor)
            let known = Set(forms.map(\.id))
            forms += page.items.filter { !known.contains($0.id) }
            next = page.next
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func replace(_ form: WebFormDetail) {
        if let index = forms.firstIndex(where: { $0.id == form.id }) { forms[index] = form }
    }

    private func copy(_ form: WebFormDetail) {
        UIPasteboard.general.string = form.publicLink
        notice = .done(form.isLive ? "Link copied." : "Link copied — publish the form to make it work.")
    }

    private func duplicate(_ form: WebFormDetail) async {
        do {
            let copy = try await api.duplicate(form.uuid)
            forms.insert(copy, at: 0)
            notice = .done("Duplicated as a draft: “\(copy.title)”.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func setOpen(_ form: WebFormDetail, open: Bool) async {
        do {
            replace(try await api.setOpen(form.uuid, open: open))
            notice = .done(open ? "Reopened: it takes responses again." : "Closed — it no longer takes responses.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete(_ form: WebFormDetail) async {
        do {
            try await api.delete(form.uuid)
            forms.removeAll { $0.id == form.id }
            notice = .done("Form deleted.")
        } catch {
            notice = .failed(error.asAPIError)
        }
        deleting = nil
    }
}

/// Opens a form's editor after it was made in a sheet.
struct WebFormOpenRoute: Hashable, Identifiable {
    let uuid: String
    var id: String { uuid }
}

/// One form in the list: title, status, numbers, what it creates, unpublished changes.
struct WebFormRow: View {
    let form: WebFormDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(form.title).font(.wsHeadline).lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(text: form.status.label, systemImage: form.status.symbol, tone: form.status.tone)
            }
            if let description = form.description {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Text("\(form.submissionCount) responses · \(form.questionCount) questions · last response "
                 + WebFormText.ago(form.lastSubmissionAt))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if !form.targets.isEmpty || form.hasUnpublishedChanges {
                HStack(spacing: 6) {
                    ForEach(form.targets, id: \.type) { target in
                        Pill(text: "→ \(target.label.lowercased())")
                    }
                    if form.hasUnpublishedChanges {
                        Pill(text: "Unpublished changes", systemImage: "exclamationmark.circle",
                             foreground: Tone.warning.textColor, background: Tone.warning.color.opacity(0.14))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "New form": blank or from a template, or described in words and drafted by AI.
struct WebFormNewFormView: View {
    let onCreated: (WebFormDetail) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var title = ""
    @State private var template = ""
    @State private var templates: [WebFormTemplate] = []
    @State private var prompt = ""
    @State private var draft: WebFormGenerated?
    @State private var drafting = false
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        Form {
            Section {
                Picker("How to start", selection: $mode) {
                    Text("Blank or template").tag(0)
                    Text("Describe it, AI drafts it").tag(1)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("forms.new.mode")
            }
            if let error { Section { InlineErrorRow(error: error) } }
            if mode == 0 { startSections } else { aiSections }
        }
        .navigationTitle("New form")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == 0 ? "Create" : "Create this form") { Task { await create() } }
                    .disabled(busy || (mode == 1 && draft == nil))
                    .accessibilityIdentifier("forms.new.create")
            }
        }
        .task { await loadTemplates() }
        .interactiveDismissDisabled(busy || drafting)
    }

    @ViewBuilder
    private var startSections: some View {
        Section {
            TextField("Title, e.g. Get a quote", text: $title)
                .accessibilityIdentifier("forms.new.title")
        } header: { Text("Title") }
        Section {
            templateRow(key: "", title: "Blank form", description: "Add your own questions.", extras: nil)
            ForEach(templates) { t in
                templateRow(key: t.key, title: t.title, description: t.description,
                            extras: [t.extras, "\(t.questionCount) questions"].compactMap { $0 }.joined(separator: " · "))
            }
        } header: { Text("Start from") } footer: {
            Text("You can change anything before you publish it.")
        }
    }

    private func templateRow(key: String, title: String, description: String, extras: String?) -> some View {
        Button {
            template = key
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.wsHeadline).foregroundStyle(.primary)
                    Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    if let extras { Text(extras).font(.wsFootnote).foregroundStyle(Tone.brand.textColor) }
                }
                Spacer()
                Image(systemName: template == key ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(template == key ? Color.accentColor : .secondaryText)
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(template == key ? .isSelected : [])
        .accessibilityIdentifier("forms.new.template.\(key.isEmpty ? "blank" : key)")
    }

    @ViewBuilder
    private var aiSections: some View {
        Section {
            TextField("A job application form: name, email, phone, a link to their CV, years of experience, and "
                      + "when they can start. Make each applicant a lead.", text: $prompt, axis: .vertical)
                .lineLimit(4...10)
                .accessibilityIdentifier("forms.new.prompt")
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    if drafting { ProgressView() }
                    Label(draft == nil ? "Draft the form" : "Draft again", systemImage: "sparkles")
                }
            }
            .disabled(drafting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
            .accessibilityIdentifier("forms.new.draft")
        } header: {
            Text("What should the form ask, and what should happen with each response?")
        } footer: {
            if drafting { Text("The AI is drafting your form. This can take a minute.") }
        }
        if let draft {
            Section {
                TextField("Title", text: Binding(get: { title.isEmpty ? draft.title : title }, set: { title = $0 }))
                if let description = draft.description {
                    Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            } header: { Text("The draft") }
            Section {
                ForEach(Array(draft.fields.enumerated()), id: \.offset) { index, field in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondaryText)
                        VStack(alignment: .leading) {
                            Text(field.displayTitle + (field.required ? " *" : ""))
                            Text(field.type.label + (field.isLocked ? " · locked" : ""))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
            } header: { Text("Questions") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !draft.targets.isEmpty {
                        Text("Creates: " + draft.targets.map { $0.label.lowercased() }.joined(separator: ", "))
                    }
                    if draft.dropped > 0 {
                        Text("\(draft.dropped) suggested question(s) were left out because they weren’t valid.")
                    }
                    Text("It is created as a draft: you can change anything before publishing.")
                }
            }
        }
    }

    private func loadTemplates() async {
        do { templates = try await services.webForms.templates() } catch {
            // Starting blank still works; the list just shows "Blank form".
        }
    }

    private func generate() async {
        drafting = true
        error = nil
        defer { drafting = false }
        do {
            draft = try await services.webForms.generate(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            self.error = error.asAPIError
        }
    }

    private func create() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let body: JSONValue
            if mode == 1, let draft {
                body = WebFormsAPI.createBody(from: draft, title: title)
            } else {
                let chosen = templates.first { $0.key == template }
                body = WebFormsAPI.createBody(title: title.trimmedOrNil ?? chosen?.title ?? "Untitled form",
                                              template: template)
            }
            let form = try await services.webForms.create(body)
            dismiss()
            onCreated(form)
        } catch {
            self.error = error.asAPIError
        }
    }
}
