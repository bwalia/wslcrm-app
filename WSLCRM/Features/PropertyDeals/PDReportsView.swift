import SwiftUI
import Charts

/// Deal reports (`/reports/*`): how fast deals move, where they get stuck, who replies slowest,
/// supplier speed and what AI costs, for a date range; managers can export any data as CSV or JSON.
struct PDReportsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var from = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
    @State private var to = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var reports: [String: Record] = [:]
    @State private var errors: [String: APIError] = [:]
    @State private var loading = false
    @State private var exportEntity = "deals"
    @State private var exported: URL?
    @State private var exporting = false
    @State private var exportError: APIError?

    static let conversionSeries = [Choice("leads", "Leads"), Choice("deals", "Deals"), Choice("completed", "Completed"),
                                    Choice("fell_through", "Fell through")]
    static let names = ["stage-times", "late-days", "conversion", "supplier-speed", "party-speed", "ai-usage"]
    static let exports = ["deals", "tasks", "properties", "buyer_profiles", "suppliers", "bookings", "enquiries", "chases",
                          "compliance_checks", "approvals", "agent_runs", "matches", "market_records", "stage_history"]

    var body: some View {
        List {
            Section {
                DatePicker("From", selection: $from, displayedComponents: .date).accessibilityIdentifier("pd.reports.from")
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date).accessibilityIdentifier("pd.reports.to")
            } footer: {
                if loading { Text("Loading…") }
            }
            if let error = errors.values.first { Section { InlineErrorRow(error: error) { Task { await load() } } } }
            headline
            stageTimes
            conversion
            partySpeed
            supplierSpeed
            aiUsage
            if session.propertyDeals?.can(.manage, .reports) ?? false { exportSection }
        }
        .navigationTitle("Deal reports")
        .task(id: "\(PDStartRenovationSheet.day(from))-\(PDStartRenovationSheet.day(to))") { await load() }
        .wsRefreshable { await load() }
    }

    private func report(_ name: String) -> Record? { reports[name] }

    @ViewBuilder
    private var headline: some View {
        let late = report("late-days")
        let ai = report("ai-usage")
        Section("At a glance") {
            PDFigureRow(label: "Deals completed", value: late?.string("completed"))
            if let onTime = late?.number("on_time_pct") { PDFigureRow(label: "Completed on time", value: "\(onTime)%") }
            PDFigureRow(label: "Average days late", value: late?.number("avg_days_late"),
                        tone: (late?.int("late") ?? 0) > 0 ? .warning : nil)
            PDFigureRow(label: "Late penalty cost", value: late?.pounds("penalty_cost"),
                        tone: (late?.decimal("penalty_cost") ?? 0) > 0 ? .danger : nil)
            PDFigureRow(label: "AI cost (US$, as the provider bills it)",
                        value: ai?.decimal("total_cost_usd").map { "$\($0.formatted(.number.precision(.fractionLength(2))))" })
        }
        let worst = late?.records("worst") ?? []
        if !worst.isEmpty {
            Section("Latest completions") {
                ForEach(worst) { deal in
                    NavigationLink(value: PDDealRoute(uuid: deal.id)) {
                        LabeledContent(deal.string("name") ?? "Deal", value: "\(deal.int("days_late") ?? 0) days late")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stageTimes: some View {
        let data = report("stage-times")
        let rows = data?.records("completed_stages", idKeys: ["stage_key"]) ?? []
        Section {
            if rows.isEmpty {
                Text("No stages finished in this period.").foregroundStyle(.secondaryText)
            } else {
                Chart {
                    ForEach(rows) { row in
                        BarMark(x: .value("Days", Self.double(row, "avg_days")), y: .value("Stage", Formatters.humanize(row.id)))
                            .foregroundStyle(by: .value("Measure", "Average"))
                            .position(by: .value("Measure", "Average"))
                        BarMark(x: .value("Days", Self.double(row, "median_days")), y: .value("Stage", Formatters.humanize(row.id)))
                            .foregroundStyle(by: .value("Measure", "Median"))
                            .position(by: .value("Measure", "Median"))
                    }
                }
                .frame(height: max(180, CGFloat(rows.count) * 44))
                .accessibilityLabel("Average and median days per stage")
                ForEach(rows) { row in
                    LabeledContent(Formatters.humanize(row.id),
                                   value: "\(row.number("avg_days") ?? "—") days (median \(row.number("median_days") ?? "—"))")
                }
            }
            let current = data?.records("current", idKeys: ["stage_key"]) ?? []
            if !current.isEmpty {
                Text("Now: " + current.map { "\(Formatters.humanize($0.id)) \($0.int("deals") ?? 0) deal(s), \($0.number("avg_days_so_far") ?? "0") days so far" }
                    .joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Time per stage (days, completed)")
        }
    }

    @ViewBuilder
    private var conversion: some View {
        let data = report("conversion")
        let months = data?.records("by_month", idKeys: ["month"]) ?? []
        Section {
            if months.isEmpty {
                Text("Nothing in this period.").foregroundStyle(.secondaryText)
            } else {
                Chart {
                    ForEach(months) { month in
                        ForEach(Self.conversionSeries) { series in
                            BarMark(x: .value("Month", month.id), y: .value("Count", Self.double(month, series.value)))
                                .foregroundStyle(by: .value("What", series.label))
                                .position(by: .value("What", series.label))
                        }
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("Leads, deals, completions and deals that fell through, by month")
            }
            if let totals = data?.object("totals") {
                Text("Lead → deal \(totals.number("lead_to_deal_pct") ?? "—")% · deal → completion \(totals.number("deal_to_completion_pct") ?? "—")%")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            ForEach(data?.records("by_source", idKeys: ["source"]) ?? []) { source in
                LabeledContent(Formatters.humanize(source.id),
                               value: "\(source.int("leads") ?? 0) leads · \(source.int("deals") ?? 0) deals · \(source.int("completed") ?? 0) completed")
            }
        } header: {
            Text("Conversion")
        }
    }

    @ViewBuilder
    private var partySpeed: some View {
        let data = report("party-speed")
        Section {
            let chases = data?.records("chases", idKeys: ["to_party"]) ?? []
            if chases.isEmpty { Text("No chases in this period.").foregroundStyle(.secondaryText) }
            ForEach(chases) { row in
                LabeledContent(Formatters.humanize(row.id),
                               value: "\(row.number("avg_hours_to_reply") ?? "—") h (median \(row.number("median_hours_to_reply") ?? "—"))")
            }
            ForEach(data?.records("enquiries", idKeys: ["owner_party"]) ?? []) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enquiries waiting on \(Formatters.humanize(row.id).lowercased())").font(.wsBody)
                    Text("\(row.int("raised") ?? 0) raised · \(row.int("resolved") ?? 0) resolved · \(row.int("still_open") ?? 0) open · \(row.number("avg_days_to_resolve") ?? "—") days to resolve")
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        } header: {
            Text("Who replies slowest (hours to reply to chases)")
        }
    }

    @ViewBuilder
    private var supplierSpeed: some View {
        let rows = reportRows("supplier-speed").filter { ($0.int("bookings") ?? 0) > 0 }
        Section("Suppliers") {
            if rows.isEmpty { Text("No bookings in this period.").foregroundStyle(.secondaryText) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.string("name") ?? "Supplier").font(.wsBody)
                    Text("\(row.int("bookings") ?? 0) bookings · \(row.number("avg_hours_to_confirm") ?? "—") h to confirm · \(row.number("avg_hours_to_done") ?? "—") h to done · \(row.number("on_time_pct").map { "\($0)%" } ?? "—") on time")
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var aiUsage: some View {
        let data = report("ai-usage")
        let agents = Self.byAgent(data?.records("daily") ?? [])
        Section {
            if agents.isEmpty {
                Text("No AI runs in this period.").foregroundStyle(.secondaryText)
            } else {
                Chart {
                    ForEach(agents, id: \.agent) { row in
                        BarMark(x: .value("Agent", Formatters.humanize(row.agent)), y: .value("Runs", row.runs))
                            .foregroundStyle(by: .value("What", "Runs")).position(by: .value("What", "Runs"))
                        BarMark(x: .value("Agent", Formatters.humanize(row.agent)), y: .value("Runs", row.failed))
                            .foregroundStyle(by: .value("What", "Failed")).position(by: .value("What", "Failed"))
                    }
                }
                .frame(height: 200)
                .accessibilityLabel("AI runs and failures by agent")
                ForEach(agents, id: \.agent) { row in
                    LabeledContent(Formatters.humanize(row.agent),
                                   value: "\(row.runs) runs · \(row.failed) failed · $\(row.cost.formatted(.number.precision(.fractionLength(2))))")
                }
            }
            ForEach(data?.records("approval_outcomes", idKeys: ["agent_key"]) ?? []) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drafts by \(Formatters.humanize(row.id).lowercased())").font(.wsBody)
                    Text("\(row.int("drafts") ?? 0) drafts · \(row.int("approved") ?? 0) approved · \(row.int("edited") ?? 0) edited · \(row.int("rejected") ?? 0) rejected · \(row.int("pending") ?? 0) waiting")
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        } header: {
            Text("AI by agent")
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Picker("What", selection: $exportEntity) {
                ForEach(Self.exports, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
            }
            .accessibilityIdentifier("pd.reports.exportEntity")
            HStack {
                Button("Make CSV") { Task { await export("csv") } }.buttonStyle(.bordered)
                Button("Make JSON") { Task { await export("json") } }.buttonStyle(.bordered)
                if exporting { ProgressView() }
            }
            if let exported {
                ShareLink(item: exported) { Label("Save or share \(exported.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("pd.reports.share")
            }
            if let exportError { InlineErrorRow(error: exportError) }
        } header: {
            Text("Export data")
        } footer: {
            Text("Everything in this workspace for the dates above, as CSV (opens in a spreadsheet) or JSON. Up to 10,000 rows.")
        }
    }

    struct AgentTotals: Sendable {
        let agent: String
        var runs: Double
        var failed: Double
        var cost: Double
    }

    /// The daily rows added up per agent, as the web's chart does.
    static func byAgent(_ daily: [Record]) -> [AgentTotals] {
        var totals: [String: AgentTotals] = [:]
        var order: [String] = []
        for row in daily {
            let agent = row.string("agent_key") ?? "unknown"
            if totals[agent] == nil { totals[agent] = AgentTotals(agent: agent, runs: 0, failed: 0, cost: 0); order.append(agent) }
            totals[agent]?.runs += double(row, "runs")
            totals[agent]?.failed += double(row, "failed")
            totals[agent]?.cost += double(row, "cost_usd")
        }
        return order.compactMap { totals[$0] }
    }

    static func double(_ row: Record, _ key: String) -> Double {
        NSDecimalNumber(decimal: row.decimal(key) ?? 0).doubleValue
    }

    /// A report whose `data` is a bare list (supplier speed).
    private func reportRows(_ name: String) -> [Record] {
        guard let record = reports[name] else { return [] }
        return record.records("_rows", idKeys: ["supplier_uuid"])
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let raw = services.pdRaw
        let query: [String: String?] = ["from": PDStartRenovationSheet.day(from), "to": PDStartRenovationSheet.day(to)]
        await withTaskGroup(of: (String, Result<JSONValue, APIError>).self) { group in
            for name in Self.names {
                group.addTask {
                    do { return (name, .success(try await raw.get("/reports/\(name)", query))) }
                    catch { return (name, .failure(error.asAPIError)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let json):
                    reports[name] = Self.reportRecord(json)
                    errors[name] = nil
                case .failure(let error):
                    if case .cancelled = error { continue }
                    errors[name] = error
                }
            }
        }
    }

    /// The report's `data`: an object, or a list kept under `_rows`.
    static func reportRecord(_ json: JSONValue) -> Record {
        if case .array(let rows)? = json["data"] { return Record(["_rows": .array(rows)]) }
        return PDRaw.record(json) ?? Record([:])
    }

    private func export(_ format: String) async {
        exporting = true
        defer { exporting = false }
        do {
            var query = QueryBuilder()
            query.add("format", format)
            query.add("from", PDStartRenovationSheet.day(from))
            query.add("to", PDStartRenovationSheet.day(to))
            let (data, _) = try await services.client.sendRaw(.get(PDRaw.path("/export/\(exportEntity)"), query: query.items))
            exported = try PDFiles.save(data, filename: "property-deals-\(exportEntity).\(format)")
            exportError = nil
        } catch {
            exportError = error.asAPIError
        }
    }
}
