import SwiftUI

/// A read-only report: one request, headline numbers, then lists of rows under headings
/// ("Below cost": products, options, products with no cost). Each row can open a native screen.
struct ReportSpec: Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var systemImage: String
    /// `GET` path of the report.
    var path: String
    var query: [String: String] = [:]
    var summary: String?
    /// Headline values (counts, totals) from the report.
    var metrics: [FieldSpec] = []
    var sections: [ReportSectionSpec]

    init(id: String, title: String, systemImage: String, path: String, query: [String: String] = [:],
         summary: String? = nil, metrics: [FieldSpec] = [], sections: [ReportSectionSpec]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.path = path
        self.query = query
        self.summary = summary
        self.metrics = metrics
        self.sections = sections
    }
}

struct ReportSectionSpec: Hashable, Sendable, Identifiable {
    let title: String
    /// Path to the rows in the report's data (`products`).
    let key: String
    let list: ListSpec
    /// Where a row goes: the target and the row's id path.
    var opens: LinkSpec?
    var empty: String?
    var id: String { key }

    init(_ title: String, key: String, list: ListSpec, opens: LinkSpec? = nil, empty: String? = nil) {
        self.title = title
        self.key = key
        self.list = list
        self.opens = opens
        self.empty = empty
    }
}

/// Opens a report by id (`NavigationLink(value: ReportRoute("shop.below_cost"))`).
struct ResourceReportRoute: Hashable, Sendable {
    let id: String
    init(_ id: String) { self.id = id }
}

struct ResourceReportView: View {
    let spec: ReportSpec
    @Environment(\.services) private var services
    @State private var state: LoadState<Record> = .idle

    init(route: ResourceReportRoute) {
        spec = ModuleCatalog.report(route.id) ?? ReportSpec(id: route.id, title: "Not available", systemImage: "questionmark",
                                                           path: "/api/v2/_missing", sections: [])
    }

    init(_ spec: ReportSpec) { self.spec = spec }

    var body: some View {
        List {
            switch state {
            case .loaded(let data):
                if let summary = spec.summary {
                    Section { Text(summary).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                }
                if !spec.metrics.isEmpty {
                    Section {
                        ForEach(spec.metrics) { metric in FieldValueRow(field: metric, record: data) }
                    }
                }
                ForEach(spec.sections) { section in
                    let rows = data.records(section.key)
                    Section {
                        if rows.isEmpty {
                            Text(section.empty ?? "Nothing here.").foregroundStyle(.secondaryText)
                        }
                        ForEach(rows) { row in
                            if let opens = section.opens, let id = row.string(opens.key) {
                                LinkTargetRow(link: opens, id: id, label: RecordRow(record: row, list: section.list))
                            } else {
                                RecordRow(record: row, list: section.list)
                            }
                        }
                    } header: {
                        Text("\(section.title) (\(rows.count))")
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                EmptyView()
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .navigationTitle(spec.title)
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            var query = QueryBuilder()
            for (key, value) in spec.query.sorted(by: { $0.key < $1.key }) { query.add(key, value) }
            let (data, _) = try await services.client.sendRaw(.get(spec.path, query: query.items))
            let json = try ResourceService.decode(data)
            guard let record = ResourceService.parseRecord(json, itemKey: nil, idKeys: []) else {
                throw ResourceService.problem(404, "This report is empty.")
            }
            state = .loaded(record)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}
