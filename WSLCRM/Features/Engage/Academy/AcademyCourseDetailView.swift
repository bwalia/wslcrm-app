import SwiftUI

/// One course: its details, its lessons (add, change, reorder, delete, preview), and the actions
/// its status allows (edit, send for review, approve or send back, delete).
struct AcademyCourseDetailView: View {
    let uuid: String
    var seed: AcademyCourse?
    let isReviewer: Bool
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var course: AcademyCourse?
    @State private var lessons: [AcademyLesson] = []
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var notice: EngageNotice?
    @State private var editing = false
    @State private var deletingLesson: AcademyLesson?
    @State private var confirmingDelete = false
    @State private var confirmingSubmit = false
    @State private var reviewing: Bool?
    @State private var working = false
    @State private var editMode: EditMode = .inactive
    @State private var academySlug: String?
    @State private var hasAppeared = false

    init(uuid: String, seed: AcademyCourse? = nil, isReviewer: Bool) {
        self.uuid = uuid
        self.seed = seed
        self.isReviewer = isReviewer
        _course = State(initialValue: seed)
    }

    private var access: AcademyAccess { AcademyAccess(session) }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            if let course {
                header(course)
                actions(course)
                lessonsSection
            }
        }
        .environment(\.editMode, $editMode)
        .overlay { if course == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("Course")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .wsRefreshable { await load() }
        .task { await load() }
        .task { academySlug = (try? await services.academy.instructorStatus())?.namespace?.slug ?? session.workspace?.slug }
        .onAppear {
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
        .toolbar { toolbar }
        .sheet(isPresented: $editing) {
            if let course {
                NavigationStack {
                    AcademyCourseFormView(existing: course, isReviewer: isReviewer) { saved, message in
                        self.course = saved
                        notice = .done(message)
                        Task { await load() }
                    }
                }
            }
        }
        .confirmationDialog("Delete “\(deletingLesson?.title ?? "")”?", isPresented: Binding(
            get: { deletingLesson != nil }, set: { if !$0 { deletingLesson = nil } }), titleVisibility: .visible) {
            Button("Delete lesson", role: .destructive) {
                if let lesson = deletingLesson { Task { await delete(lesson) } }
            }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog("Delete this course?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete course", role: .destructive) { Task { await deleteCourse() } }
        } message: {
            Text("Its lessons go too. This can’t be undone.")
        }
        .confirmationDialog("Send this course for review?", isPresented: $confirmingSubmit, titleVisibility: .visible) {
            Button("Send for review") { Task { await submit() } }
        } message: {
            Text("An admin approves it before it appears on the academy site. Your lessons aren’t public until then.")
        }
        .confirmationDialog(reviewing == true ? "Approve and publish?" : "Send back to the instructor?",
                            isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } }),
                            titleVisibility: .visible) {
            if let approve = reviewing {
                Button(approve ? "Approve and publish" : "Send back as a draft", role: approve ? nil : .destructive) {
                    Task { await review(approve: approve) }
                }
            }
        } message: {
            Text(reviewing == true ? "It becomes visible on the academy site straight away."
                 : "It goes back to draft so the instructor can change it and send it again.")
        }
    }

    // MARK: Pieces

    private func header(_ course: AcademyCourse) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if let thumbnail = course.thumbnailUrl.flatMap(URL.init(string:)) {
                    RichImage(url: thumbnail, alt: "Course picture").frame(maxHeight: 180)
                }
                Text(course.title).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    StatusBadge(text: course.statusValue.label, systemImage: course.statusValue.systemImage,
                                tone: course.statusValue.tone)
                    Pill(text: course.priceText, systemImage: course.isFree ? "gift" : "tag")
                    if !course.isFree { Pill(text: "Tier \(course.tier)", systemImage: "person.2") }
                }
                if let description = course.description {
                    Text(description).font(.wsBody).foregroundStyle(.secondaryText)
                }
                Text(byline(course)).font(.wsFootnote).foregroundStyle(.secondaryText)
                if !course.tags.isEmpty {
                    Text(course.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.wsFootnote).foregroundStyle(Tone.info.textColor)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func byline(_ course: AcademyCourse) -> String {
        var parts: [String] = []
        if let instructor = course.instructor { parts.append("By \(instructor)") }
        if let category = course.category { parts.append(category.capitalizedFirst) }
        parts.append(course.levelValue.label)
        parts.append(lessons.count == 1 ? "1 lesson" : "\(lessons.count) lessons")
        if let duration = course.durationText { parts.append(duration) }
        if let updated = EngageFormat.day(course.updatedAt) { parts.append("Updated \(updated)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ course: AcademyCourse) -> some View {
        let status = course.statusValue
        Section {
            if access.canUpdate {
                Button { editing = true } label: { Label("Edit course details", systemImage: "pencil") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("academy.course.edit")
            }
            if !isReviewer, access.canUpdate, status == .draft || status == .archived {
                Button { confirmingSubmit = true } label: { Label("Send for review", systemImage: "paperplane") }
                    .frame(minHeight: 44)
                    .disabled(working)
                    .accessibilityIdentifier("academy.course.submit")
            }
            if !isReviewer, status == .pendingReview {
                Label("Waiting for an admin to approve it", systemImage: "hourglass")
                    .foregroundStyle(Tone.warning.textColor)
            }
            if isReviewer, status == .pendingReview, access.canUpdate {
                Button { reviewing = true } label: { Label("Approve and publish", systemImage: "checkmark.circle") }
                    .frame(minHeight: 44)
                    .disabled(working)
                    .accessibilityIdentifier("academy.course.approve")
                Button(role: .destructive) { reviewing = false } label: {
                    Label("Send back to the instructor", systemImage: "xmark.circle")
                }
                .frame(minHeight: 44)
                .disabled(working)
                .accessibilityIdentifier("academy.course.reject")
            }
            if !isReviewer, status == .draft, !lessons.isEmpty {
                Text("Publishing a lesson only adds it to this draft. Send the course for review to put it live.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if access.canDelete {
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete course", systemImage: "trash") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("academy.course.delete")
            }
        }
    }

    private var lessonsSection: some View {
        Section {
            if loaded, lessons.isEmpty {
                Text(access.canCreate ? "No lessons yet. Add your first lesson and start writing."
                                      : "No lessons yet.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(lessons) { lesson in
                NavigationLink {
                    if access.canUpdate {
                        AcademyLessonEditorView(courseUUID: uuid, lessonUUID: lesson.uuid) {
                            notice = .done("Lesson saved.")
                        }
                    } else {
                        AcademyLessonLoader(uuid: lesson.uuid, namespaceSlug: academySlug)
                    }
                } label: {
                    AcademyLessonRow(lesson: lesson)
                }
                .accessibilityIdentifier("academy.lesson.\(lesson.uuid)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if access.canDelete {
                        Button(role: .destructive) { deletingLesson = lesson } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    NavigationLink {
                        AcademyLessonLoader(uuid: lesson.uuid, namespaceSlug: academySlug)
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    NavigationLink {
                        AcademyLessonLoader(uuid: lesson.uuid, namespaceSlug: academySlug)
                    } label: {
                        Label("Preview as a learner", systemImage: "eye")
                    }
                    if access.canDelete {
                        Button(role: .destructive) { deletingLesson = lesson } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .onMove(perform: access.canUpdate ? { from, to in Task { await move(from: from, to: to) } } : nil)
        } header: {
            Text("Lessons (\(lessons.count))")
        } footer: {
            if !lessons.isEmpty {
                Text(access.canUpdate
                     ? "Tap a lesson to change it. Swipe right to preview it as a learner, left to delete it."
                     : "Tap a lesson to see it as a learner.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if access.canUpdate, lessons.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .accessibilityIdentifier("academy.lessons.reorder")
            }
        }
        if access.canCreate {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    AcademyLessonEditorView(courseUUID: uuid, lessonUUID: nil) { notice = .done("Lesson added.") }
                } label: {
                    Label("Add lesson", systemImage: "plus")
                }
                .accessibilityIdentifier("academy.lesson.add")
            }
        }
    }

    // MARK: Work

    private func load() async {
        do {
            let result = try await services.academy.course(uuid)
            course = result.course
            lessons = result.lessons
            loaded = true
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func delete(_ lesson: AcademyLesson) async {
        do {
            try await services.academy.deleteLesson(lesson.uuid)
            lessons.removeAll { $0.uuid == lesson.uuid }
            notice = .done("“\(lesson.title)” was deleted.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func deleteCourse() async {
        do {
            try await services.academy.deleteCourse(uuid)
            notice = .done("Course deleted.")
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        do {
            let saved = try await services.academy.updateCourse(uuid, [("status", AcademyCourseStatus.published.rawValue)])
            course = saved
            notice = .done(saved.statusValue == .pendingReview
                           ? "Sent for review. An admin approves it before it goes live." : "Course published.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func review(approve: Bool) async {
        working = true
        defer { working = false }
        do {
            if approve {
                course = try await services.academy.approve(uuid)
                notice = .done("Approved and published.")
            } else {
                course = try await services.academy.reject(uuid)
                notice = .done("Sent back to the instructor as a draft.")
            }
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    /// Saves the new order: each lesson whose place changed gets its new position.
    private func move(from: IndexSet, to: Int) async {
        let before = lessons
        var reordered = lessons
        reordered.move(fromOffsets: from, toOffset: to)
        lessons = reordered
        let changes = AcademyLessonOrder.changes(before: before, after: reordered)
        do {
            for (lessonUUID, position) in changes {
                try await services.academy.updateLesson(lessonUUID, [("position", String(position))])
            }
            notice = .done("New lesson order saved.")
            await load()
        } catch {
            lessons = before
            notice = .failed(error.asAPIError)
        }
    }
}

enum AcademyLessonOrder {
    /// Positions (1, 2, 3…) for lessons whose place changed.
    static func changes(before: [AcademyLesson], after: [AcademyLesson]) -> [(String, Int)] {
        after.enumerated().compactMap { index, lesson in
            let position = index + 1
            let old = before.first { $0.uuid == lesson.uuid }?.position
            return old == position ? nil : (lesson.uuid, position)
        }
    }
}

struct AcademyLessonRow: View {
    let lesson: AcademyLesson
    var done: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let done {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Tone.success.textColor : .secondaryText)
                    .accessibilityLabel(done ? "Done" : "Not done")
            } else {
                Text(lesson.position.map(String.init) ?? "—")
                    .font(.wsSubheadline.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title).font(.wsHeadline).lineLimit(2)
                if let description = lesson.description {
                    Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let duration = lesson.durationText { Pill(text: duration, systemImage: "clock") }
                    if lesson.isPreview { Pill(text: "Preview", systemImage: "eye") }
                    if lesson.hasVideo { Pill(text: "Video", systemImage: "film") }
                    if done == nil {
                        StatusBadge(text: lesson.statusValue.label,
                                    systemImage: lesson.statusValue == .published ? "checkmark.circle" : "pencil.circle",
                                    tone: lesson.statusValue == .published ? .success : .warning)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Loads one lesson (with its content) and shows it as a learner would.
struct AcademyLessonLoader: View {
    let uuid: String
    var namespaceSlug: String?
    @Environment(\.services) private var services
    @State private var state: LoadState<AcademyLesson> = .idle

    var body: some View {
        Group {
            switch state {
            case .loaded(let lesson):
                AcademyLessonReaderView(lesson: lesson, namespaceSlug: namespaceSlug)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            default:
                SkeletonList()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await services.academy.lesson(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}
