import SwiftUI

// MARK: - What arrived

/// One notification, from either of two lists:
/// - tasks: `GET /api/v2/kanban/notifications` (opsapi `routes/kanban-notifications.lua`): a row of
///   `kanban_notifications` plus `project_name`, `task_title`, `task_uuid` and the actor's name, for every
///   workspace, newest first;
/// - alerts: `GET /api/v2/notifications?namespace_id=` (opsapi `routes/notifications.lua`): leads (new, a
///   reply, back again, steps due), shop orders and accepted quotes, payments recorded — this workspace's,
///   with `data` naming the record (`route`, `uuid`).
struct InboxNotification: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable { case tasks, alerts }
    let source: Source
    let uuid: String
    /// The numeric workspace id (`namespace_id`), to switch workspace before opening it.
    let workspaceId: Int?
    let type: String
    let title: String
    let message: String?
    /// The web page it points at (`/dashboard/projects/<p>/tasks/<t>`), opened natively.
    let actionPath: String?
    var isRead: Bool
    let createdAt: Date?
    let projectName: String?
    let actorName: String?
    /// An alert's record (lead, order, quote, invoice), opened natively.
    let record: AppDeepLink.Target?
    var id: String { "\(source)-\(uuid)" }

    init?(_ record: Record) {
        guard let uuid = record.string("uuid") else { return nil }
        source = .tasks
        self.record = nil
        self.uuid = uuid
        workspaceId = record.int("namespace_id")
        type = record.string("type") ?? ""
        title = record.string("title")?.trimmedOrNil ?? record.string("task_title") ?? "Notification"
        message = record.string("message")?.trimmedOrNil
        actionPath = record.string("action_url")?.trimmedOrNil
        isRead = record.bool("is_read") ?? false
        createdAt = record.date("created_at")
        projectName = record.string("project_name")?.trimmedOrNil
        actorName = record.personName("actor_")
    }

    /// An alert (`notifications` row): `data` is the JSON text the server stored.
    init?(alert row: Record) {
        guard let uuid = row.string("uuid") else { return nil }
        source = .alerts
        self.uuid = uuid
        workspaceId = nil // the list is this workspace's
        type = row.string("type") ?? ""
        title = row.string("title")?.trimmedOrNil ?? "Notification"
        message = row.string("message")?.trimmedOrNil
        isRead = row.bool("is_read") ?? false
        createdAt = row.date("created_at")
        projectName = nil
        actorName = nil
        let data = row.string("data").flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .map(WorkspaceAPI.object)
        // A to-do on a lead (`record_note.todo`) names its record as subject_type / subject_uuid.
        record = AppDeepLink.target(route: data?.string("route") ?? data?.string("subject_type"),
                                    uuid: data?.string("uuid") ?? data?.string("subject_uuid"))
        actionPath = nil
    }

    var systemImage: String {
        if source == .alerts {
            switch type {
            case "record_note.todo": return "checklist"
            case "crm_leads.lead_replied": return "arrowshape.turn.up.left.fill"
            case "crm_leads.hot_lead": return "flame"
            case let t where t.hasPrefix("crm_leads.step"): return "clock"
            case let t where t.hasPrefix("crm_leads."): return "person.crop.circle.badge.plus"
            case let t where t.hasPrefix("shop_orders."): return "cart"
            case let t where t.hasPrefix("shop_quotes."): return "doc.text"
            case let t where t.hasPrefix("invoices."): return "sterlingsign.circle"
            default: return "bell"
            }
        }
        return switch type {
        case "task_assigned", "task_unassigned": "person.badge.plus"
        case "task_commented", "comment_reply": "text.bubble"
        case "task_mentioned", "mentioned": "at"
        case "due_date", "task_due_soon", "task_overdue", "due_soon", "overdue": "clock"
        case "task_completed": "checkmark.circle"
        case "project_invited", "project_member_added": "person.2"
        default: "bell"
        }
    }

    /// One page of the list, and the counts in `meta` (`total` counts every notification, read or not).
    static func page(_ json: JSONValue) -> (items: [InboxNotification], total: Int, unread: Int) {
        let root = WorkspaceAPI.object(json)
        let items = WorkspaceAPI.records(json, idKeys: ["uuid"]).compactMap { InboxNotification($0) }
        return (items, root.int("meta.total") ?? items.count, root.int("meta.unread_count") ?? 0)
    }
}

