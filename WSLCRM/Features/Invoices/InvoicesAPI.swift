import Foundation

/// `/api/v2/invoices` (+ field-service billing). Envelope: `Envelope.Invoices`.
struct InvoicesAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/invoices"

    func invoices(search: String, status: InvoiceStatus?, page: Int, perPage: Int = 25) async throws -> Page<Invoice> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("perPage", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        if let status, [.draft, .sent, .paid, .void].contains(status) { q.add("status", status.rawValue) }
        let envelope: Envelope.Invoices<LossyArray<Invoice>> = try await client.send(.get(Self.base, query: q.items))
        return Page(items: envelope.data.elements, page: envelope.meta?.page ?? page,
                    perPage: envelope.meta?.perPage ?? perPage, total: envelope.meta?.total ?? envelope.data.elements.count)
    }

    func invoice(_ uuid: String) async throws -> Invoice {
        try await data(.get("\(Self.base)/\(uuid)"))
    }

    func stats() async throws -> InvoiceStats {
        try await data(.get("\(Self.base)/dashboard/stats"))
    }

    func taxRates() async throws -> [TaxRate] {
        let rates: LossyArray<TaxRate> = try await data(.get("\(Self.base)/tax-rates"))
        return rates.elements
    }

    /// Create returns the header only; the full invoice is fetched afterwards.
    func create(_ body: InvoiceHeaderBody) async throws -> Invoice {
        let created: Invoice = try await data(.post(Self.base, json: body))
        return try await invoice(created.id)
    }

    func updateHeader(_ uuid: String, _ body: InvoiceHeaderBody) async throws -> Invoice {
        var header = body
        header.lineItems = nil
        let _: Invoice = try await data(.put("\(Self.base)/\(uuid)", json: header))
        return try await invoice(uuid)
    }

    func send(_ uuid: String) async throws -> Invoice {
        let _: Invoice = try await data(Endpoint(.post, "\(Self.base)/\(uuid)/send"))
        return try await invoice(uuid)
    }

    func void(_ uuid: String) async throws -> Invoice {
        let _: Invoice = try await data(Endpoint(.post, "\(Self.base)/\(uuid)/void"))
        return try await invoice(uuid)
    }

    func delete(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/\(uuid)"))
    }

    // Line items and payments return only the changed row; the server recalculates totals, so re-fetch.

    func addItem(_ invoiceUuid: String, _ body: LineItemBody) async throws -> Invoice {
        try await client.sendDiscardingBody(.post("\(Self.base)/\(invoiceUuid)/items", json: body))
        return try await invoice(invoiceUuid)
    }

    func updateItem(_ invoiceUuid: String, itemId: String, _ body: LineItemBody) async throws -> Invoice {
        try await client.sendDiscardingBody(.put("\(Self.base)/items/\(itemId)", json: body))
        return try await invoice(invoiceUuid)
    }

    func deleteItem(_ invoiceUuid: String, itemId: String) async throws -> Invoice {
        try await client.sendDiscardingBody(.delete("\(Self.base)/items/\(itemId)"))
        return try await invoice(invoiceUuid)
    }

    func recordPayment(_ invoiceUuid: String, _ body: PaymentBody) async throws -> Invoice {
        try await client.sendDiscardingBody(.post("\(Self.base)/\(invoiceUuid)/payments", json: body))
        return try await invoice(invoiceUuid)
    }

    func deletePayment(_ invoiceUuid: String, paymentId: String) async throws -> Invoice {
        try await client.sendDiscardingBody(.delete("\(Self.base)/payments/\(paymentId)"))
        return try await invoice(invoiceUuid)
    }

    // MARK: Field-service billing

    func jobInvoicePreview(jobUuid: String) async throws -> JobInvoicePreview {
        let envelope: Envelope.Standard<JobInvoicePreview> =
            try await client.send(.get("\(FieldServiceAPI.base)/jobs/\(jobUuid)/invoice-preview"))
        return envelope.data
    }

    func createJobInvoice(jobUuid: String, dueDate: CalendarDay?) async throws -> JobInvoiceResult {
        struct Body: Encodable, Sendable { let dueDate: CalendarDay? }
        let envelope: Envelope.Standard<JobInvoiceResult> =
            try await client.send(.post("\(FieldServiceAPI.base)/jobs/\(jobUuid)/invoice", json: Body(dueDate: dueDate)))
        return envelope.data
    }

    private func data<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let envelope: Envelope.Invoices<T> = try await client.send(endpoint)
        return envelope.data
    }
}
