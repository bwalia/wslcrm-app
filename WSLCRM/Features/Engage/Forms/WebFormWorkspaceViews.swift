import SwiftUI

/// Spam protection for every form of the workspace: the Cloudflare Turnstile keys. The secret is write-only:
/// it is stored encrypted and never shown again.
struct WebFormSpamProtectionView: View {
    var onSaved: (WebFormWorkspaceSettings) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var current: WebFormWorkspaceSettings?
    @State private var siteKey = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var notice: EngageNotice?
    @State private var confirmingRemove = false

    var body: some View {
        Form {
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            Section {
                Text("Every form already blocks most bots (a hidden trap field, a minimum time and rate limits). "
                     + "Cloudflare Turnstile adds an “I’m human” check on the forms you choose.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let current {
                    Label(current.ownKeys ? "Your own Turnstile keys are set up. Turn the check on per form in its "
                          + "Settings tab."
                          : current.platform ? "Ready to use: the platform’s Turnstile keys cover your forms. Turn the "
                            + "check on per form in its Settings tab."
                          : "Not set up yet.",
                          systemImage: current.ready ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(current.ready ? Tone.success.textColor : .secondaryText)
                    if current.platform && !current.ownKeys {
                        Text("You only need your own keys to use your own Cloudflare account, or if your forms are on "
                             + "your own custom domain (the platform’s keys only cover the platform’s addresses).")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            }
            Section {
                Text("1. In Cloudflare, open Turnstile → Add widget and add the domains your forms are on (the "
                     + "platform’s address, and your custom domain if you use one).")
                Text("2. Copy the site key and the secret key here.")
            } header: { Text("How to get the keys") }
            .font(.wsSubheadline)
            Section {
                TextField("Site key (0x4AAAAAAA…)", text: $siteKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("forms.spam.siteKey")
                SecureField(current?.hasSecret == true ? "Secret key — saved; leave empty to keep it" : "Secret key",
                            text: $secret)
                    .accessibilityIdentifier("forms.spam.secret")
            } footer: { Text("The secret is stored encrypted. It is never shown again.") }
            if current?.ownKeys == true {
                Section {
                    Button("Remove keys", role: .destructive) { confirmingRemove = true }
                        .disabled(busy)
                }
            }
        }
        .navigationTitle("Spam protection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save(remove: false) } }
                    .disabled(busy || siteKey.trimmedOrNil == nil || (secret.trimmedOrNil == nil && current?.hasSecret != true))
                    .accessibilityIdentifier("forms.spam.save")
            }
        }
        .task { await load() }
        .confirmationDialog("Remove the Turnstile keys?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove keys", role: .destructive) { Task { await save(remove: true) } }
        } message: {
            Text("Forms with the “I’m human” check use the platform’s keys if there are any; otherwise the check stops.")
        }
    }

    private func load() async {
        do {
            let settings = try await services.webForms.workspaceSettings()
            current = settings
            siteKey = settings.siteKey ?? ""
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func save(remove: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let saved = try await services.webForms.saveWorkspaceSettings(siteKey: siteKey, secret: secret, remove: remove)
            current = saved
            secret = ""
            if remove { siteKey = "" }
            onSaved(saved)
            if remove { notice = .done("Turnstile keys removed.") } else { dismiss() }
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// The workspace's own domain for form links (forms.yourcompany.com/f/…): two DNS records, then a check.
struct WebFormDomainView: View {
    var onChanged: () -> Void = {}
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var domain: WebFormDomain?
    @State private var input = ""
    @State private var busy = ""
    @State private var notice: EngageNotice?
    @State private var confirmingRemove = false

    var body: some View {
        Form {
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            Section {
                Text("Share your forms on your own address, such as forms.yourcompany.com/f/…, instead of ours.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let domain {
                if !domain.available {
                    Section {
                        Text("Custom domains aren’t available on this platform yet. The platform administrator turns them on.")
                    }
                } else if domain.domain == nil {
                    connect
                } else {
                    connected(domain)
                }
            } else if notice == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle("Custom domain")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await run("load") { try await services.webForms.domain() } }
        .confirmationDialog("Remove \(domain?.domain ?? "the domain")?", isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await run("remove") { try await services.webForms.removeDomain() } } }
        } message: { Text("Links go back to the platform’s own address.") }
    }

    private var connect: some View {
        Section {
            TextField("forms.yourcompany.com", text: $input)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { Task { await claim() } }
                .accessibilityIdentifier("forms.domain.input")
            Button {
                Task { await claim() }
            } label: {
                HStack { if busy == "save" { ProgressView() }; Text("Connect") }
            }
            .disabled(input.trimmedOrNil == nil || !busy.isEmpty)
            .accessibilityIdentifier("forms.domain.connect")
        } header: { Text("Domain") } footer: {
            Text("A subdomain you own works best, e.g. forms.yourcompany.com. Next you’ll add two DNS records.")
        }
    }

    @ViewBuilder
    private func connected(_ d: WebFormDomain) -> some View {
        Section {
            HStack {
                Text(d.domain ?? "").font(.system(.body, design: .monospaced).weight(.semibold))
                Spacer()
                StatusBadge(text: d.isActive ? "Connected" : "Waiting for DNS",
                            systemImage: d.isActive ? "checkmark.circle" : "clock",
                            tone: d.isActive ? .success : .warning)
            }
            if d.isActive {
                Text("Form links now use https://\(d.domain ?? "")/f/…. Links you shared before keep working.")
                    .font(.wsSubheadline).foregroundStyle(Tone.success.textColor)
            } else {
                Text("Add these records at your DNS provider. They are checked for a week, so you can close this.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let error = d.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
            if let checked = d.checkedAt {
                Text("Last checked \(WebFormText.ago(checked)).").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Button {
                Task { await run("check") { try await services.webForms.checkDomain() } }
            } label: {
                HStack { if busy == "check" { ProgressView() }; Label("Check now", systemImage: "arrow.clockwise") }
            }
            .disabled(!busy.isEmpty)
            .accessibilityIdentifier("forms.domain.check")
        }
        Section("DNS records") {
            ForEach(d.records) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.type).font(.wsHeadline)
                    CopyableRow(label: "Name", value: record.name)
                    CopyableRow(label: "Value", value: record.value)
                }
            }
        }
        Section {
            Text("• The TXT record proves the domain is yours; keep it while the domain is connected.")
            Text("• Using Cloudflare? Set the \(d.records.first?.type ?? "CNAME") record to DNS only (grey cloud).")
            Text("• A root domain (yourcompany.com) can’t have a CNAME: use your provider’s ALIAS/ANAME record, or a subdomain.")
        }
        .font(.wsFootnote).foregroundStyle(.secondaryText)
        Section {
            Button("Remove domain", role: .destructive) { confirmingRemove = true }
                .disabled(!busy.isEmpty)
                .accessibilityIdentifier("forms.domain.remove")
        }
    }

    private func claim() async {
        guard let name = input.trimmedOrNil else { return }
        await run("save") { try await services.webForms.saveDomain(name) }
    }

    private func run(_ kind: String, _ work: () async throws -> WebFormDomain) async {
        busy = kind
        defer { busy = "" }
        do {
            let next = try await work()
            domain = next
            input = ""
            if kind != "load" { onChanged() }
            switch kind {
            case "remove": notice = .done("Domain removed: links use the platform’s address again.")
            case "save", "check":
                notice = next.isActive ? .done("\(next.domain ?? "The domain") is connected.")
                    : .info("Not connected yet: the DNS records below aren’t showing.")
            default: break
            }
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// "Form responses" for a customer's or lead's page: the responses that created or matched that record,
/// newest first. Shows nothing without the forms module or when there are none. (For other areas to place.)
struct WebFormRecordResponsesSection: View {
    /// Loaded by the record's page (`load`): a List row that shows nothing never appears, so the
    /// section can't load itself.
    let items: [WebFormRecordResponse]

    /// The responses about one record (`entityType`: customer, lead, user or invitation); empty when
    /// the person can't read forms or there are none.
    @MainActor
    static func load(services: Services, session: SessionStore, entityType: String,
                     entityUUID: String) async -> [WebFormRecordResponse] {
        guard session.permissions.can(.read, moduleName: WebFormsAPI.module) else { return [] }
        return (try? await services.webForms.responses(forRecord: entityType, uuid: entityUUID)) ?? []
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                Section("Form responses") {
                    ForEach(items) { response in
                        NavigationLink {
                            WebFormRecordResponseView(response: response)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(response.formTitle).font(.wsHeadline)
                                Text(WebFormText.ago(response.createdAt)
                                     + (response.outcome == "created" ? " · created this record" : ""))
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                                ForEach(Array(response.answers.prefix(6).enumerated()), id: \.offset) { _, answer in
                                    Text("\(answer.label): \(answer.value)").font(.wsSubheadline).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One response from a record's page: opens the form's response with everything on it.
private struct WebFormRecordResponseView: View {
    let response: WebFormRecordResponse
    @Environment(\.services) private var services
    @State private var form: WebFormDetail?
    @State private var error: APIError?

    var body: some View {
        Group {
            if let form {
                WebFormResponseDetailView(form: form, submissionID: response.uuid)
            } else if let error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { form = try await services.webForms.form(response.formUUID) } catch { self.error = error.asAPIError }
    }
}