extension WorkspaceAPI {
    static let notificationsPath = "/api/v2/kanban/notifications"
    static let alertsPath = "/api/v2/notifications"

    /// The workspace's alerts (`{ notifications, unread_count }`, no envelope): `limit`/`offset` paging.
    func alerts(workspace: String, limit: Int, offset: Int, unreadOnly: Bool) async throws -> JSONValue {
        try await get(Self.alertsPath, query: ["namespace_id": workspace, "limit": String(limit), "offset": String(offset),
                                               "unread_only": unreadOnly ? "true" : nil], namespace: false)
    }

    func markAlertRead(_ uuid: String) async throws {
        try await send(.put, "\(Self.alertsPath)/\(uuid)/read", namespace: false)
    }

    func markAllAlertsRead(workspace: String) async throws {
        try await send(.put, "\(Self.alertsPath)/mark-all-read", query: ["namespace_id": workspace], namespace: false)
    }

    func deleteAlert(_ uuid: String) async throws {
        try await send(.delete, "\(Self.alertsPath)/\(uuid)", namespace: false)
    }

    /// The route reads `page`, `perPage` (camel case) and `unread_only=true`.
    func notifications(page: Int, perPage: Int, unreadOnly: Bool) async throws -> JSONValue {
        try await get(Self.notificationsPath,
                      query: ["page": String(page), "perPage": String(perPage), "unread_only": unreadOnly ? "true" : nil],
                      namespace: false)
    }

    func markNotificationRead(_ uuid: String) async throws {
        try await send(.put, "\(Self.notificationsPath)/\(uuid)/read", namespace: false)
    }

    func markAllNotificationsRead() async throws {
        try await send(.post, "\(Self.notificationsPath)/mark-all-read", namespace: false)
    }

    func deleteNotification(_ uuid: String) async throws {
        try await send(.delete, "\(Self.notificationsPath)/\(uuid)", namespace: false)
    }
}

/// The person's notifications and unread count (the bell on Home): tasks from every workspace and this
/// workspace's alerts, merged newest first. Each list pages on its own; a server without the alerts list
/// (notifications not deployed) just shows tasks.
@MainActor
@Observable
final class NotificationsModel {
    static let perPage = 20
    private(set) var items: [InboxNotification] = []
    private(set) var unread = 0
    private(set) var hasLoaded = false
    private(set) var loadError: APIError?
    private(set) var unreadOnly = false
    var feedback: Feedback = .none

    private var tasks: [InboxNotification] = []
    private var alerts: [InboxNotification] = []
    private var taskPage = 1
    private var taskTotal = 0
    private var taskUnread = 0
    private var alertUnread = 0
    private var alertsMore = false
    private var workspace: String?

    var canLoadMore: Bool { tasks.count < (unreadOnly ? taskUnread : taskTotal) || alertsMore }

