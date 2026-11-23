import SwiftUI

/// Your instructor profile, shown to learners on your public page: headline, bio, picture,
/// location, website, social links, skills, achievements and education.
struct AcademyProfileView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var profile = AcademyProfile()
    @State private var original = AcademyProfile()
    @State private var skillsText = ""
    @State private var originalSkills = ""
    @State private var state: LoadState<Void> = .idle
    @State private var saving = false
    @State private var notice: EngageNotice?

    private var canSave: Bool { session.permissions.can(.update, moduleName: AcademyRBAC.module) }

    var body: some View {
        Group {
            switch state {
            case .loaded: form
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            default: SkeletonList()
            }
        }
        .navigationTitle("Instructor profile")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar {
            if canSave {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || state.value == nil)
                        .accessibilityIdentifier("academy.profile.save")
                }
            }
        }
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section {
                EngageIntro(text: canSave ? "Learners see this on your public profile page."
                                          : "Learners see this on your public profile page. You can’t change it: "
                                            + "ask the academy’s owner for permission to edit courses.")
            }
            Section("Basics") {
                TextField("Headline, e.g. Senior engineer and teacher", text: $profile.headline)
                    .accessibilityIdentifier("academy.profile.headline")
                TextField("About you: your background and what you teach", text: $profile.bio, axis: .vertical)
                    .lineLimit(4...10)
                    .accessibilityIdentifier("academy.profile.bio")
                EngageImageField(url: $profile.avatarUrl, alt: "Your photo", placeholder: "https://…/photo.jpg",
                                 previewWidth: 96, id: "academy.profile.avatar")
                TextField("Location, e.g. London, UK", text: $profile.location)
                    .accessibilityIdentifier("academy.profile.location")
                TextField("Website, https://your-site.com", text: $profile.website)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("academy.profile.website")
            }
            Section("Social links") {
                ForEach(AcademyProfile.socialKeys, id: \.self) { key in
                    TextField("\(key.capitalizedFirst) link", text: Binding(
                        get: { profile.socials[key] ?? "" }, set: { profile.socials[key] = $0 }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("academy.profile.social.\(key)")
                }
            }
            Section {
                TextField("e.g. JavaScript, React, System design", text: $skillsText, axis: .vertical)
                    .accessibilityIdentifier("academy.profile.skills")
            } header: { Text("Skills") } footer: { Text("Separate skills with commas.") }
            achievements
            education
            if canSave {
                Section {
                    Button { Task { await save() } } label: {
                        Label(saving ? "Saving…" : "Save profile", systemImage: "square.and.arrow.down")
                    }
                    .frame(minHeight: 44)
                    .disabled(saving)
                }
            }
        }
        .disabled(!canSave)
    }

    private var achievements: some View {
        Section {
            if profile.achievements.isEmpty {
                Text("No achievements yet.").foregroundStyle(.secondaryText)
            }
            ForEach($profile.achievements) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Title, e.g. AWS Certified", text: $item.title)
                    HStack {
                        TextField("Given by", text: $item.issuer)
                        TextField("Year", text: $item.year).keyboardType(.numberPad).frame(maxWidth: 80)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { profile.achievements.remove(atOffsets: $0) }
            Button { profile.achievements.append(AcademyAchievement()) } label: {
                Label("Add an achievement", systemImage: "plus.circle")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("academy.profile.addAchievement")
        } header: { Text("Achievements and certificates") } footer: {
            Text("Swipe left to remove one. Rows without a title aren’t saved.")
        }
    }

    private var education: some View {
        Section {
            if profile.education.isEmpty {
                Text("No education yet.").foregroundStyle(.secondaryText)
            }
            ForEach($profile.education) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Qualification, e.g. BSc Computer Science", text: $item.degree)
                    HStack {
                        TextField("Where", text: $item.institution)
                        TextField("Year", text: $item.year).keyboardType(.numberPad).frame(maxWidth: 80)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { profile.education.remove(atOffsets: $0) }
            Button { profile.education.append(AcademyEducation()) } label: {
                Label("Add education", systemImage: "plus.circle")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("academy.profile.addEducation")
        } header: { Text("Education and qualifications") } footer: {
            Text("Swipe left to remove one. Rows without a qualification aren’t saved.")
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let loaded = try await services.academy.profile()
            profile = loaded
            original = loaded
            skillsText = loaded.skills.joined(separator: ", ")
            originalSkills = skillsText
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let saved = try await services.academy.saveProfile(profile.formFields(skillsText: skillsText))
            profile = saved
            original = saved
            skillsText = saved.skills.joined(separator: ", ")
            notice = .done("Profile saved. Learners see the new details now.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}
