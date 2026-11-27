import SwiftUI

// The Simpro report pack: run a report, read it on the phone, and share it as a branded PDF or as
// the server's CSV (the same rows, for Excel or Power BI).

struct ReportRoute: Hashable {
    let key: String
    let title: String
    let filters: [String]
}

struct ReportsListView: View {
    @Environment(\.services) private var services
    @State private var catalogue: LoadState<[ReportCatalogueEntry]> = .idle

    private static let groupOrder = ["Assets", "Compliance", "Operations", "Performance", "Data"]

    var body: some View {
        List {
            switch catalogue {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let entries):
                // Asset history asks for an asset on its own screen (or opens from an asset).
                let runnable = entries
                ForEach(Self.groupOrder, id: \.self) { group in
                    let items = runnable.filter { $0.group == group }
                    if !items.isEmpty {
                        Section(group) {
                            ForEach(items) { entry in
                                NavigationLink(value: ReportRoute(key: entry.key, title: entry.title, filters: entry.filters)) {
                                    Label(entry.title, systemImage: Self.icon(entry.key))
                                }
                                .accessibilityIdentifier("report.\(entry.key)")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reports")
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private func load() async {
        if catalogue.value == nil { catalogue = .loading }
        do { catalogue = .loaded(try await services.simpro.reports()) } catch { catalogue = .failed(error.asAPIError) }
    }

    static func icon(_ key: String) -> String {
        switch key {
        case "asset_failure_history": "exclamationmark.triangle"
        case "ppm_forecast": "calendar.badge.clock"
        case "routine_maintenance": "checkmark.seal"
        case "fgas_register": "snowflake"
        case "employee_licences": "person.text.rectangle"
        case "engineer_locations": "map"
        case "labour_forecast": "chart.bar"
        case "response_times": "timer"
        case "admin_efficiency": "tray.full"
        case "powerbi_extract": "tablecells"
        default: "doc.text"
        }
    }
}

struct ReportDetailView: View {
    let route: ReportRoute
    @Environment(\.services) private var services
    @State private var report: LoadState<Report> = .idle
    @State private var query: ReportQuery
    @State private var pdf: ExportedFile?
    @State private var csv: ExportedFile?
    @State private var exportError: APIError?

    @State private var contractName: String?
    @State private var assetName: String?
    @State private var choosingContract = false
    @State private var choosingAsset = false

    init(route: ReportRoute) {
        self.route = route
        var query = ReportQuery()
        if route.filters.contains("date_range") {
            query.dateFrom = CalendarDay(date: Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date()).isoString
            query.dateTo = CalendarDay(date: Date()).isoString
        }
        if route.filters.contains("months") { query.months = 6 }
        if route.filters.contains("weeks") { query.weeks = 8 }
        if route.filters.contains("expiring_within_days") { query.expiringWithinDays = 90 }
        _query = State(initialValue: query)
    }

    var body: some View {
        List {
            if route.filters.contains("months") {
                Stepper("Next \(query.months ?? 6) months", value: Binding(get: { query.months ?? 6 }, set: { query.months = $0 }),
                        in: 1...24)
            }
            if route.filters.contains("weeks") {
                Stepper("Next \(query.weeks ?? 8) weeks", value: Binding(get: { query.weeks ?? 8 }, set: { query.weeks = $0 }),
                        in: 1...26)
            }
            if route.filters.contains("expiring_within_days") {
                Stepper("Expiring within \(query.expiringWithinDays ?? 90) days",
                        value: Binding(get: { query.expiringWithinDays ?? 90 }, set: { query.expiringWithinDays = $0 }),
                        in: 30...365, step: 30)
            }
            if route.filters.contains("date_range") {
                DatePicker("From", selection: dayBinding(\.dateFrom), displayedComponents: .date)
                    .accessibilityIdentifier("report.from")
                DatePicker("To", selection: dayBinding(\.dateTo), displayedComponents: .date)
                    .accessibilityIdentifier("report.to")
            }
            if route.filters.contains("contract") {
                Button { choosingContract = true } label: {
                    LabeledContent("Contract") { Text(contractName ?? "All contracts") }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("report.contract")
            }
            if route.filters.contains("asset") {
                Button { choosingAsset = true } label: {
                    LabeledContent("Asset") {
                        Text(assetName ?? "Choose an asset").foregroundStyle(assetName == nil ? Color.accentColor : .primary)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("report.asset")
            }

            switch report {
            case .idle, .loading:
                SkeletonRow()
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let report):
                Section {
                    Text(report.description).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    if !report.summaryItems.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            ForEach(report.summaryItems, id: \.label) { item in
                                StatTile(title: item.label, value: item.value, systemImage: ReportsListView.icon(report.key))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("\(report.rows.count) rows") {
                    if report.rows.isEmpty { Text("No rows for these filters").foregroundStyle(.secondaryText) }
                    ForEach(Array(report.rows.prefix(200).enumerated()), id: \.offset) { _, row in
                        ReportRowView(columns: report.columns, row: row)
                    }
                    if report.rows.count > 200 {
                        Text("Showing 200 of \(report.rows.count). The PDF and CSV include every row.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
        }
        .wsDetailList()
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            pdf = nil
            csv = nil
            await load()
        }
        .sheet(isPresented: $choosingContract) {
            NavigationStack {
                ReferencePicker(title: "Contract",
                                spec: ReferenceSpec(list: "\(SimproAPI.base)/contracts", subtitleKeys: ["contract_number",
                                                                                                    "customer_name"],
                                                    paging: .pageAndPerPage)) { record in
                    query.contractUuid = record.string("uuid")
                    contractName = record.string("name")
                } clear: {
                    query.contractUuid = nil
                    contractName = nil
                }
            }
        }
        .sheet(isPresented: $choosingAsset) {
            NavigationStack {
                ReferencePicker(title: "Asset",
                                spec: ReferenceSpec(list: "\(SimproAPI.base)/assets", titleKeys: ["asset_tag", "name"],
                                                    subtitleKeys: ["name", "site_name"], paging: .pageAndPerPage)) { record in
                    query.assetUuid = record.string("uuid")
                    assetName = record.string("asset_tag") ?? record.string("name")
                }
            }
        }
        .wsRefreshable { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let pdf {
                    ShareLink(item: pdf.url) { Label("PDF", systemImage: "doc.richtext") }
                        .accessibilityIdentifier("report.sharePDF")
                }
                if let csv {
                    ShareLink(item: csv.url) { Label("CSV", systemImage: "tablecells") }
                        .accessibilityIdentifier("report.shareCSV")
                }
            }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError?.localizedDescription ?? "")
        }
    }

    /// A date filter as a picker; the server reads plain days (`2026-11-20`).
    private func dayBinding(_ key: WritableKeyPath<ReportQuery, String?>) -> Binding<Date> {
        Binding(get: { query[keyPath: key].flatMap { CalendarDay(string: $0)?.date() } ?? Date() },
                set: { query[keyPath: key] = CalendarDay(date: $0).isoString })
    }

    private func load() async {
        // Asset history is about one asset: nothing to run until one is chosen.
        if route.filters.contains("asset"), query.assetUuid == nil {
            report = .failed(ResourceService.problem(422, "Choose an asset above to see its history."))
            return
        }
        if report.value == nil { report = .loading }
        do {
            let loaded = try await services.simpro.report(route.key, query: query)
            report = .loaded(loaded)
            await prepareExports(loaded)
        } catch {
            report = .failed(error.asAPIError)
        }
    }

    /// Build both files as soon as the report is on screen, so Share is one tap.
    private func prepareExports(_ loaded: Report) async {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        do {
            let data = ReportPDFRenderer(company: Brand.current.company).render(loaded)
            pdf = try ExportedFile.write(data, named: "\(loaded.key)-\(stamp).pdf")
            let csvData = try await services.simpro.reportCSV(route.key, query: query)
            csv = try ExportedFile.write(csvData, named: "\(loaded.key)-\(stamp).csv")
        } catch {
            exportError = error.asAPIError
        }
    }
}

/// One report row as a card: the first column as the title, the rest as label/value lines.
private struct ReportRowView: View {
    let columns: [ReportColumn]
    let row: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let first = columns.first {
                Text(ReportFormat.cell(row[first.key], type: first.type)).font(.wsHeadline)
            }
            ForEach(columns.dropFirst().prefix(8), id: \.key) { column in
                let text = ReportFormat.cell(row[column.key], type: column.type)
                if text != "—" {
                    HStack(alignment: .firstTextBaseline) {
                        Text(column.label).font(.wsFootnote).foregroundStyle(.secondaryText)
                        Spacer(minLength: 12)
                        Text(text).font(.wsFootnote.weight(column.isNumeric ? .semibold : .regular))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

