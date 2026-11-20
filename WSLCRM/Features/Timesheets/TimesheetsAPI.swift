import Foundation

/// Timesheets — `/api/v2/timesheets`. Note this module pages with snake_case `per_page`, unlike
/// kanban next door, which uses `perPage`.
struct TimesheetsAPI: Sendable {
    let client: APIClient

    static let base = "/api/v2/timesheets"

    // MARK: Mine

    func mine(status: TimesheetStatus?, page: Int, perPage: Int = 25) async throws -> Page<Timesheet> {
        var query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "per_page", value: String(perPage))]
        if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        let envelope: Envelope.Nested<LossyArray<Timesheet>> =
            try await client.send(.get(Self.base, query: query))
        return Page(items: envelope.data.data.elements,
                    page: envelope.data.meta?.page ?? page,
                    perPage: envelope.data.meta?.perPage ?? perPage,
                    total: envelope.data.meta?.total ?? envelope.data.data.elements.count)
    }

    func timesheet(_ uuid: String) async throws -> Timesheet {
        let envelope: Envelope.Standard<Timesheet> = try await client.send(.get("\(Self.base)/\(uuid)"))
        return envelope.data
    }

    func summary(from: Date? = nil, to: Date? = nil) async throws -> TimesheetSummary {
        var query = QueryBuilder()
        // The server reads `start_date`/`end_date` (the dashboard's `date_from` is ignored).
        query.add("start_date", from.map { CalendarDay(date: $0).isoString })
        query.add("end_date", to.map { CalendarDay(date: $0).isoString })
        let envelope: Envelope.Standard<TimesheetSummaryPayload> =
            try await client.send(.get("\(Self.base)/summary", query: query.items))
        return envelope.data.summary
    }

    @discardableResult
    func log(_ body: CreateTimesheetBody) async throws -> Timesheet {
        let envelope: Envelope.Standard<Timesheet> = try await client.send(.post(Self.base, json: body))
        return envelope.data
    }

    func submit(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/\(uuid)/submit", json: EmptyBody()))
    }

    func reopen(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/\(uuid)/reopen", json: EmptyBody()))
    }

    func delete(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/\(uuid)"))
    }

    // MARK: Entries and invoicing

    func addEntry(timesheetUuid: String, _ body: TimesheetEntryBody) async throws {
        try await client.sendDiscardingBody(.post("\(Self.base)/\(timesheetUuid)/entries", json: body))
    }

    func updateEntry(_ uuid: String, _ body: TimesheetEntryBody) async throws {
        try await client.sendDiscardingBody(.put("\(Self.base)/entries/\(uuid)", json: body))
    }

    func deleteEntry(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/entries/\(uuid)"))
    }

    /// Makes a draft invoice from an approved timesheet's billable hours (`invoices.create`).
    func generateInvoice(timesheetUuid: String) async throws -> TimesheetInvoice {
        let envelope: Envelope.Standard<TimesheetInvoice> =
            try await client.send(.post("/api/v2/invoices/from-timesheet", json: ["timesheet_uuid": timesheetUuid]))
        return envelope.data
    }

    // MARK: Approving other people's

    func approvalQueue(page: Int, perPage: Int = 25) async throws -> Page<Timesheet> {
        let query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "per_page", value: String(perPage))]
        let envelope: Envelope.Nested<LossyArray<Timesheet>> =
            try await client.send(.get("\(Self.base)/approval-queue", query: query))
        return Page(items: envelope.data.data.elements,
                    page: envelope.data.meta?.page ?? page,
                    perPage: envelope.data.meta?.perPage ?? perPage,
                    total: envelope.data.meta?.total ?? envelope.data.data.elements.count)
    }

    func approve(_ uuid: String, comments: String?) async throws {
        try await client.sendDiscardingBody(
            .post("\(Self.base)/\(uuid)/approve", json: TimesheetDecisionBody(comments: comments)))
    }

    func reject(_ uuid: String, reason: String) async throws {
        try await client.sendDiscardingBody(
            .post("\(Self.base)/\(uuid)/reject", json: TimesheetDecisionBody(reason: reason)))
    }

    // MARK: Lookups

    func customers(matching search: String = "") async throws -> [TimesheetCustomerOption] {
        var query = QueryBuilder()
        query.add("q", search)
        let envelope: Envelope.Standard<LossyArray<TimesheetCustomerOption>> =
            try await client.send(.get("\(Self.base)/lookups/customers", query: query.items))
        return envelope.data.elements
    }

    func tasks(matching search: String = "") async throws -> [TimesheetTaskOption] {
        var query = QueryBuilder()
        query.add("q", search)
        let envelope: Envelope.Standard<LossyArray<TimesheetTaskOption>> =
            try await client.send(.get("\(Self.base)/lookups/tasks", query: query.items))
        return envelope.data.elements
    }
}
