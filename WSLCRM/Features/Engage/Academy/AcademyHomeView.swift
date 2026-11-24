import SwiftUI

/// The academy (menu key `academy`): your courses, the review queue for admins, and the way to
/// your profile, earnings, payouts and learning. People who can't open courses yet are offered
/// to become an instructor, as on the web.
struct AcademyHomeView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.permissions.can(.read, moduleName: AcademyRBAC.module) {
            AcademyCoursesView()
        } else {
            AcademyJoinView()
        }
    }
}

/// Who may do what, mirroring `routes/academy.lua`: the `courses` grants, and the reviewer gate
/// (`can_manage_all`: a platform admin or the workspace owner).
struct AcademyAccess {
    let canCreate: Bool
    let canUpdate: Bool
    let canDelete: Bool
    let canManage: Bool
    let isReviewer: Bool
    let isPlatformAdmin: Bool

    @MainActor
    init(_ session: SessionStore, instructorOwner: Bool = false) {
        let permissions = session.permissions
        canCreate = permissions.can(.create, moduleName: AcademyRBAC.module)
        canUpdate = permissions.can(.update, moduleName: AcademyRBAC.module)
        canDelete = permissions.can(.delete, moduleName: AcademyRBAC.module)
        canManage = permissions.can(.manage, moduleName: AcademyRBAC.module)
        isPlatformAdmin = permissions.isAdmin || session.user?.platformRoles.contains("administrative") == true
        isReviewer = isPlatformAdmin || permissions.isOwner || session.workspace?.isOwner == true || instructorOwner
    }
}

@MainActor
@Observable
final class AcademyCoursesModel {
    var query = AcademyAPI.CourseQuery()
    private(set) var courses: [AcademyCourse] = []
    private(set) var total = 0
    private(set) var state: LoadState<Void> = .idle
    private(set) var pageError: APIError?
    private(set) var loadingMore = false
    private(set) var pending: [AcademyCourse] = []
    private(set) var pendingError: APIError?
    private(set) var status: AcademyInstructorStatus?
    private var page = 1
    private let api: AcademyAPI

    init(api: AcademyAPI) { self.api = api }

    var hasMore: Bool { courses.count < total }

    func load() async {
        if courses.isEmpty { state = .loading }
        do {
            let first = try await api.courses(query, page: 1)
            courses = first.items
            total = first.total
            page = 1
            pageError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if courses.isEmpty { state = .failed(apiError) } else { pageError = apiError }
        }
    }

    func loadMoreIfNeeded(_ course: AcademyCourse) async {
        guard hasMore, !loadingMore, course.id == courses.last?.id else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = try await api.courses(query, page: page + 1)
            let known = Set(courses.map(\.id))
            courses += next.items.filter { !known.contains($0.id) }
            total = next.total
            page += 1
            pageError = nil
        } catch {
            pageError = error.asAPIError
        }
    }

    func loadStatus() async {
        status = try? await api.instructorStatus()
    }

    func loadPending() async {
        do {
            pending = try await api.pendingCourses()
            pendingError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            pendingError = apiError
        }
    }

    func replace(_ course: AcademyCourse) {
        if let index = courses.firstIndex(where: { $0.id == course.id }) { courses[index] = course }
    }

    func remove(_ uuid: String) {
        courses.removeAll { $0.uuid == uuid }
        pending.removeAll { $0.uuid == uuid }
        total = max(0, total - 1)
    }
}

/// Your courses: search, level and status filters, review queue, create, edit, send for review, delete.
private struct AcademyCoursesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        AcademyCoursesContent(model: AcademyCoursesModel(api: services.academy))
    }
}

private struct AcademyCoursesContent: View {
    @State var model: AcademyCoursesModel
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var notice: EngageNotice?
    @State private var creating = false
    @State private var editing: AcademyCourse?
    @State private var deleting: AcademyCourse?
    @State private var submitting: AcademyCourse?
    @State private var reviewing: (course: AcademyCourse, approve: Bool)?
    @State private var working = false
    @State private var hasAppeared = false

    private var access: AcademyAccess { AcademyAccess(session, instructorOwner: model.status?.isOwner == true) }

