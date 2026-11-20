import SwiftUI

/// What a course save sends (`POST /courses`, `PUT /courses/:uuid`, form-encoded like the web).
struct AcademyCourseDraft: Hashable, Sendable {
    var title = ""
    var slug = ""
    var description = ""
    var instructor = ""
    var thumbnailURL = ""
    var category = "general"
    var tags: [String] = []
    var level: AcademyCourseLevel = .beginner
    var isFree = true
    /// What the person typed, in pounds/dollars (sent in minor units).
    var price = ""
    var currency = "USD"
    var tier = 1
    var status: AcademyCourseStatus = .draft

    static let maxTags = 20
    static let maxTagLength = 40

    init(instructor: String = "") { self.instructor = instructor }

    init(_ course: AcademyCourse) {
        title = course.title
        slug = course.slug
        description = course.description ?? ""
        instructor = course.instructor ?? ""
        thumbnailURL = course.thumbnailUrl ?? ""
        category = course.category ?? "general"
        tags = course.tags
        level = course.levelValue
        isFree = course.isFree
        price = course.price > 0 ? AcademyMoney.major(course.price) : ""
        currency = course.currency.uppercased()
        tier = course.tier
        status = course.statusValue
    }

    /// Adds a tag the way the web does: trimmed, at most 40 characters, no repeats, at most 20.
    mutating func addTag(_ raw: String) {
        let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTagLength))
        guard !value.isEmpty, tags.count < Self.maxTags,
              !tags.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        tags.append(value)
    }

    var priceMinor: Int { isFree ? 0 : (AcademyMoney.minor(fromTyped: price) ?? 0) }

    /// What to fix before saving, in plain words.
    var problem: String? {
        if title.trimmedOrNil == nil { return "Give the course a title." }
        if !isFree, priceMinor <= 0 { return "A paid course needs a price above 0, for example 9.99." }
        if let url = thumbnailURL.trimmedOrNil, !(url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("http://")) {
            return "The picture’s web address should start with https://"
        }
        return nil
    }

    var formFields: [(String, String)] {
        var fields: [(String, String)] = [
            ("title", title.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("description", description),
            ("instructor", instructor),
            ("thumbnail_url", thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("category", category.trimmedOrNil ?? "general"),
            // A JSON list in one field, so an empty list clears the tags (as the web sends it).
            ("tags", AcademyJSON.text(tags)),
            ("level", level.rawValue),
            ("is_free", isFree ? "true" : "false"),
            ("price", String(priceMinor)),
            ("currency", currency),
            ("tier", String(max(1, tier))),
            ("status", status.rawValue),
        ]
        if let slug = slug.trimmedOrNil { fields.insert(("slug", slug), at: 1) }
        return fields
    }
}

/// Create or change a course. Reviewers (platform admin, workspace owner) can publish directly;
/// everyone else sends it for review, as on the server.
struct AcademyCourseFormView: View {
    let existing: AcademyCourse?
    let isReviewer: Bool
    let onSaved: (AcademyCourse, String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AcademyCourseDraft()
    @State private var original = AcademyCourseDraft()
    @State private var prepared = false
    @State private var categories: [String] = []
    @State private var tagDraft = ""
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Tone.danger.textColor)
                        .accessibilityIdentifier("academy.course.problem")
                }
            }
            if let error { Section { InlineErrorRow(error: error) } }
            aboutSection
            Section {
                LabeledContent("Instructor") {
                    Text(draft.instructor.trimmedOrNil ?? (session.user?.displayName ?? "You"))
                }
            } footer: {
                Text("You’re the instructor. Change the name learners see in My instructor profile.")
            }
            organiseSection
            statusSection
            priceSection
        }
        .navigationTitle(existing == nil ? "New course" : "Edit course")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("academy.course.save")
            }
        }
        .interactiveDismissDisabled(saving || draft != original)
        .onAppear(perform: prepare)
        .task { categories = (try? await services.academy.categories()) ?? [] }
    }

    private var aboutSection: some View {
        Section {
            TextField("Title (needed), e.g. Introduction to TypeScript", text: $draft.title)
                .accessibilityIdentifier("academy.course.title")
            TextField("Short summary of the course", text: $draft.description, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("academy.course.description")
            TextField("Web address name (optional, made from the title)", text: $draft.slug)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("academy.course.slug")
            TextField("Picture address, https://…/thumb.jpg", text: $draft.thumbnailURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("academy.course.thumbnail")
            if let url = URL(string: draft.thumbnailURL.trimmingCharacters(in: .whitespaces)),
               draft.thumbnailURL.lowercased().hasPrefix("http") {
                RichImage(url: url, alt: "Course picture").frame(maxHeight: 160)
            }
        } header: { Text("About the course") }
    }

    private var organiseSection: some View {
        Section {
            HStack {
                TextField("Category", text: $draft.category)
                    .accessibilityIdentifier("academy.course.category")
                if !categories.isEmpty {
                    Menu {
                        ForEach(categories, id: \.self) { category in
                            Button(category) { draft.category = category }
                        }
                    } label: {
                        Label("Choose", systemImage: "chevron.up.chevron.down").labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Choose a category you already use")
                    .accessibilityIdentifier("academy.course.categoryMenu")
                }
            }
            Picker("Level", selection: $draft.level) {
                ForEach(AcademyCourseLevel.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("academy.course.level")
            HStack {
                TextField("Add a tag", text: $tagDraft)
                    .onSubmit(addTag)
                    .submitLabel(.done)
                    .accessibilityIdentifier("academy.course.tag")
                Button("Add", action: addTag)
                    .disabled(tagDraft.trimmedOrNil == nil || draft.tags.count >= AcademyCourseDraft.maxTags)
                    .accessibilityIdentifier("academy.course.addTag")
            }
            if !draft.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(draft.tags, id: \.self) { tag in
                            Button {
                                draft.tags.removeAll { $0 == tag }
                            } label: {
                                Label(tag, systemImage: "xmark.circle.fill")
                                    .font(.wsSubheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                }
            }
        } header: { Text("Sorting") } footer: {
            Text("Pick a category you already use or type a new one. Tags help learners find the course "
                + "(up to 20; tap a tag to remove it).")
        }
    }

    private var statusSection: some View {
        Section {
            Picker("Status", selection: $draft.status) {
                if isReviewer {
                    Text("Draft").tag(AcademyCourseStatus.draft)
                    if draft.status == .pendingReview { Text("Waiting for review").tag(AcademyCourseStatus.pendingReview) }
                    Text("Published").tag(AcademyCourseStatus.published)
                    Text("Archived").tag(AcademyCourseStatus.archived)
                } else {
                    Text("Save as draft").tag(AcademyCourseStatus.draft)
                    Text(draft.status == .pendingReview ? "Waiting for review" : "Send for review")
                        .tag(draft.status == .pendingReview ? AcademyCourseStatus.pendingReview : AcademyCourseStatus.published)
                    Text("Archived").tag(AcademyCourseStatus.archived)
                }
            }
            .accessibilityIdentifier("academy.course.status")
        } footer: {
            if isReviewer {
                Text("Published courses show on the academy site straight away.")
            } else if draft.status == .pendingReview {
                Text("An admin is checking it. Saving keeps it in the queue.")
            } else {
                Text("An admin approves a course before it appears on the academy site.")
            }
        }
    }

    private var priceSection: some View {
        Section {
            Toggle("This is a free course", isOn: $draft.isFree)
                .accessibilityIdentifier("academy.course.free")
            if !draft.isFree {
                LabeledContent("Price") {
                    TextField("e.g. 9.99", text: $draft.price)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("academy.course.price")
                }
                Picker("Currency", selection: $draft.currency) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("academy.course.currency")
                Stepper(value: $draft.tier, in: 1...20) {
                    LabeledContent("Membership tier", value: "\(draft.tier)")
                }
                .accessibilityIdentifier("academy.course.tier")
            }
        } header: { Text("Price") } footer: {
            if !draft.isFree {
                Text("What a learner pays. A member can watch it when their membership tier is this number or higher "
                    + "(tier 1 is your entry plan). People who buy it always get it.")
            }
        }
    }

    private var currencies: [String] {
        AcademyMoney.currencies.contains(draft.currency) ? AcademyMoney.currencies : [draft.currency] + AcademyMoney.currencies
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let existing {
            draft = AcademyCourseDraft(existing)
        } else {
            draft = AcademyCourseDraft(instructor: session.user?.displayName ?? "")
        }
        original = draft
    }

    private func addTag() {
        draft.addTag(tagDraft)
        tagDraft = ""
    }

    private func save() async {
        if tagDraft.trimmedOrNil != nil { addTag() }
        problem = draft.problem
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let saved = if let existing {
                try await services.academy.updateCourse(existing.uuid, draft.formFields)
            } else {
                try await services.academy.createCourse(draft.formFields)
            }
            original = draft
            let message = saved.statusValue == .pendingReview
                ? "Sent for review. An admin approves it before it goes live."
                : (existing == nil ? "Course created." : "Course saved.")
            onSaved(saved, message)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
