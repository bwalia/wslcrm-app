import Charts
import SwiftUI

/// Who signed in and what they did in this workspace (`/api/v2/namespace/activity*`, RBAC `activity.read`),
/// and how much AI the workspace used (`/api/v2/namespace/ai-usage`). Read only.
struct ActivityView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case overview, members, log, audit, ai
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .members: "Members"
            case .log: "Log"
            case .audit: "Changes"
            case .ai: "AI"
            }
        }
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var tab: Tab = .overview
    /// The member the log is narrowed to (set from Overview or Members).
    @State private var logMember: ActivityPerson?
    @State private var people: [ActivityPerson] = []

    var body: some View {
        Group {
            if session.permissions.can(.read, moduleName: "activity") {
                VStack(spacing: 0) {
                    SectionTabs(tabs: Tab.allCases, selection: $tab) { $0.title }
                    switch tab {
                    case .overview:
                        ActivityOverviewTab { person in open(person) }
                    case .members:
                        ActivityMembersTab(api: services.workspace()) { person in open(person) }
                    case .log:
                        ActivityLogTab(people: people, member: $logMember)
                    case .audit:
                        ActivityChangesTab(people: people)
                    case .ai:
                        ActivityAIUsageTab(isPlatformAdmin: session.permissions.isAdmin)
                    }
                }
                .task { await loadPeople() }
            } else {
                ContentUnavailableView("You can’t see activity", systemImage: "lock",
                                       description: Text("Seeing who did what needs the Activity permission. Ask the workspace owner."))
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func open(_ person: ActivityPerson) {
        logMember = person
        tab = .log
    }

    /// Everyone in the workspace, for the member filters.
    private func loadPeople() async {
        guard people.isEmpty,
              let json = try? await services.workspace().get("/api/v2/namespace/activity/members",
                                                             query: ["sort": "name", "per_page": "100"]) else { return }
        people = WorkspaceAPI.records(json, idKeys: ["user_uuid"]).compactMap(ActivityPerson.init)
    }
}

/// A member, for filters and links.
struct ActivityPerson: Hashable, Identifiable, Sendable {
    let uuid: String
    let name: String
    var id: String { uuid }

    init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
    }

    init?(_ record: Record) {
        guard let uuid = record.string("user_uuid") else { return nil }
        self.init(uuid: uuid, name: record.string("name") ?? record.string("email") ?? "Someone")
    }
}

/// Labels the dashboard uses for activity, in one place so they can be tested.
enum ActivityLabels {
    /// "crm_accounts.contacts.update" → ("Updated", "Crm accounts › Contacts").
    static func action(_ action: String) -> (verb: String?, area: String) {
        var parts = action.split(separator: ".").map(String.init)
        let verbs = ["read": "Viewed", "create": "Created", "update": "Updated", "delete": "Deleted"]
        var verb: String?
        if let last = parts.last, let label = verbs[last] {
            verb = label
            parts.removeLast()
        }
        return (verb, parts.map { Formatters.humanize($0) }.joined(separator: " › "))
    }

    /// The sign-in method as the dashboard names it.
    static func signInMethod(_ method: String?) -> String? {
        guard let method, !method.isEmpty else { return nil }
        switch method {
        case "password": return "Password"
        case "google": return "Google"
        case "oauth": return "SSO"
        default: return Formatters.humanize(method)
        }
    }

    /// "Safari · iOS" from a user agent; nil when nothing is recognisable.
    static func device(_ userAgent: String?) -> String? {
        guard let ua = userAgent, !ua.isEmpty else { return nil }
        if ua.hasPrefix("WSLCRM-iOS") { return "iPhone app" }
        let browser: String? = if ua.contains("Edg/") { "Edge" } else if ua.contains("Firefox/") { "Firefox" }
            else if ua.contains("Chrome/") || ua.contains("CriOS/") { "Chrome" } else if ua.contains("Safari/") { "Safari" }
            else if ua.lowercased().contains("curl") { "curl" } else { nil }
        let system: String? = if ua.contains("iPhone") { "iOS" } else if ua.contains("iPad") { "iPadOS" }
            else if ua.contains("Android") { "Android" } else if ua.contains("Mac OS X") || ua.contains("Macintosh") { "macOS" }
            else if ua.contains("Windows") { "Windows" } else if ua.contains("Linux") { "Linux" } else { nil }
        let parts = [browser, system].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The tone of an HTTP status.
    static func tone(status: Int) -> Tone {
        if status >= 500 { return .danger }
        if status >= 400 { return .warning }
        if status >= 300 { return .info }
        return .success
    }

    /// The AI features the dashboard names.
    static func feature(_ key: String) -> String {
        switch key {
        case "assistant": "AI assistant"
        case "tax_classify": "Transaction classification"
        case "statement_extract": "Statement reading"
        case "bookkeeping": "Bookkeeping AI"
        case "tax_chat": "Tax AI chat"
        case "health_check": "Model health checks"
        case "other": "Other"
        default: Formatters.humanize(key)
        }
    }

    /// "invoice.updated" / action filter → the verb shown on a change.
    static func changeVerb(_ event: String) -> (label: String, tone: Tone) {
        if event.hasSuffix(".created") { return ("Created", .success) }
        if event.hasSuffix(".deleted") { return ("Deleted", .danger) }
        return ("Updated", .warning)
    }

    /// "crm.deal" → "Crm › Deal".
    static func entity(_ entity: String) -> String {
        entity.split(separator: ".").map { Formatters.humanize(String($0)) }.joined(separator: " › ")
    }

    /// One field change as a line: "status: draft → sent", or "name: Acme" for a create/delete.
    static func changeLines(event: String, old: [String: JSONValue], new: [String: JSONValue]) -> [String] {
        let skipped: Set<String> = ["id", "namespace_id", "created_at", "updated_at"]
        func text(_ value: JSONValue?) -> String {
            guard let value else { return "—" }
            switch value {
            case .null: return "—"
            case .string, .number, .bool: return value.stringValue ?? "—"
            default:
                let data = (try? JSONEncoder.sorted.encode(value)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
        }
        if event.hasSuffix(".updated") || (!old.isEmpty && !new.isEmpty) {
            return Set(old.keys).union(new.keys).sorted().map { "\(Formatters.humanize($0)): \(text(old[$0])) → \(text(new[$0]))" }
        }
        let values = new.isEmpty ? old : new
        return values.keys.filter { !skipped.contains($0) }.sorted().map { "\(Formatters.humanize($0)): \(text(values[$0]))" }
    }
}

// MARK: - Overview

private struct ActivityDay: Identifiable {
    let date: Date
    let activeMembers: Int
    let changes: Int
    let requests: Int
    let errors: Int
    var id: Date { date }
}

private struct ActivityOverviewTab: View {
    let open: (ActivityPerson) -> Void
    @Environment(\.services) private var services
    @State private var days = 30
    @State private var state: LoadState<Record> = .idle

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                }
                .accessibilityIdentifier("activity.overview.range")
            }
            switch state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let summary):
                content(summary)
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .task(id: days) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ summary: Record) -> some View {
        let requests = summary.int("totals.requests") ?? 0
        let errors = summary.int("totals.errors") ?? 0
        let errorShare = requests > 0 ? Double(errors) / Double(requests) : 0
        Section {
            MetricGrid(tiles: [
                MetricTile(title: "Active members", value: activityNumber(summary.int("totals.active_members") ?? 0),
                           detail: "of \(activityNumber(summary.int("totals.members") ?? 0)) members"),
                MetricTile(title: "Active today", value: activityNumber(summary.int("totals.active_today") ?? 0),
                           detail: "since midnight UTC"),
                MetricTile(title: "Changes", value: activityNumber(summary.int("totals.changes") ?? 0),
                           detail: "records added, edited or deleted"),
                MetricTile(title: "Failed requests", value: activityNumber(errors),
                           detail: "\(errorShare.formatted(.percent.precision(.fractionLength(0...1)))) of \(activityNumber(requests)) requests",
                           tone: errorShare > 0.05 ? .warning : .neutral),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
        if requests == 0 {
            Section {
                ContentUnavailableView("No activity yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Nobody has used this workspace in this period. Activity appears here as people sign in and work."))
            }
        } else {
            let series = Self.series(summary)
            Section("Active members per day") {
                Chart(series) { day in
                    AreaMark(x: .value("Day", day.date, unit: .day), y: .value("Active members", day.activeMembers))
                        .foregroundStyle(Color.accentColor.opacity(0.25))
                    LineMark(x: .value("Day", day.date, unit: .day), y: .value("Active members", day.activeMembers))
                }
                .frame(height: 180)
                .accessibilityIdentifier("activity.chart.members")
            }
            Section("Changes and failed requests per day") {
                Chart {
                    ForEach(series) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Count", day.changes))
                            .foregroundStyle(by: .value("Kind", "Changes"))
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Count", day.errors))
                            .foregroundStyle(by: .value("Kind", "Failed requests"))
                    }
                }
                .chartForegroundStyleScale(["Changes": Color.accentColor, "Failed requests": Tone.danger.solidColor])
                .frame(height: 180)
                .accessibilityIdentifier("activity.chart.changes")
            }
            let areas = Array(summary.records("areas", idKeys: ["area"]).prefix(8))
            if !areas.isEmpty {
                let top = max(areas.map { $0.int("requests") ?? 0 }.max() ?? 1, 1)
                Section("Most used areas") {
                    ForEach(areas) { area in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Formatters.humanize(area.string("area") ?? "Other")).font(.wsBody)
                                Spacer()
                                Text("\(activityNumber(area.int("requests") ?? 0)) requests · \(activityNumber(area.int("changes") ?? 0)) changes")
                                    .font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
                            }
                            ProgressView(value: Double(area.int("requests") ?? 0), total: Double(top))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            let members = summary.records("top_members", idKeys: ["user_uuid"])
            if !members.isEmpty {
                Section {
                    ForEach(members) { member in
                        Button {
                            if let person = ActivityPerson(member) { open(person) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.string("name") ?? member.string("email") ?? "Someone").font(.wsHeadline)
                                Text("\(activityNumber(member.int("requests") ?? 0)) requests · \(activityNumber(member.int("changes") ?? 0)) changes · \(activityRelative(member.date("last_active_at"), otherwise: "no activity"))")
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            .foregroundStyle(.primary)
                        }
                        .accessibilityHint("Shows what they did")
                        .accessibilityIdentifier("activity.topMember.\(member.id)")
                    }
                } header: {
                    Text("Most active members")
                } footer: {
                    Text("Tap someone to see what they did.")
                }
            }
        }
    }

    private static func series(_ summary: Record) -> [ActivityDay] {
        summary.records("series", idKeys: ["day"]).compactMap { row in
            guard let raw = row.string("day"), let day = CalendarDay(string: raw) else { return nil }
            return ActivityDay(date: day.date(), activeMembers: row.int("active_members") ?? 0,
                               changes: row.int("changes") ?? 0, requests: row.int("requests") ?? 0,
                               errors: row.int("errors") ?? 0)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/namespace/activity/summary", query: ["days": String(days)])
            state = .loaded(WorkspaceAPI.record(json) ?? Record([:]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

// MARK: - Members

@MainActor
private final class ActivityMembersSource {
    var sort = "last_login"
}

private struct ActivityMembersTab: View {
    let open: (ActivityPerson) -> Void
    @State private var source: ActivityMembersSource
    @State private var model: PagedListModel<Record>
    @State private var sort = "last_login"

    init(api: WorkspaceAPI, open: @escaping (ActivityPerson) -> Void) {
        self.open = open
        let source = ActivityMembersSource()
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in
            let json = try await api.get("/api/v2/namespace/activity/members",
                                         query: ["search": search, "sort": source.sort, "page": String(page), "per_page": "25"])
            return WorkspaceAPI.page(json, page: page, perPage: 25, idKeys: ["user_uuid"])
        })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search by name or email", emptyTitle: "No members",
                  emptySystemImage: "person.2") { member in
            Button {
                if let person = ActivityPerson(member) { open(person) }
            } label: {
                ActivityMemberRow(member: member).foregroundStyle(.primary)
            }
            .accessibilityHint("Shows what they did")
            .accessibilityIdentifier("activity.member.\(member.id)")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Recently signed in").tag("last_login")
                        Text("Name").tag("name")
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("activity.members.sort")
            }
        }
        .onChange(of: sort) { _, value in
            source.sort = value
            Task { await model.load() }
        }
    }
}

private struct ActivityMemberRow: View {
    let member: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(member.string("name") ?? member.string("email") ?? "Someone").font(.wsHeadline)
                if member.bool("is_owner") == true {
                    StatusBadge(text: "Owner", systemImage: "crown", tone: .brand)
                }
                if member.bool("active") == false {
                    StatusBadge(text: "Deactivated", systemImage: "person.slash", tone: .neutral)
                } else if let status = member.string("status"), status != "active" {
                    StatusBadge(text: Formatters.humanize(status), systemImage: "circle", tone: .warning)
                }
            }
            if member.string("name") != nil, let email = member.string("email") {
                Text(email).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Text(signIn).font(.wsFootnote).foregroundStyle(.secondaryText)
            Text("Last active here: \(activityRelative(member.date("last_active_at"), otherwise: "no activity"))")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            Text("Last 30 days: \(activityNumber(member.int("requests_30d") ?? 0)) requests · \(activityNumber(member.int("changes_30d") ?? 0)) changes")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            let failed = member.int("failed_login_count") ?? 0
            if failed > 0 {
                Label("\(failed) failed sign-in\(failed == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            } else {
                Label("Sign-in health OK", systemImage: "checkmark.shield").font(.wsFootnote)
                    .foregroundStyle(Tone.success.textColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var signIn: String {
        let last = member.date("last_login_at").flatMap { Formatters.relative($0) }
        guard let last else { return "Last sign-in: never" }
        let method = ActivityLabels.signInMethod(member.string("last_login_method"))
        let count = member.int("login_count") ?? 0
        return "Last sign-in: \(last)" + (method.map { " · \($0)" } ?? "") + " · \(activityNumber(count)) in total"
    }
}

// MARK: - Activity log

private struct ActivityLogTab: View {
    let people: [ActivityPerson]
    @Binding var member: ActivityPerson?
    @Environment(\.services) private var services
    @State private var kind = "all"
    @State private var area = ""
    @State private var days = 7
    @State private var areas: [String] = []
    @State private var rows: [Record] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var error: APIError?

    private var filterKey: String { "\(kind)|\(area)|\(days)|\(member?.uuid ?? "")" }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $kind) {
                    Text("Everything").tag("all")
                    Text("Changes").tag("changes")
                    Text("Failed").tag("errors")
                }
                .accessibilityIdentifier("activity.log.kind")
                Picker("Member", selection: Binding(get: { member?.uuid ?? "" }, set: { uuid in
                    member = people.first { $0.uuid == uuid }
                })) {
                    Text("Everyone").tag("")
                    ForEach(people) { Text($0.name).tag($0.uuid) }
                    if let member, !people.contains(member) { Text(member.name).tag(member.uuid) }
                }
                .accessibilityIdentifier("activity.log.member")
                Picker("Area", selection: $area) {
                    Text("Every area").tag("")
                    ForEach(areas, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                }
                .accessibilityIdentifier("activity.log.area")
                Picker("Period", selection: $days) {
                    Text("Last 24 hours").tag(1)
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                }
                .accessibilityIdentifier("activity.log.range")
            }
            if let error { Section { InlineErrorRow(error: error) { Task { await load(reset: true) } } } }
            if rows.isEmpty, !loading, error == nil {
                Section {
                    ContentUnavailableView("Nothing in this period", systemImage: "list.bullet.rectangle",
                                           description: Text("Try a longer period or fewer filters."))
                }
            }
            Section {
                ForEach(rows) { row in ActivityLogRow(row: row) }
                if nextCursor != nil {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        Label("Load more", systemImage: "arrow.down.circle")
                    }
                    .disabled(loading)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("activity.log.more")
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .task(id: filterKey) { await load(reset: true) }
        .task(id: days) { await loadAreas() }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let json = try await services.workspace().get("/api/v2/namespace/activity", query: [
                "days": String(days), "user_uuid": member?.uuid, "area": area.isEmpty ? nil : area,
                "kind": kind == "all" ? nil : kind, "cursor": reset ? nil : nextCursor, "limit": "50",
            ])
            let page = WorkspaceAPI.records(json, idKeys: ["cursor"])
            rows = reset ? page : rows + page
            nextCursor = WorkspaceAPI.object(json).string("meta.next_cursor")
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func loadAreas() async {
        guard let json = try? await services.workspace().get("/api/v2/namespace/activity/summary",
                                                             query: ["days": String(days)]) else { return }
        areas = (WorkspaceAPI.record(json) ?? Record([:])).records("areas", idKeys: ["area"]).compactMap { $0.string("area") }
    }
}

private struct ActivityLogRow: View {
    let row: Record

    var body: some View {
        let parsed = ActivityLabels.action(row.string("action") ?? "")
        let status = row.int("status") ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text([parsed.verb, parsed.area.isEmpty ? nil : parsed.area].compactMap { $0 }.joined(separator: " "))
                    .font(.wsHeadline)
                if let hits = row.int("hits"), hits > 1 {
                    Text("×\(hits)").font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
                }
                Spacer()
                StatusBadge(text: "\(status)", systemImage: status >= 400 ? "exclamationmark.triangle" : "checkmark",
                            tone: ActivityLabels.tone(status: status))
            }
            Text(row.string("name") ?? row.string("email") ?? "Someone").font(.wsSubheadline)
            Text(origin).font(.wsFootnote).foregroundStyle(.secondaryText)
            Text([row.string("method"), row.string("route"), row.string("entity_id")].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(2)
            Text(when).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var origin: String {
        let how = row.string("via") == "api_key" ? "API key" : (ActivityLabels.device(row.string("user_agent")) ?? "Browser")
        return [how, row.string("ip")].compactMap { $0 }.joined(separator: " · ")
    }

    private var when: String {
        let date = row.date("occurred_at")
        let relative = Formatters.relative(date) ?? ""
        let exact = date?.formatted(.dateTime.day().month(.abbreviated).hour().minute().second()) ?? ""
        var parts = [relative, exact].filter { !$0.isEmpty }
        if let ms = row.int("duration_ms") { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Audit trail (record changes)

private struct ActivityChangesTab: View {
    let people: [ActivityPerson]
    @Environment(\.services) private var services
    @State private var action = "all"
    @State private var memberUUID = ""
    @State private var entity = ""
    @State private var days = 30
    /// One record's history (from tapping it).
    @State private var record: (entity: String, id: String)?
    @State private var entities: [String] = []
    @State private var rows: [Record] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var error: APIError?

    private var filterKey: String { "\(action)|\(memberUUID)|\(entity)|\(days)|\(record?.entity ?? "")|\(record?.id ?? "")" }

    var body: some View {
        List {
            Section {
                Picker("Change", selection: $action) {
                    Text("Every change").tag("all")
                    Text("Created").tag("created")
                    Text("Updated").tag("updated")
                    Text("Deleted").tag("deleted")
                }
                .accessibilityIdentifier("activity.changes.action")
                Picker("Member", selection: $memberUUID) {
                    Text("Everyone").tag("")
                    ForEach(people) { Text($0.name).tag($0.uuid) }
                }
                .accessibilityIdentifier("activity.changes.member")
                Picker("Record type", selection: $entity) {
                    Text("Every type").tag("")
                    ForEach(entities, id: \.self) { Text(ActivityLabels.entity($0)).tag($0) }
                }
                .disabled(record != nil)
                .accessibilityIdentifier("activity.changes.entity")
                Picker("Period", selection: $days) {
                    Text("Last 24 hours").tag(1)
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                    Text("Last 12 months").tag(365)
                }
                .accessibilityIdentifier("activity.changes.range")
            } footer: {
                Text("Who created, changed or deleted which record, with the values before and after.")
            }
            if let record {
                Section {
                    Label("History of \(ActivityLabels.entity(record.entity)) \(record.id)", systemImage: "clock.arrow.circlepath")
                    Button("Show all records") { self.record = nil }
                        .accessibilityIdentifier("activity.changes.clearRecord")
                }
            }
            if let error { Section { InlineErrorRow(error: error) { Task { await load(reset: true) } } } }
            if rows.isEmpty, !loading, error == nil {
                Section {
                    ContentUnavailableView("No changes in this period", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Try a longer period or fewer filters."))
                }
            }
            Section {
                ForEach(rows) { row in
                    ActivityChangeRow(row: row) { entity, id in record = (entity, id) }
                }
                if nextCursor != nil {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        Label("Load more", systemImage: "arrow.down.circle")
                    }
                    .disabled(loading)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("activity.changes.more")
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .task(id: filterKey) { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let json = try await services.workspace().get("/api/v2/namespace/activity/changes", query: [
                "days": String(days), "user_uuid": memberUUID.isEmpty ? nil : memberUUID,
                "entity": record?.entity ?? (entity.isEmpty ? nil : entity), "entity_id": record?.id,
                "action": action == "all" ? nil : action, "cursor": reset ? nil : nextCursor, "limit": "50",
            ])
            let page = WorkspaceAPI.records(json, idKeys: ["cursor"])
            rows = reset ? page : rows + page
            let meta = WorkspaceAPI.object(json)
            nextCursor = meta.string("meta.next_cursor")
            let listed = meta.array("meta.entities").compactMap(\.stringValue)
            if !listed.isEmpty { entities = listed }
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }
}

private struct ActivityChangeRow: View {
    let row: Record
    let showHistory: (String, String) -> Void
    @State private var expanded = false

    var body: some View {
        let event = row.string("event") ?? ""
        let verb = ActivityLabels.changeVerb(event)
        let lines = ActivityLabels.changeLines(event: event, old: row.objectMap("old_values"), new: row.objectMap("new_values"))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusBadge(text: verb.label, systemImage: "pencil.circle", tone: verb.tone)
                Text(ActivityLabels.entity(row.string("entity") ?? event)).font(.wsHeadline)
            }
            Text(who).font(.wsSubheadline)
            Text(whenAndHow).font(.wsFootnote).foregroundStyle(.secondaryText)
            ForEach(expanded ? lines : Array(lines.prefix(4)), id: \.self) { line in
                Text(line).font(.wsFootnote.monospaced()).lineLimit(expanded ? nil : 2)
            }
            if lines.count > 4 {
                Button(expanded ? "Show fewer fields" : "Show all \(lines.count) fields") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.wsFootnote)
                    .accessibilityIdentifier("activity.change.expand.\(row.id)")
            }
            if let entity = row.string("entity"), let id = row.string("entity_id") {
                Button {
                    showHistory(entity, id)
                } label: {
                    Label("History of this record (\(id))", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .font(.wsFootnote)
                .accessibilityIdentifier("activity.change.history.\(row.id)")
            }
        }
        .padding(.vertical, 2)
    }

    private var who: String {
        if let name = row.string("name") ?? row.string("email") { return name }
        return row.string("via") == "anonymous" ? "Public (signed out)" : "System"
    }

    private var whenAndHow: String {
        var parts = [Formatters.relative(row.date("occurred_at")), Formatters.dateTime(row.date("occurred_at"))].compactMap { $0 }
        if row.string("via") == "api_key" { parts.append("API key") }
        if let ip = row.string("ip") { parts.append(ip) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AI usage

private struct ActivityTokenDay: Identifiable {
    let date: Date
    let input: Int
    let output: Int
    let requests: Int
    var id: Date { date }
}

private struct ActivityAIUsageTab: View {
    let isPlatformAdmin: Bool
    @Environment(\.services) private var services
    @State private var days = 30
    @State private var everyWorkspace = false
    @State private var state: LoadState<Record> = .idle

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                    Text("Last 12 months").tag(365)
                }
                .accessibilityIdentifier("activity.ai.range")
                if isPlatformAdmin {
                    Picker("Show", selection: $everyWorkspace) {
                        Text("This workspace").tag(false)
                        Text("All workspaces").tag(true)
                    }
                    .accessibilityIdentifier("activity.ai.scope")
                }
            }
            switch state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let usage):
                content(usage)
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .task(id: "\(days)|\(everyWorkspace)") { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ usage: Record) -> some View {
        let requests = usage.int("totals.requests") ?? 0
        let calls = usage.int("totals.model_calls") ?? 0
        let input = usage.int("totals.input_tokens") ?? 0
        let output = usage.int("totals.output_tokens") ?? 0
        let cached = usage.int("totals.cached_input_tokens") ?? 0
        let failed = usage.int("totals.failed") ?? 0
        let latency = Double(usage.int("totals.avg_latency_ms") ?? 0) / 1000
        Section {
            MetricGrid(tiles: [
                MetricTile(title: "AI requests", value: activityNumber(requests), detail: "\(activityNumber(calls)) model calls"),
                MetricTile(title: "Tokens used", value: activityCompact(input + output),
                           detail: cached > 0 ? "\(activityCompact(cached)) cached" : "in \(activityCompact(input)) · out \(activityCompact(output))"),
                MetricTile(title: "Members using AI", value: activityNumber(usage.int("totals.users") ?? 0)),
                MetricTile(title: "Failed model calls", value: activityNumber(failed),
                           detail: "\((calls > 0 ? Double(failed) / Double(calls) : 0).formatted(.percent.precision(.fractionLength(0...1)))) · average \(latency.formatted(.number.precision(.fractionLength(1)))) s",
                           tone: failed > 0 ? .warning : .neutral),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
        if requests == 0 && calls == 0 {
            Section {
                ContentUnavailableView("No AI used yet", systemImage: "sparkles",
                                       description: Text("When people use the AI assistant or AI features, the tokens they use are counted here."))
            }
        } else {
            let series = Self.series(usage)
            Section("Tokens per day") {
                Chart {
                    ForEach(series) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.input))
                            .foregroundStyle(by: .value("Kind", "In"))
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.output))
                            .foregroundStyle(by: .value("Kind", "Out"))
                    }
                }
                .frame(height: 180)
                .accessibilityIdentifier("activity.chart.tokens")
            }
            Section("Requests per day") {
                Chart(series) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Requests", day.requests))
                }
                .frame(height: 160)
                .accessibilityIdentifier("activity.chart.requests")
            }
            let features = usage.records("features", idKeys: ["feature"])
            if !features.isEmpty {
                Section("By feature") {
                    ForEach(features) { row in
                        usageRow(ActivityLabels.feature(row.string("feature") ?? "other"), row)
                    }
                }
            }
            let models = usage.records("models", idKeys: ["model"])
            if !models.isEmpty {
                Section("By model") {
                    ForEach(models) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.string("model") ?? "Unknown model").font(.wsHeadline)
                            Text([Formatters.humanize(row.string("provider")),
                                  "\(activityNumber(row.int("model_calls") ?? 0)) calls",
                                  "in \(activityCompact(row.int("input_tokens") ?? 0))" + ((row.int("cached_input_tokens") ?? 0) > 0
                                      ? " (\(activityCompact(row.int("cached_input_tokens") ?? 0)) cached)" : ""),
                                  "out \(activityCompact(row.int("output_tokens") ?? 0))"].joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if everyWorkspace {
                let workspaces = usage.records("workspaces", idKeys: ["namespace_uuid"])
                if !workspaces.isEmpty {
                    Section("By workspace") {
                        ForEach(workspaces) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.string("name") ?? row.string("slug") ?? "Workspace").font(.wsHeadline)
                                Text("\(activityNumber(row.int("users") ?? 0)) members using AI · \(activityNumber(row.int("requests") ?? 0)) requests")
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                                Text(tokens(row)).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            let members = usage.records("members", idKeys: ["user_uuid"])
            if !members.isEmpty {
                Section("By member") {
                    ForEach(members) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.string("name") ?? row.string("email") ?? "Someone").font(.wsHeadline)
                            Text("\(activityNumber(row.int("requests") ?? 0)) requests · \(activityNumber(row.int("model_calls") ?? 0)) model calls")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                            Text(tokens(row)).font(.wsFootnote).foregroundStyle(.secondaryText)
                            Text("Last used \(activityRelative(row.date("last_used_at"), otherwise: "never"))")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func usageRow(_ title: String, _ row: Record) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsHeadline)
            Text("\(activityNumber(row.int("requests") ?? 0)) requests · \(activityNumber(row.int("model_calls") ?? 0)) model calls")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            Text(tokens(row)).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func tokens(_ row: Record) -> String {
        let input = row.int("input_tokens") ?? 0
        let output = row.int("output_tokens") ?? 0
        return "Tokens: in \(activityCompact(input)) · out \(activityCompact(output)) · total \(activityCompact(input + output))"
    }

    private static func series(_ usage: Record) -> [ActivityTokenDay] {
        usage.records("series", idKeys: ["day"]).compactMap { row in
            guard let raw = row.string("day"), let day = CalendarDay(string: String(raw.prefix(10))) else { return nil }
            return ActivityTokenDay(date: day.date(), input: row.int("input_tokens") ?? 0,
                                    output: row.int("output_tokens") ?? 0, requests: row.int("requests") ?? 0)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let json: JSONValue
            if everyWorkspace {
                // Every workspace: platform admins only, not tied to the selected workspace.
                json = try await services.workspace().get("/api/v2/admin/ai-usage", query: ["days": String(days)], namespace: false)
            } else {
                json = try await services.workspace().get("/api/v2/namespace/ai-usage", query: ["days": String(days)])
            }
            state = .loaded(WorkspaceAPI.record(json) ?? Record([:]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}
