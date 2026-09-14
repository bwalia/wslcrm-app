import SwiftUI

@MainActor
@Observable
final class JobsListViewModel {
    var query = JobListQuery()
    private(set) var jobs: [Job] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var isLoadingMore = false
    private(set) var pageError: APIError?
    private var lastPage: Page<Job>?

    private let api: FieldServiceAPI

    init(api: FieldServiceAPI) {
        self.api = api
    }

    var hasMore: Bool { lastPage?.hasMore ?? false }

    func load() async {
        if jobs.isEmpty { state = .loading }
        var first = query
        first.page = 1
        do {
            let page = try await api.jobs(first)
            jobs = page.items
            lastPage = page
            pageError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if jobs.isEmpty {
                state = .failed(apiError)
            } else {
                pageError = apiError
            }
        }
    }

    func loadMoreIfNeeded(current job: Job) async {
        guard hasMore, !isLoadingMore, job.id == jobs.last?.id, let lastPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var next = query
        next.page = lastPage.page + 1
        do {
            let page = try await api.jobs(next)
            let known = Set(jobs.map(\.id))
            jobs.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.lastPage = page
            pageError = nil
        } catch {
            pageError = error.asAPIError
        }
    }
}

struct JobsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: JobsListViewModel?

    var body: some View {
        Group {
            if let model {
                JobsListContent(model: model, canFilterMine: session.policy.isDispatcherForJobs)
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Jobs")
        .onAppear {
            if model == nil { model = JobsListViewModel(api: services.fieldService) }
        }
    }
}

struct JobRoute: Hashable {
    let uuid: String
}

private struct JobsListContent: View {
    @Bindable var model: JobsListViewModel
    let canFilterMine: Bool

    var body: some View {
        List {
            ForEach(model.jobs) { job in
                NavigationLink(value: JobRoute(uuid: job.uuid)) {
                    JobRow(job: job)
                }
                .task { await model.loadMoreIfNeeded(current: job) }
                .accessibilityIdentifier("jobs.row.\(job.jobNumber)")
            }
            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error = model.pageError {
                InlineErrorRow(error: error) {
                    Task {
                        if model.hasMore, let last = model.jobs.last {
                            await model.loadMoreIfNeeded(current: last)
                        } else {
                            await model.load()
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            switch model.state {
            case .idle:
                SkeletonList()
            case .loading where model.jobs.isEmpty:
                SkeletonList()
            case .failed(let error) where model.jobs.isEmpty:
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded where model.jobs.isEmpty:
                ContentUnavailableView {
                    Label(model.query.search.isEmpty ? "No jobs" : "No matching jobs", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text(model.query.status == .open ? "There are no open jobs. Try showing all jobs." : "Try a different filter.")
                } actions: {
                    if model.query.status != .all {
                        Button("Show all jobs") { model.query.status = .all }
                            .buttonStyle(.bordered)
                    }
                }
            default:
                EmptyView()
            }
        }
        .searchable(text: $model.query.search, prompt: "Job number, customer, postcode")
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $model.query.status) {
                        ForEach(JobListQuery.StatusFilter.allCases, id: \.self) { filter in
                            Text(filter == .open ? "Open" : filter == .all ? "All" : Formatters.humanize(filter.rawValue))
                                .tag(filter)
                        }
                    }
                    if canFilterMine {
                        Toggle("Only my jobs", isOn: $model.query.mine)
                    }
                    Toggle("Overdue only", isOn: $model.query.overdue)
                } label: {
                    Label("Filter", systemImage: model.query == JobListQuery(search: model.query.search)
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("jobs.filter")
            }
        }
        .task(id: FilterKey(query: model.query)) {
            // Debounce typing; filter changes load immediately.
            if !model.jobs.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }

    private struct FilterKey: Hashable {
        let status: JobListQuery.StatusFilter
        let search: String
        let mine: Bool
        let overdue: Bool

        init(query: JobListQuery) {
            status = query.status
            search = query.search
            mine = query.mine
            overdue = query.overdue
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.jobNumber)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                if job.priority == .urgent || job.priority == .high {
                    job.priority.badge
                }
                Spacer()
                job.status.badge
            }
            Text(job.title)
                .font(.headline)
                .lineLimit(2)
            if let customer = job.customerName {
                Label(customer, systemImage: "person")
                    .font(.subheadline)
            }
            if let address = job.fullAddress {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 16) {
                if job.phaseCount > 0 {
                    Label("\(job.phasesDone)/\(job.phaseCount) phases", systemImage: "list.bullet.clipboard")
                }
                if let next = job.nextVisitAt {
                    Label(Formatters.dateTime(next) ?? "", systemImage: "calendar")
                }
                if job.isOverdue {
                    Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.danger.color)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
