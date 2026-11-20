import SwiftUI

/// Message templates (dashboard /dashboard/shop/templates): pre-written messages to suppliers with details
/// filled in when they're sent. One group per kind, with the built-in wording; new, edit, copy and delete
/// (RBAC `shop` create / update / delete).
struct ShopTemplatesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[ShopTemplate]> = .idle
    @State private var kinds: [ShopTemplateKindInfo] = []
    @State private var suppliers: [ShopSupplierName] = []
    @State private var editing: ShopTemplateDraft?
    @State private var deleting: ShopTemplate?
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let actionError {
                Section { InlineErrorRow(error: actionError) }
            }
            if let rows = state.value {
                ForEach(ShopTemplateKind.allCases) { kind in
                    kindSection(kind, rows: rows.filter { $0.kind == kind.rawValue && !$0.builtin })
                }
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .navigationTitle("Templates")
        .toolbar {
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { start(nil, kind: .supplierIntro, copy: true) } label: { Label("New template", systemImage: "plus") }
                        .accessibilityIdentifier("shop.templates.new")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { draft in
            NavigationStack {
                ShopTemplateEditor(draft: draft, kinds: kinds, suppliers: suppliers) { name in
                    notice = "Template “\(name)” saved."
                    actionError = nil
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { template in
            Button("Delete template", role: .destructive) { Task { await delete(template) } }
        } message: { _ in
            Text("Messages already sent are not affected. If it was the default, the built-in wording is used again.")
        }
    }

    @ViewBuilder
    private func kindSection(_ kind: ShopTemplateKind, rows: [ShopTemplate]) -> some View {
        let builtin = kinds.first { $0.kind == kind.rawValue }?.builtin
        Section {
            ForEach(rows) { template in
                ShopTemplateRow(template: template)
                    .swipeActions {
                        if session.shopPolicy.canDelete {
                            Button("Delete", role: .destructive) { deleting = template }
                        }
                        if session.shopPolicy.canCreate {
                            Button("Copy") { start(template, kind: kind, copy: true) }.tint(.indigo)
                        }
                    }
                    .contextMenu {
                        if session.shopPolicy.canUpdate { Button("Edit", systemImage: "pencil") { start(template, kind: kind) } }
                        if session.shopPolicy.canCreate { Button("Copy", systemImage: "doc.on.doc") { start(template, kind: kind, copy: true) } }
                        if session.shopPolicy.canDelete { Button("Delete", systemImage: "trash", role: .destructive) { deleting = template } }
                    }
                    .onTapGesture { if session.shopPolicy.canUpdate { start(template, kind: kind) } }
            }
            if let builtin {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(builtin.name).font(.wsHeadline).foregroundStyle(.secondaryText)
                            if !rows.contains(where: { $0.isDefault && $0.isActive }) {
                                StatusBadge(text: "In use", systemImage: "checkmark.circle", tone: .neutral)
                            }
                        }
                        Text(builtin.subject).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    if session.shopPolicy.canCreate {
                        Button("Copy to edit") { start(nil, kind: kind, copy: true) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("shop.templates.copyBuiltin.\(kind.rawValue)")
                    }
                }
            }
        } header: {
            HStack {
                Text(kind.label)
                Spacer()
                if session.shopPolicy.canCreate {
                    Button("New") { start(nil, kind: kind, copy: true) }
                        .font(.wsCaption.weight(.semibold))
                        .accessibilityIdentifier("shop.templates.new.\(kind.rawValue)")
                }
            }
        } footer: {
            Text(kind.help)
        }
    }

    /// Opens the editor: an existing template, a copy of one, or a new one starting from the built-in wording.
    private func start(_ template: ShopTemplate?, kind: ShopTemplateKind, copy: Bool = false) {
        let builtin = kinds.first { $0.kind == kind.rawValue }?.builtin
        editing = ShopTemplateDraft.start(from: template, builtin: builtin, kind: kind, copy: copy)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            async let rows = services.shop.messageTemplates()
            async let meta = services.shop.templateKinds()
            let (list, info) = try await (rows, meta)
            kinds = info
            state = .loaded(list)
            suppliers = (try? await services.shop.templateSuppliers()) ?? suppliers
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    private func delete(_ template: ShopTemplate) async {
        guard let uuid = template.uuid else { return }
        do {
            try await services.shop.deleteMessageTemplate(uuid)
            notice = "Template “\(template.name)” deleted."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

private struct ShopTemplateRow: View {
    let template: ShopTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name).font(.wsHeadline)
            HStack(spacing: 6) {
                if template.isDefault { StatusBadge(text: "Default", systemImage: "star.fill", tone: .success) }
                if let supplier = template.supplierName { StatusBadge(text: "For \(supplier)", systemImage: "truck.box", tone: .info) }
                if !template.isActive { StatusBadge(text: "Inactive", systemImage: "pause.circle", tone: .neutral) }
            }
            Text(template.subject).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to edit. Swipe for copy and delete.")
    }
}

/// What the editor is working on.
struct ShopTemplateDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var uuid: String?
    var kind: String
    var name: String
    var subject: String
    var body: String
    var supplierUuid: String?
    var isDefault: Bool
    var isActive: Bool

    /// The dashboard's startFrom: edit keeps everything; copy or new starts inactive-free from the source's wording.
    static func start(from template: ShopTemplate?, builtin: ShopTemplate?, kind: ShopTemplateKind, copy: Bool) -> ShopTemplateDraft {
        let source = template ?? builtin
        let editing = template != nil && !copy
        var name = ""
        if editing, let template { name = template.name }
        else if copy, let source { name = "\(source.name.replacingOccurrences(of: " (built-in)", with: "")) (copy)" }
        return ShopTemplateDraft(uuid: editing ? template?.uuid : nil, kind: kind.rawValue, name: name,
                                 subject: source?.subject ?? "", body: source?.body ?? "",
                                 supplierUuid: editing ? template?.supplierUuid : nil,
                                 isDefault: editing ? (template?.isDefault ?? false) : false,
                                 isActive: editing ? (template?.isActive ?? true) : true)
    }

    var input: ShopTemplateInput {
        ShopTemplateInput(kind: kind, name: name.trimmingCharacters(in: .whitespacesAndNewlines), subject: subject, body: body,
                          supplierUuid: supplierUuid, isDefault: isDefault, isActive: isActive)
    }
}

/// New or edit a template: kind, name, supplier, subject, message with placeholders, default/active, preview.
private struct ShopTemplateEditor: View {
    @State var draft: ShopTemplateDraft
    let kinds: [ShopTemplateKindInfo]
    let suppliers: [ShopSupplierName]
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: APIError?

    private var info: ShopTemplateKindInfo? { kinds.first { $0.kind == draft.kind } }
    private var allowed: Set<String> { Set(info?.placeholders.map(\.name) ?? []) }
    private var problem: String? {
        ShopTemplateText.problem(kind: draft.kind, subject: draft.subject, body: draft.body, allowed: allowed)
    }

    var body: some View {
        Form {
            Section {
                Picker("Used for", selection: Binding(get: { draft.kind }, set: { kind in
                    draft.kind = kind
                    if let builtin = kinds.first(where: { $0.kind == kind })?.builtin {
                        draft.subject = builtin.subject
                        draft.body = builtin.body
                    }
                })) {
                    ForEach(ShopTemplateKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(draft.uuid != nil)
                .accessibilityIdentifier("shop.template.kind")
                TextField("Name, e.g. Introduction to Boston", text: $draft.name)
                    .onChange(of: draft.name) { _, value in if value.count > 160 { draft.name = String(value.prefix(160)) } }
                    .accessibilityIdentifier("shop.template.name")
                Picker("Only for this supplier", selection: $draft.supplierUuid) {
                    Text("Any supplier").tag(String?.none)
                    ForEach(suppliers) { Text($0.name).tag(String?.some($0.uuid)) }
                }
                .accessibilityIdentifier("shop.template.supplier")
            } footer: {
                Text(ShopTemplateKind(rawValue: draft.kind)?.help ?? "")
            }

            Section("Subject") {
                TextField("Subject", text: $draft.subject, axis: .vertical)
                    .onChange(of: draft.subject) { _, value in if value.count > 200 { draft.subject = String(value.prefix(200)) } }
                    .accessibilityIdentifier("shop.template.subject")
            }

            Section {
                TextField("Message", text: $draft.body, axis: .vertical)
                    .lineLimit(8...30)
                    .onChange(of: draft.body) { _, value in if value.count > 8000 { draft.body = String(value.prefix(8000)) } }
                    .accessibilityIdentifier("shop.template.body")
            } header: {
                Text("Message")
            } footer: {
                Text("\(draft.body.count) / 8000 characters.")
            }

            if let info, !info.placeholders.isEmpty {
                Section {
                    ForEach(info.placeholders, id: \.name) { placeholder in
                        Button {
                            draft.body += "{{\(placeholder.name)}}"
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("{{\(placeholder.name)}}").font(.wsSubheadline.monospaced())
                                Text(placeholder.description).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                        .accessibilityHint("Adds it to the end of the message")
                    }
                } header: {
                    Text("Placeholders")
                } footer: {
                    Text("Tap one to add it to the end of the message. A line whose placeholders are all empty is left out.")
                }
            }

            Section {
                Toggle("Default for this kind", isOn: Binding(get: { draft.isDefault }, set: { on in
                    draft.isDefault = on
                    if on { draft.isActive = true }
                }))
                .accessibilityIdentifier("shop.template.default")
                Toggle("Active", isOn: Binding(get: { draft.isActive }, set: { on in
                    draft.isActive = on
                    if !on { draft.isDefault = false }
                }))
                .accessibilityIdentifier("shop.template.active")
            } footer: {
                Text("The default is used when no supplier-specific template applies. Inactive templates aren’t offered when sending.")
            }

            Section("Preview with example details") {
                Text(ShopTemplateText.preview(draft.subject)).font(.wsHeadline)
                Text(ShopTemplateText.preview(draft.body)).font(.wsSubheadline).textSelection(.enabled)
            }

            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(draft.uuid == nil ? "New template" : "Edit template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || problem != nil || draft.name.trimmedOrNil == nil)
                    .accessibilityIdentifier("shop.template.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await services.shop.saveMessageTemplate(uuid: draft.uuid, draft.input)
            onSaved(draft.input.name)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
