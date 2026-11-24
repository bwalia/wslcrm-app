import SwiftUI

/// Joy templates & rules: the message copy (every save a new version; a Joy admin approves or
/// retires it) and the client-journey sequences (on or off).
struct PLSetupView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case templates, rules
        var id: String { rawValue }
        var title: String { self == .templates ? "Templates" : "Rules" }
    }

    @State private var tab: Tab = .templates

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("pl.setup.tab")
            switch tab {
            case .templates: PLTemplatesList()
            case .rules: PLRulesList()
            }
        }
        .navigationTitle("Joy templates & rules")
    }
}

/// Status words and tones for templates.
enum PLTemplateStatus {
    static let style = StatusStyle(tones: ["placeholder": .warning, "draft": .info, "approved": .success, "retired": .neutral],
                                   labels: ["placeholder": "Placeholder copy"])
    @MainActor
    static func badge(_ status: String?) -> some View {
        let value = status ?? "draft"
        return StatusBadge(text: style.label(for: value), systemImage: style.symbol(for: value), tone: style.tone(for: value))
    }
}

private struct PLTemplatesList: View {
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var filter = ""
    @State private var hasAppeared = false

    var body: some View {
        List {
            switch state {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let all):
                let shown = all.filter { Self.matches($0, filter) }
                if shown.isEmpty {
                    Text(all.isEmpty ? "No templates yet." : "Nothing matches “\(filter)”.").foregroundStyle(.secondaryText)
                }
                Section {
                    ForEach(shown) { template in
                        NavigationLink(value: NativeScreenRoute(PLScreens.template, template.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(template.string("template_id") ?? "Template").font(.wsHeadline)
                                    Spacer(minLength: 8)
                                    PLTemplateStatus.badge(template.string("status"))
                                }
                                if let purpose = template.string("purpose") {
                                    Text(purpose).font(.wsSubheadline).foregroundStyle(.secondaryText)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .accessibilityIdentifier("pl.template.\(template.id)")
                    }
                } footer: {
                    Text("Copy comes from Document 03; until then every template says PLACEHOLDER.")
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter (A1, booking…)")
        .task { await load() }
        .wsRefreshable { await load() }
        .onAppear {
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
    }

    static func matches(_ template: Record, _ filter: String) -> Bool {
        guard let q = filter.trimmedOrNil?.lowercased() else { return true }
        return (template.string("template_id") ?? "").lowercased().contains(q)
            || (template.string("purpose") ?? "").lowercased().contains(q)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await PLAPI(client: services.client).templates()) } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            if state.value == nil { state = .failed(e) }
        }
    }
}

/// One template: its copy per channel, a preview with a sample client, saving a new version,
/// approving or retiring it (Joy admins), and its history.
struct PLTemplateView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var template: LoadState<Record> = .idle
    @State private var whatsapp = ""
    @State private var sms = ""
    @State private var emailSubject = ""
    @State private var emailBody = ""
    @State private var status = "draft"
    @State private var working = false
    @State private var notice: String?
    @State private var problem: String?

    private var canEdit: Bool { session.permissions.allows(.update, PLModule.templates) }
    /// Approving or retiring what clients receive is a Joy admin's sign-off (the API agrees).
    private var canApprove: Bool { session.permissions.allows(.manage, PLModule.templates) }

    var body: some View {
        Form {
            switch template {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let t):
                editor(t)
            }
        }
        .navigationTitle(template.value?.string("template_id") ?? "Template")
        .navigationBarTitleDisplayMode(.inline)
        .task { if template.value == nil { await load() } }
    }

