import SwiftUI
import UIKit

/// Email (`/dashboard/namespace/email`): the workspace's own mail servers, which account sends each
/// kind of email, and the wording of the emails it sends.
struct MailSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var tab: MailTab = .accounts
    @State private var overview: Record?
    @State private var templates: [Record] = []
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var adding = false
    @State private var hasAppeared = false

    private var canEdit: Bool { session.permissions.can(.update, moduleName: "namespace") }

    var body: some View {
        List {
            if let loadError, overview == nil {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
            switch tab {
            case .accounts: accounts
            case .routing: routing
            case .templates: templateList
            }
        }
        .overlay { if overview == nil, loadError == nil { SkeletonList() } }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SectionTabs(tabs: MailTab.allCases, selection: $tab) { $0.title }
                FeedbackBar(feedback: feedback)
            }
        }
        .navigationTitle("Email")
        .task { await load() }
        .refreshable { await load() }
        .onAppear {
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
        .toolbar {
            if canEdit, tab == .accounts {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add an email account", systemImage: "plus") }
                        .accessibilityIdentifier("mail.addAccount")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ResourceFormView(descriptor: WorkspaceAdminCatalog.mailAccounts, existing: nil) { _ in
                    feedback = .done("Email account added. Send a test email to check it works.")
                    Task { await load() }
                }
            }
        }
    }

    // MARK: Accounts

    private var accountRecords: [Record] { overview?.records("accounts", idKeys: ["uuid"]) ?? [] }

    @ViewBuilder
    private var accounts: some View {
        Section {
            if overview != nil, accountRecords.isEmpty {
                Text("No email accounts yet. Until you add one, emails go out from the platform’s own server.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(accountRecords) { account in
                NavigationLink(value: ResourceRoute(descriptorID: WorkspaceAdminCatalog.mailAccounts.id,
                                                    recordID: account.id, seed: account)) {
                    MailAccountRow(account: account)
                }
                .accessibilityIdentifier("mail.account.\(account.id)")
            }
        } header: {
            Text("Your email accounts")
        } footer: {
            Text("Open an account to send a test email, make it the default, change it or delete it.")
        }
        if let overview {
            Section {
                let name = overview.string("platform.from_name")
                let email = overview.string("platform.from_email")
                DetailRow(label: "Platform server", value: [name, email.map { "<\($0)>" }].compactMap { $0 }
                    .joined(separator: " ").trimmedOrNil ?? "Not set up")
                ForEach(overview.array("platform_only").compactMap(\.stringValue), id: \.self) { kind in
                    Label(kind, systemImage: "lock").font(.wsFootnote)
                }
            } header: {
                Text("Always sent by the platform")
            } footer: {
                Text("These emails always come from the platform’s server, whatever you choose here.")
            }
        }
    }

    // MARK: Routing

    private var routes: [Record] { overview?.records("routing", idKeys: ["key"]) ?? [] }

    @ViewBuilder
    private var routing: some View {
        let groups = MailRouting.groups(routes)
        if overview != nil, groups.isEmpty {
            Section { Text("There are no kinds of email to choose for.").foregroundStyle(.secondaryText) }
        }
        ForEach(groups, id: \.0) { group, rows in
            Section(group) {
                ForEach(rows) { row in
                    MailRouteRow(row: row, accounts: accountRecords, canEdit: canEdit) { uuid in
                        Task { await route(row, to: uuid) }
                    }
                }
            }
        }
        if overview != nil {
            Section {
                EmptyView()
            } footer: {
                Text(canEdit ? "“Default account” sends with whichever account is the default. Sign-in codes and "
                     + "security alerts always come from the platform."
                     : "Only people who can change workspace settings can choose these.")
            }
        }
    }

    // MARK: Templates

    @ViewBuilder
    private var templateList: some View {
        Section {
            if overview != nil, templates.isEmpty {
                Text("No email wording can be changed here.").foregroundStyle(.secondaryText)
            }
            ForEach(templates) { template in
                NavigationLink {
                    MailTemplateEditorView(template: template, canEdit: canEdit) { message in
                        feedback = .done(message)
                        Task { await load() }
                    }
                } label: {
                    MailTemplateRow(template: template)
                }
                .accessibilityIdentifier("mail.template.\(template.id)")
            }
        } footer: {
            Text("Change the wording of the emails your workspace sends. Built-in wording is used until you change it.")
        }
    }

    // MARK: Work

    private func load() async {
        let api = services.workspace()
        do {
            let json = try await api.get("/api/v2/namespace/mail-accounts")
            overview = WorkspaceAPI.object(json).object("data") ?? WorkspaceAPI.object(json)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        if let json = try? await api.get("/api/v2/namespace/email-templates") {
            templates = WorkspaceAPI.records(json, idKeys: ["key"])
        }
    }

    private func route(_ row: Record, to uuid: String?) async {
        guard let key = row.string("key") else { return }
        let name = row.string("name") ?? Formatters.humanize(key)
        let account = accountRecords.first { $0.id == uuid }?.string("name")
        let message = key == "default"
            ? (account.map { "\($0) is now the default account." } ?? "Emails now go out from the platform’s server.")
            : (account.map { "\(name) emails now go out from \($0)." } ?? "\(name) emails now use the default account.")
        await perform($feedback, done: message) {
            let json = try await services.workspace().send(.put, "/api/v2/namespace/mail-routing",
                                                            body: MailRouting.body(key: key, account: uuid))
            let updated = WorkspaceAPI.records(json, idKeys: ["key"])
            if !updated.isEmpty, var fields = overview?.fields {
                fields["routing"] = .array(updated.map(\.json))
                overview = Record(fields)
            }
        }
        await load()
    }
}

private enum MailTab: String, CaseIterable, Identifiable, Hashable {
    case accounts, routing, templates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .routing: "Who sends what"
        case .templates: "Wording"
        }
    }
}

