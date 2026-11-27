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
        DetailPage {
            if let record {
                header(record)
            } else if let loadError {
                InlineErrorRow(error: loadError) { Task { await load() } }
            }
        } main: {
            if let record {
                if let loadError {
                    // Showing the list row; the full record failed to load.
                    DetailSection { InlineErrorRow(error: loadError) { Task { await load() } } }
                }
                if let notice {
                    DetailSection {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                            .accessibilityIdentifier("resource.notice")
                    }
                }
                if let actionError { DetailSection { InlineErrorRow(error: actionError) } }
                ForEach(mainSections(for: record)) { section in
                    FieldSection(section: section, record: record)
                }
                ForEach(descriptor.related.filter { $0.embeddedKey != nil }) { related in
                    RelatedSection(related: related, parent: record)
                }
                relatedLinks(record)
                if canDelete {
                    DetailSection {
                        DeleteButton(title: "Delete \(descriptor.noun)",
                                     message: "This can’t be undone.") { await delete(record) }
                    }
                }
            }
        } side: {
            if let record, let facts = sideSection(for: record) {
                FieldSection(section: facts, record: record, fallbackTitle: "Details")
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
        .wsRefreshable { await load() }
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

    private func header(_ record: Record) -> some View {
        let row = RecordRow(record: record, list: descriptor.list)
        let title = descriptor.singleton ? descriptor.title : row.title
        return DetailHeader(title,
                            subtitle: descriptor.singleton ? descriptor.summary : row.subtitle,
                            avatar: .icon(descriptor.systemImage, Palette.tile(for: descriptor.id))) {
            if let badge = descriptor.list.badge, let value = record.string(badge.key) {
                DetailChips { FieldBadge(field: badge, value: value) }
            }
        } actions: {
            actionBar(record)
        }
    }

    /// The descriptor's actions this person may run on this record: the first one prominent, the rest beside it,
    /// destructive ones under More.
    @ViewBuilder
    private func actionBar(_ record: Record) -> some View {
        let actions = descriptor.actions.filter { action in
            (action.visibleWhen?.matches(record) ?? true)
                && session.permissions.allows(action.action, action.module ?? descriptor.permissions.module)
        }
        let plain = actions.filter { !$0.destructive }
        let destructive = actions.filter(\.destructive)
        if !actions.isEmpty {
            RecordActionBar(showsMore: !destructive.isEmpty) {
                ForEach(plain) { action in
                    actionButton(action, record)
                        .buttonStyle(.action(prominent: action.id == plain.first?.id))
                }
            } more: {
                ForEach(destructive) { action in actionButton(action, record) }
            }
            .disabled(busy)
        }
    }

    private func actionButton(_ action: ActionSpec, _ record: Record) -> some View {
        Button(role: action.destructive ? .destructive : nil) {
            if !action.inputs.isEmpty { running = action }
            else if action.confirm != nil || action.destructive { confirming = action }
            else { Task { _ = await run(action, on: record, inputs: [:]) } }
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .accessibilityIdentifier("resource.action.\(action.id)")
    }

    /// Other screens this record leads to: the records it points at and its related lists, in one section.
    @ViewBuilder
    private func relatedLinks(_ record: Record) -> some View {
        let links = descriptor.links.filter { record.string($0.key) != nil }
        let lists = descriptor.related.filter { $0.embeddedKey == nil && ModuleCatalog.descriptor($0.descriptorID) != nil }
        if !links.isEmpty || !lists.isEmpty {
            DetailSection("Related", systemImage: "link") {
                ForEach(links) { link in
                    LinkTargetRow(link: link, id: record.string(link.key) ?? "")
                }
                ForEach(lists) { related in
                    RelatedSection(related: related, parent: record)
                }
            }
        }
    }

    /// The descriptor's sections, or every field the server sent when it describes none.
    private func sections(for record: Record) -> [SectionSpec] {
        descriptor.detail.isEmpty ? [AutoFields.section(for: record)] : descriptor.detail.filter { $0.isVisible(for: record) }
    }

    /// On a wide page the first section (the record's key facts) sits beside the rest — when there is a rest.
    private func sideSection(for record: Record) -> SectionSpec? {
        let all = sections(for: record)
        return all.count > 1 ? all.first : nil
    }

    private func mainSections(for record: Record) -> [SectionSpec] {
        let all = sections(for: record)
        return all.count > 1 ? Array(all.dropFirst()) : all
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
    /// A card's title when the section has none (a list section stays untitled).
    var fallbackTitle: String?
    @Environment(\.detailLayout) private var layout

    var body: some View {
        let shown = section.fields.filter { FieldFormatter.text(record, $0) != nil }
        if !shown.isEmpty {
            DetailSection {
                ForEach(shown) { field in FieldValueRow(field: field, record: record) }
            } header: {
                if let title = section.title ?? (layout == .cards ? fallbackTitle : nil) {
                    DetailSectionTitle(title)
                }
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
                Text(text).wsParagraph().textSelection(.enabled)
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
                    DetailSection(related.title, systemImage: child.systemImage) {
                        ForEach(rows) { row in
                            if child.api.item != nil {
                                NavigationLink(value: ResourceRoute(descriptorID: child.id, recordID: row.id, seed: row)) {
                                    // Its own colours in a card too (a card's links are otherwise in the accent).
                                    RecordRow(record: row, list: child.list).foregroundStyle(Color(.label))
                                }
                            } else {
                                RecordRow(record: row, list: child.list)
                            }
                        }
                    }
                }
            } else {
                // A link to the related list (a row of the page's "Related" section).
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
