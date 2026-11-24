import SwiftUI

/// Joy dashboard: speed to lead, enquiry → booked → held → outcome by source, calls held, clients
/// coming back this week, referrals, and the work waiting right now. UK dates.
struct PLDashboardView: View {
    @Environment(\.services) private var services
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var from = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var state: LoadState<Record> = .idle

    var body: some View {
        List {
            Section {
                DatePicker("Enquiries from", selection: $from, in: ...to, displayedComponents: .date)
                    .accessibilityIdentifier("pl.dashboard.from")
                DatePicker("to", selection: $to, in: from..., displayedComponents: .date)
                    .accessibilityIdentifier("pl.dashboard.to")
                Button { Task { await load() } } label: { Label("Show", systemImage: "arrow.clockwise") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("pl.dashboard.show")
            } footer: {
                if let at = state.value?.string("generated_at") {
                    Text("As of \(PLTime.uk(at) ?? at) · UK dates")
                }
            }
            switch state {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let report):
                sections(report)
            }
        }
        .navigationTitle("Joy dashboard")
        .task { if state.value == nil { await load() } }
        .wsRefreshable { await load() }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 150), spacing: 10)]
    }

    @ViewBuilder
    private func sections(_ d: Record) -> some View {
        let speed = d.object("speed") ?? Record([:])
        let calls = d.object("calls") ?? Record([:])
        let now = d.object("now") ?? Record([:])
        let referrals = d.object("referrals") ?? Record([:])
        Section("Speed to lead") {
            if (now.int("blocked_last_24h") ?? 0) > 0 {
                Label("Messages are being held by the allow-list (\(now.int("blocked_last_24h") ?? 0) in the last 24 h). "
                      + "Held auto-replies and recaps don't count as sent, so these figures stay at 0 until sending is "
                      + "switched on. That's expected, not Joy failing.", systemImage: "info.circle")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                PLTile("\(speed.int("enquiries") ?? 0)", "enquiries")
                PLTile(PLTime.duration(seconds(speed, "auto_p50")),
                       "median time to auto-reply (90% within \(PLTime.duration(seconds(speed, "auto_p90"))))",
                       warn: (seconds(speed, "auto_p50") ?? 0) > 30)
                PLTile(PLTime.percent(speed.int("auto_within_30s"), of: speed.int("enquiries")), "auto-replied within 30 s")
                PLTile(PLTime.duration(seconds(speed, "human_p50")),
                       "median time to first human message (90% within \(PLTime.duration(seconds(speed, "human_p90"))))")
                PLTile("\(speed.int("human_replied") ?? 0) / \(speed.int("enquiries") ?? 0)", "have had a message from a person")
            }
            .padding(.vertical, 4)
        }
        funnelSection(d.records("funnel", idKeys: ["source"]))
        Section("Calls held in these dates") {
            LazyVGrid(columns: columns, spacing: 10) {
                PLTile("\(calls.int("held") ?? 0)", "strategy calls held")
                PLTile("\(calls.int("retained") ?? 0)", "retained")
                PLTile("\(calls.int("deployment_interest") ?? 0)", "deployment interest")
                PLTile("\(calls.int("waiting_list") ?? 0)", "waiting list")
                PLTile("\(calls.int("not_ready") ?? 0)", "not ready")
                PLTile("\(calls.int("no_outcome_yet") ?? 0)", "no outcome logged yet", warn: (calls.int("no_outcome_yet") ?? 0) > 0)
                PLTile(PLTime.percent(calls.int("recap_within_2h"), of: calls.int("held")),
                       "recaps sent within 2 h (\(calls.int("recap_late") ?? 0) late, \(calls.int("recap_not_sent") ?? 0) not sent)",
                       warn: (calls.int("recap_not_sent") ?? 0) > 0)
                PLTile(PLTime.percent(calls.int("notes_within_15m"), of: calls.int("held")), "Joy's call notes within 15 min")
            }
            .padding(.vertical, 4)
        }
        Section("Not ready: coming back this week") {
            let returning = d.records("not_ready_returning", idKeys: ["pl_contact_uuid"])
            if returning.isEmpty { Text("Nobody this week.").foregroundStyle(.secondaryText) }
            ForEach(returning) { person in
                NavigationLink(value: NativeScreenRoute(PLScreens.client, person.id)) {
                    LabeledContent(PLClientRow.name(person),
                                   value: person.string("return_date").flatMap { CalendarDay(string: $0) }
                                       .flatMap { Formatters.day($0.date()) } ?? "")
                }
            }
        }
        Section("Referrals") {
            Text("Referred: \(referrals.int("referred") ?? 0) (\(PLTime.percent(referrals.int("referred_booked"), of: referrals.int("referred"))) booked) · "
                 + "Cold: \(referrals.int("cold") ?? 0) (\(PLTime.percent(referrals.int("cold_booked"), of: referrals.int("cold"))) booked)")
            ForEach(d.records("top_referrers", idKeys: ["pl_contact_uuid"])) { person in
                NavigationLink(value: NativeScreenRoute(PLScreens.client, person.id)) {
                    LabeledContent(PLClientRow.name(person), value: "\(person.int("enquiries") ?? 0)")
                }
            }
        }
        Section("Waiting right now") {
            LazyVGrid(columns: columns, spacing: 10) {
                PLTile("\(now.int("open_alerts") ?? 0)", "open alerts", warn: (now.int("open_alerts") ?? 0) > 0)
                PLTile("\(now.int("overdue_tasks") ?? 0)", "overdue tasks", warn: (now.int("overdue_tasks") ?? 0) > 0)
                PLTile("\(now.int("drafts_waiting") ?? 0)", "drafts to review")
                PLTile("\(now.int("blocked_last_24h") ?? 0)", "messages blocked by the allow-list (24 h)")
            }
            .padding(.vertical, 4)
            NavigationLink(value: NativeScreenRoute(PLScreens.drafts)) {
                Label("Review drafts", systemImage: "tray.full")
            }
        }
    }

    @ViewBuilder
    private func funnelSection(_ funnel: [Record]) -> some View {
        Section {
            if funnel.isEmpty { Text("No enquiries in these dates.").foregroundStyle(.secondaryText) }
            ForEach(funnel) { row in PLFunnelRow(title: PLText.label(row.string("source")), row: PLFunnel(row)) }
            if !funnel.isEmpty {
                PLFunnelRow(title: "All", row: PLFunnel.total(funnel)).fontWeight(.semibold)
            }
        } header: {
            Text("Enquiry → booked → held → outcome, by source")
        } footer: {
            Text("Each client counts once per column. Booked = a strategy call was booked (any status).")
        }
    }

    private func seconds(_ record: Record, _ key: String) -> Double? {
        record.decimal(key).map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await PLAPI(client: services.client).daily(from: PLTime.ukDay(from), to: PLTime.ukDay(to)))
        } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            state = .failed(e)
        }
    }
}

