import Foundation

/// `/api/v2/invoices` (+ field-service billing). Envelope: `Envelope.Invoices`.
struct InvoicesAPI: Sendable {
    let client: APIClient
    static let base = "/api/v2/invoices"

    /// `issuedFrom`/`issuedTo` filter on the issue date.
    func invoices(search: String, status: InvoiceStatus?, issuedFrom: CalendarDay? = nil, issuedTo: CalendarDay? = nil,
                  page: Int, perPage: Int = 25) async throws -> Page<Invoice> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("perPage", perPage)
        q.add("search", search.trimmingCharacters(in: .whitespaces))
        // "overdue" isn't stored: the server works it out (sent, past due, still owing).
        if let status, status != .unknown { q.add("status", status.rawValue) }
        q.add("from_date", issuedFrom?.isoString)
        q.add("to_date", issuedTo?.isoString)
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

    /// Create returns the header only; the full invoice is fetched afterwards. `idempotencyKey`: one per form
    /// (`MoneyRetryKey`), so a retry after a lost reply can be answered with the first invoice.
    func create(_ body: InvoiceHeaderBody, idempotencyKey: String = UUID().uuidString) async throws -> Invoice {
        let created: Invoice = try await data(Endpoint.post(Self.base, json: body).withIdempotencyKey(idempotencyKey))
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

    /// Emails the invoice PDF to the customer (#611). The PDF is rendered on device; emailing
    /// also marks a draft as sent. Needs `invoices.update`.
    @discardableResult
    func email(_ uuid: String, pdf: Data, filename: String, to: String? = nil,
               message: String? = nil) async throws -> EmailResult {
        let body = EmailDocumentBody(pdfBase64: pdf.base64EncodedString(), filename: filename,
                                     to: to?.trimmedOrNil, message: message?.trimmedOrNil)
        return try await data(.post("/api/v2/invoices/\(uuid)/email", json: body))
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

    // MARK: Getting paid, billing hours, VAT

    /// The workspace's ways to be paid (`/api/v2/namespace/payment-methods`, readable with invoices.read).
    func paymentMethods() async throws -> [PaymentMethodInfo] {
        let envelope: Envelope.Standard<LossyArray<PaymentMethodInfo>> = try await client.send(.get("/api/v2/namespace/payment-methods"))
        return envelope.data.elements
    }

    /// Customers to bill hours to (the timesheets lookup the web uses).
    func billableCustomers(search: String) async throws -> [BillableCustomer] {
        var q = QueryBuilder()
        q.add("q", search.trimmingCharacters(in: .whitespaces))
        let envelope: Envelope.Standard<LossyArray<BillableCustomer>> =
            try await client.send(.get("/api/v2/timesheets/lookups/customers", query: q.items))
        return envelope.data.elements
    }

    func customerBillable(customerUuid: String, from: CalendarDay?, to: CalendarDay?) async throws -> CustomerBillablePreview {
        var q = QueryBuilder()
        q.add("customer_uuid", customerUuid)
        q.add("from", from?.isoString)
        q.add("to", to?.isoString)
        return try await data(.get("\(Self.base)/customer-billable", query: q.items))
    }

    /// One invoice for every approved, un-invoiced hour of the customer in the period.
    func createFromCustomer(customerUuid: String, from: CalendarDay?, to: CalendarDay?) async throws -> Invoice {
        struct Body: Encodable, Sendable { let customerUuid: String; let periodStart: String?; let periodEnd: String? }
        let created: Invoice = try await data(.post("\(Self.base)/from-customer",
                                                    json: Body(customerUuid: customerUuid, periodStart: from?.isoString,
                                                               periodEnd: to?.isoString)))
        return created
    }

    /// nil when the deployment has no VAT feature (the route answers 404).
    func vatCheck(_ uuid: String) async throws -> VatInvoiceCheck? {
        do {
            let envelope: Envelope.Standard<VatInvoiceCheck> = try await client.send(.get("/api/v2/vat/invoices/\(uuid)/check"))
            return envelope.data
        } catch let error as APIError {
            if case .notFound = error { return nil }
            throw error
        }
    }

    func einvoiceCheck(_ uuid: String) async throws -> EinvoiceCheck {
        struct Result: Decodable, Sendable { let check: EinvoiceCheck }
        let envelope: Envelope.Standard<Result> = try await client.send(
            .get("/api/v2/vat/invoices/\(uuid)/einvoice", query: [URLQueryItem(name: "check", value: "1")]))
        return envelope.data.check
    }

    /// The Peppol UBL e-invoice (XML).
    func einvoiceXML(_ uuid: String) async throws -> Data {
        let (data, _) = try await client.sendRaw(.get("/api/v2/vat/invoices/\(uuid)/einvoice"))
        return data
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
