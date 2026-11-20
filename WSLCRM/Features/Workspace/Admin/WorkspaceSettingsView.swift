import PhotosUI
import SwiftUI

/// Workspace settings (`/dashboard/namespace/settings`), for the owner: name and type of business,
/// logo and banner (uploaded from the phone), the name on emails, the custom domain, whether everyone
/// gets a sign-in code, and the plan and limits the platform set.
struct WorkspaceSettingsView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.permissions.isOwnerOrAdmin {
            WorkspaceSettingsForm()
        } else {
            ContentUnavailableView {
                Label("Only the owner can change these", systemImage: "lock")
            } description: {
                Text("Only the workspace owner can change these settings. Ask them if something needs changing.")
            }
            .navigationTitle("Workspace settings")
        }
    }
}

/// The values a person can change, kept apart from the view so the body sent can be tested.
struct WorkspaceSettingsDraft: Equatable {
    var name = ""
    var businessType = ""
    var description = ""
    var logoURL = ""
    var bannerURL = ""
    var emailName = ""
    var domain = ""

    init() {}

    init(_ record: Record) {
        name = record.string("name") ?? ""
        businessType = record.string("business_type") ?? ""
        description = record.string("description") ?? ""
        logoURL = record.string("logo_url") ?? ""
        bannerURL = record.string("banner_url") ?? ""
        emailName = record.string("email_name") ?? ""
        domain = record.string("domain") ?? ""
    }

    /// `PUT /api/v2/namespace`: only what changed, every value a string ("" clears it). The slug and
    /// domain are the owner's alone, so the domain is sent only when the owner changed it.
    func body(comparedTo original: WorkspaceSettingsDraft, isOwner: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        func put(_ key: String, _ value: String, _ before: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != before.trimmingCharacters(in: .whitespacesAndNewlines) { body[key] = .string(trimmed) }
        }
        put("name", name, original.name)
        put("business_type", businessType, original.businessType)
        put("description", description, original.description)
        put("logo_url", logoURL, original.logoURL)
        put("banner_url", bannerURL, original.bannerURL)
        put("email_name", emailName, original.emailName)
        if isOwner { put("domain", domain, original.domain) }
        return body
    }

    /// nil when it can be saved, else what to fix.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The workspace needs a name." }
        if emailName.count > 80 { return "The name in emails can be at most 80 characters." }
        return nil
    }
}