/// Which account sends each kind of email (`/api/v2/namespace/mail-routing`).
enum MailRouting {
    /// Rows grouped as the server orders them (General, Leads and customers, Sales, …).
    static func groups(_ rows: [Record]) -> [(String, [Record])] {
        var order: [String] = []
        var groups: [String: [Record]] = [:]
        for row in rows {
            let group = row.string("group") ?? "Other"
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(row)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// `{routes: {key: uuid | null}}`. null: the default account (for `default`: the platform's server).
    static func body(key: String, account: String?) -> JSONValue {
        .object(["routes": .object([key: account.map(JSONValue.string) ?? .null])])
    }

    /// How an account's health reads: off, its last test failed, tested when, or never tested.
    static func status(_ account: Record) -> (String, Tone, String) {
        if account.bool("enabled") == false { return ("Off", .neutral, "pause.circle") }
        if account.string("last_error") != nil { return ("Last test failed", .danger, "xmark.octagon") }
        if let tested = account.date("last_tested_at") {
            return ("Tested \(Formatters.relative(tested) ?? "")", .success, "checkmark.circle")
        }
        return ("Not tested", .warning, "questionmark.circle")
    }
}

private struct MailAccountRow: View {
    let account: Record

    var body: some View {
        let (text, tone, symbol) = MailRouting.status(account)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.string("name") ?? "Email account").font(.wsHeadline)
                if account.bool("is_default") == true {
                    Image(systemName: "star.fill").foregroundStyle(Tone.info.textColor).accessibilityLabel("Default")
                }
            }
            if let from = account.string("from_email") {
                Text(from).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let host = account.string("host") {
                Text("\(host):\(account.int("port") ?? 587)").font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
            }
            StatusBadge(text: text, systemImage: symbol, tone: tone)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct MailRouteRow: View {
    let row: Record
    let accounts: [Record]
    let canEdit: Bool
    let choose: (String?) -> Void

    var body: some View {
        let isDefault = row.string("key") == "default"
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { row.string("account_uuid") ?? "" },
                                      set: { choose($0.isEmpty ? nil : $0) })) {
                Text(isDefault ? "Platform server" : "Default account").tag("")
                ForEach(accounts) { account in
                    Text((account.string("name") ?? "Account") + (account.bool("enabled") == false ? " (off)" : ""))
                        .tag(account.id)
                }
            } label: {
                Text(row.string("name") ?? Formatters.humanize(row.string("key"))).font(.wsBody)
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("mail.route.\(row.id)")
            if let description = row.string("description") {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }
}

private struct MailTemplateRow: View {
    let template: Record

    var body: some View {
        let customised = template.bool("customised") == true
        VStack(alignment: .leading, spacing: 4) {
            Text(template.string("name") ?? Formatters.humanize(template.string("key"))).font(.wsHeadline)
            if let subject = template.string("subject") {
                Text(subject).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            }
            StatusBadge(text: customised ? "Customised" : "Built-in",
                        systemImage: customised ? "pencil.circle" : "shippingbox", tone: customised ? .brand : .neutral)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editing an email's wording

private struct MailTemplateEditorView: View {
    let template: Record
    let canEdit: Bool
    let changed: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var html = ""
    @State private var prepared = false
    @State private var preview: MailPreview?
    @State private var feedback: Feedback = .none
    @State private var working = false
    @State private var confirmingReset = false

    private var key: String { template.string("key") ?? template.id }
    private var customised: Bool { template.bool("customised") == true }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section("Subject") {
                TextField(template.string("default_subject") ?? "Subject", text: $subject, axis: .vertical)
                    .disabled(!canEdit)
                    .accessibilityIdentifier("mailTemplate.subject")
            }
            Section {
                TextEditor(text: $html)
                    .font(.wsFootnote.monospaced())
                    .frame(minHeight: 220)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!canEdit)
                    .accessibilityIdentifier("mailTemplate.html")
            } header: {
                Text("Email body (HTML)")
            } footer: {
                Text(customised || !html.isEmpty ? "Up to 100 kB."
                     : "This email uses the built-in wording. Write your own here to replace it; preview to see the built-in one.")
            }
            let variables = template.array("variables").compactMap(\.stringValue)
            if !variables.isEmpty {
                Section {
                    ForEach(variables, id: \.self) { variable in
                        Button {
                            html += "{{\(variable)}}"
                        } label: {
                            HStack {
                                Text("{{\(variable)}}").font(.wsFootnote.monospaced())
                                Spacer()
                                Image(systemName: "plus.circle").accessibilityHidden(true)
                            }
                        }
                        .disabled(!canEdit)
                        .accessibilityLabel("Add \(variable)")
                    }
                } header: {
                    Text("Details you can put in")
                } footer: {
                    Text("Tap one to add it to the end of the body. It’s filled in when the email is sent.")
                }
            }
            Section {
                Button { Task { await showPreview() } } label: { Label("Preview", systemImage: "eye") }
                    .disabled(working)
                    .accessibilityIdentifier("mailTemplate.preview")
                if canEdit, customised {
                    Button(role: .destructive) { confirmingReset = true } label: {
                        Label("Go back to the built-in wording", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(working)
                    .accessibilityIdentifier("mailTemplate.reset")
                }
            }
        }
        .navigationTitle(template.string("name") ?? "Email")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(working)
                        .accessibilityIdentifier("mailTemplate.save")
                }
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            subject = template.string("subject") ?? template.string("default_subject") ?? ""
            html = template.string("html") ?? ""
        }
        .sheet(item: $preview) { preview in
            NavigationStack {
                MailPreviewView(preview: preview)
            }
        }
        .confirmationDialog("Go back to the built-in wording?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Use the built-in wording", role: .destructive) { Task { await reset() } }
        } message: {
            Text("Your version of this email is deleted.")
        }
    }

    private func showPreview() async {
        working = true
        defer { working = false }
        var draft: [String: JSONValue] = [:]
        if let text = JSONValue.text(subject) { draft["subject"] = text }
        if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft["html"] = .string(html) }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/namespace/email-templates/\(key)/preview",
                                                            body: .object(draft))
            let data = WorkspaceAPI.object(json).object("data") ?? WorkspaceAPI.object(json)
            preview = MailPreview(subject: data.string("subject") ?? subject, html: data.string("html") ?? "")
            feedback = .none
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func save() async {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty, trimmedSubject.count <= 200 else {
            feedback = .failed(ResourceService.problem(422, "The subject is needed (up to 200 characters)."))
            return
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback = .failed(ResourceService.problem(422, "Write the email body before saving."))
            return
        }
        working = true
        defer { working = false }
        if await perform($feedback, done: "Saved.", {
            try await services.workspace().send(.put, "/api/v2/namespace/email-templates/\(key)",
                                                body: .object(["subject": .string(trimmedSubject), "html": .string(html)]))
        }) {
            changed("“\(template.string("name") ?? "Email")” now uses your wording.")
            dismiss()
        }
    }

    private func reset() async {
        working = true
        defer { working = false }
        if await perform($feedback, done: "Reset.", {
            try await services.workspace().send(.delete, "/api/v2/namespace/email-templates/\(key)")
        }) {
            changed("“\(template.string("name") ?? "Email")” uses the built-in wording again.")
            dismiss()
        }
    }
}

private struct MailPreview: Identifiable {
    let id = UUID()
    let subject: String
    let html: String
}

private struct MailPreviewView: View {
    let preview: MailPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.subject).font(.wsHeadline).textSelection(.enabled)
                Divider()
                MailHTMLText(html: preview.html)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            }
            .padding()
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// HTML drawn as styled text (no web view): what an email or document looks like, near enough.
struct MailHTMLText: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "mail.preview.body"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.attributedText = Self.attributed(html)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    static func attributed(_ html: String) -> NSAttributedString {
        guard let data = html.data(using: .utf8),
              let text = try? NSAttributedString(data: data, options: [
                  .documentType: NSAttributedString.DocumentType.html,
                  .characterEncoding: String.Encoding.utf8.rawValue,
              ], documentAttributes: nil) else {
            return NSAttributedString(string: html)
        }
        return text
    }
}