    @ViewBuilder
    private func editor(_ t: Record) -> some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                .accessibilityIdentifier("pl.template.notice")
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
        }
        Section {
            HStack {
                PLTemplateStatus.badge(t.string("status"))
                Spacer()
                Text("Version \(t.int("current_version") ?? 1)").foregroundStyle(.secondaryText)
            }
            if let purpose = t.string("purpose") { Text(purpose).font(.wsSubheadline) }
            let fields = t.array("fields").compactMap(\.stringValue)
            if !fields.isEmpty {
                Text("Merge fields: " + fields.map { "{\($0)}" }.joined(separator: " "))
                    .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText).textSelection(.enabled)
            }
        }
        Section {
            TextField("WhatsApp", text: $whatsapp, axis: .vertical).lineLimit(3...10).disabled(!canEdit)
                .accessibilityIdentifier("pl.template.whatsapp")
        } header: { Text("WhatsApp") } footer: { Text("Must match the template Meta approved.") }
        Section {
            TextField("SMS", text: $sms, axis: .vertical).lineLimit(2...8).disabled(!canEdit)
                .accessibilityIdentifier("pl.template.sms")
        } header: { Text("SMS") } footer: { Text("The fallback. At most 640 characters (\(sms.count) now).") }
        Section("Email") {
            TextField("Subject", text: $emailSubject).disabled(!canEdit)
                .accessibilityIdentifier("pl.template.subject")
            TextField("Body", text: $emailBody, axis: .vertical).lineLimit(4...14).disabled(!canEdit)
                .accessibilityIdentifier("pl.template.body")
        }
        Section("Preview with a sample client") {
            Text("WhatsApp: \(PLTemplatePreview.fill(whatsapp))\n\nEmail: \(PLTemplatePreview.fill(emailSubject))\n"
                 + PLTemplatePreview.fill(emailBody))
                .font(.wsFootnote).textSelection(.enabled)
        }
        if canEdit {
            Section {
                Button { Task { await saveCopy() } } label: {
                    Label("Save as new version", systemImage: "square.and.arrow.down")
                }
                .frame(minHeight: 44)
                .disabled(working)
                .accessibilityIdentifier("pl.template.save")
                if canApprove {
                    Picker("Status", selection: $status) {
                        Text("Draft").tag("draft")
                        Text("Approved").tag("approved")
                        Text("Retired").tag("retired")
                    }
                    .accessibilityIdentifier("pl.template.status")
                    Button { Task { await setStatus() } } label: { Label("Set status", systemImage: "checkmark.seal") }
                        .frame(minHeight: 44)
                        .disabled(working)
                        .accessibilityIdentifier("pl.template.setStatus")
                }
            } footer: {
                if !canApprove { Text("Saved copy is a draft until a Joy admin approves it.") }
            }
        }
        let versions = t.records("versions", idKeys: ["version"])
        Section("History (\(versions.count))") {
            ForEach(versions) { v in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(v.int("version") ?? 0)").font(.wsSubheadline.weight(.semibold))
                    Text("\(v.string("edited_by") ?? "Seed") · \(PLTime.uk(v.string("created_at")) ?? "")")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var api: PLAPI { PLAPI(client: services.client) }

    private func load() async {
        if template.value == nil { template = .loading }
        do {
            let t = try await api.template(uuid)
            template = .loaded(t)
            let latest = t.records("versions", idKeys: ["version"]).first
            whatsapp = latest?.string("whatsapp_text") ?? ""
            sms = latest?.string("sms_text") ?? ""
            emailSubject = latest?.string("email_subject") ?? ""
            emailBody = latest?.string("email_body") ?? ""
            let current = t.string("status") ?? "draft"
            status = ["draft", "approved", "retired"].contains(current) ? current : "draft"
        } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            if template.value == nil { template = .failed(e) }
        }
    }

    static func copyBody(whatsapp: String, sms: String, subject: String, body: String) -> [String: JSONValue] {
        ["whatsapp_text": .string(whatsapp), "sms_text": .string(sms), "email_subject": .string(subject),
         "email_body": .string(body)]
    }

    private func saveCopy() async {
        await change(Self.copyBody(whatsapp: whatsapp, sms: sms, subject: emailSubject, body: emailBody))
    }

    private func setStatus() async {
        await change(["status": .string(status)])
    }

    private func change(_ body: [String: JSONValue]) async {
        working = true
        defer { working = false }
        do {
            let saved = try await api.editTemplate(uuid, body)
            let version = saved?.int("current_version").map { "v\($0)" } ?? "the template"
            notice = "Saved \(version) (\(PLTemplateStatus.style.label(for: saved?.string("status") ?? status).lowercased()))."
            problem = nil
            await load()
        } catch {
            problem = PluginProblem.message(error.asAPIError, labels: ["whatsapp_text": "WhatsApp", "sms_text": "SMS",
                                                                       "email_subject": "Email subject",
                                                                       "email_body": "Email body", "status": "Status"])
            notice = nil
        }
    }
}

