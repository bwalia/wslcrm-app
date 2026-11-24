import SwiftUI

/// The detail screen for any described resource: its fields, actions, related records, edit and delete.
struct ResourceDetailView: View {
    let route: ResourceRoute
    @Environment(\.services) private var services

    var body: some View {
        ResourceDetailContent(descriptor: ModuleCatalog.descriptor(route.descriptorID) ?? .missing(route.descriptorID),
                              recordID: route.recordID, seed: route.seed, service: services.resources)
    }
}

private struct ResourceDetailContent: View {
    let descriptor: ResourceDescriptor
    let recordID: String
    let service: ResourceService
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var record: Record?
    @State private var loadError: APIError?
    @State private var editing = false
    @State private var running: ActionSpec?
    @State private var confirming: ActionSpec?
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var busy = false

    init(descriptor: ResourceDescriptor, recordID: String, seed: Record?, service: ResourceService) {
        self.descriptor = descriptor
        self.recordID = recordID
        self.service = service
        _record = State(initialValue: seed)
    }

    var body: some View {
        List {
            if let loadError, record == nil {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            } else if let loadError {
                // Showing the list row; the full record failed to load.
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
            if let record {
                header(record)
                if let notice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                            .accessibilityIdentifier("resource.notice")
                    }
                }
                if let actionError { Section { InlineErrorRow(error: actionError) } }
                ForEach(sections(for: record)) { section in
                    FieldSection(section: section, record: record)
                }
                linksSection(record)
                actionsSection(record)
                ForEach(descriptor.related) { related in
                    RelatedSection(related: related, parent: record)
                }
                if canDelete {
                    Section {
                        DeleteButton(title: "Delete \(descriptor.noun)",
                                     message: "This can’t be undone.") { await delete(record) }
                    }
                }
            }
        }
        .overlay { if record == nil, loadError == nil { SkeletonList() } }
        .navigationTitle(descriptor.noun.capitalizedFirst)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .disabled(record == nil)
                        .accessibilityIdentifier("resource.edit")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing) {
            if let record {
                NavigationStack {
                    ResourceFormView(descriptor: descriptor, existing: record) { saved in
                        if let saved { self.record = saved }
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(item: $running) { action in
            NavigationStack {
                ActionInputForm(action: action) { inputs in
                    guard let record else { return false }
                    // A failure is shown in the sheet itself, which stays open with what was typed.
                    try await perform(action, on: record, inputs: inputs)
                    return true
                }
            }
        }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming, let record {
                Button(action.title, role: action.destructive ? .destructive : nil) {
                    Task { _ = await run(action, on: record, inputs: [:]) }
                }
            }
        } message: {
            if let confirm = confirming?.confirm { Text(confirm) }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func header(_ record: Record) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(descriptor.singleton ? descriptor.title : RecordRow(record: record, list: descriptor.list).title)
                    .font(.wsTitle3.bold())
                    .accessibilityAddTraits(.isHeader)
                if descriptor.singleton, let summary = descriptor.summary {
                    Text(summary).font(.wsSubheadline).foregroundStyle(.secondaryText)
                } else if let subtitle = RecordRow(record: record, list: descriptor.list).subtitle {
                    Text(subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                if let badge = descriptor.list.badge, let value = record.string(badge.key) {
                    FieldBadge(field: badge, value: value)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func actionsSection(_ record: Record) -> some View {
        let actions = descriptor.actions.filter { action in
            (action.visibleWhen?.matches(record) ?? true)
                && session.permissions.allows(action.action, action.module ?? descriptor.permissions.module)
        }
        if !actions.isEmpty {
            Section {
                ForEach(actions) { action in
                    Button(role: action.destructive ? .destructive : nil) {
                        if !action.inputs.isEmpty { running = action }
                        else if action.confirm != nil || action.destructive { confirming = action }
                        else { Task { _ = await run(action, on: record, inputs: [:]) } }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .frame(minHeight: 44)
                    .disabled(busy)
                    .accessibilityIdentifier("resource.action.\(action.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func linksSection(_ record: Record) -> some View {
        let links = descriptor.links.filter { record.string($0.key) != nil }
        if !links.isEmpty {
            Section {
                ForEach(links) { link in
                    LinkTargetRow(link: link, id: record.string(link.key) ?? "")
                }
            }
        }
    }

    /// The descriptor's sections, or every field the server sent when it describes none.
    private func sections(for record: Record) -> [SectionSpec] {
        descriptor.detail.isEmpty ? [AutoFields.section(for: record)] : descriptor.detail
    }

    private var isWritable: Bool {
        guard let record, let condition = descriptor.writableWhen else { return true }
        return condition.matches(record)
    }

    private var canEdit: Bool {
        descriptor.api.update != nil && descriptor.form != nil && isWritable
            && session.permissions.allows(.update, on: descriptor.permissions)
    }

    private var canDelete: Bool {
        descriptor.api.delete != nil && !descriptor.singleton && isWritable
            && session.permissions.allows(.delete, on: descriptor.permissions)
    }

    // MARK: - Work

    private func load() async {
        do {
            record = try await service.record(descriptor, id: recordID, seed: record)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    /// Runs an action from a button or a confirmation: a failure shows on this screen.
    private func run(_ action: ActionSpec, on record: Record, inputs: [String: JSONValue]) async -> Bool {
        do {
            try await perform(action, on: record, inputs: inputs)
            return true
        } catch {
            actionError = error.asAPIError
            notice = nil
            return false
        }
    }

    private func perform(_ action: ActionSpec, on record: Record, inputs: [String: JSONValue]) async throws {
        busy = true
        defer { busy = false }
        let response = try await service.run(action, on: record, inputs: inputs,
                                             requiresNamespace: descriptor.api.requiresNamespace)
        actionError = nil
        notice = action.done ?? "\(action.title): done."
        if action.method == .delete { dismiss(); return }
        // The server usually answers with the changed record: show it straight away (the only
        // way to refresh a resource that can't be fetched on its own).
        if let response,
           let updated = ResourceService.parseRecord(response, itemKey: descriptor.api.itemKey,
                                                     idKeys: descriptor.api.idKeys),
           updated.id == record.id {
            self.record = updated
        }
        await load()
    }

    private func delete(_ record: Record) async -> Bool {
        do {
            try await service.delete(descriptor, record: record)
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

/// Opens another of the app's screens for an id found in the record.
struct LinkTargetRow<RowLabel: View>: View {
    let link: LinkSpec
    let id: String
    let custom: RowLabel?

    init(link: LinkSpec, id: String, label: RowLabel) {
        self.link = link
        self.id = id
        custom = label
    }

    var body: some View {
        Group {
            switch link.target {
            case .purchaseOrder:
                NavigationLink(value: PurchaseOrderRoute(uuid: id)) { label }
            case .resource(let descriptorID):
                NavigationLink(value: ResourceRoute(descriptorID: descriptorID, recordID: id)) { label }
            case .shopProduct:
                NavigationLink { ShopProductDetailView(uuid: id) } label: { label }
            case .shopOrder:
                NavigationLink { ShopOrderDetailView(uuid: id) } label: { label }
            case .shopQuote:
                NavigationLink { ShopQuoteDetailView(uuid: id) } label: { label }
            case .shopDeal:
                NavigationLink { ShopDealDetailView(code: id) } label: { label }
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var label: some View {
        if let custom { custom } else { Label(link.title, systemImage: link.systemImage) }
    }
}

extension LinkTargetRow where RowLabel == EmptyView {
    init(link: LinkSpec, id: String) {
        self.link = link
        self.id = id
        custom = nil
    }
}

/// A section of fields on a detail screen.
struct FieldSection: View {
    let section: SectionSpec
    let record: Record

    var body: some View {
        let shown = section.fields.filter { FieldFormatter.text(record, $0) != nil }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { field in FieldValueRow(field: field, record: record) }
            } header: {
                if let title = section.title { Text(title) }
            } footer: {
                if let footer = section.footer { Text(footer) }
            }
        }
    }
}

/// One field, shown the way its kind suggests (a phone number calls, an email writes, a status is a pill).
struct FieldValueRow: View {
    let field: FieldSpec
    let record: Record

    var body: some View {
        let text = FieldFormatter.text(record, field) ?? ""
        switch field.kind {
        case .email:
            EmailLinkRow(email: text)
        case .phone:
            PhoneLinkRow(name: field.label, phone: text)
        case .url:
            CopyableRow(label: field.label, value: text)
        case .status, .choice:
            LabeledContent(field.label) {
                FieldBadge(field: field, value: record.string(field.key) ?? text)
            }
            .accessibilityElement(children: .combine)
        case .multiline, .json:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.wsCaption).foregroundStyle(.secondaryText)
                Text(text).font(.wsBody).textSelection(.enabled)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        case .money, .integer, .decimal, .percent, .count:
            LabeledContent(field.label) {
                Text(text).font(.wsBody.monospacedDigit())
            }
            .accessibilityElement(children: .combine)
        default:
            DetailRow(label: field.label, value: text)
        }
    }
}

/// Related records under a parent: embedded rows, or a link to the related list.
private struct RelatedSection: View {
    let related: RelatedSpec
    let parent: Record

    var body: some View {
        if let child = ModuleCatalog.descriptor(related.descriptorID) {
            if let key = related.embeddedKey {
                let rows = parent.records(key, idKeys: child.api.idKeys)
                if !rows.isEmpty {
                    Section(related.title) {
                        ForEach(rows) { row in
                            if child.api.item != nil {
                                NavigationLink(value: ResourceRoute(descriptorID: child.id, recordID: row.id, seed: row)) {
                                    RecordRow(record: row, list: child.list)
                                }
                            } else {
                                RecordRow(record: row, list: child.list)
                            }
                        }
                    }
                }
            } else {
                Section {
                    NavigationLink(value: ResourceListRoute(child.id,
                                                            query: related.query.mapValues { parent.fill($0) },
                                                            title: related.title)) {
                        Label(related.title, systemImage: child.systemImage)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }
}

/// When a resource has no described detail, every simple field the server sent, in plain words.
enum AutoFields {
    static let hidden: Set<String> = ["id", "uuid", "namespace_id", "user_id", "store_id", "password", "password_hash",
                                      "token", "secret", "api_key", "deleted_at"]

    static func section(for record: Record) -> SectionSpec {
        let fields = record.fields.keys.sorted().compactMap { key -> FieldSpec? in
            guard !hidden.contains(key), !key.hasSuffix("_id"), let value = record.fields[key] else { return nil }
            switch value {
            case .string(let s):
                if s.count >= 19, APIDate.parse(s) != nil { return FieldSpec(key, Formatters.humanize(key), .dateTime) }
                if key.contains("status") { return FieldSpec(key, Formatters.humanize(key), .status(.standard)) }
                if key.contains("email") { return FieldSpec(key, Formatters.humanize(key), .email) }
                if key.contains("phone") || key.contains("mobile") { return FieldSpec(key, Formatters.humanize(key), .phone) }
                return FieldSpec(key, Formatters.humanize(key), s.count > 60 ? .multiline : .text)
            case .number:
                return FieldSpec(key, Formatters.humanize(key), .decimal(places: 2))
            case .bool:
                return FieldSpec(key, Formatters.humanize(key), .bool)
            default:
                return nil
            }
        }
        return SectionSpec("Details", fields)
    }
}

extension String {
    /// "member" → "Member".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
