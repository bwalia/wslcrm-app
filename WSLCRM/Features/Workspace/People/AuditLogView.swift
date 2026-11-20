import SwiftUI

/// The workspace's audit log (the `reports` menu key): who changed members, roles, the workspace,
/// its sign-in code setting and API keys, with the values before and after.
/// `GET /api/v2/namespace/audit-logs` (RBAC `namespace.read`).
struct AuditLogScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        if session.permissions.can(.read, moduleName: "namespace") {
            AuditLogList(api: services.workspace())
        } else {
            PeopleNoAccessView(title: "Audit log",
                               message: "Seeing the audit log needs permission to read the workspace. "
                                   + "Ask the workspace owner to add it to your role.")
                .navigationTitle("Audit log")
        }
    }
}

/// What the log can be filtered by, and the words shown for each value.
enum AuditLogVocabulary {
    static let entityTypes: [Choice] = [
        Choice("namespace_member", "Members"), Choice("namespace_role", "Roles"), Choice("namespace", "Workspace"),
        Choice("api_key", "API keys"), Choice("namespace_redirect_origins", "Sign-in return addresses"),
    ]

    static let actions: [Choice] = [
        Choice("member.added", "Member added"), Choice("member.role_changed", "Member’s roles changed"),
        Choice("member.removed", "Member removed"), Choice("role.created", "Role created"),
        Choice("role.permissions_updated", "Role permissions changed"), Choice("role.deleted", "Role deleted"),
        Choice("namespace.updated", "Workspace details changed"),
        Choice("namespace.ownership_transferred", "Ownership transferred"),
        Choice("mfa.enabled", "Sign-in codes turned on"), Choice("mfa.disabled", "Sign-in codes turned off"),
        Choice("api_key.created", "API key created"), Choice("api_key.revoked", "API key revoked"),
        Choice("update", "Updated"),
    ]

    static func actionLabel(_ value: String) -> String {
        actions.first { $0.value == value }?.label
            ?? Formatters.humanize(value.replacingOccurrences(of: ".", with: " "))
    }

    static func entityLabel(_ value: String) -> String {
        entityTypes.first { $0.value == value }?.label ?? Formatters.humanize(value)
    }

    /// Green for things added, red for things removed, amber for changes (as on the web).
    static func tone(for action: String) -> Tone {
        let lower = action.lowercased()
        if lower.contains("added") || lower.contains("created") || lower.contains("enabled") { return .success }
        if lower.contains("removed") || lower.contains("deleted") || lower.contains("revoked")
            || lower.contains("disabled") { return .danger }
        if lower.contains("updated") || lower.contains("changed") || lower.contains("transferred") || lower == "update" {
            return .warning
        }
        return .neutral
    }

    /// "Created", "Deleted", the changed fields, or nil when there's nothing to compare.
    static func changeSummary(_ row: Record) -> String? {
        let old = row.objectMap("old_values"), new = row.objectMap("new_values")
        if old.isEmpty && new.isEmpty { return nil }
        if old.isEmpty { return "Created" }
        if new.isEmpty { return "Deleted" }
        let keys = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
        return keys.isEmpty ? "No changes" : keys.map(Formatters.humanize).joined(separator: ", ")
    }

    /// The `to_date` the server compares with `<=`: the end of the chosen day, so that day is included.
    static func dayStart(_ date: Date) -> String { "\(CalendarDay(date: date).isoString) 00:00:00" }
    static func dayEnd(_ date: Date) -> String { "\(CalendarDay(date: date).isoString) 23:59:59" }
}

@MainActor
@Observable
private final class AuditLogFilters {
    var entityType = ""
    var action = ""
    var from: Date?
    var to: Date?

    var isActive: Bool { !entityType.isEmpty || !action.isEmpty || from != nil || to != nil }

    var query: [String: String?] {
        ["entity_type": entityType, "action": action,
         "from_date": from.map(AuditLogVocabulary.dayStart), "to_date": to.map(AuditLogVocabulary.dayEnd)]
    }
}

private struct AuditLogList: View {
    @State private var filters: AuditLogFilters
    @State private var model: PagedListModel<Record>
    @State private var expanded: Set<String> = []
    @State private var choosingDates = false

