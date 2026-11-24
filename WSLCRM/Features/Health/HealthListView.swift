import SwiftUI

/// A filter on a health list: fixed choices, typed text, or another record picked from a list.
struct HealthFilter: Identifiable, Sendable {
    enum Kind: Sendable {
        case choice([Choice])
        case text(placeholder: String)
        case reference(ReferenceSpec)
    }

    let param: String
    let label: String
    let kind: Kind
    var id: String { param }

    init(_ param: String, _ label: String, _ kind: Kind) {
        self.param = param
        self.label = label
        self.kind = kind
    }

    /// The words for a chosen value ("Care home", or the picked record's name).
    func describe(_ value: String, names: [String: String]) -> String {
        switch kind {
        case .choice(let choices): choices.first { $0.value == value }?.label ?? Formatters.humanize(value)
        case .text: "“\(value)”"
        case .reference: names[param] ?? value
        }
    }
}

/// What the person chose on a list: filters (by query parameter) and the order.
struct HealthListChoices: Equatable, Sendable {
    var values: [String: String] = [:]
    /// Names of picked records, by parameter.
    var names: [String: String] = [:]
    var sort: String = ""
    var descending = false

    /// The query sent with each page (`orderBy` + `orderDir`, as the hospital and patient lists take).
    var query: [String: String] {
        var query = values.filter { !$0.value.isEmpty }
        if !sort.isEmpty {
            query["orderBy"] = sort
            query["orderDir"] = descending ? "desc" : "asc"
        }
        return query
    }
}

/// Fetches pages for one list; the person's choices are read at fetch time.
@MainActor
final class HealthListSource {
    let descriptor: ResourceDescriptor
    let fixed: [String: String]
    let service: ResourceService
    var choices = HealthListChoices()

    init(descriptor: ResourceDescriptor, fixed: [String: String], service: ResourceService) {
        self.descriptor = descriptor
        self.fixed = fixed
        self.service = service
    }

    func fetch(search: String, page: Int) async throws -> Page<Record> {
        try await service.page(descriptor, search: search, page: page,
                               query: fixed.merging(choices.query) { _, chosen in chosen })
    }
}

/// A searchable, filterable, sortable list whose rows open a hand-built screen (a hospital, a
/// patient). New records are added with the kit's form.
struct HealthListView<Row: View>: View {
    let descriptor: ResourceDescriptor
    let title: String
    let filters: [HealthFilter]
    let sorts: [Choice]
    /// The form used for "New" (a variant may already know the hospital). nil: no adding here.
    let createDescriptor: ResourceDescriptor?
    let destination: (Record) -> NativeScreenRoute
    let row: (Record) -> Row
    @Environment(SessionStore.self) private var session
    @State private var source: HealthListSource
    @State private var model: PagedListModel<Record>
    @State private var choices: HealthListChoices
    @State private var filtering = false
    @State private var creating = false
    @State private var created: NativeScreenRoute?
    @State private var hasAppeared = false

    init(descriptor: ResourceDescriptor, title: String, service: ResourceService, fixed: [String: String] = [:],
         initial: HealthListChoices = HealthListChoices(), filters: [HealthFilter], sorts: [Choice],
         createDescriptor: ResourceDescriptor?, destination: @escaping (Record) -> NativeScreenRoute,
         @ViewBuilder row: @escaping (Record) -> Row) {
        self.descriptor = descriptor
        self.title = title
        self.filters = filters
        self.sorts = sorts
        self.createDescriptor = createDescriptor
        self.destination = destination
        self.row = row
        let source = HealthListSource(descriptor: descriptor, fixed: fixed, service: service)
        source.choices = initial
        _source = State(initialValue: source)
        _choices = State(initialValue: initial)
        _model = State(initialValue: PagedListModel { search, page in
            try await source.fetch(search: search, page: page)
        })
    }

