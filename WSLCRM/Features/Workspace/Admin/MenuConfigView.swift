import SwiftUI

/// Which pages this workspace shows in its menu, and what they're called (`/api/v2/namespace/menu-config`).
/// For the owner and people with full workspace access. Switching a page off hides it from the menu;
/// it doesn't take away anyone's permissions.
struct MenuConfigView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var items: [Record] = []
    @State private var loaded = false
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var renaming: Record?
    @State private var newName = ""
    @State private var busy: String?

    private var allowed: Bool {
        session.permissions.isOwnerOrAdmin || session.permissions.can(.manage, moduleName: "namespace")
    }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            FeedbackSection(feedback: feedback)
            Section {
                ForEach(items) { item in
                    MenuConfigRow(item: item, busy: busy == item.id) { on in
                        Task { await setEnabled(item, on) }
                    } rename: {
                        newName = MenuConfigRow.name(item)
                        renaming = item
                    }
                }
            } footer: {
                if !items.isEmpty {
                    Text("Switching a page off hides it from everyone’s menu in this workspace. It doesn’t change "
                         + "what anyone is allowed to do.")
                }
            }
        }
        .overlay {
            if !allowed {
                ContentUnavailableView("You can't change the menu", systemImage: "lock",
                                       description: Text("The owner, or someone with full access to the workspace's "
                                                         + "settings, can. Ask them if a page should be shown or hidden."))
            } else if !loaded, loadError == nil {
                SkeletonList()
            } else if loaded, items.isEmpty, loadError == nil {
                ContentUnavailableView("Nothing to set up", systemImage: "list.bullet.indent",
                                       description: Text("This workspace has no menu pages to switch on or off."))
            }
        }
        .navigationTitle("Menu")
        .task { if allowed { await load() } }
        .wsRefreshable { await load() }
        .alert("Rename this page", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name in the menu", text: $newName)
                .accessibilityIdentifier("menuConfig.rename.field")
            Button("Save") {
                if let item = renaming { Task { await rename(item, to: newName) } }
            }
            if let item = renaming, item.string("custom_name") != nil {
                Button("Use the usual name") { Task { await rename(item, to: item.string("default_name") ?? "") } }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The new name shows in everyone’s menu in this workspace.")
        }
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/namespace/menu-config")
            items = WorkspaceAPI.records(json, key: "menu_config", idKeys: ["menu_key", "uuid"])
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        loaded = true
    }

    private func setEnabled(_ item: Record, _ on: Bool) async {
        busy = item.id
        defer { busy = nil }
        let name = MenuConfigRow.name(item)
        if await perform($feedback, done: on ? "\(name) is back in the menu." : "\(name) is hidden from the menu.", {
            try await services.workspace().send(.post, "/api/v2/namespace/menu-config/\(item.id)/\(on ? "enable" : "disable")")
        }) {
            await load()
            await session.reloadPermissions()
        }
    }

    private func rename(_ item: Record, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty else {
            feedback = .failed(ResourceService.problem(422, "The name can’t be empty."))
            return
        }
        if await perform($feedback, done: "Renamed to “\(trimmed)”.", {
            try await services.workspace().send(.put, "/api/v2/namespace/menu-config/\(item.id)",
                                                body: .object(["custom_name": .string(trimmed)]))
        }) {
            await load()
            await session.reloadPermissions()
        }
    }
}

private struct MenuConfigRow: View {
    let item: Record
    let busy: Bool
    let toggle: (Bool) -> Void
    let rename: () -> Void

    static func name(_ item: Record) -> String {
        item.string("custom_name") ?? item.string("default_name") ?? Formatters.humanize(item.id)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: MenuIcon.systemName(for: item.string("custom_icon") ?? item.string("default_icon")))
                .frame(width: 28)
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(item)).font(.wsBody)
                let notes = [item.string("custom_name") != nil ? "Usually “\(item.string("default_name") ?? "")”" : nil,
                             item.bool("is_admin_only") == true ? "Platform admins only" : nil,
                             item.bool("always_show") == true ? "Always shown" : nil].compactMap { $0 }
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                Button("Rename", action: rename)
                    .buttonStyle(.borderless)
                    .font(.wsFootnote)
                    .accessibilityIdentifier("menuConfig.rename.\(item.id)")
            }
            Spacer()
            if busy { ProgressView() }
            Toggle("Shown", isOn: Binding(get: { item.bool("is_enabled") ?? true }, set: toggle))
                .labelsHidden()
                .disabled(busy)
                .accessibilityLabel("Show \(Self.name(item)) in the menu")
                .accessibilityIdentifier("menuConfig.toggle.\(item.id)")
        }
        .padding(.vertical, 2)
    }
}