    var body: some View {
        List {
            toolsSection
            if !access.isReviewer, !unsubmittedWithLessons.isEmpty { nudgeSection }
            if access.isReviewer { reviewSection }
            coursesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Academy")
        .searchable(text: $model.query.search, prompt: "Search courses")
        .wsRefreshable { await reload() }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar { toolbar }
        .task(id: model.query) {
            if hasAppeared { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.load()
        }
        .task {
            await model.loadStatus()
            if access.isReviewer { await model.loadPending() }
        }
        .onAppear {
            if hasAppeared { Task { await reload() } }
            hasAppeared = true
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                AcademyCourseFormView(existing: nil, isReviewer: access.isReviewer) { _, message in
                    notice = .done(message)
                    Task { await reload() }
                }
            }
        }
        .sheet(item: $editing) { course in
            NavigationStack {
                AcademyCourseFormView(existing: course, isReviewer: access.isReviewer) { saved, message in
                    model.replace(saved)
                    notice = .done(message)
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete course", role: .destructive) {
                if let course = deleting { Task { await delete(course) } }
            }
        } message: {
            Text("Its lessons go too. This can’t be undone.")
        }
        .confirmationDialog("Send “\(submitting?.title ?? "")” for review?", isPresented: Binding(
            get: { submitting != nil }, set: { if !$0 { submitting = nil } }), titleVisibility: .visible) {
            Button("Send for review") {
                if let course = submitting { Task { await submit(course) } }
            }
        } message: {
            Text("An admin approves it before it appears on the academy site. Your lessons aren’t public until then.")
        }
        .confirmationDialog(reviewing?.approve == true ? "Approve and publish?" : "Send back to the instructor?",
                            isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } }),
                            titleVisibility: .visible) {
            if let reviewing {
                Button(reviewing.approve ? "Approve and publish" : "Send back as a draft",
                       role: reviewing.approve ? nil : .destructive) {
                    Task { await review(reviewing.course, approve: reviewing.approve) }
                }
            }
        } message: {
            if let reviewing {
                Text(reviewing.approve
                     ? "“\(reviewing.course.title)” becomes visible on the academy site straight away."
                     : "“\(reviewing.course.title)” goes back to draft so the instructor can change it and send it again.")
            }
        }
    }

    // MARK: Sections

    private var toolsSection: some View {
        Section {
            NavigationLink { AcademyLearningView() } label: {
                Label("My learning", systemImage: "graduationcap")
            }
            .accessibilityIdentifier("academy.learning")
            NavigationLink { AcademyProfileView() } label: {
                Label("My instructor profile", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("academy.profile")
            NavigationLink { AcademyMonetisationView() } label: {
                Label("Earnings and payments", systemImage: "creditcard")
            }
            .accessibilityIdentifier("academy.monetisation")
            if access.isPlatformAdmin {
                NavigationLink { AcademyPayoutsView() } label: {
                    Label("Payouts and platform fee", systemImage: "banknote")
                }
                .accessibilityIdentifier("academy.payouts")
            }
        } header: {
            Text("Manage courses and lessons, and see what you earn.")
                .textCase(nil)
        }
    }

    private var unsubmittedWithLessons: [AcademyCourse] {
        model.courses.filter { $0.statusValue == .draft && ($0.lessonCount ?? 0) > 0 }
    }

    private var nudgeSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your lessons aren’t live yet").font(.wsHeadline)
                    Text("Publishing a lesson only adds it to the course draft. When a course is ready, send it for "
                        + "review; an admin approves it before it goes live. "
                        + (unsubmittedWithLessons.count == 1 ? "1 course has lessons still in draft."
                           : "\(unsubmittedWithLessons.count) courses have lessons still in draft."))
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            } icon: {
                Image(systemName: "checklist").foregroundStyle(Tone.info.textColor)
            }
        }
    }

    private var reviewSection: some View {
        Section {
            if let error = model.pendingError {
                InlineErrorRow(error: error) { Task { await model.loadPending() } }
            } else if model.pending.isEmpty {
                Text("Nothing is waiting for review.").foregroundStyle(.secondaryText)
            }
            ForEach(model.pending) { course in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink {
                        AcademyCourseDetailView(uuid: course.uuid, seed: course, isReviewer: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(course.title).font(.wsHeadline)
                            Text(["/\(course.slug)", course.instructor,
                                  "\(course.lessonCount ?? 0) lesson\((course.lessonCount ?? 0) == 1 ? "" : "s")"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    // Approve / send back are courses.update as well as the reviewer rule (academy.lua).
                    if access.canUpdate {
                        HStack {
                            Button { reviewing = (course, false) } label: { Label("Send back", systemImage: "xmark.circle") }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("academy.review.reject.\(course.uuid)")
                            Button { reviewing = (course, true) } label: { Label("Approve", systemImage: "checkmark.circle") }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("academy.review.approve.\(course.uuid)")
                        }
                        .disabled(working)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Waiting for your review (\(model.pending.count))")
        } footer: {
            Text(access.canUpdate ? "Courses instructors sent for approval. Approving publishes them on the academy site."
                 : "Courses instructors sent for approval. Your role can't change courses, so it can't approve them.")
        }
    }

    private var coursesSection: some View {
        Section {
            if let error = model.pageError { InlineErrorRow(error: error) { Task { await model.load() } } }
            // Loading, failed or empty: a row in this section (over the whole list it covered the
            // other sections).
            if model.courses.isEmpty {
                overlay.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            ForEach(model.courses) { course in
                NavigationLink {
                    AcademyCourseDetailView(uuid: course.uuid, seed: course, isReviewer: access.isReviewer)
                } label: {
                    AcademyCourseRow(course: course, showReviewState: !access.isReviewer)
                }
                .accessibilityIdentifier("academy.course.\(course.uuid)")
                .task { await model.loadMoreIfNeeded(course) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if access.canDelete {
                        Button(role: .destructive) { deleting = course } label: { Label("Delete", systemImage: "trash") }
                    }
                    if access.canUpdate {
                        Button { editing = course } label: { Label("Edit", systemImage: "pencil") }.tint(.indigo)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if !access.isReviewer, access.canUpdate,
                       course.statusValue == .draft || course.statusValue == .archived {
                        Button { submitting = course } label: { Label("Send for review", systemImage: "paperplane") }
                            .tint(.blue)
                    }
                }
                .contextMenu {
                    if access.canUpdate { Button { editing = course } label: { Label("Edit", systemImage: "pencil") } }
                    if !access.isReviewer, access.canUpdate,
                       course.statusValue == .draft || course.statusValue == .archived {
                        Button { submitting = course } label: { Label("Send for review", systemImage: "paperplane") }
                    }
                    if access.canDelete {
                        Button(role: .destructive) { deleting = course } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            if model.loadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
        } header: {
            HStack {
                Text(model.total > 0 ? "Courses (\(model.total))" : "Courses")
                Spacer()
                if model.query.level != nil || model.query.status != nil {
                    Button("Clear filters") { model.query.level = nil; model.query.status = nil }
                        .font(.wsCaption)
                        .textCase(nil)
                }
            }
        } footer: {
            if !model.courses.isEmpty {
                Text("Swipe a course left to edit or delete it\(access.isReviewer ? "" : ", right to send it for review").")
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .idle, .loading where model.courses.isEmpty:
            if model.courses.isEmpty { ProgressView() }
        case .failed(let error) where model.courses.isEmpty:
            ErrorStateView(error: error) { Task { await model.load() } }
        case .loaded where model.courses.isEmpty && model.pending.isEmpty:
            ContentUnavailableView {
                Label(model.query.search.isEmpty && model.query.level == nil && model.query.status == nil
                      ? "No courses yet" : "No courses match", systemImage: "book.closed")
            } description: {
                Text(model.query.search.isEmpty && model.query.level == nil && model.query.status == nil
                     ? (access.canCreate ? "Create your first course with the + button, then add its lessons."
                                         : "Courses you write appear here.")
                     : "Try other words or clear the filters.")
            }
        default:
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Level", selection: $model.query.level) {
                    Text("All levels").tag(AcademyCourseLevel?.none)
                    ForEach(AcademyCourseLevel.allCases) { Text($0.label).tag(AcademyCourseLevel?.some($0)) }
                }
                Picker("Status", selection: $model.query.status) {
                    Text("Any status").tag(AcademyCourseStatus?.none)
                    ForEach(AcademyCourseStatus.allCases) { Text($0.label).tag(AcademyCourseStatus?.some($0)) }
                }
            } label: {
                Label("Filter", systemImage: model.query.level == nil && model.query.status == nil
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityIdentifier("academy.filter")
        }
        if access.canCreate {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New course", systemImage: "plus") }
                    .accessibilityIdentifier("academy.newCourse")
            }
        }
    }

    // MARK: Work

    private func reload() async {
        await model.load()
        if access.isReviewer { await model.loadPending() }
    }

    private func delete(_ course: AcademyCourse) async {
        do {
            try await services.academy.deleteCourse(course.uuid)
            model.remove(course.uuid)
            notice = .done("“\(course.title)” was deleted.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func submit(_ course: AcademyCourse) async {
        working = true
        defer { working = false }
        do {
            let saved = try await services.academy.updateCourse(course.uuid, [("status", AcademyCourseStatus.published.rawValue)])
            model.replace(saved)
            notice = .done(saved.statusValue == .pendingReview
                           ? "Sent for review. An admin approves it before it goes live."
                           : (saved.statusValue == .published ? "Course published." : "Course updated."))
            await reload()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func review(_ course: AcademyCourse, approve: Bool) async {
        working = true
        defer { working = false }
        do {
            if approve {
                try await services.academy.approve(course.uuid)
                notice = .done("“\(course.title)” is approved and published.")
            } else {
                try await services.academy.reject(course.uuid)
                notice = .done("“\(course.title)” went back to the instructor as a draft.")
            }
            await reload()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// One course in a list.
struct AcademyCourseRow: View {
    let course: AcademyCourse
    var showReviewState = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(course.title).font(.wsHeadline).lineLimit(2)
            Text(details).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            HStack(spacing: 8) {
                let status = course.statusValue
                StatusBadge(text: showReviewState && status == .pendingReview ? "In review" : status.label,
                            systemImage: status.systemImage, tone: status.tone)
                Text(course.priceText)
                    .font(.wsSubheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(course.isFree ? Tone.success.textColor : .primary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = ["/\(course.slug)"]
        if let category = course.category { parts.append(category.capitalizedFirst) }
        parts.append(course.levelValue.label)
        let lessons = course.lessonCount ?? 0
        parts.append(lessons == 1 ? "1 lesson" : "\(lessons) lessons")
        if let duration = course.durationText { parts.append(duration) }
        if let updated = EngageFormat.day(course.updatedAt) { parts.append("Updated \(updated)") }
        return parts.joined(separator: " · ")
    }
}
