import SwiftUI

/// The vault, users, all workspaces (platform admin), employees, stores and the audit log:
/// `vault`, `users`, `namespaces`, `employees`, `stores`, `reports`.
extension WorkspacePart {
    static let people = WorkspacePart(
        descriptors: [StoreCatalog.stores],
        screens: [
            "vault": WorkspaceScreen.vault,
            "users": WorkspaceScreen.users,
            "namespaces": WorkspaceScreen.namespaces,
            "employees": WorkspaceScreen.employees,
            "stores": StoreCatalog.screenID,
            "reports": WorkspaceScreen.auditLog,
        ],
        screen: { id in
            switch id {
            case WorkspaceScreen.vault: AnyView(VaultScreen())
            case WorkspaceScreen.users: AnyView(AdminUsersScreen())
            case WorkspaceScreen.namespaces: AnyView(AdminWorkspacesScreen())
            case WorkspaceScreen.employees: AnyView(EmployeesScreen())
            case StoreCatalog.screenID: AnyView(StoresScreen())
            case WorkspaceScreen.auditLog: AnyView(AuditLogScreen())
            default: nil
            }
        })
}

/// Workspace roles to choose from when adding someone (`GET /api/v2/namespace/roles` →
/// `{data: [{id, role_name, display_name, …}], total}`). The owner role is never handed out here.
enum PeopleRoles {
    struct Option: Identifiable, Hashable, Sendable {
        let id: Int?
        let name: String
        let label: String
    }

    static func options(_ json: JSONValue) -> [Option] {
        WorkspaceAPI.records(json, idKeys: ["role_name"]).compactMap { row in
            guard let name = row.string("role_name"), name.lowercased() != "owner" else { return nil }
            return Option(id: row.int("id"), name: name, label: row.string("display_name") ?? Formatters.humanize(name))
        }
    }

    static func load(_ api: WorkspaceAPI) async throws -> [Option] {
        options(try await api.get("/api/v2/namespace/roles"))
    }
}

/// A plain explanation when the person can't open a screen.
struct PeopleNoAccessView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "lock")
        } description: {
            Text(message)
        }
    }
}

/// An optional date: "Add" until one is chosen, then a picker with a way to clear it.
struct PeopleOptionalDateRow: View {
    let label: String
    @Binding var date: Date?
    var includesTime = false

    var body: some View {
        if let current = date {
            HStack {
                DatePicker(label, selection: Binding(get: { current }, set: { date = $0 }),
                           displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear \(label)")
            }
        } else {
            Button { date = Date() } label: {
                LabeledContent(label) { Text("Add").foregroundStyle(.tint) }
            }
            .frame(minHeight: 44)
        }
    }
}

extension Record {
    /// A record's status-like field as a pill with the house tones.
    func peopleBadge(_ path: String, style: StatusStyle = .standard) -> StatusBadge? {
        guard let value = string(path) else { return nil }
        return StatusBadge(text: style.label(for: value), systemImage: style.symbol(for: value), tone: style.tone(for: value))
    }
}
