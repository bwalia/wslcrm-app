import SwiftUI

enum HelpdeskScreens {
    static let overview = "plugin.helpdesk.overview"
    /// The helpdesk's RBAC module (`projects/helpdesk/project.lua`).
    static let module = "helpdesk_tickets"
}

/// The helpdesk plugin's API (`/api/v2/helpdesk`, projects/helpdesk/api).
struct HelpdeskAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/helpdesk"

    /// `GET /stats`: `[{ status, count }]` → count per status.
    func stats() async throws -> [String: Int] {
        let (data, _) = try await client.sendRaw(.get("\(Self.base)/stats"))
        return Self.parseStats(try ResourceService.decode(data))
    }

    static func parseStats(_ json: JSONValue) -> [String: Int] {
        let page = ResourceService.parsePage(json, listKey: nil, idKeys: ["status"], requestedPage: 1, perPage: 0)
        var counts: [String: Int] = [:]
        for row in page.items {
            if let status = row.string("status") { counts[status] = row.int("count") ?? 0 }
        }
        return counts
    }

    /// The open tickets most in need of attention: highest priority first (as the web overview asks).
    func needsAttention() async throws -> Page<Record> {
        let query = [URLQueryItem(name: "status", value: "open"), URLQueryItem(name: "sort", value: "priority"),
                     URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "per_page", value: "10")]
        let (data, _) = try await client.sendRaw(.get("\(Self.base)/tickets", query: query))
        return ResourceService.parsePage(try ResourceService.decode(data), listKey: nil, idKeys: ["uuid"],
                                         requestedPage: 1, perPage: 10)
    }

    func ticket(_ uuid: String) async throws -> Record {
        let (data, _) = try await client.sendRaw(.get("\(Self.base)/tickets/\(uuid)"))
        guard let record = ResourceService.parseRecord(try ResourceService.decode(data), itemKey: nil, idKeys: ["uuid"]) else {
            throw ResourceService.problem(404, "This ticket wasn't found. It may have been deleted.")
        }
        return record
    }

    static func newTicketBody(title: String, priority: Int) -> [String: JSONValue] {
        ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "priority": .number(Double(priority)),
         "status": .string("open")]
    }

    func open(title: String, priority: Int) async throws {
        try await send(.post, "\(Self.base)/tickets", body: Self.newTicketBody(title: title, priority: priority))
    }

    /// `PUT /tickets/:id { status: "closed" }` (publishes helpdesk.ticket.closed).
    func close(_ uuid: String) async throws {
        try await send(.put, "\(Self.base)/tickets/\(uuid)", body: ["status": .string("closed")])
    }

    /// Priority 5 and the team is alerted (`helpdesk.ticket.escalated`).
    func escalate(_ uuid: String) async throws {
        try await send(.post, "\(Self.base)/tickets/\(uuid)/escalate", body: [:])
    }

    private func send(_ method: HTTPMethod, _ path: String, body: [String: JSONValue]) async throws {
        let endpoint = Endpoint(method, path).withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body)))
        _ = try await client.sendRaw(endpoint)
    }
}

