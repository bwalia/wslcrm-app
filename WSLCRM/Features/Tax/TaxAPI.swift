import Foundation
import SwiftUI

/// Calls for the tax, VAT and bookkeeping screens.
///
/// OpsAPI's tax routes are not uniform, so each call says how it talks to the server:
/// - most `/api/v2/tax/*` and every `/api/v2/hmrc/*` route read only form fields (Lapis `self.params`),
///   so writes are form-encoded (`form:`), exactly as the web dashboard sends them;
/// - VAT, bookkeeping, filing requests and the tax assistant read JSON bodies (`json:`);
/// - every response is read as JSON (`JSONValue` / `Record`), so lua-cjson's `{}` for an empty list,
///   absent NULL columns and numbers sent as strings never break a screen.
///
/// HMRC-bound calls carry the device's fraud-prevention signals (`HMRCFraudSignals`), which the
/// server forwards to HMRC as its mandatory `Gov-Client-*` headers.
struct TaxAPI: Sendable {
    let client: APIClient
    /// `X-Gov-Client-*` headers captured on the main actor when the screen made this facade.
    var fraudHeaders: [String: String] = [:]

    /// Slow HMRC round trips (cumulative submission + calculation polling) and the assistant's model turns.
    static let hmrcTimeout: TimeInterval = 180
    static let assistantTimeout: TimeInterval = 300
    static let uploadTimeout: TimeInterval = 90

    // MARK: - Reading

    func get(_ path: String, query: [String: String?] = [:], namespace: Bool = true,
             timeout: TimeInterval = 30) async throws -> JSONValue {
        var endpoint = Endpoint.get(path, query: Self.queryItems(query))
        endpoint.requiresNamespace = namespace
        endpoint.timeout = timeout
        return try await send(endpoint)
    }

    /// The payload of `{data: …}` (or the whole body when there is no `data`) as one record.
    func record(_ path: String, query: [String: String?] = [:], namespace: Bool = true) async throws -> Record {
        Record(try await get(path, query: query, namespace: namespace).payload.objectFields, idKeys: Record.defaultIDKeys)
    }

    /// The rows of a list response, whatever its envelope (`data`, `items`, a bare array, `{}`).
    func records(_ path: String, query: [String: String?] = [:], namespace: Bool = true,
                 listKey: String? = nil) async throws -> [Record] {
        let json = try await get(path, query: query, namespace: namespace)
        return ResourceService.parsePage(json, listKey: listKey, idKeys: Record.defaultIDKeys,
                                         requestedPage: 1, perPage: 0).items
    }

    // MARK: - Writing

    /// A form-encoded write (`application/x-www-form-urlencoded`), as the tax and HMRC routes read.
    @discardableResult
    func form(_ method: HTTPMethod, _ path: String, _ fields: [(String, String)] = [],
              query: [String: String?] = [:], namespace: Bool = true,
              timeout: TimeInterval = 30) async throws -> JSONValue {
        var endpoint = Endpoint(method, path, query: Self.queryItems(query)).withForm(fields)
        endpoint.requiresNamespace = namespace
        endpoint.timeout = timeout
        return try await send(endpoint)
    }

    /// A JSON write, for the routes that decode the body themselves.
    @discardableResult
    func json(_ method: HTTPMethod, _ path: String, _ body: [String: JSONValue] = [:],
              query: [String: String?] = [:], namespace: Bool = true,
              timeout: TimeInterval = 30) async throws -> JSONValue {
        var endpoint = Endpoint(method, path, query: Self.queryItems(query))
            .withRawBody(try JSONEncoder.sorted.encode(JSONValue.object(body)))
        endpoint.requiresNamespace = namespace
        endpoint.timeout = timeout
        return try await send(endpoint)
    }

    @discardableResult
    func delete(_ path: String, query: [String: String?] = [:], namespace: Bool = true) async throws -> JSONValue {
        var endpoint = Endpoint(.delete, path, query: Self.queryItems(query))
        endpoint.requiresNamespace = namespace
        return try await send(endpoint)
    }

    /// One file as `multipart/form-data` (statement uploads, bank details detection).
    @discardableResult
    func upload(_ path: String, file: Endpoint.FilePart, fields: [(String, String)] = [],
                namespace: Bool = true) async throws -> JSONValue {
        var endpoint = Endpoint(.post, path).withMultipart(fields: fields, file: file)
        endpoint.requiresNamespace = namespace
        endpoint.timeout = Self.uploadTimeout
        return try await send(endpoint)
    }