    func load(_ api: WorkspaceAPI, workspace: String?, unreadOnly: Bool? = nil) async {
        if let unreadOnly { self.unreadOnly = unreadOnly }
        self.workspace = workspace
        let only = self.unreadOnly
        async let taskJSON = api.notifications(page: 1, perPage: Self.perPage, unreadOnly: only)
        async let alertJSON: JSONValue? = workspace == nil ? nil
            : try? await api.alerts(workspace: workspace ?? "", limit: Self.perPage, offset: 0, unreadOnly: only)
        do {
            let t = InboxNotification.page(try await taskJSON)
            tasks = t.items
            taskTotal = t.total
            taskUnread = t.unread
            taskPage = 1
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        let a = Self.alertPage(await alertJSON)
        alerts = a.items
        alertUnread = a.unread
        alertsMore = a.items.count == Self.perPage
        merge()
        hasLoaded = true
    }

    func loadMore(_ api: WorkspaceAPI) async {
        guard canLoadMore else { return }
        let only = unreadOnly
        if tasks.count < (only ? taskUnread : taskTotal),
           let json = try? await api.notifications(page: taskPage + 1, perPage: Self.perPage, unreadOnly: only) {
            let result = InboxNotification.page(json)
            let known = Set(tasks.map(\.uuid))
            tasks += result.items.filter { !known.contains($0.uuid) }
            taskPage += 1
            if result.items.isEmpty { taskTotal = tasks.count }
        }
        if alertsMore, let workspace {
            let json = try? await api.alerts(workspace: workspace, limit: Self.perPage, offset: alerts.count, unreadOnly: only)
            let result = Self.alertPage(json)
            let known = Set(alerts.map(\.uuid))
            alerts += result.items.filter { !known.contains($0.uuid) }
            alertsMore = result.items.count == Self.perPage
        }
        merge()
    }

    /// Best effort: opening a notification shouldn't fail because it couldn't be marked read.
    func markRead(_ notification: InboxNotification, api: WorkspaceAPI) async {
        guard !notification.isRead else { return }
        let ok: Bool
        switch notification.source {
        case .tasks: ok = (try? await api.markNotificationRead(notification.uuid)) != nil
        case .alerts: ok = (try? await api.markAlertRead(notification.uuid)) != nil
        }
        guard ok else { return }
        setRead(notification)
    }

    func markAllRead(_ api: WorkspaceAPI) async {
        let workspace = workspace
        if await run(done: "All marked as read.", {
            try await api.markAllNotificationsRead()
            if let workspace, alertUnread > 0 { try await api.markAllAlertsRead(workspace: workspace) }
        }) {
            await load(api, workspace: workspace)
        }
    }

    func delete(_ notification: InboxNotification, api: WorkspaceAPI) async {
        let source = notification.source
        if await run(done: "Notification removed.", {
            switch source {
            case .tasks: try await api.deleteNotification(notification.uuid)
            case .alerts: try await api.deleteAlert(notification.uuid)
            }
        }) {
            switch source {
            case .tasks:
                tasks.removeAll { $0.uuid == notification.uuid }
                taskTotal = max(0, taskTotal - 1)
                if !notification.isRead { taskUnread = max(0, taskUnread - 1) }
            case .alerts:
                alerts.removeAll { $0.uuid == notification.uuid }
                if !notification.isRead { alertUnread = max(0, alertUnread - 1) }
            }
            merge()
        }
    }

    nonisolated static func alertPage(_ json: JSONValue?) -> (items: [InboxNotification], unread: Int) {
        guard let json else { return ([], 0) }
        let items = WorkspaceAPI.records(json, key: "notifications", idKeys: ["uuid"]).compactMap { InboxNotification(alert: $0) }
        return (items, WorkspaceAPI.object(json).int("unread_count") ?? 0)
    }

    private func merge() {
        items = (tasks + alerts).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        unread = taskUnread + alertUnread
    }

    private func run(done message: String, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            feedback = .done(message)
            return true
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return false }
            feedback = .failed(apiError)
            return false
        }
    }

    private func setRead(_ notification: InboxNotification) {
        func mark(_ list: inout [InboxNotification]) -> Bool {
            guard let index = list.firstIndex(where: { $0.uuid == notification.uuid }), !list[index].isRead else { return false }
            list[index].isRead = true
            if unreadOnly { list.remove(at: index) }
            return true
        }
        switch notification.source {
        case .tasks: if mark(&tasks) { taskUnread = max(0, taskUnread - 1) }
        case .alerts: if mark(&alerts) { alertUnread = max(0, alertUnread - 1) }
        }
        merge()
    }
}

/// A notification's page waiting to open after a workspace switch (the switch rebuilds the tabs;
/// the new Home opens it).
@MainActor
enum PendingNotificationPage {
    static var path: String?

    static func take() -> String? {
        defer { path = nil }
        return path
    }
}

// MARK: - The list

