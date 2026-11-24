import SwiftUI

/// The site-visit schedule (`GET /api/v2/field-service/visits`), a day or a week at a time.
/// Engineers see their own visits; people who dispatch (`fs_visits.update`) can switch to everyone's,
/// filter by engineer (or unassigned) and status, and move through days or weeks or jump to a date.
struct VisitsScheduleView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var mine: Bool?
    @State private var span: VisitSchedule.Span = .week
    @State private var anchor = VisitSchedule.calendar.startOfDay(for: Date())
    @State private var engineer = ""
    @State private var status = ""
    @State private var engineers: [Engineer] = []
    @State private var state: LoadState<[Visit]> = .idle
    @State private var cachedAt: Date?
    @State private var pickingDate = false

    private var canSeeAll: Bool { session.permissions.can(.update, .fsVisits) }
    private var showsMine: Bool { mine ?? !canSeeAll }

    var body: some View {
        let window = VisitSchedule.window(anchor: anchor, span: span)
        List {
            Section {
                if canSeeAll {
                    Picker("Whose visits", selection: Binding(get: { showsMine }, set: { mine = $0 })) {
                        Text("My visits").tag(true)
                        Text("All visits").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("visits.whose")
                }
                Picker("Show", selection: $span) {
                    Text("Day").tag(VisitSchedule.Span.day)
                    Text("Week").tag(VisitSchedule.Span.week)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("visits.span")
                HStack(spacing: 12) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(span == .day ? "Previous day" : "Previous week")
                        .accessibilityIdentifier("visits.previous")
                    Button { pickingDate = true } label: {
                        Text(VisitSchedule.title(window: window, span: span))
                            .font(.wsHeadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityHint("Pick a date")
                    .accessibilityIdentifier("visits.pickDate")
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(span == .day ? "Next day" : "Next week")
                        .accessibilityIdentifier("visits.next")
                }
                .buttonStyle(.borderless)
                if !window.contains(Date()) {
                    Button("Back to today") { anchor = VisitSchedule.calendar.startOfDay(for: Date()) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("visits.today")
                }
            } footer: {
                Text(filterSummary)
            }

            if let cachedAt { CachedDataNotice(savedAt: cachedAt) }

            switch state {
            case .idle, .loading:
                Section { ForEach(0..<3, id: \.self) { _ in SkeletonRow() } }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let visits):
                ForEach(VisitSchedule.days(visits, window: window, span: span), id: \.date) { day in
                    Section {
                        if day.visits.isEmpty {
                            Text("No visits").foregroundStyle(.secondaryText)
                        }
                        ForEach(day.visits) { visit in
                            NavigationLink(value: VisitRoute(uuid: visit.uuid)) {
                                VisitSummaryRow(visit: visit, showsEngineer: !showsMine)
                            }
                            .accessibilityIdentifier("visits.row.\(visit.uuid)")
                        }
                    } header: {
                        Text(VisitSchedule.dayTitle(day.date, count: day.visits.count))
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Site visits")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        .wsRefreshable { await load() }
        .task(id: VisitSchedule.Key(mine: showsMine, span: span, anchor: anchor, engineer: engineer, status: status)) {
            await load()
        }
        .task {
            guard canSeeAll, engineers.isEmpty else { return }
            engineers = (try? await services.fieldService.engineers()) ?? []
        }
        .sheet(isPresented: $pickingDate) {
            VisitDatePicker(date: anchor) { anchor = VisitSchedule.calendar.startOfDay(for: $0) }
                .presentationDetents([.medium, .large])
        }
    }

    private var filterSummary: String {
        var parts: [String] = [showsMine ? "Your visits" : "Every engineer's visits"]
        if !showsMine, !engineer.isEmpty {
            parts.append(engineer == "unassigned" ? "not assigned yet"
                         : (engineers.first { $0.uuid == engineer }?.displayName ?? "one engineer"))
        }
        if !status.isEmpty { parts.append(VisitSchedule.statusLabel(status).lowercased()) }
        return parts.joined(separator: " · ")
    }

    private var filterMenu: some View {
        Menu {
            if !showsMine {
                Picker("Engineer", selection: $engineer) {
                    Text("All engineers").tag("")
                    Text("Not assigned yet").tag("unassigned")
                    ForEach(engineers) { Text($0.pickerLabel).tag($0.uuid) }
                }
            }
            Picker("Status", selection: $status) {
                Text("All statuses").tag("")
                ForEach(VisitSchedule.statusFilters, id: \.self) { Text(VisitSchedule.statusLabel($0)).tag($0) }
            }
        } label: {
            Label("Filter", systemImage: engineer.isEmpty && status.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                            : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("visits.filter")
    }

    private func step(_ direction: Int) {
        anchor = VisitSchedule.calendar.date(byAdding: .day, value: direction * span.days, to: anchor) ?? anchor
    }

    private func load() async {
        let window = VisitSchedule.window(anchor: anchor, span: span)
        if state.value == nil { state = .loading }
        do {
            var all: [Visit] = []
            var page = 1
            var oldest: Date?
            // A busy week can be more than one page: keep going until the server has sent them all.
            while page <= 10 {
                let query = VisitListQuery(mine: showsMine, status: status.isEmpty ? nil : status,
                                           from: window.start, to: window.end, page: page, perPage: 200,
                                           engineerUuid: showsMine || engineer.isEmpty ? nil : engineer)
                let fetched = try await services.fieldService.visits(query)
                all += fetched.value.items
                if let saved = fetched.cachedAt { oldest = min(oldest ?? saved, saved) }
                guard fetched.value.hasMore else { break }
                page += 1
            }
            state = .loaded(all)
            cachedAt = oldest
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// A graphical calendar to jump the schedule to any date.
private struct VisitDatePicker: View {
    @State var date: Date
    let choose: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("visits.datePicker")
            }
            .navigationTitle("Go to a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") { choose(date); dismiss() }
                        .accessibilityIdentifier("visits.datePicker.show")
                }
            }
        }
    }
}

/// The schedule's arithmetic, kept apart from the view so it can be tested: the window shown,
/// the days in it, and which visits fall on each.
enum VisitSchedule {
    enum Span: Hashable, Sendable {
        case day, week
        var days: Int { self == .day ? 1 : 7 }
    }

    struct Key: Hashable {
        let mine: Bool
        let span: Span
        let anchor: Date
        let engineer: String
        let status: String
    }

    struct Day: Sendable {
        let date: Date
        var visits: [Visit]
    }

    /// Weeks start on Monday.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    /// `server value` for the status filter; "open" = scheduled, en route or on site.
    static let statusFilters = ["open", "scheduled", "en_route", "on_site", "completed", "no_access", "cancelled"]

    static func statusLabel(_ value: String) -> String {
        switch value {
        case "open": "Still to do"
        case "en_route": "On the way"
        case "on_site": "On site"
        case "no_access": "No access"
        default: Formatters.humanize(value)
        }
    }

    static func window(anchor: Date, span: Span) -> DateInterval {
        let calendar = calendar
        let day = calendar.startOfDay(for: anchor)
        let start: Date
        if span == .week {
            start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        } else {
            start = day
        }
        let end = calendar.date(byAdding: .day, value: span.days, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Every day in the window (empty ones too, for the week view) with its visits in time order.
    static func days(_ visits: [Visit], window: DateInterval, span: Span) -> [Day] {
        let calendar = calendar
        var days = (0..<span.days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: window.start).map { Day(date: $0, visits: []) }
        }
        for visit in visits.sorted(by: { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }) {
            guard let start = visit.scheduledStart,
                  let index = days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: start) }) else { continue }
            days[index].visits.append(visit)
        }
        return days
    }

    static func title(window: DateInterval, span: Span) -> String {
        if span == .day {
            return window.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
        let last = calendar.date(byAdding: .day, value: -1, to: window.end) ?? window.end
        return "\(window.start.formatted(.dateTime.day().month(.abbreviated))) – "
            + last.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func dayTitle(_ date: Date, count: Int) -> String {
        let name = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let today = calendar.isDateInToday(date) ? " · Today" : ""
        return "\(name)\(today) — \(count) visit\(count == 1 ? "" : "s")"
    }
}