    /// A file the server builds (the tax sheet, a CSV export), saved where `ShareLink` can hand it on.
    func download(_ path: String, query: [String: String?] = [:], fallbackName: String,
                  namespace: Bool = true) async throws -> URL {
        var endpoint = Endpoint.get(path, query: Self.queryItems(query))
        endpoint.requiresNamespace = namespace
        endpoint.timeout = 120
        endpoint.headers = fraudHeaders
        endpoint.headers["Accept"] = "*/*"
        let (data, response) = try await client.sendRaw(endpoint)
        let name = Self.filename(from: response.value(forHTTPHeaderField: "Content-Disposition")) ?? fallbackName
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tax-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A file at a full URL (a short-lived link to an uploaded statement), saved for Quick Look.
    func downloadFile(at url: URL, name: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResourceService.problem(http.statusCode == 404 ? 404 : 422, "The original file couldn’t be opened.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tax-originals", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(name.isEmpty ? "statement" : name.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.removeItem(at: local)
        try data.write(to: local, options: .atomic)
        return local
    }

    // MARK: - Internals

    private func send(_ endpoint: Endpoint) async throws -> JSONValue {
        var endpoint = endpoint
        if Self.isHMRCBound(endpoint.path) {
            for (name, value) in fraudHeaders { endpoint.headers[name] = value }
            // OpsAPI's HMRC routes answer 401 "No HMRC token found" when HMRC isn't connected:
            // that is not the person's sign-in ending.
            if endpoint.path.hasPrefix("/api/v2/hmrc") || endpoint.path.hasPrefix("/auth/hmrc") {
                endpoint.unauthorizedEndsSession = false
            }
        }
        let (data, _) = try await client.sendRaw(endpoint)
        guard !data.isEmpty else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    /// The web forwards its device signals on every call that may reach HMRC; so does the app.
    static func isHMRCBound(_ path: String) -> Bool {
        path.contains("hmrc") || path.hasPrefix("/api/v2/tax/agent/") || path.hasPrefix("/api/v2/vat")
    }

    static func queryItems(_ query: [String: String?]) -> [URLQueryItem] {
        query.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }.sorted { $0.name < $1.name }
    }

    static func filename(from disposition: String?) -> String? {
        guard let disposition, let range = disposition.range(of: "filename=") else { return nil }
        var name = String(disposition[range.upperBound...])
        if let end = name.firstIndex(of: ";") { name = String(name[..<end]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return name.isEmpty ? nil : name
    }
}

extension JSONValue {
    var objectFields: [String: JSONValue] {
        if case .object(let o) = self { return o }
        return [:]
    }

    var record: Record { Record(objectFields) }

    /// A list, treating lua-cjson's `{}` (an empty list sent as an object) and absence as empty.
    var list: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var recordList: [Record] {
        list.compactMap { if case .object(let o) = $0 { Record(o) } else { nil } }
    }
}

extension Record {
    /// Money that always has a value to show (`£0.00` instead of a dash where the web shows zero).
    func money(_ path: String, currency: String = "GBP") -> String {
        Formatters.money(decimal(path) ?? 0, currency: currency) ?? "£0.00"
    }

    func moneyOrDash(_ path: String, currency: String = "GBP") -> String {
        guard let value = decimal(path) else { return "—" }
        return Formatters.money(value, currency: currency) ?? "—"
    }

    /// A plain day ("2026-04-06") or a timestamp, as "6 Apr 2026".
    func day(_ path: String) -> String? {
        guard let raw = string(path) else { return nil }
        if raw.count == 10, let day = CalendarDay(string: raw) { return Formatters.day(day.date()) }
        return Formatters.day(APIDate.parse(raw)) ?? raw
    }
}

extension APIError {
    /// The server's machine-readable `code` (`NINO_REQUIRED`, `FIGURES_CHANGED`…), if it sent one.
    var serverCode: String? {
        if let code = serverError?.code { return code }
        guard let raw = serverError?.rawBody, let data = raw.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["code"]?.stringValue
    }

    /// The whole error body as JSON (for errors that carry data, such as `offending_transactions`).
    var body: JSONValue? {
        guard let raw = serverError?.rawBody, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

}

/// Money in pounds, as the tax screens show it.
enum TaxMoney {
    static func text(_ value: Decimal?, currency: String = "GBP") -> String {
        Formatters.money(value ?? 0, currency: currency) ?? "£0.00"
    }

    static func signed(_ value: Decimal?, currency: String = "GBP") -> String {
        let v = value ?? 0
        let body = Formatters.money(abs(v), currency: currency) ?? "£0.00"
        return v > 0 ? "+\(body)" : v < 0 ? "−\(body)" : body
    }
}

/// UK tax years ("2025-26": 6 April 2025 to 5 April 2026).
enum TaxYear {
    /// The tax year a date falls in.
    static func of(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 2026
        let start = (c.month ?? 1) > 4 || ((c.month ?? 1) == 4 && (c.day ?? 1) >= 6) ? year : year - 1
        return label(start: start)
    }

    static func label(start: Int) -> String {
        "\(start)-\(String(format: "%02d", (start + 1) % 100))"
    }

    static func start(of taxYear: String) -> Int? { Int(taxYear.prefix(4)) }

    /// The last year that has ended: the one people file now.
    static func filing(_ date: Date = Date()) -> String {
        label(start: (start(of: of(date)) ?? 2026) - 1)
    }

    /// The year in progress, then the four before it (the web's year pickers).
    static func recent(count: Int = 5, now: Date = Date()) -> [String] {
        let current = start(of: of(now)) ?? 2026
        return (0..<count).map { label(start: current - $0) }
    }

    /// "6 Apr 2025 – 5 Apr 2026".
    static func span(_ taxYear: String) -> String {
        guard let y = start(of: taxYear) else { return taxYear }
        return "6 Apr \(y) – 5 Apr \(y + 1)"
    }

    static func bounds(_ taxYear: String) -> (from: String, to: String)? {
        guard let y = start(of: taxYear) else { return nil }
        return ("\(y)-04-06", "\(y + 1)-04-05")
    }

    static func isValid(_ taxYear: String) -> Bool {
        taxYear.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// "Tax year 2025/26".
    static func title(_ taxYear: String) -> String { "Tax year \(taxYear.replacingOccurrences(of: "-", with: "/"))" }
}

extension View {
    /// The tax facade for this screen, with the device's HMRC fraud-prevention signals.
    @MainActor
    func makeTaxAPI(_ services: Services, user: CurrentUser?) -> TaxAPI {
        TaxAPI(client: services.client, fraudHeaders: HMRCFraudSignals.headers(userID: user?.uuid))
    }
}