/// Helpdesk → Support overview: tickets by status, opening a ticket, the open tickets that need
/// attention (escalate, close), and a way to every ticket. Everything `ui/overview.html` does.
struct HelpdeskOverviewView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stats: LoadState<[String: Int]> = .idle
    @State private var rows: LoadState<Page<Record>> = .idle
    @State private var newTitle = ""
    @State private var newPriority = 3
    @State private var opening = false
    @State private var notice: String?
    @State private var actionError: String?
    @State private var showing: Record?
    @State private var escalating: Record?

    private var api: HelpdeskAPI { HelpdeskAPI(client: services.client) }
    private var canCreate: Bool { session.permissions.allows(.create, HelpdeskScreens.module) }
    private var canUpdate: Bool { session.permissions.allows(.update, HelpdeskScreens.module) }

    var body: some View {
        List {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.textColor)
                    .accessibilityIdentifier("helpdesk.notice")
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.danger.textColor)
                    .accessibilityIdentifier("helpdesk.error")
            }
            Section("Tickets by status") { statsGrid }
            if canCreate { newTicketSection }
            needsAttentionSection
            Section {
                NavigationLink(value: PluginPages.route(code: "helpdesk", key: "tickets")) {
                    Label("All tickets", systemImage: "list.bullet.rectangle")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("helpdesk.allTickets")
            }
        }
        .navigationTitle("Support overview")
        .task { await refresh() }
        .wsRefreshable { await refresh() }
        .sheet(item: $showing) { ticket in
            NavigationStack {
                HelpdeskTicketSheet(ticket: ticket, canUpdate: canUpdate) { message in
                    notice = message
                    actionError = nil
                    Task { await refresh() }
                }
            }
        }
        .confirmationDialog("Escalate ticket", isPresented: Binding(get: { escalating != nil },
                                                                      set: { if !$0 { escalating = nil } }),
                            titleVisibility: .visible) {
            if let ticket = escalating {
                Button("Escalate", role: .destructive) { Task { await escalate(ticket) } }
            }
        } message: {
            Text("Raise “\(escalating?.string("title") ?? "this ticket")” to priority 5 and alert the team?")
        }
    }

    @ViewBuilder
    private var statsGrid: some View {
        switch stats {
        case .idle, .loading:
            SkeletonRow()
        case .failed(let error):
            InlineErrorRow(error: error) { Task { await refresh() } }
        case .loaded(let counts):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 140), spacing: 10)],
                      spacing: 10) {
                StatTile(title: "Open", value: "\(counts["open"] ?? 0)", systemImage: "tray.full")
                StatTile(title: "Pending", value: "\(counts["pending"] ?? 0)", systemImage: "hourglass")
                StatTile(title: "Closed", value: "\(counts["closed"] ?? 0)", systemImage: "checkmark.circle")
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("helpdesk.stats")
        }
    }

    private var newTicketSection: some View {
        Section {
            TextField("What's the problem?", text: $newTitle)
                .accessibilityIdentifier("helpdesk.new.title")
            Picker("Priority", selection: $newPriority) {
                ForEach(1...5, id: \.self) { value in
                    Text(Self.priorityLabel(value)).tag(value)
                }
            }
            .accessibilityIdentifier("helpdesk.new.priority")
            Button {
                Task { await openTicket() }
            } label: {
                if opening { ProgressView() } else { Label("Open ticket", systemImage: "plus.circle.fill") }
            }
            .disabled(opening || newTitle.trimmedOrNil == nil)
            .frame(minHeight: 44)
            .accessibilityIdentifier("helpdesk.new.open")
        } header: {
            Text("New ticket")
        }
    }

    @ViewBuilder
    private var needsAttentionSection: some View {
        Section {
            switch rows {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await refresh() } }
            case .loaded(let page) where page.items.isEmpty:
                Text("No open tickets. Nice work.").foregroundStyle(.secondaryText)
            case .loaded(let page):
                ForEach(page.items) { ticket in
                    Button { showing = ticket } label: { HelpdeskTicketRow(ticket: ticket) }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("helpdesk.row.\(ticket.id)")
                        .swipeActions(allowsFullSwipe: false) {
                            if canUpdate, ticket.int("priority") != 5 {
                                Button("Escalate") { escalating = ticket }.tint(.orange)
                            }
                        }
                        .contextMenu {
                            if canUpdate, ticket.int("priority") != 5 {
                                Button("Escalate", systemImage: "exclamationmark.triangle") { escalating = ticket }
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text("Needs attention")
                Spacer()
                if let total = rows.value?.total, total > 0 { Text("\(total) open") }
            }
        } footer: {
            if canUpdate, rows.value?.items.isEmpty == false {
                Text("Swipe a ticket to escalate it, or tap it to read it and close it.")
            }
        }
    }

    static func priorityLabel(_ value: Int) -> String {
        switch value {
        case 1: "1 · low"
        case 5: "5 · urgent"
        default: "\(value)"
        }
    }

    private func refresh() async {
        let api = self.api
        async let counts = api.stats()
        async let open = api.needsAttention()
        do { stats = .loaded(try await counts) } catch {
            let e = error.asAPIError
            if case .cancelled = e {} else if stats.value == nil { stats = .failed(e) }
        }
        do { rows = .loaded(try await open) } catch {
            let e = error.asAPIError
            if case .cancelled = e {} else if rows.value == nil { rows = .failed(e) }
        }
    }

    private func openTicket() async {
        opening = true
        defer { opening = false }
        do {
            try await api.open(title: newTitle, priority: newPriority)
            newTitle = ""
            newPriority = 3
            notice = "Ticket opened."
            actionError = nil
            await refresh()
        } catch {
            actionError = PluginProblem.message(error.asAPIError)
            notice = nil
        }
    }

    private func escalate(_ ticket: Record) async {
        do {
            try await api.escalate(ticket.id)
            notice = "Ticket escalated. The team has been alerted."
            actionError = nil
            await refresh()
        } catch {
            actionError = PluginProblem.message(error.asAPIError)
            notice = nil
        }
    }
}

