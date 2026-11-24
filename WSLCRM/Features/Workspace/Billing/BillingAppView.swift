import SwiftUI

/// One app the workspace sells (`/dashboard/billing/apps/[uuid]`): Overview, Features, Plans, Upgrades.
struct BillingAppView: View {
    let uuid: String
    let name: String

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case overview, features, plans, upgrades
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .features: "Features"
            case .plans: "Plans"
            case .upgrades: "Upgrades"
            }
        }
    }

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .overview
    @State private var state: LoadState<BillingAppInfo> = .idle

    var body: some View {
        Group {
            switch state {
            case .loaded(let app):
                switch tab {
                case .overview:
                    BillingAppOverview(app: Binding(get: { state.value ?? app }, set: { state = .loaded($0) })) {
                        dismiss()
                    }
                case .features: BillingFeaturesTab(appUUID: app.uuid)
                case .plans: BillingPlansTab(appUUID: app.uuid)
                case .upgrades: BillingUpgradesTab(appUUID: app.uuid)
                }
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            default:
                SkeletonList()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SectionTabs(tabs: Tab.allCases, selection: $tab) { $0.title }
        }
        .navigationTitle(state.value?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            state = .loaded(try await services.billing.app(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

// MARK: - Overview

/// Figures, keys, the app's customer pages, its details and settings, and delete.
private struct BillingAppOverview: View {
    @Binding var app: BillingAppInfo
    let onDeleted: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var report: LoadState<Record> = .idle
    @State private var dashboard: URL?
    @State private var name = ""
    @State private var kind = "web"
    @State private var mode = "test"
    @State private var active = true
    @State private var prepared = false
    @State private var saving = false
    @State private var confirmingRotate = false
    @State private var feedback: Feedback = .none

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: BillingModule.billing) }
    private var changed: Bool {
        name.trimmingCharacters(in: .whitespaces) != app.name || kind != app.kind || mode != app.mode || active != app.active
    }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            figures
            Section {
                CopyableRow(label: "Publishable key", value: app.publishableKey)
                    .accessibilityIdentifier("billing.app.key")
                CopyableRow(label: "App id", value: app.uuid)
                CopyableRow(label: "Slug", value: app.slug)
                if canUpdate {
                    Button { confirmingRotate = true } label: {
                        Label("Issue a new publishable key", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billing.app.rotate")
                }
            } header: {
                Text("Keys")
            } footer: {
                Text("The publishable key is safe to put in browsers and app builds. Your own server checks a customer’s access with a workspace API key.")
            }
            Section {
                ForEach(customerPages, id: \.0) { label, value in CopyableRow(label: label, value: value) }
            } header: {
                Text("Pages for your customers")
            } footer: {
                Text("Send these links to your customers. They choose a plan and pay there; nothing is paid in this app.")
            }
            details
            Section {
                NavigationLink {
                    BillingAppSettingsView(app: app, editable: canUpdate) { app = $0 }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("billing.app.settings")
            } footer: {
                Text("Offline behaviour, licences and devices, public endpoints, privacy, branding and key delivery.")
            }
            if session.permissions.can(.delete, moduleName: BillingModule.billing) {
                Section {
                    DeleteButton(title: "Delete app",
                                 message: "Its keys stop working at once. Plans, purchases, subscriptions and licences are kept for your records.") {
                        do {
                            try await services.workspace().send(.delete, "/api/v2/billing/apps/\(app.uuid)")
                            onDeleted()
                            return true
                        } catch {
                            feedback = .failed(error.asAPIError)
                            return false
                        }
                    }
                }
            }
        }
        .wsRefreshable { await loadReport() }
        .task {
            prepare()
            dashboard = DashboardURL.forAPI(await services.client.currentBaseURL)
            await loadReport()
        }
        .confirmationDialog("Issue a new publishable key?", isPresented: $confirmingRotate, titleVisibility: .visible) {
            Button("Issue new key", role: .destructive) { Task { await rotate() } }
        } message: {
            Text("The current key stops working at once. Update your pricing page and app builds with the new key.")
        }
    }

    @ViewBuilder
    private var figures: some View {
        Section {
            switch report {
            case .loaded(let r):
                MetricGrid(tiles: [
                    MetricTile(title: "Active subscriptions", value: "\(r.int("active") ?? 0)",
                               detail: "\(r.int("trialing") ?? 0) on trial"),
                    MetricTile(title: "Monthly recurring revenue", value: mrr(r)),
                    MetricTile(title: "Payment late", value: "\(r.int("past_due") ?? 0)",
                               detail: "\(r.int("churned_30d") ?? 0) cancelled in 30 days",
                               tone: (r.int("past_due") ?? 0) > 0 ? .warning : .neutral),
                    MetricTile(title: "Licences", value: "\(r.int("active_licenses") ?? 0)",
                               detail: "\(r.int("active_activations") ?? 0) devices · \(r.int("active_grants") ?? 0) grants"),
                ])
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Text("\(r.int("new_30d") ?? 0) new in the last 30 days.").font(.wsFootnote).foregroundStyle(.secondaryText)
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await loadReport() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        Section {
            TextField("Name", text: $name)
                .disabled(!canUpdate)
                .accessibilityIdentifier("billing.app.name")
            Picker("Kind", selection: $kind) {
                ForEach(BillingAppInfo.kinds) { Text($0.label).tag($0.value) }
            }
            .disabled(!canUpdate)
            Picker("Mode", selection: $mode) {
                Text("Test").tag("test")
                Text("Live").tag("live")
            }
            .disabled(!canUpdate)
            Toggle("Active", isOn: $active).disabled(!canUpdate)
            if canUpdate && changed {
                Button("Save changes") { Task { await save() } }
                    .disabled(saving || name.trimmedOrNil == nil)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billing.app.save")
            }
        } header: {
            Text("App")
        } footer: {
            Text("Desktop and self-hosted apps use licence keys. Switching mode issues a new publishable key.")
        }
    }

    private var customerPages: [(String, String)] {
        let base = dashboard?.absoluteString ?? ""
        return [("Pricing (choose a plan)", "\(base)/b/\(app.uuid)/pricing"),
                ("My account (licences, upgrades, billing)", "\(base)/b/\(app.uuid)/account")]
    }

    private func mrr(_ r: Record) -> String {
        let parts = r.records("mrr", idKeys: ["currency"]).map { BillingMoney.text($0.int("amount"), $0.string("currency")) }
        return parts.isEmpty ? BillingMoney.text(0, "gbp") : parts.joined(separator: " + ")
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        name = app.name
        kind = app.kind
        mode = app.mode
        active = app.active
    }

    private func loadReport() async {
        do {
            report = .loaded(BillingAPI.data(try await services.workspace().get("/api/v2/billing/apps/\(app.uuid)/reports")))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            report = .failed(apiError)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = [:]
        if name.trimmingCharacters(in: .whitespaces) != app.name { body["name"] = .string(name.trimmingCharacters(in: .whitespaces)) }
        if kind != app.kind { body["kind"] = .string(kind) }
        if mode != app.mode { body["mode"] = .string(mode) }
        if active != app.active { body["active"] = .bool(active) }
        let modeChanged = mode != app.mode
        do {
            let json = try await services.workspace().send(.put, "/api/v2/billing/apps/\(app.uuid)", body: .object(body))
            app = BillingAppInfo(BillingAPI.data(json))
            prepared = false
            prepare()
            feedback = .done(modeChanged ? "Saved. The app has a new publishable key for \(mode) mode." : "App saved.")
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }

    private func rotate() async {
        await perform($feedback, done: "New publishable key issued. The old one stopped working.") {
            let json = try await services.workspace().send(.post, "/api/v2/billing/apps/\(app.uuid)/rotate-key")
            app = BillingAppInfo(BillingAPI.data(json))
        }
    }
}

// MARK: - Settings

/// An app's settings, drawn from the server's schema so a new setting appears without an app update.
/// Only what changed is sent.
struct BillingAppSettingsView: View {
    let app: BillingAppInfo
    let editable: Bool
    let onSaved: (BillingAppInfo) -> Void
    @Environment(\.services) private var services
    @State private var schema: LoadState<[BillingSettingSpec]> = .idle
    @State private var original: [String: JSONValue] = [:]
    @State private var values: [String: JSONValue] = [:]
    @State private var feedback: Feedback = .none
    @State private var saving = false
    @State private var prepared = false

    private var changes: [String: JSONValue] {
        BillingSettings.changed(schema.value ?? [], original: original, edited: values)
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            switch schema {
            case .loaded(let specs):
                ForEach(groups(specs), id: \.id) { group in
                    Section {
                        ForEach(group.fields) { spec in
                            BillingSettingField(spec: spec, value: binding(spec.key), disabled: !editable || spec.readonly)
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        if let hint = group.hint { Text(hint) }
                    }
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editable {
                ToolbarItem(placement: .confirmationAction) {
                    Button(changes.isEmpty ? "Save" : "Save (\(changes.count))") { Task { await save() } }
                        .disabled(saving || changes.isEmpty)
                        .accessibilityIdentifier("billing.settings.save")
                }
            }
        }
        .task {
            if !prepared {
                prepared = true
                original = app.settings
                values = app.settings
            }
            await load()
        }
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let hint: String?
        let fields: [BillingSettingSpec]
    }

    private func groups(_ specs: [BillingSettingSpec]) -> [Group] {
        var result = BillingSettings.groups.compactMap { group -> Group? in
            let fields = specs.filter { $0.group == group.id }
            return fields.isEmpty ? nil : Group(id: group.id, title: group.title, hint: group.hint, fields: fields)
        }
        let known = Set(BillingSettings.groups.map(\.id))
        let other = specs.filter { !known.contains($0.group) }
        if !other.isEmpty { result.append(Group(id: "other", title: "Other", hint: nil, fields: other)) }
        return result
    }

    private func binding(_ key: String) -> Binding<JSONValue?> {
        Binding(get: { values[key] }, set: { values[key] = $0 })
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/billing/settings-schema", query: ["kind": app.kind])
            schema = .loaded(WorkspaceAPI.records(json, idKeys: ["key"]).map(BillingSettingSpec.init))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            schema = .failed(apiError)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let count = changes.count
        do {
            let json = try await services.workspace().send(.put, "/api/v2/billing/apps/\(app.uuid)",
                                                           body: .object(["settings": .object(changes)]))
            let updated = BillingAppInfo(BillingAPI.data(json))
            original = updated.settings
            values = updated.settings
            onSaved(updated)
            feedback = .done(count == 1 ? "1 setting saved." : "\(count) settings saved.")
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

/// One setting's control, by its type.
private struct BillingSettingField: View {
    let spec: BillingSettingSpec
    @Binding var value: JSONValue?
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
                .disabled(disabled)
                .accessibilityIdentifier("billing.setting.\(spec.key)")
            if let help = spec.help {
                Text(help).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if spec.readonly {
            CopyableRow(label: spec.label, value: value?.stringValue ?? "—")
        } else {
            switch spec.type {
            case "boolean":
                Toggle(spec.label, isOn: Binding(get: { value?.boolValue ?? false }, set: { value = .bool($0) }))
            case "enum":
                Picker(spec.label, selection: Binding(get: { value?.stringValue ?? "" }, set: { value = .string($0) })) {
                    if (value?.stringValue ?? "").isEmpty { Text("Choose").tag("") }
                    ForEach(spec.values, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                }
            case "integer":
                LabeledContent(spec.label) {
                    TextField(spec.nullable ? "Unlimited" : "", text: integerText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            case "origins", "urls":
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(spec.label) (one per line)").font(.wsCaption).foregroundStyle(.secondaryText)
                    TextField(spec.type == "origins" ? "https://app.example.com" : "https://app.example.com/account",
                              text: linesText, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            case "object":
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.label).font(.wsBody)
                    ForEach(spec.fields, id: \.key) { field in
                        LabeledContent(Formatters.humanize(field.key)) {
                            TextField("\(field.defaultValue)", text: objectText(field))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.wsSubheadline)
                    }
                }
            case "color":
                LabeledContent(spec.label) {
                    HStack {
                        TextField("#2563eb", text: stringText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                        Circle().fill(Self.color(hex: value?.stringValue) ?? .clear)
                            .overlay(Circle().stroke(Color.secondaryText.opacity(0.4)))
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                    }
                }
            default:
                LabeledContent(spec.label) {
                    TextField("", text: stringText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(spec.type == "email" ? .emailAddress : spec.type == "url" ? .URL : .default)
                        .textInputAutocapitalization(spec.type == "string" ? .sentences : .never)
                        .autocorrectionDisabled(spec.type != "string")
                }
            }
        }
    }

    private var stringText: Binding<String> {
        Binding(get: { value?.stringValue ?? "" }, set: { value = .string($0) })
    }

    private var integerText: Binding<String> {
        Binding(get: {
            if case .number(let n)? = value { return String(Int(n)) }
            return value?.stringValue ?? ""
        }, set: { text in
            let digits = text.filter(\.isNumber)
            if digits.isEmpty { value = spec.nullable ? .null : .number(Double(spec.min ?? 0)) }
            else { value = .number(Double(Int(digits) ?? 0)) }
        })
    }

    private var linesText: Binding<String> {
        Binding(get: { (value?.arrayItems ?? []).compactMap(\.stringValue).joined(separator: "\n") },
                set: { text in
                    value = .array(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.map(JSONValue.string))
                })
    }

    private func objectText(_ field: BillingSettingSpec.SubField) -> Binding<String> {
        Binding(get: {
            let object = value?.objectFields ?? [:]
            return object[field.key]?.stringValue ?? "\(field.defaultValue)"
        }, set: { text in
            var object = value?.objectFields ?? [:]
            // Keep every part, so the server never gets half an object.
            for other in spec.fields where object[other.key] == nil { object[other.key] = .number(Double(other.defaultValue)) }
            object[field.key] = .number(Double(Int(text.filter(\.isNumber)) ?? field.defaultValue))
            value = .object(object)
        })
    }

    static func color(hex: String?) -> Color? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let rgb = UInt32(text, radix: 16) else { return nil }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}