/// Notifications, newest first: tap to open the record natively (switching workspace when it
/// belongs to another one), swipe to mark read or remove.
struct NotificationsView: View {
    let model: NotificationsModel
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var target: ChatLinkTarget?
    @State private var path = NavigationPath()
    @State private var notInApp = false
    @State private var dashboardHost: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                FeedbackSection(feedback: model.feedback)
                Section {
                    Picker("Show", selection: Binding(get: { model.unreadOnly },
                                                      set: { only in Task { await model.load(api, workspace: workspaceUuid,
                                                                                             unreadOnly: only) } })) {
                        Text("All").tag(false)
                        Text(model.unread > 0 ? "Unread (\(model.unread))" : "Unread").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("notifications.filter")
                }
                if let error = model.loadError, model.items.isEmpty {
                    Section { InlineErrorRow(error: error) { Task { await model.load(api, workspace: workspaceUuid) } } }
                } else if !model.hasLoaded {
                    Section { ProgressView("Loading…") }
                } else if model.items.isEmpty {
                    Section {
                        Label(model.unreadOnly ? "Nothing unread. You're up to date." : "No notifications yet. "
                              + "New leads, customers' replies, orders, accepted quotes and payments show here, and so "
                              + "does anyone assigning you a task, mentioning you or commenting.",
                              systemImage: "bell.slash")
                            .font(.wsSubheadline)
                            .foregroundStyle(.secondaryText)
                    }
                } else {
                    Section {
                        ForEach(model.items) { notification in
                            row(notification)
                        }
                        if model.canLoadMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .task { await model.loadMore(api) }
                        }
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The Mac's leading slot is a round button, so a word is cut to "D…": show the usual close cross there.
                    Button { dismiss() } label: {
                        if MacSupport.isMac { Image(systemName: "xmark") } else { Text("Done") }
                    }
                    .accessibilityLabel("Done")
                }
                if model.unread > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Mark all read") { Task { await model.markAllRead(api) } }
                            .accessibilityIdentifier("notifications.markAll")
                    }
                }
            }
            .wsRefreshable { await model.load(api, workspace: workspaceUuid) }
            .task {
                dashboardHost = DashboardURL.forAPI(await services.client.currentBaseURL)?.host
                await model.load(api, workspace: workspaceUuid)
            }
            .navigationDestination(item: $target) { ChatLinkDestinationView(target: $0) }
            .withAppDestinations()
            .alert("This one has nothing to open", isPresented: $notInApp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It's marked as read. Its page isn't one you can open in this workspace.")
            }
        }
    }

    private var api: WorkspaceAPI { services.workspace() }
    private var workspaceUuid: String? { session.workspace?.uuid }

    private func row(_ notification: InboxNotification) -> some View {
        Button { Task { await open(notification) } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notification.systemImage)
                    .font(.wsSubheadline)
                    .foregroundStyle(notification.isRead ? Color.secondary : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background((notification.isRead ? Color.secondary : Color.accentColor).opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        .font(notification.isRead ? .wsSubheadline : .wsHeadline)
                        .foregroundStyle(Color(.label))
                    if let message = notification.message {
                        Text(message).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(3)
                    }
                    Text(details(notification)).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                Spacer(minLength: 0)
                if !notification.isRead {
                    Circle().fill(Color.accentColor).frame(width: 9, height: 9).accessibilityLabel("Unread")
                }
            }
            .padding(.vertical, 4)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !notification.isRead {
                Button("Mark read") { Task { await model.markRead(notification, api: api) } }.tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) { Task { await model.delete(notification, api: api) } }
        }
        .accessibilityIdentifier("notification.\(notification.uuid)")
    }

    private func details(_ notification: InboxNotification) -> String {
        var parts: [String] = []
        if let elsewhere = otherWorkspace(for: notification) { parts.append("In \(elsewhere.name)") }
        if let project = notification.projectName { parts.append(project) }
        if let when = notification.createdAt { parts.append(when.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    /// The workspace it belongs to when that isn't the one open now.
    private func otherWorkspace(for notification: InboxNotification) -> Workspace? {
        guard let id = notification.workspaceId, let current = session.workspace, current.internalId != id else { return nil }
        return session.workspaces.first { $0.internalId == id }
    }

    private func open(_ notification: InboxNotification) async {
        await model.markRead(notification, api: api)
        // An alert: its lead, order, quote or invoice.
        if notification.source == .alerts {
            var next = path
            if let record = notification.record, RecordLinks.append(record, to: &next, permissions: session.permissions) {
                path = next
            } else {
                notInApp = true
            }
            return
        }
        guard let path = notification.actionPath else { return }
        if let workspace = otherWorkspace(for: notification) {
            // Its record lives in another workspace: switch, and the new Home opens it.
            PendingNotificationPage.path = path
            dismiss()
            await session.select(workspace)
            return
        }
        guard let url = URL(string: path),
              case .native(let found) = ChatLinks.resolve(url, dashboardHost: dashboardHost, menu: session.menu) else {
            notInApp = true
            return
        }
        target = found
    }
}