    init(api: WorkspaceAPI) {
        let filters = AuditLogFilters()
        _filters = State(initialValue: filters)
        _model = State(initialValue: PagedListModel { _, page in
            var query = filters.query
            query["page"] = String(page)
            query["per_page"] = "20"
            let json = try await api.get("/api/v2/namespace/audit-logs", query: query)
            return WorkspaceAPI.page(json, page: page, perPage: 20)
        })
    }

    var body: some View {
        PagedList(model: model, emptyTitle: filters.isActive ? "Nothing matches these filters" : "No changes recorded yet",
                  emptySystemImage: "list.bullet.clipboard",
                  emptyDescription: filters.isActive
                      ? "Try another type of change or a wider date range."
                      : "Changes to members, roles, the workspace and its API keys are recorded here.") { row in
            AuditLogRow(row: row, expanded: expanded.contains(row.id)) {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            }
        }
        .navigationTitle("Audit log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("What changed", selection: Binding(get: { filters.entityType }, set: { filters.entityType = $0; reload() })) {
                        Text("Everything").tag("")
                        ForEach(AuditLogVocabulary.entityTypes) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.menu)
                    Picker("Action", selection: Binding(get: { filters.action }, set: { filters.action = $0; reload() })) {
                        Text("Every action").tag("")
                        ForEach(AuditLogVocabulary.actions) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.menu)
                    Button { choosingDates = true } label: { Label("Dates…", systemImage: "calendar") }
                    if filters.isActive {
                        Button("Clear filters", role: .destructive) {
                            filters.entityType = ""; filters.action = ""; filters.from = nil; filters.to = nil
                            reload()
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                                  : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("auditLog.filter")
            }
        }
        .sheet(isPresented: $choosingDates) {
            NavigationStack {
                Form {
                    Section {
                        PeopleOptionalDateRow(label: "From", date: Binding(get: { filters.from }, set: { filters.from = $0 }))
                        PeopleOptionalDateRow(label: "To", date: Binding(get: { filters.to }, set: { filters.to = $0 }))
                    } footer: {
                        Text("Both days are included.")
                    }
                }
                .navigationTitle("Dates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show") { choosingDates = false; reload() }
                            .accessibilityIdentifier("auditLog.dates.apply")
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func reload() {
        Task { await model.load() }
    }
}

private struct AuditLogRow: View {
    let row: Record
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let action = row.string("action") ?? "update"
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusBadge(text: AuditLogVocabulary.actionLabel(action), systemImage: symbol(action),
                                    tone: AuditLogVocabulary.tone(for: action))
                        Text(who).font(.wsHeadline)
                        if let email = row.string("user_email"), email != who {
                            Text(email).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        HStack(spacing: 6) {
                            if let entity = row.string("entity_type") {
                                Text(AuditLogVocabulary.entityLabel(entity)).font(.wsCaption.weight(.semibold))
                            }
                            if let id = row.string("entity_id") {
                                Text(id).font(.wsCaption.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .foregroundStyle(.secondaryText)
                        if let changes = AuditLogVocabulary.changeSummary(row) {
                            Text(changes).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(expanded ? nil : 2)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let when = row.date("created_at") {
                            Text(Formatters.relative(when) ?? "").font(.wsFootnote)
                            Text(Formatters.dateTime(when) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        if hasDetail {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.wsFootnote)
                                .foregroundStyle(.secondaryText)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(hasDetail ? (expanded ? "Hides the details" : "Shows the details") : "")
            .accessibilityIdentifier("auditLog.row.\(row.id)")
            if expanded { details }
        }
        .padding(.vertical, 4)
    }

    private var who: String { row.personName("user_") ?? row.string("user_email") ?? "System" }

    private var hasDetail: Bool {
        !row.objectMap("old_values").isEmpty || !row.objectMap("new_values").isEmpty
            || row.string("ip_address") != nil || row.string("user_agent") != nil
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = FieldFormatter.describe(.object(row.objectMap("old_values"))) {
                block("Before", text)
            }
            if let text = FieldFormatter.describe(.object(row.objectMap("new_values"))) {
                block("After", text)
            }
            if let ip = row.string("ip_address") { block("IP address", ip) }
            if let agent = row.string("user_agent") { block("Device", agent) }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
            Text(text).font(.wsFootnote.monospaced()).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ action: String) -> String {
        switch AuditLogVocabulary.tone(for: action) {
        case .success: "plus.circle"
        case .danger: "minus.circle"
        case .warning: "pencil.circle"
        default: "circle"
        }
    }
}
