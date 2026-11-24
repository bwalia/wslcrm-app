import SwiftUI

/// The list screen for any described resource: search, filters, paging, pull to refresh, add.
struct ResourceListView: View {
    let descriptor: ResourceDescriptor
    var query: [String: String] = [:]
    var title: String?
    @Environment(\.services) private var services

    init(_ descriptor: ResourceDescriptor, query: [String: String] = [:], title: String? = nil) {
        self.descriptor = descriptor
        self.query = query
        self.title = title
    }

    init(route: ResourceListRoute) {
        // An unknown id is a programming error caught by ModuleCatalogTests; show nothing rather than crash.
        self.init(ModuleCatalog.descriptor(route.descriptorID) ?? .missing(route.descriptorID),
                  query: route.query, title: route.title)
    }

    var body: some View {
        ResourceListContent(descriptor: descriptor, query: query, title: title, service: services.resources)
            // A new query (a related list for another parent) is a new list.
            .id(query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))
    }
}

/// Fetches pages for one list; the filters chosen on screen are read at fetch time.
@MainActor
final class ResourceListSource {
    let descriptor: ResourceDescriptor
    let query: [String: String]
    let service: ResourceService
    var filters: [String: String] = [:]

    init(descriptor: ResourceDescriptor, query: [String: String], service: ResourceService) {
        self.descriptor = descriptor
        self.query = query
        self.service = service
    }

    func fetch(search: String, page: Int) async throws -> Page<Record> {
        try await service.page(descriptor, search: search, page: page,
                               query: query.merging(filters, uniquingKeysWith: { _, chosen in chosen }))
    }
}

private struct ResourceListContent: View {
    let descriptor: ResourceDescriptor
    let title: String?
    @Environment(SessionStore.self) private var session
    @State private var source: ResourceListSource
    @State private var model: PagedListModel<Record>
    @State private var filters: [String: String] = [:]
    @State private var creating = false
    @State private var running: ActionSpec?
    @State private var confirming: ActionSpec?
    @State private var notice: String?
    @State private var actionError: APIError?
    /// Coming back from a record may mean it changed there: the list reloads.
    @State private var hasAppeared = false