private struct WorkspaceSettingsForm: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var record: Record?
    @State private var isOwner = false
    @State private var draft = WorkspaceSettingsDraft()
    @State private var original = WorkspaceSettingsDraft()
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var logoItem: PhotosPickerItem?
    @State private var bannerItem: PhotosPickerItem?
    @State private var uploading: String?
    // Sign-in codes.
    @State private var mfaRequired = true
    @State private var mfaCanChange = false
    @State private var mfaLoaded = false
    @State private var confirmingMFAOff = false

    var body: some View {
        Form {
            if let loadError, record == nil {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
            FeedbackSection(feedback: feedback)
            if record != nil {
                general
                branding
                domain
                mfa
                planAndLimits
            }
        }
        .overlay { if record == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("Workspace settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || draft == original || record == nil)
                    .accessibilityIdentifier("workspaceSettings.save")
            }
            if draft != original {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Undo changes") { draft = original }
                        .accessibilityIdentifier("workspaceSettings.reset")
                }
            }
        }
        .task { await load() }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { await upload(item, field: \.logoURL, key: "logo_url", what: "logo") }
        }
        .onChange(of: bannerItem) { _, item in
            guard let item else { return }
            Task { await upload(item, field: \.bannerURL, key: "banner_url", what: "banner") }
        }
        .confirmationDialog("Turn off sign-in codes?", isPresented: $confirmingMFAOff, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { Task { await setMFA(false) } }
        } message: {
            Text("Members will sign in with their password only. Platform admins still get a code.")
        }
    }

    // MARK: Sections

    private var general: some View {
        Section("General") {
            LabeledContent("Name (needed)") {
                TextField("Workspace name", text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("workspaceSettings.name")
            }
            LabeledContent("Short name (slug)") {
                Text(record?.string("slug") ?? "—").font(.wsBody.monospaced()).foregroundStyle(.secondaryText)
            }
            .accessibilityHint("It can’t be changed.")
            Picker("Type of business", selection: $draft.businessType) {
                ForEach(WorkspaceBusinessType.choices) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("workspaceSettings.businessType")
            TextField("Description", text: $draft.description, axis: .vertical)
                .lineLimit(2...6)
                .accessibilityIdentifier("workspaceSettings.description")
        }
    }

    private var branding: some View {
        Section {
            imageRow(title: "Logo", url: draft.logoURL, item: $logoItem, key: "logo")
            TextField("Logo address (https://…)", text: $draft.logoURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.wsFootnote)
                .accessibilityIdentifier("workspaceSettings.logoURL")
            imageRow(title: "Banner", url: draft.bannerURL, item: $bannerItem, key: "banner")
            TextField("Banner address (https://…)", text: $draft.bannerURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.wsFootnote)
                .accessibilityIdentifier("workspaceSettings.bannerURL")
            LabeledContent("Name in emails") {
                TextField(draft.name.isEmpty ? "Workspace name" : draft.name, text: $draft.emailName)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("workspaceSettings.emailName")
            }
        } header: {
            Text("Branding")
        } footer: {
            Text("The logo shows in the app and on documents. “Name in emails” is who emails appear to come from "
                 + "(up to 80 characters); leave it empty to use the workspace name.")
        }
    }

    @ViewBuilder
    private func imageRow(title: String, url: String, item: Binding<PhotosPickerItem?>, key: String) -> some View {
        HStack(spacing: 12) {
            WorkspaceLogoImage(raw: url.isEmpty ? nil : url, name: draft.name.isEmpty ? title : draft.name, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.wsHeadline)
                HStack(spacing: 16) {
                    PhotosPicker(selection: item, matching: .images) {
                        Text(url.isEmpty ? "Choose a picture" : "Replace")
                    }
                    .buttonStyle(.borderless)
                    .disabled(uploading != nil)
                    .accessibilityIdentifier("workspaceSettings.\(key).choose")
                    if !url.isEmpty {
                        Button("Remove", role: .destructive) {
                            Task { await saveImage(key == "logo" ? "logo_url" : "banner_url", "", what: title.lowercased()) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(uploading != nil)
                        .accessibilityIdentifier("workspaceSettings.\(key).remove")
                    }
                }
                .font(.wsSubheadline)
                if uploading == key {
                    ProgressView("Uploading…").font(.wsFootnote)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var domain: some View {
        Section {
            TextField("e.g. app.yourcompany.co.uk", text: $draft.domain)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!isOwner)
                .accessibilityIdentifier("workspaceSettings.domain")
        } header: {
            Text("Custom domain")
        } footer: {
            Text(isOwner ? "Your own web address for this workspace. Leave it empty to remove it."
                 : "Only the workspace owner can change the domain.")
        }
    }

    @ViewBuilder
    private var mfa: some View {
        Section {
            Toggle("Sign-in code (MFA)", isOn: Binding(
                get: { mfaRequired },
                set: { on in
                    if on { Task { await setMFA(true) } } else { confirmingMFAOff = true }
                }))
                .disabled(!mfaLoaded || !mfaCanChange)
                .accessibilityIdentifier("workspaceSettings.mfa")
            Text(mfaRequired ? "On: everyone gets a code by email when they sign in."
                 : "Off: members sign in with their password only.")
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
        } header: {
            Text("Signing in")
        } footer: {
            if mfaLoaded, !mfaCanChange { Text("Only the workspace owner can change this.") }
        }
    }

    @ViewBuilder
    private var planAndLimits: some View {
        if let record {
            Section {
                DetailRow(label: "Plan", value: Formatters.humanize(record.string("plan") ?? "free"))
                DetailRow(label: "Status", value: Formatters.humanize(record.string("status") ?? "active"))
                DetailRow(label: "Most members", value: record.int("max_users").map { $0.formatted() } ?? "—")
                DetailRow(label: "Most stores", value: record.int("max_stores").map { $0.formatted() } ?? "—")
            } header: {
                Text("Plan and limits")
            } footer: {
                Text("Set by your platform administrator.")
            }
        }
    }

    // MARK: Work

    private func load() async {
        let api = services.workspace()
        do {
            let root = WorkspaceAPI.object(try await api.get("/api/v2/namespace"))
            guard let namespace = root.object("namespace") else {
                throw ResourceService.problem(404, "This workspace wasn’t found.")
            }
            record = namespace
            isOwner = root.bool("membership.is_owner") ?? session.permissions.isOwner
            draft = WorkspaceSettingsDraft(namespace)
            original = draft
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if let security = try? await api.get("/api/v2/namespace/security") {
            let fields = WorkspaceAPI.object(security)
            mfaRequired = fields.bool("mfa_required") ?? true
            mfaCanChange = fields.bool("can_change") ?? false
            mfaLoaded = true
        }
    }

    private func save() async {
        if let problem = draft.problem {
            feedback = .failed(ResourceService.problem(422, problem))
            return
        }
        let body = draft.body(comparedTo: original, isOwner: isOwner)
        guard !body.isEmpty else { return }
        saving = true
        defer { saving = false }
        let brandingChanged = body["name"] != nil || body["logo_url"] != nil || body["banner_url"] != nil
        if await perform($feedback, done: "Settings saved.", {
            let root = WorkspaceAPI.object(try await services.workspace().send(.put, "/api/v2/namespace", body: .object(body)))
            if let saved = root.object("namespace") {
                record = saved
                draft = WorkspaceSettingsDraft(saved)
                original = draft
            } else {
                original = draft
            }
        }) {
            if brandingChanged { await refreshBrand() }
        }
    }

    /// Saves one picture field straight away (after an upload, or to remove it).
    private func saveImage(_ key: String, _ url: String, what: String) async {
        let done = url.isEmpty ? "The \(what) was removed." : "The new \(what) is saved."
        if await perform($feedback, done: done, {
            let root = WorkspaceAPI.object(try await services.workspace().send(
                .put, "/api/v2/namespace", body: .object([key: .string(url)])))
            let saved = root.object("namespace")?.string(key) ?? url
            if key == "logo_url" { draft.logoURL = saved; original.logoURL = saved }
            else { draft.bannerURL = saved; original.bannerURL = saved }
        }) {
            await refreshBrand()
        }
    }

    private func upload(_ item: PhotosPickerItem, field: WritableKeyPath<WorkspaceSettingsDraft, String>,
                        key: String, what: String) async {
        uploading = key == "logo_url" ? "logo" : "banner"
        defer {
            uploading = nil
            logoItem = nil
            bannerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                feedback = .failed(ResourceService.problem(422, "That picture couldn’t be read. Try another one."))
                return
            }
            // A logo keeps its transparency; a banner is a photo.
            let isLogo = key == "logo_url"
            let file: Endpoint.FilePart = if isLogo, let png = image.pngData() {
                Endpoint.FilePart(fieldName: "file", filename: "logo.png", mimeType: "image/png", data: png)
            } else {
                Endpoint.FilePart(fieldName: "file", filename: "\(isLogo ? "logo" : "banner").jpg",
                                  mimeType: "image/jpeg", data: image.jpegData(compressionQuality: 0.85) ?? data)
            }
            let json = try await services.workspace().upload("/api/v2/documents/upload",
                                                              fields: [("prefix", "workspace-branding")], file: file)
            guard let url = WorkspaceAPI.object(json).string("data.url") ?? WorkspaceAPI.object(json).string("url") else {
                feedback = .failed(ResourceService.problem(422, "The upload didn’t give back an address. Try again."))
                return
            }
            await saveImage(key, url, what: what)
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func setMFA(_ on: Bool) async {
        let before = mfaRequired
        mfaRequired = on
        if !(await perform($feedback, done: on ? "Sign-in codes are on for everyone." : "Sign-in codes are off.", {
            let fields = WorkspaceAPI.object(try await services.workspace().send(
                .put, "/api/v2/namespace/security", body: .object(["mfa_required": .bool(on)])))
            mfaRequired = fields.bool("mfa_required") ?? on
        })) {
            mfaRequired = before
        }
    }

    /// The app's own logo and name for this workspace follow the change.
    private func refreshBrand() async {
        guard let workspace = session.workspace else { return }
        await session.select(workspace, notifyServer: false)
    }
}
