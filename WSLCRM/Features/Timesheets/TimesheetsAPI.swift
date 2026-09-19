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
        let envelope: Envelope.Standard<LossyArray<Timesheet>> =
            try await client.send(.get(Self.base, query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func timesheet(_ uuid: String) async throws -> Timesheet {
        let envelope: Envelope.Standard<Timesheet> = try await client.send(.get("\(Self.base)/\(uuid)"))
        return envelope.data
    }

    func summary(from: Date? = nil, to: Date? = nil) async throws -> TimesheetSummary {
        var query = QueryBuilder()
        query.add("date_from", from)
        query.add("date_to", to)
        let envelope: Envelope.Standard<TimesheetSummary> =
            try await client.send(.get("\(Self.base)/summary", query: query.items))
        return envelope.data
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

    // MARK: Approving other people's

    func approvalQueue(page: Int, perPage: Int = 25) async throws -> Page<Timesheet> {
        let query = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "per_page", value: String(perPage))]
        let envelope: Envelope.Standard<LossyArray<Timesheet>> =
            try await client.send(.get("\(Self.base)/approval-queue", query: query))
        return Page(items: envelope.data.elements,
                    page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage,
                    total: envelope.meta?.total ?? envelope.data.elements.count)
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
