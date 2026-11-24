import Charts
import SwiftUI

/// A project's analytics, as on the web: headline numbers, created against finished over 30 days,
/// cards by status and priority, how long cards take by priority, the team's workload — and the
/// latest activity across the project.
struct ProjectAnalyticsView: View {
    let projectUuid: String
    @Environment(\.services) private var services
    @State private var stats: ProjectAnalytics?
    @State private var statsFailed: APIError?
    @State private var trend: [CompletionTrendPoint] = []
    @State private var priorities: [PriorityCount] = []
    @State private var workload: [WorkloadRow] = []
    @State private var leadTimes: [LeadTimeRow] = []
    @State private var activity: [ProjectActivityRow] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading, stats == nil {
                Section { HStack { ProgressView(); Text("Working out the numbers…") } }
            }
            if let statsFailed {
                Section { InlineErrorRow(error: statsFailed) { Task { await load() } } }
            }
            if let stats {
                Section { kpis(stats) }
                Section("Created and finished, last 30 days") {
                    if trend.isEmpty { noData } else { trendChart.frame(height: 200) }
                }
                Section("Cards by status") {
                    let slices = statusSlices(stats)
                    if slices.isEmpty { noData } else { statusChart(slices).frame(height: 220) }
                }
            }
            Section("Cards by priority") {
                if priorities.isEmpty { noData } else { priorityChart.frame(height: 200) }
            }
            Section {
                if leadTimes.isEmpty { noData } else { leadTimeChart.frame(height: 200) }
            } header: {
                Text("Average time to finish, by priority")
            } footer: {
                Text("Hours from a card being created to being done.")
            }
            Section("Team workload") {
                if workload.isEmpty { noData } else { workloadChart.frame(height: CGFloat(max(160, workload.count * 44))) }
            }
            if !activity.isEmpty {
                Section("Latest activity") {
                    ForEach(activity) { row in
                        Group {
                            if let taskUuid = row.taskUuid {
                                NavigationLink(value: TaskRoute(uuid: taskUuid)) { activityRow(row) }
                            } else {
                                activityRow(row)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Analytics")
        .wsRefreshable { await load() }
        .task { await load() }
    }

    private var noData: some View {
        Text("No data yet.").foregroundStyle(.secondaryText)
    }

    private func kpis(_ s: ProjectAnalytics) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            KPI(title: "Cards", value: "\(s.totalTasks)", detail: "\(s.boardCount) boards · \(s.memberCount) people")
            KPI(title: "Done", value: "\(s.completedTasks)", detail: "\(s.progressPercentage)% of the work", tone: .success)
            KPI(title: "In progress", value: "\(s.inProgressTasks)", detail: "\(s.reviewTasks) in review")
            KPI(title: "Overdue", value: "\(s.overdueTasks)", detail: "\(s.dueTodayTasks) due today", tone: s.overdueTasks > 0 ? .danger : .neutral)
            KPI(title: "Blocked", value: "\(s.blockedTasks)", detail: "need help", tone: s.blockedTasks > 0 ? .warning : .neutral)
            KPI(title: "Points", value: "\(s.completedPoints)/\(s.totalPoints)", detail: "done of total")
            KPI(title: "Time logged", value: Minutes.format(s.totalMinutes), detail: "\(Minutes.format(s.billableMinutes)) billable")
            KPI(title: "Sprints running", value: "\(s.activeSprints)", detail: "\(s.completedSprints) finished")
        }
        .accessibilityIdentifier("analytics.kpis")
    }

    private var trendChart: some View {
        Chart(trend) { point in
            LineMark(x: .value("Day", point.date, unit: .day), y: .value("Cards", point.createdCount))
                .foregroundStyle(by: .value("Kind", "Created"))
            LineMark(x: .value("Day", point.date, unit: .day), y: .value("Cards", point.completedCount))
                .foregroundStyle(by: .value("Kind", "Finished"))
        }
        .chartForegroundStyleScale(["Created": Color.blue, "Finished": Color.green])
        .accessibilityLabel("Cards created and finished each day")
    }

    private struct Slice: Identifiable {
        let name: String
        let count: Int
        let color: Color
        var id: String { name }
    }

    private func statusSlices(_ s: ProjectAnalytics) -> [Slice] {
        [Slice(name: "Open", count: s.openTasks, color: .gray), Slice(name: "In progress", count: s.inProgressTasks, color: .blue),
         Slice(name: "Blocked", count: s.blockedTasks, color: .red), Slice(name: "In review", count: s.reviewTasks, color: .purple),
         Slice(name: "Done", count: s.completedTasks, color: .green), Slice(name: "Cancelled", count: s.cancelledTasks, color: .secondary)]
            .filter { $0.count > 0 }
    }

    private func statusChart(_ slices: [Slice]) -> some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Cards", slice.count), innerRadius: .ratio(0.55), angularInset: 1.5)
                .foregroundStyle(by: .value("Status", slice.name))
                .annotation(position: .overlay) { Text("\(slice.count)").font(.wsCaption.weight(.bold)).foregroundStyle(.white) }
        }
        .chartForegroundStyleScale(domain: slices.map(\.name), range: slices.map(\.color))
        .accessibilityLabel("Cards by status: " + slices.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
    }

    private var priorityChart: some View {
        Chart(priorities) { row in
            BarMark(x: .value("Priority", row.priority.label), y: .value("Cards", row.count))
                .foregroundStyle(row.priority.chartColor)
                .annotation(position: .top) { Text("\(row.count)").font(.wsCaption2) }
        }
        .accessibilityLabel("Cards by priority")
    }

    private var leadTimeChart: some View {
        Chart(leadTimes) { row in
            BarMark(x: .value("Priority", row.priority.label), y: .value("Hours", (row.averageHours * 10).rounded() / 10))
                .foregroundStyle(row.priority.chartColor)
                .annotation(position: .top) { Text(row.averageHours.formatted(.number.precision(.fractionLength(0...1)))).font(.wsCaption2) }
        }
        .chartYAxisLabel("Hours")
        .accessibilityLabel("Average hours to finish by priority")
    }

    private var workloadChart: some View {
        Chart {
            ForEach(workload) { person in
                BarMark(x: .value("Cards", max(0, person.activeTasks - person.overdueTasks)), y: .value("Person", person.name))
                    .foregroundStyle(by: .value("Kind", "Active"))
                BarMark(x: .value("Cards", person.overdueTasks), y: .value("Person", person.name))
                    .foregroundStyle(by: .value("Kind", "Overdue"))
                BarMark(x: .value("Cards", person.completedTasks), y: .value("Person", person.name))
                    .foregroundStyle(by: .value("Kind", "Done"))
            }
        }
        .chartForegroundStyleScale(["Active": Color.blue, "Overdue": Color.red, "Done": Color.green])
        .accessibilityLabel("Team workload: " + workload.map { "\($0.name) \($0.activeTasks) active, \($0.overdueTasks) overdue" }.joined(separator: "; "))
    }

    private func activityRow(_ row: ProjectActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ActorChip(actor: row.activity.actor)
                Text(row.activity.summary.replacingOccurrences(of: "this task", with: "the card")).font(.wsSubheadline)
            }
            Text([row.taskNumber.map { "#\($0)" }, row.taskTitle, Formatters.relative(row.activity.createdAt)].compactMap { $0 }
                .joined(separator: " · "))
                .font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let stats = services.kanban.analytics(projectUuid: projectUuid)
        async let trend = services.kanban.completionTrend(projectUuid: projectUuid)
        async let priorities = services.kanban.priorityDistribution(projectUuid: projectUuid)
        async let workload = services.kanban.teamWorkload(projectUuid: projectUuid)
        async let leadTimes = services.kanban.leadTimes(projectUuid: projectUuid)
        async let activity = services.kanban.projectActivity(projectUuid: projectUuid)
        do {
            self.stats = try await stats
            statsFailed = nil
        } catch {
            statsFailed = error.asAPIError
        }
        self.trend = (try? await trend) ?? []
        self.priorities = (try? await priorities) ?? []
        self.workload = (try? await workload) ?? []
        self.leadTimes = (try? await leadTimes) ?? []
        self.activity = (try? await activity) ?? []
    }
}

private struct KPI: View {
    let title: String
    let value: String
    let detail: String
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value).font(.wsTitle3.weight(.bold)).foregroundStyle(tone == .neutral ? .primary : tone.textColor)
            Text(detail).font(.wsCaption2).foregroundStyle(.secondaryText).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

extension KanbanTaskPriority {
    var chartColor: Color {
        switch self {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .none, .unknown: .gray
        }
    }
}