/// A ticket in a list: title, priority, requester and due date.
struct HelpdeskTicketRow: View {
    let ticket: Record

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.string("title") ?? "Untitled").font(.wsHeadline).lineLimit(2)
                let details = [ticket.string("requester_email"),
                               ticket.string("due_on").flatMap { CalendarDay(string: $0) }.map { "Due \(Formatters.day($0.date()) ?? "")" }]
                    .compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 8)
            HelpdeskPriorityBadge(priority: ticket.int("priority"))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct HelpdeskPriorityBadge: View {
    let priority: Int?

    var body: some View {
        if let priority {
            let tone: Tone = priority >= 4 ? .danger : priority >= 3 ? .warning : .neutral
            StatusBadge(text: "P\(priority)", systemImage: priority >= 4 ? "exclamationmark.2" : "flag", tone: tone)
                .accessibilityLabel("Priority \(priority)")
        } else {
            Text("No priority").font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }
}

/// One ticket, read in full, with Close and Escalate.
private struct HelpdeskTicketSheet: View {
    let canUpdate: Bool
    let changed: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var ticket: Record
    @State private var working = false
    @State private var problem: String?
    @State private var confirmingEscalate = false

    init(ticket: Record, canUpdate: Bool, changed: @escaping (String) -> Void) {
        _ticket = State(initialValue: ticket)
        self.canUpdate = canUpdate
        self.changed = changed
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ticket.string("title") ?? "Untitled").font(.wsTitle3.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let status = ticket.string("status") {
                        FieldBadge(field: FieldSpec("status", "Status", .status(.standard)), value: status)
                    }
                }
                .padding(.vertical, 4)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
            }
            Section("Description") {
                Text(ticket.string("description") ?? "No description.")
                    .font(.wsBody).textSelection(.enabled)
            }
            Section {
                LabeledContent("Priority") { HelpdeskPriorityBadge(priority: ticket.int("priority")) }
                if let email = ticket.string("requester_email") { EmailLinkRow(email: email) }
                ForEach(Self.details.filter { FieldFormatter.text(ticket, $0) != nil }) { field in
                    FieldValueRow(field: field, record: ticket)
                }
            }
            if canUpdate {
                Section {
                    if ticket.string("status") != "closed" {
                        Button { Task { await close() } } label: {
                            Label("Close ticket", systemImage: "checkmark.circle")
                        }
                        .frame(minHeight: 44)
                        .disabled(working)
                        .accessibilityIdentifier("helpdesk.ticket.close")
                    }
                    if ticket.int("priority") != 5 {
                        Button(role: .destructive) { confirmingEscalate = true } label: {
                            Label("Escalate", systemImage: "exclamationmark.triangle")
                        }
                        .frame(minHeight: 44)
                        .disabled(working)
                        .accessibilityIdentifier("helpdesk.ticket.escalate")
                    }
                }
            }
        }
        .navigationTitle("Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await reload() }
        .confirmationDialog("Escalate ticket", isPresented: $confirmingEscalate, titleVisibility: .visible) {
            Button("Escalate", role: .destructive) { Task { await escalate() } }
        } message: {
            Text("Raise this ticket to priority 5 and alert the team?")
        }
    }

    private var api: HelpdeskAPI { HelpdeskAPI(client: services.client) }

    private static let details = [FieldSpec("due_on", "Due", .date), FieldSpec("resolved", "Resolved", .bool),
                                  FieldSpec("created_at", "Opened", .dateTime)]

    private func reload() async {
        if let fresh = try? await api.ticket(ticket.id) { ticket = fresh }
    }

    private func close() async {
        working = true
        defer { working = false }
        do {
            try await api.close(ticket.id)
            await reload()
            problem = nil
            changed("Ticket closed.")
        } catch {
            problem = PluginProblem.message(error.asAPIError)
        }
    }

    private func escalate() async {
        working = true
        defer { working = false }
        do {
            try await api.escalate(ticket.id)
            await reload()
            problem = nil
            changed("Ticket escalated. The team has been alerted.")
        } catch {
            problem = PluginProblem.message(error.asAPIError)
        }
    }
}
