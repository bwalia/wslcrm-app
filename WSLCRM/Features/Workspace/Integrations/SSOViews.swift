import SwiftUI
import UniformTypeIdentifiers

/// Single sign-on (SAML): people sign in with the company's own identity provider (Okta, Microsoft
/// Entra ID, Google Workspace…). `/api/v2/sso/saml/*`, RBAC `namespace.read` to look, `namespace.manage`
/// to change.
struct SSOProvidersView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var feedback: Feedback = .none
    @State private var editing: SSOEditTarget?
    @State private var deleting: Record?
    @State private var checking: String?

    var body: some View {
        List {
            Section {
                Text("Let people sign in with your company’s own sign-in service. They must use an email at one of your domains, and you prove you own each domain once.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            FeedbackSection(feedback: feedback)
            switch state {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let providers) where providers.isEmpty:
                Section {
                    ContentUnavailableView("No single sign-on yet", systemImage: "person.badge.key",
                                           description: Text(canManage ? "Tap + to connect your identity provider."
                                                                       : "Ask an owner or admin to set it up."))
                }
            case .loaded(let providers):
                ForEach(providers) { provider in providerSections(provider) }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Single sign-on")
        .toolbar {
            if canManage {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = SSOEditTarget(provider: nil) } label: { Label("Add provider", systemImage: "plus") }
                        .accessibilityIdentifier("sso.new")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(item: $editing) { target in
            NavigationStack {
                SSOProviderForm(existing: target.provider) { message in
                    editing = nil
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete \(deleting?.string("name") ?? "this provider")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let provider = deleting {
                Button("Delete", role: .destructive) { Task { await delete(provider) } }
            }
        } message: {
            Text("People can no longer sign in through \(deleting?.string("name") ?? "it"). Their accounts stay; they can reset a password to sign in.")
        }
    }

    private var canManage: Bool { session.permissions.can(.manage, moduleName: "namespace") }

    @ViewBuilder
    private func providerSections(_ provider: Record) -> some View {
        let enabled = provider.bool("is_enabled") ?? false
        Section {
            HStack {
                Text(provider.string("name") ?? "Identity provider").font(.wsHeadline)
                Spacer()
                StatusBadge(text: enabled ? "Enabled" : "Off", systemImage: enabled ? "checkmark.circle" : "pause.circle",
                            tone: enabled ? .success : .neutral)
            }
            .accessibilityElement(children: .combine)
            Text(SSOPresentation.signIns(provider)).font(.wsFootnote).foregroundStyle(.secondaryText)
            LabeledContent("Email domains", value: provider.array("email_domains").compactMap(\.stringValue).joined(separator: ", "))
            if canManage {
                Button { editing = SSOEditTarget(provider: provider) } label: { Label("Edit", systemImage: "pencil") }
                    .accessibilityIdentifier("sso.edit.\(provider.id)")
                Button(role: .destructive) { deleting = provider } label: { Label("Delete", systemImage: "trash") }
                    .accessibilityIdentifier("sso.delete.\(provider.id)")
            }
        }
        let domains = provider.records("domains", idKeys: ["domain"])
        if !domains.isEmpty {
            Section {
                ForEach(domains) { domain in domainRows(domain) }
            } header: {
                Text("Domain proof")
            } footer: {
                Text("Add each TXT record at your DNS provider, wait a few minutes, then check. Nobody at an unproven domain can sign in.")
            }
        }
        Section {
            CopyableRow(label: "Metadata URL", value: provider.string("sp.sp_entity_id") ?? "")
            CopyableRow(label: "Entity ID (Audience)", value: provider.string("sp.sp_entity_id") ?? "")
            CopyableRow(label: "ACS URL", value: provider.string("sp.acs_url") ?? "")
            CopyableRow(label: "Direct sign-in link", value: provider.string("sp.login_url") ?? "")
        } header: {
            Text("Give these to your identity provider")
        } footer: {
            Text("NameID: the person’s email. Send the attributes email, firstName and lastName. Sign responses with SHA-256.")
        }
    }

    @ViewBuilder
    private func domainRows(_ domain: Record) -> some View {
        let name = domain.string("domain") ?? ""
        let verified = domain.bool("verified") ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.wsBody)
                Spacer()
                StatusBadge(text: verified ? "Verified" : "Not verified yet",
                            systemImage: verified ? "checkmark.seal" : "exclamationmark.triangle",
                            tone: verified ? .success : .warning)
            }
            if verified {
                if let at = Formatters.dateTime(domain.date("verified_at")) {
                    Text("Proved \(at)").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            } else {
                Text("Nobody at \(name) can sign in until you prove you own it.").font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
                if let message = domain.string("message") {
                    Text(message).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
        if !verified {
            CopyableRow(label: "TXT record name", value: domain.string("txt_name") ?? "_opsapi-challenge.\(name)")
            CopyableRow(label: "TXT record value", value: domain.string("txt_value") ?? "")
            if canManage {
                Button {
                    Task { await verify(name) }
                } label: {
                    Label(checking == name ? "Checking…" : "Check now", systemImage: "magnifyingglass")
                }
                .disabled(checking != nil)
                .frame(minHeight: 44)
                .accessibilityIdentifier("sso.verify.\(name)")
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let json = try await services.workspace().get("/api/v2/sso/saml/providers")
            state = .loaded(WorkspaceAPI.records(json, idKeys: ["uuid"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func verify(_ domain: String) async {
        checking = domain
        defer { checking = nil }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/sso/saml/domains/verify",
                                                           body: .object(["domain": .string(domain)]))
            let status = WorkspaceAPI.record(json) ?? Record([:])
            if status.bool("verified") == true {
                feedback = .done("\(domain) is proved. People there can now sign in with single sign-on.")
            } else {
                feedback = .failed(ResourceService.problem(422, status.string("message")
                    ?? "The TXT record isn’t there yet. DNS changes can take a while; try again later."))
            }
            await load()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func delete(_ provider: Record) async {
        deleting = nil
        await perform($feedback, done: "\(provider.string("name") ?? "Provider") deleted. People there sign in with their password now.") {
            try await services.workspace().send(.delete, "/api/v2/sso/saml/providers/\(provider.id)")
        }
        await load()
    }
}

/// Words for a provider.
enum SSOPresentation {
    static func signIns(_ provider: Record) -> String {
        let count = provider.int("login_count") ?? 0
        let base = "\(count) sign-in\(count == 1 ? "" : "s")"
        guard let last = Formatters.day(provider.date("last_login_at")) else { return base }
        return "\(base) · last \(last)"
    }

    /// "acme.com, acme.co.uk" → ["acme.com", "acme.co.uk"].
    static func domains(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// The provider being edited (nil = a new one), as a sheet item.
struct SSOEditTarget: Identifiable {
    let id = UUID()
    let provider: Record?
}

/// Everything the identity provider and OpsAPI need to agree on.
struct SSOProviderDraft: Equatable {
    var name = ""
    var entityID = ""
    var ssoURL = ""
    var certificate = ""
    var domains = ""
    var defaultRole = ""
    var autoProvision = true
    var allowIdPInitiated = false
    var enabled = true
    var emailAttribute = ""
    var firstNameAttribute = ""
    var lastNameAttribute = ""

    init() {}

    init(_ provider: Record) {
        name = provider.string("name") ?? ""
        entityID = provider.string("idp_entity_id") ?? ""
        ssoURL = provider.string("idp_sso_url") ?? ""
        certificate = provider.string("idp_x509_cert") ?? ""
        domains = provider.array("email_domains").compactMap(\.stringValue).joined(separator: ", ")
        defaultRole = provider.string("default_role") ?? ""
        autoProvision = provider.bool("auto_provision") ?? true
        allowIdPInitiated = provider.bool("allow_idp_initiated") ?? false
        enabled = provider.bool("is_enabled") ?? true
        emailAttribute = provider.string("attribute_mapping.email") ?? ""
        firstNameAttribute = provider.string("attribute_mapping.first_name") ?? ""
        lastNameAttribute = provider.string("attribute_mapping.last_name") ?? ""
    }

    /// The body `POST`/`PUT /api/v2/sso/saml/providers` expect.
    var body: JSONValue {
        func text(_ value: String) -> JSONValue { .string(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var mapping: [String: JSONValue] = [:]
        if let v = JSONValue.text(emailAttribute) { mapping["email"] = v }
        if let v = JSONValue.text(firstNameAttribute) { mapping["first_name"] = v }
        if let v = JSONValue.text(lastNameAttribute) { mapping["last_name"] = v }
        return .object([
            "name": text(name), "idp_entity_id": text(entityID), "idp_sso_url": text(ssoURL),
            "idp_x509_cert": text(certificate),
            "email_domains": .array(SSOPresentation.domains(domains).map(JSONValue.string)),
            "default_role": text(defaultRole),
            "auto_provision": .bool(autoProvision), "allow_idp_initiated": .bool(allowIdPInitiated),
            "is_enabled": .bool(enabled), "attribute_mapping": .object(mapping),
        ])
    }

    /// What's missing, in plain words; nil when it can be saved.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the provider a name." }
        if entityID.trimmingCharacters(in: .whitespaces).isEmpty { return "Fill in the identity provider’s entity ID." }
        let url = ssoURL.trimmingCharacters(in: .whitespaces).lowercased()
        if !(url.hasPrefix("https://") || url.hasPrefix("http://")) { return "The sign-in URL must start with https://." }
        if certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste the identity provider’s certificate." }
        if SSOPresentation.domains(domains).isEmpty { return "Add at least one email domain, such as acme.com." }
        return nil
    }
}

private struct SSOProviderForm: View {
    let existing: Record?
    let saved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SSOProviderDraft()
    @State private var roles: [Record] = []
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false
    @State private var prepared = false
    @State private var importingMetadata = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Okta"))
                    .accessibilityIdentifier("sso.name")
            }
            Section {
                Button { importingMetadata = true } label: {
                    Label("Fill in from metadata", systemImage: "doc.badge.arrow.up")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("sso.metadata")
                TextField("Entity ID (issuer)", text: $draft.entityID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.entityID")
                TextField("Sign-in URL (SSO URL)", text: $draft.ssoURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.ssoURL")
                TextField("Certificate (-----BEGIN CERTIFICATE-----…)", text: $draft.certificate, axis: .vertical)
                    .font(.wsFootnote.monospaced())
                    .lineLimit(4...10)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.certificate")
            } header: {
                Text("Your identity provider")
            } footer: {
                Text("Copy these from your identity provider, or fill them in from its metadata XML.")
            }
            Section {
                TextField("acme.com, acme.co.uk", text: $draft.domains)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.domains")
            } header: {
                Text("Email domains")
            } footer: {
                Text("Only people with an email at these domains can sign in this way. You prove each domain with a DNS record after saving.")
            }
            Section {
                Picker("Role for new people", selection: $draft.defaultRole) {
                    Text("Workspace default").tag("")
                    ForEach(roles) { role in
                        Text(role.string("display_name") ?? role.string("role_name") ?? "Role").tag(role.string("role_name") ?? "")
                    }
                    if !draft.defaultRole.isEmpty, !roles.contains(where: { $0.string("role_name") == draft.defaultRole }) {
                        Text(draft.defaultRole).tag(draft.defaultRole)
                    }
                }
                .accessibilityIdentifier("sso.defaultRole")
                Toggle("Create accounts on first sign-in", isOn: $draft.autoProvision)
                    .accessibilityIdentifier("sso.autoProvision")
                Toggle("Allow IdP-initiated sign-in", isOn: $draft.allowIdPInitiated)
                    .accessibilityIdentifier("sso.idpInitiated")
                Toggle("Enabled", isOn: $draft.enabled).accessibilityIdentifier("sso.enabled")
            } header: {
                Text("Who can sign in")
            } footer: {
                Text("With “Create accounts” off, people must be invited before their first sign-in. IdP-initiated means starting from the provider’s own app list.")
            }
            Section {
                TextField("email", text: $draft.emailAttribute)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.attr.email")
                TextField("firstName", text: $draft.firstNameAttribute)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.attr.first")
                TextField("lastName", text: $draft.lastNameAttribute)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.attr.last")
            } header: {
                Text("Attribute names (optional)")
            } footer: {
                Text("Only if your provider names the email, first name and last name attributes differently.")
            }
        }
        .navigationTitle(existing == nil ? "Add provider" : "Edit provider")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("sso.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            if let existing { draft = SSOProviderDraft(existing) }
        }
        .task {
            if let json = try? await services.workspace().get("/api/v2/namespace/roles") {
                roles = WorkspaceAPI.records(json).filter { $0.string("role_name") != "owner" }
            }
        }
        .sheet(isPresented: $importingMetadata) {
            NavigationStack {
                SSOMetadataSheet { fields in
                    importingMetadata = false
                    if let value = fields.string("idp_entity_id") { draft.entityID = value }
                    if let value = fields.string("idp_sso_url") { draft.ssoURL = value }
                    if let value = fields.string("idp_x509_cert") { draft.certificate = value }
                }
            }
        }
    }

    private func save() async {
        if let missing = draft.problem { problem = missing; return }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            if let existing {
                try await services.workspace().send(.put, "/api/v2/sso/saml/providers/\(existing.id)", body: draft.body)
                saved("\(draft.name) saved.")
            } else {
                try await services.workspace().send(.post, "/api/v2/sso/saml/providers", body: draft.body)
                saved("\(draft.name) added. Now prove you own each email domain with its TXT record.")
            }
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// Reads the identity provider's metadata XML (pasted or from a file) into the form.
private struct SSOMetadataSheet: View {
    let filled: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var xml = ""
    @State private var choosingFile = false
    @State private var error: APIError?
    @State private var reading = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                Button { choosingFile = true } label: { Label("Choose an XML file", systemImage: "folder") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("sso.metadata.file")
                TextField("Or paste the metadata XML here", text: $xml, axis: .vertical)
                    .font(.wsFootnote.monospaced())
                    .lineLimit(6...16)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sso.metadata.xml")
            } footer: {
                Text("Your identity provider offers this as “IdP metadata” or “Federation metadata XML”.")
            }
        }
        .navigationTitle("Fill in from metadata")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Read it") { Task { await read() } }
                    .disabled(reading || xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("sso.metadata.read")
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.xml, .data]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    xml = text
                    Task { await read() }
                } else {
                    error = ResourceService.problem(422, "That file couldn’t be read as text. Choose the metadata .xml file.")
                }
            case .failure:
                break
            }
        }
    }

    private func read() async {
        reading = true
        defer { reading = false }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/sso/saml/metadata/parse",
                                                           body: .object(["xml": .string(xml)]))
            filled(WorkspaceAPI.record(json) ?? Record([:]))
        } catch {
            self.error = error.asAPIError
        }
    }
}
