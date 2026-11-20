import SwiftUI

/// "Website updates" (CMS webhooks): tell your website to refresh after you publish or change content.
/// Add a website's update address, see whether the last update worked, update it now, set it up with
/// its secret key and code samples for a developer, change or remove it.
struct CMSWebhooksView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var hooks: [Record] = []
    @State private var state: LoadState<Void> = .idle
    @State private var editing: CMSWebhookEdit?
    @State private var guide: CMSWebhookGuideTarget?
    @State private var removing: Record?
    @State private var sending: String?
    @State private var notice: EngageNotice?
    @State private var howExpanded: Bool?

    private var canWrite: Bool { session.permissions.can(.update, moduleName: CMS.module) }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: CMS.module) }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: CMS.module) }

    var body: some View {
        List {
            if state.value != nil {
                Section {
                    DisclosureGroup("How website updates work", isExpanded: Binding(
                        get: { howExpanded ?? hooks.isEmpty }, set: { howExpanded = $0 })) {
                        CMSWebhookHowItWorks()
                    }
                    .accessibilityIdentifier("cms.webhooks.how")
                }
            }
            ForEach(hooks) { hook in
                Section { card(hook) }
            }
        }
        .overlay { overlay }
        .navigationTitle("Website updates")
        .refreshable { await load() }
        .task { if state.value == nil { await load() } }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = CMSWebhookEdit(hook: nil) } label: { Label("Add website", systemImage: "plus") }
                        .accessibilityIdentifier("cms.webhooks.add")
                }
            }
        }
        .sheet(item: $editing) { edit in
            NavigationStack {
                CMSWebhookForm(hook: edit.hook) { saved, created in
                    Task { await load() }
                    if created { guide = CMSWebhookGuideTarget(hook: saved, justCreated: true) } else { notice = .done("Saved.") }
                }
            }
        }
        .sheet(item: $guide) { target in
            NavigationStack {
                CMSWebhookGuideView(hook: target.hook, justCreated: target.justCreated, canSend: canWrite) {
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Remove this website?", isPresented: Binding(get: { removing != nil },
                                                                       set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("OpsAPI will stop sending updates to “\(removing?.string("name") ?? removing?.string("url") ?? "it")”. "
                 + "Your website itself isn’t changed.")
        }
    }

    @ViewBuilder
    private func card(_ hook: Record) -> some View {
        let active = hook.bool("active") ?? false
        let last = CMSWebhookText.lastDelivery(hook)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hook.string("name") ?? "Website").font(.wsHeadline)
                Spacer()
                StatusBadge(text: active ? "On" : "Paused", systemImage: active ? "checkmark.circle" : "pause.circle",
                            tone: active ? .success : .neutral)
            }
            Text(hook.string("url") ?? "").font(.wsFootnote).foregroundStyle(.secondaryText).textSelection(.enabled)
            Label(last.text, systemImage: last.ok == nil ? "clock" : (last.ok == true ? "checkmark" : "exclamationmark.circle"))
                .font(.wsFootnote)
                .foregroundStyle(last.ok == false ? Tone.danger.textColor : (last.ok == true ? Tone.success.textColor : .secondaryText))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        if canWrite {
            Button {
                Task { await updateNow(hook) }
            } label: {
                Label(sending == hook.id ? "Sending…" : "Update website now", systemImage: "paperplane")
            }
            .disabled(!active || sending != nil)
            .accessibilityIdentifier("cms.webhooks.send.\(hook.id)")
            if !active {
                Text("Turn it on (Change) to send updates.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        Button { guide = CMSWebhookGuideTarget(hook: hook, justCreated: false) } label: {
            Label("Setup guide and secret key", systemImage: "key")
        }
        .accessibilityIdentifier("cms.webhooks.guide.\(hook.id)")
        if canWrite {
            Button { editing = CMSWebhookEdit(hook: hook) } label: { Label("Change", systemImage: "pencil") }
                .accessibilityIdentifier("cms.webhooks.edit.\(hook.id)")
        }
        if canDelete {
            Button(role: .destructive) { removing = hook } label: { Label("Remove", systemImage: "trash") }
                .accessibilityIdentifier("cms.webhooks.remove.\(hook.id)")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch state {
        case .idle, .loading:
            SkeletonList()
        case .failed(let error):
            ErrorStateView(error: error) { Task { await load() } }
        case .loaded:
            if hooks.isEmpty {
                ContentUnavailableView {
                    Label("No website connected yet", systemImage: "globe")
                } description: {
                    Text("Add your website’s update address, and you can refresh the website from here whenever you publish.")
                } actions: {
                    if canCreate {
                        Button("Add website") { editing = CMSWebhookEdit(hook: nil) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 160)
            }
        }
    }

    private func load() async {
        if hooks.isEmpty { state = .loading }
        do {
            hooks = try await services.cms.webhooks()
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func updateNow(_ hook: Record) async {
        sending = hook.id
        defer { sending = nil }
        do {
            let result = try await services.cms.trigger(hook.id, event: "manual.trigger").explanation
            notice = result.ok ? .done(result.text) : .info(result.text)
            await load()
        } catch {
            notice = .info("The update could not be sent. Try again in a moment.")
        }
    }

    private func remove() async {
        guard let hook = removing else { return }
        removing = nil
        do {
            try await services.cms.deleteWebhook(hook.id)
            hooks.removeAll { $0.id == hook.id }
            notice = .done("Removed.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

struct CMSWebhookEdit: Identifiable {
    let id = UUID()
    let hook: Record?
}

struct CMSWebhookGuideTarget: Identifiable {
    let hook: Record
    let justCreated: Bool
    var id: String { hook.id }
}

/// The four steps, in plain words.
struct CMSWebhookHowItWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your website keeps its own copy of your posts and pages. When you change them here, your website has to "
                 + "be told so it can refresh. A webhook is that message: OpsAPI sends it to your website’s update address "
                 + "when you ask.")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            ForEach(Array(CMSWebhookText.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.wsCaption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Tone.brand.solidColor, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Label(step.title, systemImage: step.icon).font(.wsSubheadline.weight(.semibold))
                        Text(step.text).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Add or change a website (name, update address, on/off).
struct CMSWebhookForm: View {
    let hook: Record?
    let onSaved: (Record, Bool) -> Void

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var active = true
    @State private var problem: String?
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            Section {
                TextField("Company website", text: $name)
                    .accessibilityIdentifier("cms.webhook.name")
            } header: {
                Text("Name")
            } footer: {
                Text("A name you’ll recognise, e.g. “Company website” or “Blog”.")
            }
            Section {
                TextField("https://www.example.com/api/opsapi-update", text: Binding(get: { url }, set: { url = $0; problem = nil }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("cms.webhook.url")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                }
            } header: {
                Text("Update address")
            } footer: {
                Text("The address your website gave you for updates. Ask your developer, or copy the “Deploy Hook” from "
                     + "your host (Vercel, Netlify, Cloudflare Pages).")
            }
            Section {
                Toggle("On", isOn: $active).accessibilityIdentifier("cms.webhook.active")
            } footer: {
                Text("When it’s off, it isn’t offered when you publish and can’t be sent.")
            }
        }
        .navigationTitle(hook == nil ? "Add a website" : "Change website")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : (hook == nil ? "Add website" : "Save")) { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("cms.webhook.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            name = hook?.string("name") ?? ""
            url = hook?.string("url") ?? ""
            active = hook?.bool("active") ?? true
        }
    }

    private func save() async {
        guard CMSWebhookText.looksLikeAddress(url) else {
            problem = "Paste the full address, starting with https://"
            return
        }
        saving = true
        defer { saving = false }
        do {
            let saved: Record
            if let hook {
                saved = try await services.cms.updateWebhook(hook.id, name: name, url: url, active: active)
            } else {
                saved = try await services.cms.createWebhook(name: name, url: url, active: active)
            }
            onSaved(saved, hook == nil)
            dismiss()
        } catch {
            problem = CMSWebhookText.saveError(error.asAPIError.cmsMessage)
        }
    }
}

/// Shown right after a website is added, and from its "Setup guide": the secret key, a message for a
/// developer, a test, and what OpsAPI sends with code samples.
struct CMSWebhookGuideView: View {
    let hook: Record
    let justCreated: Bool
    let canSend: Bool
    let onTested: () -> Void

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var showingKey = false
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var sample = 0
    @State private var copied: String?

    private var secret: String { hook.string("secret") ?? "" }
    private var name: String { hook.string("name") ?? "Website" }

    var body: some View {
        Form {
            Section {
                Text("Follow these once. After that, you update your website from here or when you publish a post.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Section {
                Text("This key lets your website check that an update really came from you, so nobody else can make it "
                     + "refresh. Treat it like a password: send it to your developer on its own (not in the same message as "
                     + "the address), and they save it on the website as \(CMSWebhookText.secretEnv).")
                    .font(.wsSubheadline)
                Text(showingKey ? secret : String(repeating: "•", count: min(secret.count, 32)))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(showingKey ? "Secret key \(secret)" : "Secret key, hidden")
                Button(showingKey ? "Hide key" : "Show key") { showingKey.toggle() }
                    .accessibilityIdentifier("cms.guide.showKey")
                Button { copy(secret, "Secret key") } label: { Label("Copy key", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("cms.guide.copyKey")
                Button { copy(CMSWebhookText.developerMessage(url: hook.string("url") ?? ""), "Message for your developer") } label: {
                    Label("Copy a message for your developer", systemImage: "text.bubble")
                }
                ShareLink(item: CMSWebhookText.developerMessage(url: hook.string("url") ?? "")) {
                    Label("Send the message for your developer", systemImage: "square.and.arrow.up")
                }
                Text("Everything they need except the key. Using a Deploy Hook from Vercel, Netlify or Cloudflare Pages? "
                     + "Skip this step: those addresses are secret themselves and ignore the key.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            } header: {
                Text("1. Give your website its secret key")
            }
            Section {
                Text("Once the key is saved on your website, send a test update to check everything is connected.")
                    .font(.wsSubheadline)
                if canSend {
                    Button { Task { await test() } } label: {
                        Label(testing ? "Sending…" : "Send a test update", systemImage: "paperplane")
                    }
                    .disabled(testing)
                    .accessibilityIdentifier("cms.guide.test")
                } else {
                    Text("Sending needs permission to change website content.").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(result.ok ? Tone.success.textColor : Tone.danger.textColor)
                        .accessibilityIdentifier("cms.guide.result")
                }
            } header: {
                Text("2. Send a test")
            }
            Section {
                DisclosureGroup("What OpsAPI sends and how to check it") { developerDetails }
            } header: {
                Text("For developers")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: copied.map { .done("\($0) copied.") }) }
        .navigationTitle(justCreated ? "\(name) added: two steps left" : "Set up \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    @ViewBuilder
    private var developerDetails: some View {
        Text("A POST to \(hook.string("url") ?? "the address") with Content-Type: application/json, X-Opsapi-Event and "
             + "X-Opsapi-Signature-256: \"sha256=\" + the HMAC-SHA256 (hex) of the raw body with the secret key. Reject a "
             + "mismatch with 401, and a timestamp older than 5 minutes. Answer 2xx when done.")
            .font(.wsFootnote)
        Text(CMSWebhookText.sampleBody)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        Picker("Code sample", selection: $sample) {
            ForEach(Array(CMSWebhookText.codeSamples.enumerated()), id: \.offset) { index, item in Text(item.label).tag(index) }
        }
        .pickerStyle(.segmented)
        ScrollView(.horizontal) {
            Text(CMSWebhookText.codeSamples[sample].code)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        Button { copy(CMSWebhookText.codeSamples[sample].code, "Code") } label: { Label("Copy code", systemImage: "doc.on.doc") }
        ShareLink(item: CMSWebhookText.codeSamples[sample].code) { Label("Share code", systemImage: "square.and.arrow.up") }
    }

    private func copy(_ text: String, _ what: String) {
        UIPasteboard.general.string = text
        copied = what
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            result = try await services.cms.trigger(hook.id, event: "manual.trigger").explanation
            onTested()
        } catch {
            result = (false, "The test could not be sent. Try again in a moment.")
        }
    }
}
