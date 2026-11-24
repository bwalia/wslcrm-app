import SwiftUI

/// The Settings tab: after someone submits, closing automatically, privacy, emails and the auto-reply,
/// alerts (in the app and a chat channel), branding, the "I'm human" check and how long responses are kept.
/// Saved with one button, like the web.
struct WebFormSettingsTab: View {
    @Bindable var model: WebFormEditorModel
    let readOnly: Bool
    @Environment(\.services) private var services
    @State private var settings = WebFormSettings()
    @State private var prepared = false
    @State private var problems: [String: String] = [:]
    @State private var saving = false
    @State private var notice: EngageNotice?
    @State private var channels: [(uuid: String, name: String)]?
    @State private var spam: WebFormWorkspaceSettings?
    @State private var showingSpam = false

    var body: some View {
        Form {
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            afterSubmit
            closing
            privacy
            emails
            alerts
            WebFormBrandingSection(settings: $settings, canHideBranding: model.form?.canHideBranding ?? false,
                                   problems: problems)
            spamSection
            retention
            if !readOnly {
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { if saving { ProgressView() }; Text("Save settings") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.large())
                    .disabled(saving)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("forms.settings.save")
                }
            }
        }
        .disabled(readOnly)
        .onAppear(perform: prepare)
        .task { await loadExtras() }
        .sheet(isPresented: $showingSpam) {
            NavigationStack { WebFormSpamProtectionView { spam = $0 } }
        }
    }

    private func prepare() {
        guard !prepared, let form = model.form else { return }
        prepared = true
        settings = form.settings
    }

    // MARK: Sections

    private var afterSubmit: some View {
        Section("After someone submits") {
            TextField("Thank-you message, e.g. Thanks — your response has been received.",
                      text: $settings.successMessage, axis: .vertical)
                .lineLimit(2...6)
            TextField("Or send them to a page (https://…)", text: $settings.redirectURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            problem("redirect_url")
        }
    }

    private var closing: some View {
        Section {
            if let date = settings.closeAt {
                HStack {
                    DatePicker("Close on", selection: Binding(get: { date }, set: { settings.closeAt = $0 }))
                    Button { settings.closeAt = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondaryText)
                        .accessibilityLabel("Don’t close on a date")
                }
            } else {
                Button { settings.closeAt = Calendar.current.date(byAdding: .day, value: 7, to: Date()) } label: {
                    LabeledContent("Close on") { Text("Choose a date").foregroundStyle(.tint) }
                }
            }
            LabeledContent("After this many responses") {
                TextField("No limit", text: $settings.maxSubmissions)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            problem("max_submissions")
            TextField("Closed message, e.g. This form is no longer accepting responses.",
                      text: $settings.closedMessage, axis: .vertical)
                .lineLimit(2...4)
        } header: { Text("Close the form automatically") } footer: {
            Text("People see the closed message instead of the form.")
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            Toggle(isOn: $settings.confidential) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Confidential answers", systemImage: "lock")
                    Text("Answers are shown only here, to people who can see forms. Emails and chat posts say a "
                         + "response arrived and link to it, without the answers, auto-replies don’t include answers, "
                         + "and answers are never sent to AI.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("forms.settings.confidential")
        }
    }

    private var emails: some View {
        Section {
            emailVia
            TextField("sales@example.com, owner@example.com", text: $settings.notifyEmails, axis: .vertical)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("forms.settings.notify")
            problem("notify_emails")
            Toggle(isOn: $settings.autoReply.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reply to the person who answered")
                    Text("Sent to the email they gave. Use {{answer_key}} to include an answer.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            if settings.autoReply.enabled {
                TextField("Subject, e.g. Thanks, {{name}}", text: $settings.autoReply.subject)
                TextField("Hi {{name}}, thanks for getting in touch. We will reply within one working day.",
                          text: $settings.autoReply.body, axis: .vertical)
                    .lineLimit(4...12)
                problem("auto_reply")
                Text("Answer keys: " + (model.form?.fields ?? []).filter { $0.type.isInput }.compactMap(\.key)
                    .map { "{{\($0)}}" }.joined(separator: "  "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText).textSelection(.enabled)
            }
        } header: { Text("Emails") } footer: {
            Text("Tell these people about each new response: comma-separated, up to 10. Empty = the person who "
                 + "created the form.")
        }
    }

    @ViewBuilder
    private var emailVia: some View {
        switch model.form?.emailVia {
        case "workspace":
            Label("Emails go out from your workspace’s own email server (Workspace → Email).",
                  systemImage: "envelope.badge.shield.half.filled")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        case "platform":
            Label("Emails go out from the platform’s email server. Set up your own under Workspace → Email to send "
                  + "from your domain.", systemImage: "envelope")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        case "none":
            Label("No email server is set up, so none of these emails will be sent (responses are still saved). Set "
                  + "one up under Workspace → Email.", systemImage: "exclamationmark.triangle")
                .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
        default:
            EmptyView()
        }
    }

    private var alerts: some View {
        Section {
            Toggle(isOn: $settings.notifyInApp) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In-app notification")
                    Text("To you and the notify addresses that are members of this workspace.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            if let channels {
                Picker("Post each new response to a chat channel", selection: $settings.chatChannelUUID) {
                    Text("Don’t post").tag("")
                    ForEach(channels, id: \.uuid) { Text("#\($0.name)").tag($0.uuid) }
                    if !settings.chatChannelUUID.isEmpty, !channels.contains(where: { $0.uuid == settings.chatChannelUUID }) {
                        Text("A channel you can’t see").tag(settings.chatChannelUUID)
                    }
                }
            }
        } header: { Text("Alerts") } footer: { Text("Besides email: tell the team in the app and in chat.") }
    }

    private var spamSection: some View {
        Section {
            Toggle(isOn: $settings.captcha) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("“I’m human” check (Cloudflare Turnstile)")
                    Text(spam?.ready == false ? "Add your workspace’s Turnstile keys first."
                         : "People tick “Verify you are human” before they can send the form.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .disabled(spam?.ready == false && !settings.captcha)
            Button(spam?.ownKeys == true ? "Workspace keys" : "Set up Turnstile") { showingSpam = true }
                .accessibilityIdentifier("forms.settings.spamKeys")
        } header: { Text("Spam protection") } footer: {
            Text("Bots are already filtered (a hidden trap field, a minimum time, rate limits).")
        }
    }

    private var retention: some View {
        Section {
            LabeledContent("Days") {
                TextField("Keep them", text: $settings.retentionDays)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            problem("retention_days")
        } header: { Text("Keep responses") } footer: {
            Text("Responses older than this are deleted automatically. Leave empty to keep them.")
        }
    }

    @ViewBuilder
    private func problem(_ key: String) -> some View {
        if let text = problems[key] {
            Label(text, systemImage: "exclamationmark.circle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
        }
    }

    // MARK: Work

    private func loadExtras() async {
        channels = try? await services.webForms.chatChannels()
        spam = try? await services.webForms.workspaceSettings()
    }

    private func save() async {
        problems = settings.problems()
        guard problems.isEmpty else {
            notice = .info("Check the settings marked below.")
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await model.saveSettings(settings)
            if let form = model.form { settings = form.settings }
            notice = .done("Settings saved.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// How the public page looks: colours, logo, the submit button's words, "Powered by".
private struct WebFormBrandingSection: View {
    @Binding var settings: WebFormSettings
    let canHideBranding: Bool
    let problems: [String: String]

    var body: some View {
        Section {
            WebFormColourRow(label: "Main colour (buttons, highlights)", hex: $settings.primaryColor, fallback: "#00806b")
            if let p = problems["primary_color"] { Text(p).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
            WebFormColourRow(label: "Page background", hex: $settings.background, fallback: "#f8fafc")
            if let p = problems["background"] { Text(p).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
            EngageImageField(url: $settings.logoURL, alt: "Logo", placeholder: "Logo (image address, https://…)",
                             previewHeight: 80, id: "forms.settings.logo")
            if let p = problems["logo_url"] { Text(p).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
            TextField("Submit button text, e.g. Submit", text: Binding(get: { settings.submitLabel },
                                                                       set: { settings.submitLabel = String($0.prefix(40)) }))
            if canHideBranding {
                Toggle("Hide “Powered by OpsAPI”", isOn: $settings.hideBranding)
            }
        } header: { Text("Branding") } footer: {
            Text("How the public page looks. An empty logo uses your workspace’s logo.")
        }
    }
}

/// A colour picked natively and kept as `#rrggbb` (empty = the default).
struct WebFormColourRow: View {
    let label: String
    @Binding var hex: String
    let fallback: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColorPicker(label, selection: Binding(get: { Self.color(hex.isEmpty ? fallback : hex) },
                                                  set: { hex = Self.hex($0) }), supportsOpacity: false)
            HStack {
                TextField("Default", text: $hex)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !hex.isEmpty {
                    Button("Reset") { hex = "" }.buttonStyle(.borderless).font(.wsFootnote)
                }
            }
        }
    }

    static func color(_ hex: String) -> Color {
        RichColor(css: hex)?.color ?? .accentColor
    }

    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}
