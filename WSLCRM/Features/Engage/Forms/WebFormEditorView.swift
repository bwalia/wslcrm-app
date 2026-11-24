import SwiftUI

/// One form: Build · Settings · Share · Responses · Insights (the web's form editor), with Publish,
/// Close / Reopen, Fill it in now, Duplicate and Delete.
struct WebFormEditorView: View {
    let uuid: String
    @Environment(\.services) private var services

    var body: some View {
        WebFormEditorContent(model: WebFormEditorModel(uuid: uuid, api: services.webForms))
    }
}

enum WebFormEditorTab: String, CaseIterable, Identifiable {
    case build, settings, share, responses, insights
    var id: String { rawValue }

    var label: String {
        switch self {
        case .build: "Build"
        case .settings: "Settings"
        case .share: "Share"
        case .responses: "Responses"
        case .insights: "Insights"
        }
    }
}

private struct WebFormEditorContent: View {
    @State var model: WebFormEditorModel
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: WebFormEditorTab = .build
    @State private var filling = false
    @State private var confirmingDelete = false
    @State private var copied: WebFormDetail?

    private var readOnly: Bool { !session.permissions.can(.update, moduleName: WebFormsAPI.module) }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: WebFormsAPI.module) }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: WebFormsAPI.module) }

    var body: some View {
        Group {
            if let form = model.form {
                content(form)
            } else if let error = model.loadError {
                ErrorStateView(error: error) { Task { await model.load() } }
            } else {
                SkeletonList()
            }
        }
        .navigationTitle(model.form == nil ? "Form" : (model.title.trimmedOrNil ?? "Untitled form"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.form == nil { await model.load() } }
        .onDisappear { Task { await model.flush() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await model.flush() } } }
        .toolbar { toolbar }
        .sheet(isPresented: $filling) {
            if let form = model.form {
                NavigationStack { WebFormLiveFillView(publicID: form.publicID, title: form.title) }
            }
        }
        .navigationDestination(item: $copied) { copy in WebFormEditorView(uuid: copy.uuid) }
        .confirmationDialog("Delete form", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await model.delete() { dismiss() } }
            }
        } message: {
            Text("Delete “\(model.title)”? Its link stops working at once; its responses are removed after 30 days.")
        }
    }

    private func content(_ form: WebFormDetail) -> some View {
        VStack(spacing: 0) {
            header(form)
            EngageNoticeBar(notice: model.notice)
            switch tab {
            case .build: WebFormBuildTab(model: model, readOnly: readOnly)
            case .settings: WebFormSettingsTab(model: model, readOnly: readOnly)
            case .share: WebFormShareTab(form: form) { filling = true }
            case .responses: WebFormResponsesTab(form: form)
            case .insights: WebFormInsightsTab(form: form)
            }
        }
    }

    private func header(_ form: WebFormDetail) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatusBadge(text: form.status.label, systemImage: form.status.symbol, tone: form.status.tone)
                Spacer()
                WebFormSaveIndicator(state: model.saveState) { Task { await model.reload() } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Picker("Section", selection: $tab) {
                    ForEach(WebFormEditorTab.allCases) { tab in
                        Text(tab == .responses && form.submissionCount > 0 ? "Responses (\(form.submissionCount))"
                             : tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("forms.editor.tabs")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let form = model.form {
            if !readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { if await model.publish() { tab = .share } }
                    } label: {
                        if model.publishing { ProgressView() } else { Text(model.publishTitle) }
                    }
                    .disabled(!model.canPublish || model.publishing)
                    .accessibilityIdentifier("forms.editor.publish")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if form.publishedVersion != nil {
                        Button { filling = true } label: { Label("Fill it in now", systemImage: "square.and.pencil") }
                            .disabled(!form.isLive)
                    }
                    if let url = URL(string: form.publicLink) {
                        ShareLink(item: url, subject: Text(form.title)) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !readOnly && form.status == .published {
                        Button { Task { await model.setOpen(false) } } label: { Label("Close", systemImage: "lock") }
                    }
                    if !readOnly && form.status == .closed {
                        Button { Task { await model.setOpen(true) } } label: { Label("Reopen", systemImage: "lock.open") }
                    }
                    if canCreate {
                        Button {
                            Task { copied = await model.duplicate() }
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    }
                    if canDelete {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete form", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("forms.editor.more")
            }
        }
    }
}

/// "Saved" / "Saving…" / "Not saved" / "Changed elsewhere — Reload".
struct WebFormSaveIndicator: View {
    let state: WebFormEditorModel.SaveState
    let reload: () -> Void

    var body: some View {
        Group {
            switch state {
            case .saved: Label("Saved", systemImage: "checkmark").foregroundStyle(Tone.success.textColor)
            case .dirty: Label("Not saved yet", systemImage: "circle.dotted").foregroundStyle(.secondaryText)
            case .saving: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Saving…") }
                .foregroundStyle(.secondaryText)
            case .failed: Label("Not saved", systemImage: "icloud.slash").foregroundStyle(Tone.danger.textColor)
            case .conflict:
                Button("Changed elsewhere — Reload", systemImage: "arrow.clockwise", action: reload)
                    .foregroundStyle(Tone.warning.textColor)
                    .accessibilityIdentifier("forms.editor.reload")
            }
        }
        .font(.wsFootnote)
        .accessibilityIdentifier("forms.editor.saveState")
    }
}

// MARK: - Build

/// The Build tab: the title, "Create records", the questions (reorder, duplicate, delete, open one to change it),
/// adding questions of every type, and a preview that behaves like the live form.
struct WebFormBuildTab: View {
    @Bindable var model: WebFormEditorModel
    let readOnly: Bool
    @State private var opened: WebFormFieldRoute?
    @State private var previewing = false

    var body: some View {
        List {
            Section("Title") {
                TextField("Form title", text: Binding(get: { model.title }, set: { model.setTitle(String($0.prefix(200))) }))
                    .font(.wsHeadline)
                    .disabled(readOnly)
                    .accessibilityIdentifier("forms.build.title")
            }
            WebFormTargetsSection(model: model, readOnly: readOnly)
            questions
            if !readOnly { addSection }
        }
        .navigationDestination(item: $opened) { route in
            WebFormFieldInspector(model: model, fieldID: route.id, readOnly: readOnly)
        }
        .sheet(isPresented: $previewing) {
            NavigationStack { WebFormPreviewView(fields: model.fields, title: model.title) }
        }
    }

    private var questions: some View {
        Section {
            if model.fields.isEmpty {
                Text("No questions yet. Add your first one below.").foregroundStyle(.secondaryText)
            }
            ForEach(model.fields) { field in
                Button {
                    opened = WebFormFieldRoute(id: field.id)
                } label: {
                    WebFormFieldRow(field: field)
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("forms.build.field.\(field.key ?? field.type.rawValue)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !readOnly && !field.isLocked {
                        Button(role: .destructive) { model.remove(field.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                    if !readOnly {
                        Button { model.duplicate(field.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .tint(.indigo)
                    }
                }
                .contextMenu { if !readOnly { rowMenu(field) } }
            }
            .onMove(perform: moveAction)
        } header: {
            HStack {
                Text("Questions (\(model.fields.count))")
                Spacer()
                Button { previewing = true } label: { Label("Preview", systemImage: "eye") }
                    .font(.wsFootnote)
                    .textCase(nil)
                    .accessibilityIdentifier("forms.build.preview")
            }
        } footer: {
            if !readOnly { Text("Touch and hold a question to move it, or use its menu.") }
        }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard !readOnly else { return nil }
        return { source, destination in model.move(from: source, to: destination) }
    }

    @ViewBuilder
    private func rowMenu(_ field: WebFormField) -> some View {
        let index = model.index(of: field.id) ?? 0
        Button { model.move(field.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
            .disabled(index == 0)
        Button { model.move(field.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
            .disabled(index >= model.fields.count - 1)
        Button { model.duplicate(field.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if !field.isLocked {
            Button(role: .destructive) { model.remove(field.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var addSection: some View {
        Section("Add a question") {
            ForEach(WebFormFieldType.Group.allCases, id: \.self) { group in
                Menu {
                    ForEach(WebFormFieldType.allCases.filter { $0.group == group }) { type in
                        Button { opened = WebFormFieldRoute(id: model.add(type)) } label: {
                            Label(type.label, systemImage: type.systemImage)
                        }
                        .accessibilityIdentifier("forms.build.add.\(type.rawValue)")
                    }
                } label: {
                    Label(group.label, systemImage: group.systemImage).frame(minHeight: 44)
                }
                .accessibilityIdentifier("forms.build.addGroup.\(group.rawValue)")
            }
        }
    }
}

extension WebFormFieldType.Group {
    var label: String {
        switch self {
        case .text: "Text, number, date or time"
        case .choice: "Choices, yes/no and ratings"
        case .contact: "Name, email, phone, address, website"
        case .other: "Files, table, consent, hidden"
        case .layout: "Headings, text and page breaks"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .choice: "checklist"
        case .contact: "person.crop.circle"
        case .other: "square.grid.2x2"
        case .layout: "rectangle.split.1x2"
        }
    }
}

struct WebFormFieldRoute: Hashable, Identifiable {
    let id: UUID
}

/// One question in the builder: what it is and what's special about it.
struct WebFormFieldRow: View {
    let field: WebFormField

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: field.type.systemImage)
                .foregroundStyle(.secondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(field.displayTitle + (field.required ? " *" : "")).font(.wsBody).lineLimit(2)
                Text(details).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 0)
            if field.isLocked {
                Image(systemName: "lock.fill").foregroundStyle(.secondaryText).accessibilityLabel("Locked")
            }
        }
        .padding(.vertical, 2)
        .background(field.type == .pageBreak ? Color.secondary.opacity(0.06) : Color.clear)
    }

    private var details: String {
        var parts = [field.unknownType.map { Formatters.humanize($0) } ?? field.type.label]
        if field.isLocked { parts.append("locked") }
        if let maps = field.mapsTo { parts.append("→ \(maps.label)") }
        if field.halfWidth { parts.append("half width") }
        if !(field.logic?.rules.isEmpty ?? true) { parts.append("shown only if…") }
        if field.type == .pageBreak { parts.append("a new step starts here") }
        return parts.joined(separator: " · ")
    }
}

/// "Create records from each response": customers, leads or invitations to the workspace.
struct WebFormTargetsSection: View {
    @Bindable var model: WebFormEditorModel
    let readOnly: Bool

    var body: some View {
        if !model.targetOptions.isEmpty {
            Section {
                ForEach(model.targetOptions) { option in
                    let on = model.targets.contains { $0.type == option.key }
                    Toggle(isOn: Binding(get: { on }, set: { model.setTarget(option.key, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                            Text(option.allowed ? option.description : "Needs the \(option.permission) permission.")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .disabled(readOnly || (!option.allowed && !on))
                    .accessibilityIdentifier("forms.build.target.\(option.key)")
                }
                if let invite = model.targets.first(where: { $0.type == "user" }),
                   let option = model.targetOptions.first(where: { $0.key == "user" }) {
                    Label("Anyone with the link can ask to join this workspace. They get the role below only after "
                          + "accepting the invitation from their email.", systemImage: "exclamationmark.triangle")
                        .font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                    Picker("Role for invited people", selection: Binding(get: { invite.role ?? "" },
                                                                         set: { model.setInviteRole($0) })) {
                        ForEach(option.roles) { Text($0.label).tag($0.name) }
                    }
                    .disabled(readOnly)
                }
            } header: {
                Text("Create records from each response")
            } footer: {
                Text("Ticking one adds the name and email questions it needs and locks them. An email that already "
                     + "exists is linked, never changed.")
            }
        }
    }
}

/// The preview: the form as people fill it in (logic and steps work; nothing is sent).
struct WebFormPreviewView: View {
    let fields: [WebFormField]
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: JSONValue] = [:]
    @State private var errors: [String: String] = [:]
    @State private var done = false
    @State private var wide = false
    @State private var run = 0

    var body: some View {
        Group {
            if done {
                ContentUnavailableView {
                    Label("That’s the end of the form", systemImage: "checkmark.circle")
                } description: {
                    Text("On the live form, Submit sends it.")
                } actions: {
                    Button("Start again") {
                        answers = [:]
                        errors = [:]
                        done = false
                        run += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                WebFormRunnerView(fields: fields, answers: $answers, errors: $errors, wide: wide,
                                  header: AnyView(Label("Preview only: nothing is sent. Logic and steps work as on the "
                                                        + "live form.", systemImage: "eye")
                                                    .font(.wsFootnote).foregroundStyle(.secondaryText))) { _ in
                    done = true
                }
                .id(run)
            }
        }
        .navigationTitle(title.trimmedOrNil ?? "Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Size", selection: $wide) {
                    Label("Phone", systemImage: "iphone").tag(false)
                    Label("Wide screen", systemImage: "desktopcomputer").tag(true)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("forms.preview.size")
            }
        }
    }
}