/// One source's funnel counts.
struct PLFunnel: Equatable {
    var enquiries = 0, booked = 0, held = 0, outcome = 0

    init(enquiries: Int = 0, booked: Int = 0, held: Int = 0, outcome: Int = 0) {
        self.enquiries = enquiries
        self.booked = booked
        self.held = held
        self.outcome = outcome
    }

    init(_ row: Record) {
        self.init(enquiries: row.int("enquiries") ?? 0, booked: row.int("booked") ?? 0, held: row.int("held") ?? 0,
                  outcome: row.int("outcome") ?? 0)
    }

    static func total(_ rows: [Record]) -> PLFunnel {
        rows.map { PLFunnel($0) }.reduce(PLFunnel()) {
            PLFunnel(enquiries: $0.enquiries + $1.enquiries, booked: $0.booked + $1.booked, held: $0.held + $1.held,
                     outcome: $0.outcome + $1.outcome)
        }
    }
}

private struct PLFunnelRow: View {
    let title: String
    let row: PLFunnel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.wsHeadline)
                Spacer()
                Text("\(PLTime.percent(row.booked, of: row.enquiries)) booked").font(.wsSubheadline.monospacedDigit())
            }
            Text("\(row.enquiries) enquiries · \(row.booked) booked · \(row.held) held · \(row.outcome) outcome")
                .font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dashboard figure; `warn` marks one that needs attention (icon + tone, not colour alone).
private struct PLTile: View {
    let value: String
    let title: String
    var warn = false

    init(_ value: String, _ title: String, warn: Bool = false) {
        self.value = value
        self.title = title
        self.warn = warn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.wsTitle3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            HStack(alignment: .top, spacing: 4) {
                if warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor) }
                Text(title).font(.wsCaption).foregroundStyle(Color(.label))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(warn ? Tone.warning.color.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(warn ? "Needs attention: \(value) \(title)" : "\(value) \(title)")
    }
}
