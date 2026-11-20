import SwiftUI

/// Calls the Property Deals API (`/api/v2/property-deals`) and reads the answers as module kit
/// `Record`s: the screens that show the server's rows as they come (buyers, compliance, the map,
/// reports, settings) need no hand-written model, and a new column never breaks decoding.
struct PDRaw: Sendable {
    let client: APIClient

    /// `/buyer-profiles` → `/api/v2/property-deals/buyer-profiles`; a full `/api/…` path is kept.
    static func path(_ path: String) -> String {
        path.hasPrefix("/api/") ? path : PropertyDealsAPI.base + path
    }

    func get(_ path: String, _ query: [String: String?] = [:]) async throws -> JSONValue {
        var builder = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { builder.add(key, value) }
        let (data, _) = try await client.sendRaw(.get(Self.path(path), query: builder.items))
        return try ResourceService.decode(data)
    }

    /// A write. `idempotent` sends an `Idempotency-Key` so a retry never creates twice.
    @discardableResult
    func send(_ method: HTTPMethod, _ path: String, _ body: [String: JSONValue] = [:],
              idempotent: Bool = false) async throws -> JSONValue? {
        var endpoint = Endpoint(method, Self.path(path))
        if method != .get && method != .delete {
            endpoint = endpoint.withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body)))
        }
        if idempotent { endpoint = endpoint.withIdempotencyKey(UUID().uuidString) }
        let (data, _) = try await client.sendRaw(endpoint)
        return data.isEmpty ? nil : try? ResourceService.decode(data)
    }

    /// Every row of a list answer (`{ data: [...] }`).
    func rows(_ path: String, _ query: [String: String?] = [:], idKeys: [String] = Record.defaultIDKeys) async throws -> [Record] {
        Self.rows(try await get(path, query), idKeys: idKeys)
    }

    /// One page of a list answer, with the server's paging (`meta.total`).
    func page(_ path: String, _ query: [String: String?] = [:], page: Int, perPage: Int = Paging.pageSize,
              idKeys: [String] = Record.defaultIDKeys) async throws -> Page<Record> {
        var query = query
        query["page"] = String(page)
        query["per_page"] = String(perPage)
        return ResourceService.parsePage(try await get(path, query), listKey: nil, idKeys: idKeys,
                                         requestedPage: page, perPage: perPage)
    }

    /// The object answer (`{ data: {...} }`).
    func record(_ path: String, _ query: [String: String?] = [:], idKeys: [String] = Record.defaultIDKeys) async throws -> Record {
        guard let record = Self.record(try await get(path, query), idKeys: idKeys) else {
            throw ResourceService.problem(404, "That wasn’t found. It may have been deleted.")
        }
        return record
    }

    static func rows(_ json: JSONValue, idKeys: [String] = Record.defaultIDKeys) -> [Record] {
        ResourceService.parsePage(json, listKey: nil, idKeys: idKeys, requestedPage: 1, perPage: 0).items
    }

    static func record(_ json: JSONValue?, idKeys: [String] = Record.defaultIDKeys) -> Record? {
        guard let json else { return nil }
        return ResourceService.parseRecord(json, itemKey: nil, idKeys: idKeys)
    }
}

extension Services {
    /// The Property Deals API read as module kit records.
    var pdRaw: PDRaw { PDRaw(client: client) }
}

extension JSONValue {
    /// `"5"` → 5, `""` → nil: a typed number for a request body.
    static func number(text: String) -> JSONValue? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned) else { return nil }
        return .number(value)
    }

}

extension Record {
    /// A number shown plainly ("12.5"), for figures without a unit.
    func number(_ path: String, places: Int = 1) -> String? {
        decimal(path).map { $0.formatted(.number.precision(.fractionLength(0...places))) }
    }

    /// Money in pounds (Property Deals stores whole currency units, not pence).
    func pounds(_ path: String, currency: String? = "GBP") -> String? {
        Formatters.money(decimal(path), currency: currency)
    }

    /// Strings in an array field, also when the server sent the array as JSON text.
    func strings(_ path: String) -> [String] {
        array(path).compactMap(\.stringValue)
    }
}

/// A plain-words "what just happened" line, shown at the top of a screen after an action.
struct PDNoticeBar: View {
    let notice: String?
    let error: APIError?

    var body: some View {
        if let error {
            InlineErrorRow(error: error).padding(.horizontal).background(.bar)
        } else if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.wsSubheadline)
                .foregroundStyle(Tone.success.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("pd.notice")
        }
    }
}

/// A label/value row for a figure that may be missing ("—").
struct PDFigureRow: View {
    let label: String
    let value: String?
    var tone: Tone?

    var body: some View {
        LabeledContent(label) {
            Text(value ?? "—")
                .font(.wsBody.monospacedDigit())
                .foregroundStyle(tone?.textColor ?? .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum PDWords {
    /// `seller_solicitor` → "Seller solicitor".
    static func label(_ raw: String?) -> String { Formatters.humanize(raw) }
}