/// The web editor's preview: merge fields filled with a sample client.
enum PLTemplatePreview {
    static let sample: [String: String] = [
        "first_name": "Sarah", "booking_link": "https://portfoliolab.co.uk/book", "owner_first_name": "Sophie",
        "funds_band": "100-250k", "return_date": "15 March", "referrer_first_name": "Mark", "pack_link": "https://…/pack",
        "window_expires_local": "Thu 15:00", "invoice_link": "https://…/pay", "amount_gross": "£3,600.00",
        "milestone_name": "Searches ordered", "next_step": "Draft contract", "brief_summary": "Leeds/Manchester, BTL, 6.5%+",
        "deal_teaser": "BTL · 18% BMV · Leeds", "case_study_link": "https://…/case",
    ]

    /// `{first_name}` → "Sarah"; an unknown field shows as `{field?}`.
    static func fill(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                out += sample[name] ?? "{\(name)?}"
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// The client-journey sequences: switch one off and new clients stop entering it.
private struct PLRulesList: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var enabled: [String: Bool] = [:]
    @State private var turningOff: Record?
    @State private var notice: String?
    @State private var problem: String?

    private var canManage: Bool { session.permissions.allows(.manage, PLModule.rules) }

    var body: some View {
        List {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                    .accessibilityIdentifier("pl.rules.notice")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
            }
            switch state {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let rules):
                if rules.isEmpty { Text("No sequences yet.").foregroundStyle(.secondaryText) }
                Section {
                    ForEach(rules) { rule in row(rule) }
                } footer: {
                    Text("Switching a sequence off stops new clients entering it; clients already in it keep the version "
                         + "they started on.")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .confirmationDialog("Turn off \(turningOff?.string("sequence_id") ?? "this sequence")?",
                            isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { turningOff = nil } }),
                            titleVisibility: .visible) {
            if let rule = turningOff {
                Button("Turn it off", role: .destructive) { Task { await set(rule, on: false) } }
                Button("Keep it on", role: .cancel) {}
            }
        } message: {
            Text("New clients stop entering this sequence. Clients already in it carry on.")
        }
    }

    @ViewBuilder
    private func row(_ rule: Record) -> some View {
        let on = enabled[rule.id] ?? rule.bool("enabled") ?? false
        let title = "\(rule.string("sequence_id") ?? "") · \(rule.string("name") ?? "")"
        let detail = "From \(rule.string("source") ?? "—") · version \(rule.int("current_version") ?? 1)"
        if canManage {
            Toggle(isOn: Binding(get: { on }, set: { wanted in
                if wanted { Task { await set(rule, on: true) } } else { turningOff = rule }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.wsHeadline)
                    Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("pl.rule.\(rule.id)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wsHeadline)
                Text("\(detail) · \(on ? "on" : "off")").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let rules = try await PLAPI(client: services.client).rules()
            state = .loaded(rules)
            enabled = [:]
        } catch {
            let e = error.asAPIError
            if case .cancelled = e { return }
            if state.value == nil { state = .failed(e) }
        }
    }

    private func set(_ rule: Record, on: Bool) async {
        let sequence = rule.string("sequence_id") ?? "The sequence"
        enabled[rule.id] = on
        do {
            try await PLAPI(client: services.client).setRule(rule.id, enabled: on)
            notice = "\(sequence) is \(on ? "on" : "off")."
            problem = nil
        } catch {
            enabled[rule.id] = !on
            problem = PluginProblem.message(error.asAPIError)
            notice = nil
        }
    }
}