    var body: some View {
        PagedList(model: model,
                  searchPrompt: descriptor.api.searchParam == nil ? nil : descriptor.list.searchPrompt,
                  emptyTitle: isFiltered ? "Nothing matches these filters" : (descriptor.list.emptyTitle ?? "Nothing here yet"),
                  emptySystemImage: descriptor.systemImage,
                  emptyDescription: isFiltered ? "Change or clear the filters to see more." : descriptor.list.emptyDescription) { record in
            NavigationLink(value: destination(record)) { row(record) }
                .accessibilityIdentifier("health.row.\(record.id)")
        }
        .overlay {
            // A refusal is about the person's role, not a fault: say who can fix it.
            if HealthAccess.isRefused(model.state.error), model.items.isEmpty {
                HealthNoAccessView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
            }
        }
        .navigationTitle(title)
        .safeAreaInset(edge: .top, spacing: 0) { filterSummary }
        .onAppear {
            // Coming back from a record may mean it changed or was deleted there.
            if hasAppeared { Task { await model.load() } }
            hasAppeared = true
        }
        .toolbar {
            if !filters.isEmpty || !sorts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { filtering = true } label: {
                        Label("Filter and sort", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                                                         : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("health.filter")
                }
            }
            if let createDescriptor, session.permissions.allows(.create, createDescriptor.permissions.module) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New \(createDescriptor.noun)", systemImage: "plus") }
                        .accessibilityIdentifier("health.new")
                }
            }
        }
        .sheet(isPresented: $filtering) {
            NavigationStack {
                HealthFilterSheet(filters: filters, sorts: sorts, choices: choices) { chosen in apply(chosen) }
            }
        }
        .sheet(isPresented: $creating) {
            if let createDescriptor {
                NavigationStack {
                    ResourceFormView(descriptor: createDescriptor, existing: nil) { saved in
                        Task {
                            await model.load()
                            // Open what was just added once the form has gone.
                            if let saved {
                                try? await Task.sleep(for: .milliseconds(500))
                                created = destination(saved)
                            }
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $created) { route in NativeScreenView(route: route) }
    }

    private var isFiltered: Bool { !choices.values.filter { !$0.value.isEmpty }.isEmpty }

    @ViewBuilder
    private var filterSummary: some View {
        let shown = filters.compactMap { filter -> String? in
            guard let value = choices.values[filter.param], !value.isEmpty else { return nil }
            return "\(filter.label): \(filter.describe(value, names: choices.names))"
        }
        if !shown.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Label(shown.joined(separator: " · "), systemImage: "line.3.horizontal.decrease")
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
                Spacer(minLength: 8)
                Button("Clear") {
                    var cleared = choices
                    cleared.values = [:]
                    cleared.names = [:]
                    apply(cleared)
                }
                .font(.wsSubheadline.weight(.semibold))
                .accessibilityIdentifier("health.filter.clear")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func apply(_ chosen: HealthListChoices) {
        choices = chosen
        source.choices = chosen
        Task { await model.load() }
    }
}

/// Filters and order for a health list, applied together.
struct HealthFilterSheet: View {
    let filters: [HealthFilter]
    let sorts: [Choice]
    let apply: (HealthListChoices) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HealthListChoices

    init(filters: [HealthFilter], sorts: [Choice], choices: HealthListChoices, apply: @escaping (HealthListChoices) -> Void) {
        self.filters = filters
        self.sorts = sorts
        self.apply = apply
        _draft = State(initialValue: choices)
    }

    var body: some View {
        Form {
            if !filters.isEmpty {
                Section("Show only") {
                    ForEach(filters) { filter in control(filter) }
                }
            }
            if !sorts.isEmpty {
                Section("Order") {
                    Picker("Sort by", selection: $draft.sort) {
                        Text("Usual order").tag("")
                        ForEach(sorts) { Text($0.label).tag($0.value) }
                    }
                    .accessibilityIdentifier("health.sort")
                    if !draft.sort.isEmpty {
                        Picker("Direction", selection: $draft.descending) {
                            Text("A to Z, oldest or smallest first").tag(false)
                            Text("Z to A, newest or largest first").tag(true)
                        }
                        .accessibilityIdentifier("health.sort.direction")
                    }
                }
            }
            Section {
                Button("Clear all", role: .destructive) { draft = HealthListChoices() }
                    .frame(minHeight: 44)
            }
        }
        .navigationTitle("Filter and sort")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Show") {
                    apply(draft)
                    dismiss()
                }
                .accessibilityIdentifier("health.filter.apply")
            }
        }
    }

    @ViewBuilder
    private func control(_ filter: HealthFilter) -> some View {
        let binding = Binding(get: { draft.values[filter.param] ?? "" },
                              set: { draft.values[filter.param] = $0.isEmpty ? nil : $0 })
        switch filter.kind {
        case .choice(let choices):
            Picker(filter.label, selection: binding) {
                Text("Any").tag("")
                ForEach(choices) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("health.filter.\(filter.param)")
        case .text(let placeholder):
            LabeledContent(filter.label) {
                TextField(placeholder, text: binding)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
            .accessibilityIdentifier("health.filter.\(filter.param)")
        case .reference(let spec):
            NavigationLink {
                ReferencePicker(title: filter.label, spec: spec) { record in
                    draft.values[filter.param] = record.string(spec.valueKey) ?? record.id
                    draft.names[filter.param] = spec.titleKeys.lazy.compactMap { record.string($0) }.first ?? record.id
                } clear: {
                    draft.values[filter.param] = nil
                    draft.names[filter.param] = nil
                }
            } label: {
                LabeledContent(filter.label) {
                    Text(draft.values[filter.param].map { filter.describe($0, names: draft.names) } ?? "Any")
                }
            }
            .accessibilityIdentifier("health.filter.\(filter.param)")
        }
    }
}