    init(descriptor: ResourceDescriptor, query: [String: String], title: String?, service: ResourceService) {
        self.descriptor = descriptor
        self.title = title
        let source = ResourceListSource(descriptor: descriptor, query: query, service: service)
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in
            try await source.fetch(search: search, page: page)
        })
    }

    var body: some View {
        PagedList(model: model,
                  searchPrompt: descriptor.api.searchParam == nil ? nil
                      : (descriptor.list.searchPrompt ?? "Search \(descriptor.title.lowercased())"),
                  emptyTitle: descriptor.list.emptyTitle ?? "No \(descriptor.title.lowercased()) yet",
                  emptySystemImage: descriptor.systemImage,
                  emptyDescription: descriptor.list.emptyDescription ?? descriptor.summary,
                  emptyActionTitle: "New \(descriptor.noun)",
                  emptyAction: canCreate ? { creating = true } : nil) { record in
            NavigationLink(value: ResourceRoute(descriptorID: descriptor.id, recordID: record.id, seed: record)) {
                RecordRow(record: record, list: descriptor.list)
            }
            .accessibilityIdentifier("resource.row.\(record.id)")
        }
        .navigationTitle(title ?? descriptor.title)
        .safeAreaInset(edge: .top, spacing: 0) { actionResult }
        .onAppear {
            if hasAppeared { Task { await model.load() } }
            hasAppeared = true
        }
        .toolbar {
            if !descriptor.list.filters.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            if !allowedListActions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { listActionsMenu }
            }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Label("New \(descriptor.noun)", systemImage: "plus")
                    }
                    .accessibilityIdentifier("resource.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ResourceFormView(descriptor: descriptor, existing: nil) { _ in
                    Task { await model.load() }
                }
            }
        }
        .sheet(item: $running) { action in
            NavigationStack {
                ActionInputForm(action: action) { inputs in await run(action, inputs: inputs) }
            }
        }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming {
                Button(action.title, role: action.destructive ? .destructive : nil) {
                    Task { _ = await run(action, inputs: [:]) }
                }
            }
        } message: {
            Text(confirming?.confirm ?? "")
        }
    }

    private var allowedListActions: [ActionSpec] {
        descriptor.listActions.filter {
            session.permissions.allows($0.action, $0.module ?? descriptor.permissions.module)
        }
    }

    private var listActionsMenu: some View {
        Menu {
            ForEach(allowedListActions) { action in
                Button(role: action.destructive ? .destructive : nil) {
                    if !action.inputs.isEmpty { running = action }
                    else if action.confirm != nil { confirming = action }
                    else { Task { _ = await run(action, inputs: [:]) } }
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .accessibilityIdentifier("resource.listAction.\(action.id)")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("resource.listActions")
    }

    @ViewBuilder
    private var actionResult: some View {
        if let actionError {
            InlineErrorRow(error: actionError).padding(.horizontal).background(.bar)
        } else if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.wsSubheadline)
                .foregroundStyle(Tone.success.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("resource.notice")
        }
    }

    private func run(_ action: ActionSpec, inputs: [String: JSONValue]) async -> Bool {
        do {
            _ = try await source.service.run(action, on: Record([:]), inputs: inputs,
                                             requiresNamespace: descriptor.api.requiresNamespace)
            actionError = nil
            notice = action.done ?? "\(action.title): done."
            await model.load()
            return true
        } catch {
            actionError = error.asAPIError
            notice = nil
            return false
        }
    }

    private var canCreate: Bool {
        guard descriptor.api.create != nil, descriptor.form != nil else { return false }
        return session.permissions.allows(.create, on: descriptor.permissions)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(descriptor.list.filters) { filter in
                Picker(filter.label, selection: Binding(
                    get: { filters[filter.param] ?? "" },
                    set: { value in
                        filters[filter.param] = value.isEmpty ? nil : value
                        source.filters = filters
                        Task { await model.load() }
                    })) {
                    Text("All").tag("")
                    ForEach(filter.choices) { choice in Text(choice.label).tag(choice.value) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("Filter", systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("resource.filter")
    }
}

/// One row: title, supporting details, a status pill and a value on the right.
struct RecordRow: View {
    let record: Record
    let list: ListSpec

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.wsHeadline).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                }
                if let badge = list.badge, let value = record.string(badge.key) {
                    FieldBadge(field: badge, value: value)
                }
            }
            Spacer(minLength: 8)
            if let trailing = list.trailing, let text = FieldFormatter.text(record, trailing) {
                Text(text).font(.wsSubheadline.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    var title: String {
        for path in list.title {
            if let text = record.string(path) { return text }
        }
        return "Untitled"
    }

    var subtitle: String? {
        let parts = list.subtitle.compactMap { FieldFormatter.text(record, $0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A status-like field as a pill (icon + words + tone, readable without colour).
struct FieldBadge: View {
    let field: FieldSpec
    let value: String

    var body: some View {
        let style: StatusStyle = if case .status(let style) = field.kind { style } else { .standard }
        let label: String = if case .choice(let choices) = field.kind {
            choices.first { $0.value == value }?.label ?? Formatters.humanize(value)
        } else {
            style.label(for: value)
        }
        StatusBadge(text: label, systemImage: style.symbol(for: value), tone: style.tone(for: value))
    }
}

extension PermissionSet {
    /// Writes are open when the descriptor names no module, else the module must grant the action.
    func allows(_ action: Action, _ module: String?) -> Bool {
        guard let module else { return true }
        return can(action, moduleName: module)
    }
}

extension ResourceDescriptor {
    /// Stand-in for an id that isn't in the catalogue (never shipped: ModuleCatalogTests checks every id).
    static func missing(_ id: String) -> ResourceDescriptor {
        ResourceDescriptor(id: id, title: "Not available", noun: "item", systemImage: "questionmark.square.dashed",
                           api: ResourceAPISpec(list: "/api/v2/_missing", searchParam: nil),
                           list: ListSpec(title: ["name"], emptyTitle: "Not available in the app yet"))
    }
}
