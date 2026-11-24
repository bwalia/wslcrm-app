import SwiftUI

/// My learning: the courses you're taking (with your progress) and the academy's other courses,
/// which you can join (free ones) and study, lesson by lesson.
struct AcademyLearningView: View {
    @Environment(\.services) private var services
    @State private var namespace: AcademyNamespace?
    @State private var learning: AcademyLearning?
    @State private var catalogue: [AcademyLearnerCourse] = []
    @State private var error: APIError?
    @State private var loading = true

    var body: some View {
        List {
            if let error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            if let learning {
                statsSection(learning)
                mineSection(learning)
            }
            if !others.isEmpty || (learning != nil && !loading) {
                cataloguesection
            }
        }
        .overlay { if loading, learning == nil, error == nil { SkeletonList() } }
        .navigationTitle("My learning")
        .wsRefreshable { await load() }
        .task { await load() }
    }

    private var others: [AcademyLearnerCourse] {
        let mine = Set(learning?.courses.map(\.id) ?? [])
        return catalogue.filter { !mine.contains($0.id) }
    }

    private func statsSection(_ learning: AcademyLearning) -> some View {
        Section {
            EngageMetricGrid(metrics: [
                .init(title: "Courses taken", value: learning.coursesEnrolled.formatted(), systemImage: "books.vertical", tone: .info),
                .init(title: "Courses finished", value: learning.coursesCompleted.formatted(), systemImage: "rosette", tone: .success),
                .init(title: "Lessons done", value: learning.lessonsCompleted.formatted(), systemImage: "checkmark.circle", tone: .brand),
                .init(title: "Minutes learned", value: learning.minutesCompleted.formatted(), systemImage: "clock", tone: .progress),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
        }
    }

    private func mineSection(_ learning: AcademyLearning) -> some View {
        Section {
            if learning.courses.isEmpty {
                Text("You haven’t started a course yet. Pick one below.").foregroundStyle(.secondaryText)
            }
            ForEach(learning.courses) { item in
                NavigationLink {
                    if let namespace { AcademyLearnerCourseView(namespace: namespace.slug, slug: item.course.slug, title: item.course.title) }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.course.title).font(.wsHeadline)
                        if let instructor = item.instructorName ?? item.course.instructor {
                            Text("By \(instructor)").font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        if let progress = item.progress {
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                                .accessibilityLabel("Progress")
                                .accessibilityValue("\(progress.percent) percent")
                            Text(progress.total == 0 ? "No lessons yet"
                                 : "\(progress.completed) of \(progress.total) lessons done · \(progress.percent)%")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityIdentifier("academy.learning.course.\(item.id)")
            }
        } header: { Text("Your courses") }
    }

    private var cataloguesection: some View {
        Section {
            if others.isEmpty {
                Text("There are no other courses right now.").foregroundStyle(.secondaryText)
            }
            ForEach(others) { item in
                NavigationLink {
                    if let namespace { AcademyLearnerCourseView(namespace: namespace.slug, slug: item.course.slug, title: item.course.title) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.course.title).font(.wsHeadline)
                        Text([item.instructorName ?? item.course.instructor, item.course.levelValue.label,
                              "\(item.lessons.count) lesson\(item.lessons.count == 1 ? "" : "s")"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                        Text(item.course.priceText)
                            .font(.wsSubheadline.weight(.semibold))
                            .foregroundStyle(item.course.isFree ? Tone.success.textColor : .primary)
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityIdentifier("academy.catalogue.course.\(item.id)")
            }
        } header: { Text("All courses") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let status = try await services.academy.instructorStatus()
            guard let namespace = status.namespace else {
                throw ResourceService.problem(404, "The academy isn’t available for this workspace yet.")
            }
            self.namespace = namespace
            async let mine = services.academy.learning(namespace: namespace.slug)
            async let all = services.academy.catalogue(namespace: namespace.slug)
            learning = try await mine
            catalogue = (try? await all) ?? []
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }
}

/// A course on the learner's side: join it (free), see progress, open its lessons.
struct AcademyLearnerCourseView: View {
    let namespace: String
    let slug: String
    let title: String
    @Environment(\.services) private var services
    @State private var course: AcademyLearnerCourse?
    @State private var hasAccess = false
    @State private var progress = AcademyCourseProgress()
    @State private var error: APIError?
    @State private var notice: EngageNotice?
    @State private var joining = false

    var body: some View {
        List {
            if let error, course == nil { Section { InlineErrorRow(error: error) { Task { await load() } } } }
            if let course {
                header(course)
                accessSection(course)
                lessonsSection(course)
            }
        }
        .overlay { if course == nil, error == nil { SkeletonList() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .wsRefreshable { await load() }
        .task { await load() }
    }

    private func header(_ item: AcademyLearnerCourse) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let thumbnail = item.course.thumbnailUrl.flatMap(URL.init(string:)) {
                    RichImage(url: thumbnail, alt: "Course picture").frame(maxHeight: 180)
                }
                Text(item.course.title).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                Text([item.instructorName ?? item.course.instructor.map { "By \($0)" }, item.course.levelValue.label,
                      item.course.durationText].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if let description = item.course.description {
                    Text(description).font(.wsBody)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func accessSection(_ item: AcademyLearnerCourse) -> some View {
        Section {
            if hasAccess {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .accessibilityLabel("Progress")
                Text(progress.total == 0 ? "No lessons yet."
                     : "\(progress.completed) of \(progress.total) lessons done.")
                    .font(.wsSubheadline)
                if let next = progress.nextLessonId, let lesson = item.lessons.first(where: { $0.uuid == next }) {
                    NavigationLink {
                        study(item, from: lesson)
                    } label: {
                        Label("Continue: \(lesson.title)", systemImage: "play.circle.fill")
                    }
                    .accessibilityIdentifier("academy.learner.continue")
                } else if progress.total > 0 {
                    Label("You’ve finished this course. Well done!", systemImage: "rosette")
                        .foregroundStyle(Tone.success.textColor)
                }
            } else if item.course.isFree {
                Button { Task { await join() } } label: {
                    Label(joining ? "Joining…" : "Join this course — it’s free", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.large(.brand))
                .disabled(joining)
                .accessibilityIdentifier("academy.learner.join")
            } else {
                Label {
                    Text("This course costs \(item.course.priceText). Paying for it takes Stripe’s secure card payment page, "
                        + "which this app can’t show, so it can’t be bought here yet. Free preview lessons are open below.")
                } icon: {
                    Image(systemName: "creditcard")
                }
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
            }
        }
    }

    private func lessonsSection(_ item: AcademyLearnerCourse) -> some View {
        Section {
            ForEach(item.lessons) { lesson in
                let open = hasAccess || lesson.isPreview
                if open {
                    NavigationLink {
                        study(item, from: lesson)
                    } label: {
                        AcademyLessonRow(lesson: lesson, done: hasAccess ? progress.completedLessonIds.contains(lesson.uuid) : nil)
                    }
                    .accessibilityIdentifier("academy.learner.lesson.\(lesson.uuid)")
                } else {
                    HStack {
                        AcademyLessonRow(lesson: lesson, done: nil)
                        Image(systemName: "lock.fill").foregroundStyle(.secondaryText).accessibilityLabel("Locked")
                    }
                }
            }
        } header: { Text("Lessons (\(item.lessons.count))") }
    }

    private func study(_ item: AcademyLearnerCourse, from lesson: AcademyLesson) -> some View {
        AcademyStudyView(namespace: namespace, lessons: item.lessons.filter { hasAccess || $0.isPreview },
                         start: lesson, tracksProgress: hasAccess,
                         completed: Set(progress.completedLessonIds)) { lessonUUID, done in
            do {
                let answer = try await services.academy.setCompleted(namespace: namespace, lesson: lessonUUID, completed: done)
                if done { progress.completedLessonIds.append(lessonUUID) } else { progress.completedLessonIds.removeAll { $0 == lessonUUID } }
                progress.completed = answer.completedCount?.value ?? progress.completedLessonIds.count
                progress.total = answer.total?.value ?? progress.total
                return true
            } catch {
                notice = .failed(error.asAPIError)
                return false
            }
        }
    }

    private func load() async {
        do {
            let loaded = try await services.academy.publicCourse(namespace: namespace, slug: slug)
            course = loaded
            hasAccess = (try? await services.academy.hasAccess(namespace: namespace, slug: slug)) ?? false
            if hasAccess { progress = (try? await services.academy.courseProgress(namespace: namespace, slug: slug)) ?? progress }
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            try await services.academy.enrol(namespace: namespace, slug: slug)
            notice = .done("You’ve joined the course. Start with the first lesson.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Studying: one lesson at a time, marking each done, with the next one a tap away.
struct AcademyStudyView: View {
    let namespace: String
    let lessons: [AcademyLesson]
    let start: AcademyLesson
    let tracksProgress: Bool
    let completed: Set<String>
    let setCompleted: (String, Bool) async -> Bool
    @State private var current: AcademyLesson?
    @State private var done: Set<String> = []

    var body: some View {
        let lesson = current ?? start
        let index = lessons.firstIndex { $0.uuid == lesson.uuid }
        let next = index.flatMap { lessons.indices.contains($0 + 1) ? lessons[$0 + 1] : nil }
        AcademyLessonReaderView(lesson: lesson, namespaceSlug: namespace,
                                completed: tracksProgress ? done.contains(lesson.uuid) : nil,
                                onToggleComplete: tracksProgress ? { value in
                                    let ok = await setCompleted(lesson.uuid, value)
                                    if ok { if value { done.insert(lesson.uuid) } else { done.remove(lesson.uuid) } }
                                    return ok
                                } : nil,
                                nextLesson: next,
                                openNext: { current = $0 })
            .id(lesson.uuid)
            .onAppear { if done.isEmpty { done = completed } }
    }
}
