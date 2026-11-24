import SwiftUI

// MARK: - What arrived

/// One notification, from `GET /api/v2/kanban/notifications` (opsapi `routes/kanban-notifications.lua`,
/// `KanbanNotificationQueries.getByUser`): a row of `kanban_notifications` plus `project_name`,
/// `task_title`, `task_uuid` and the actor's name. It lists every workspace's, newest first.
struct InboxNotification: Identifiable, Equatable, Sendable {
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
    var id: String { uuid }

    init?(_ record: Record) {
        guard let uuid = record.string("uuid") else { return nil }
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

    var systemImage: String {
        switch type {
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
        let items = WorkspaceAPI.records(json, idKeys: ["uuid"]).compactMap(InboxNotification.init)
        return (items, root.int("meta.total") ?? items.count, root.int("meta.unread_count") ?? 0)
    }
}

extension WorkspaceAPI {
    static let notificationsPath = "/api/v2/kanban/notifications"

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

/// The person's notifications and unread count (the bell on Home).
@MainActor
@Observable
final class NotificationsModel {
    static let perPage = 20
    private(set) var items: [InboxNotification] = []
    private(set) var unread = 0
    private(set) var total = 0
    private(set) var hasLoaded = false
    private(set) var loadError: APIError?
    private(set) var page = 1
    private(set) var unreadOnly = false
    var feedback: Feedback = .none

    var canLoadMore: Bool { items.count < (unreadOnly ? unread : total) }

    func load(_ api: WorkspaceAPI, unreadOnly: Bool? = nil) async {
        if let unreadOnly { self.unreadOnly = unreadOnly }
        do {
            let result = InboxNotification.page(try await api.notifications(page: 1, perPage: Self.perPage,
                                                                          unreadOnly: self.unreadOnly))
            items = result.items
            total = result.total
            unread = result.unread
            page = 1
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
        hasLoaded = true
    }

    func loadMore(_ api: WorkspaceAPI) async {
        guard canLoadMore,
              let json = try? await api.notifications(page: page + 1, perPage: Self.perPage, unreadOnly: unreadOnly)
        else { return }
        let result = InboxNotification.page(json)
        let known = Set(items.map(\.uuid))
        items += result.items.filter { !known.contains($0.uuid) }
        page += 1
        if result.items.isEmpty { total = items.count }
    }

    /// Best effort: opening a notification shouldn't fail because it couldn't be marked read.
    func markRead(_ notification: InboxNotification, api: WorkspaceAPI) async {
        guard !notification.isRead, (try? await api.markNotificationRead(notification.uuid)) != nil else { return }
        setRead(notification.uuid)
    }

    func markAllRead(_ api: WorkspaceAPI) async {
        if await run(done: "All marked as read.", { try await api.markAllNotificationsRead() }) {
            await load(api)
        }
    }

    func delete(_ notification: InboxNotification, api: WorkspaceAPI) async {
        if await run(done: "Notification removed.", { try await api.deleteNotification(notification.uuid) }) {
            items.removeAll { $0.uuid == notification.uuid }
            total = max(0, total - 1)
            if !notification.isRead { unread = max(0, unread - 1) }
        }
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

    private func setRead(_ uuid: String) {
        guard let index = items.firstIndex(where: { $0.uuid == uuid }), !items[index].isRead else { return }
        items[index].isRead = true
        unread = max(0, unread - 1)
        if unreadOnly { items.remove(at: index) }
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
    @State private var notInApp = false
    @State private var dashboardHost: String?

    var body: some View {
        NavigationStack {
            List {
                FeedbackSection(feedback: model.feedback)
                Section {
                    Picker("Show", selection: Binding(get: { model.unreadOnly },
                                                      set: { only in Task { await model.load(api, unreadOnly: only) } })) {
                        Text("All").tag(false)
                        Text(model.unread > 0 ? "Unread (\(model.unread))" : "Unread").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("notifications.filter")
                }
                if let error = model.loadError, model.items.isEmpty {
                    Section { InlineErrorRow(error: error) { Task { await model.load(api) } } }
                } else if !model.hasLoaded {
                    Section { ProgressView("Loading…") }
                } else if model.items.isEmpty {
                    Section {
                        Label(model.unreadOnly ? "Nothing unread. You're up to date." : "No notifications yet. "
                              + "When someone assigns you a task, mentions you or comments, it shows here.",
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
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if model.unread > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Mark all read") { Task { await model.markAllRead(api) } }
                            .accessibilityIdentifier("notifications.markAll")
                    }
                }
            }
            .wsRefreshable { await model.load(api) }
            .task {
                dashboardHost = DashboardURL.forAPI(await services.client.currentBaseURL)?.host
                await model.load(api)
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
