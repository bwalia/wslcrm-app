import Foundation

// Simpro-aligned field service records served by OPSAPI's
// /api/v2/field-service/{assets,reports,simpro} routes (opsapi PR #612).

enum SimproSyncState: String, Sendable, Hashable {
    case synced, pending, conflict, error
    case localOnly = "local_only"

    var label: String {
        switch self {
        case .synced: "In Simpro"
        case .pending: "To push"
        case .conflict: "Conflict"
        case .error: "Sync error"
        case .localOnly: "Not in Simpro"
        }
    }

    var tone: Tone {
        switch self {
        case .synced: .success
        case .pending: .warning
        case .conflict, .error: .danger
        case .localOnly: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .pending: "icloud.and.arrow.up"
        case .conflict: "exclamationmark.icloud"
        case .error: "xmark.icloud"
        case .localOnly: "icloud.slash"
        }
    }
}

/// DBS survey scale: 1 excellent – 6 budget for replacement.
enum ConditionRating {
    static func label(_ rating: Int) -> String {
        switch rating {
        case 1: "Excellent"
        case 2: "Good"
        case 3: "Fair"
        case 4: "Poor"
        case 5: "Plan replacement"
        default: "Replace"
        }
    }

    static func tone(_ rating: Int) -> Tone {
        switch rating {
        case ...2: .success
        case 3: .info
        case 4: .warning
        default: .danger
        }
    }
}

struct AssetServiceLevel: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var name: String
    var kind: String
    var frequencyMonths: Int
    var lastServiceDate: String?
    var nextServiceDate: String?
    var contractName: String?

    enum CodingKeys: String, CodingKey {
        case uuid, name, kind, frequencyMonths, lastServiceDate, nextServiceDate, contractName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Service"
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "service"
        frequencyMonths = c.decodeFlexibleInt(forKey: .frequencyMonths) ?? 12
        lastServiceDate = c.decodeFlexibleString(forKey: .lastServiceDate)
        nextServiceDate = c.decodeFlexibleString(forKey: .nextServiceDate)
        contractName = try? c.decodeIfPresent(String.self, forKey: .contractName)
    }
}

struct AssetReading: Hashable, Sendable, Decodable {
    var key: String
    var label: String
    var value: JSONValue?
    var unit: String?

    var displayValue: String {
        let text = value?.stringValue ?? "—"
        return unit.map { "\(text) \($0)" } ?? text
    }
}

struct AssetFailurePoint: Hashable, Sendable, Decodable {
    var key: String?
    var label: String
}

struct AssetTest: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var testedAt: String?
    var result: String
    var conditionRating: Int?
    var technicianName: String?
    var readings: [AssetReading]
    var failurePoints: [AssetFailurePoint]
    var notes: String?
    var serviceLevel: String?

    enum CodingKeys: String, CodingKey {
        case uuid, testedAt, result, conditionRating, technicianName, readings, failurePoints, notes, serviceLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        testedAt = c.decodeFlexibleString(forKey: .testedAt)
        result = (try? c.decodeIfPresent(String.self, forKey: .result)) ?? "pass"
        conditionRating = c.decodeFlexibleInt(forKey: .conditionRating)
        technicianName = try? c.decodeIfPresent(String.self, forKey: .technicianName)
        readings = (try? c.decodeIfPresent(LossyArray<AssetReading>.self, forKey: .readings))?.elements ?? []
        failurePoints = (try? c.decodeIfPresent(LossyArray<AssetFailurePoint>.self, forKey: .failurePoints))?.elements ?? []
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        serviceLevel = try? c.decodeIfPresent(String.self, forKey: .serviceLevel)
    }
}

/// A customer asset: the individual machine at a site (Simpro "Customer Asset").
struct CustomerAsset: Identifiable, Hashable, Sendable, Decodable {
    let uuid: String
    var id: String { uuid }
    var assetTag: String?
    var name: String
    var assetType: String?
    var manufacturer: String?
    var model: String?
    var serialNumber: String?
    var locationDetail: String?
    var installedAt: String?
    var conditionRating: Int?
    var conditionNotes: String?
    var lastSurveyedAt: String?
    var refrigerantType: String?
    var refrigerantChargeKg: Decimal?
    var co2eTonnes: Decimal?
    var leakCheckMonths: Int?
    var nextLeakCheckAt: String?
    var siteName: String?
    var customerName: String?
    var contractName: String?
    var nextServiceDate: String?
    var simproId: String?
    var syncState: SimproSyncState
    var serviceLevels: [AssetServiceLevel]
    var recentTests: [AssetTest]

    enum CodingKeys: String, CodingKey {
        case uuid, assetTag, name, assetType, manufacturer, model, serialNumber, locationDetail, installedAt
        case conditionRating, conditionNotes, lastSurveyedAt, refrigerantType, refrigerantChargeKg, co2eTonnes
        case leakCheckMonths, nextLeakCheckAt, siteName, customerName, contractName, nextServiceDate
        case simproId, simproSyncState, serviceLevels, recentTests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        assetTag = try? c.decodeIfPresent(String.self, forKey: .assetTag)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Asset"
        assetType = try? c.decodeIfPresent(String.self, forKey: .assetType)
        manufacturer = try? c.decodeIfPresent(String.self, forKey: .manufacturer)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        serialNumber = c.decodeFlexibleString(forKey: .serialNumber)
        locationDetail = try? c.decodeIfPresent(String.self, forKey: .locationDetail)
        installedAt = c.decodeFlexibleString(forKey: .installedAt)
        conditionRating = c.decodeFlexibleInt(forKey: .conditionRating)
        conditionNotes = try? c.decodeIfPresent(String.self, forKey: .conditionNotes)
        lastSurveyedAt = c.decodeFlexibleString(forKey: .lastSurveyedAt)
        refrigerantType = try? c.decodeIfPresent(String.self, forKey: .refrigerantType)
        refrigerantChargeKg = c.decodeFlexibleDecimal(forKey: .refrigerantChargeKg)
        co2eTonnes = c.decodeFlexibleDecimal(forKey: .co2eTonnes)
        leakCheckMonths = c.decodeFlexibleInt(forKey: .leakCheckMonths)
        nextLeakCheckAt = c.decodeFlexibleString(forKey: .nextLeakCheckAt)
        siteName = try? c.decodeIfPresent(String.self, forKey: .siteName)
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        contractName = try? c.decodeIfPresent(String.self, forKey: .contractName)
        nextServiceDate = c.decodeFlexibleString(forKey: .nextServiceDate)
        simproId = c.decodeFlexibleString(forKey: .simproId)
        syncState = (try? c.decodeIfPresent(String.self, forKey: .simproSyncState))
            .flatMap(SimproSyncState.init(rawValue:)) ?? .localOnly
        serviceLevels = (try? c.decodeIfPresent(LossyArray<AssetServiceLevel>.self, forKey: .serviceLevels))?.elements ?? []
        recentTests = (try? c.decodeIfPresent(LossyArray<AssetTest>.self, forKey: .recentTests))?.elements ?? []
    }

    /// True when the soonest service level is due before today.
    func isServiceOverdue(today: Date = Date()) -> Bool {
        guard let due = SimproDates.day(nextServiceDate) else { return false }
        return due < Calendar.current.startOfDay(for: today)
    }
}

struct RecordSurveyBody: Encodable, Sendable {
    var conditionRating: Int
    var result: String
    var serviceLevelUuid: String?
    var refrigerantAddedKg: Decimal?
    var leakCheckResult: String?
    var notes: String?
    var readings: [Reading]

    struct Reading: Encodable, Sendable {
        var key: String
        var label: String
        var value: Int
    }
}

// MARK: - Reports

struct ReportCatalogueEntry: Identifiable, Hashable, Sendable, Decodable {
    var key: String
    var id: String { key }
    var title: String
    var group: String
    var filters: [String]
}

struct ReportColumn: Hashable, Sendable, Decodable {
    var key: String
    var label: String
    var type: String

    var isNumeric: Bool { ["number", "money", "hours"].contains(type) }
}

/// Any report from the pack: typed columns, rows keyed by column key, and a summary.
struct Report: Sendable, Decodable {
    var key: String
    var title: String
    var description: String
    var generatedAt: String?
    var columns: [ReportColumn]
    var rows: [[String: JSONValue]]
    var summary: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case key, title, description, generatedAt, columns, rows, summary
    }

    init(key: String, title: String, description: String, generatedAt: String?, columns: [ReportColumn],
         rows: [[String: JSONValue]], summary: [String: JSONValue]) {
        self.key = key
        self.title = title
        self.description = description
        self.generatedAt = generatedAt
        self.columns = columns
        self.rows = rows
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? key
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        generatedAt = c.decodeFlexibleString(forKey: .generatedAt)
        columns = (try? c.decodeIfPresent([ReportColumn].self, forKey: .columns)) ?? []
        // The server encodes an empty Lua table as {} rather than [] — treat either as no rows.
        rows = (try? c.decodeIfPresent([[String: JSONValue]].self, forKey: .rows)) ?? []
        summary = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .summary)) ?? [:]
    }

    /// Scalar summary values in a stable order, labelled for display ("failure_rate_pct" → "Failure rate %").
    var summaryItems: [(label: String, value: String)] {
        summary.keys.sorted().compactMap { key in
            guard let value = summary[key] else { return nil }
            switch value {
            case .object, .array, .null: return nil
            default: return (ReportFormat.summaryLabel(key), ReportFormat.cell(value, type: "number"))
            }
        }
    }
}

struct ReportQuery: Sendable, Equatable {
    var dateFrom: String?
    var dateTo: String?
    var months: Int?
    var weeks: Int?
    var expiringWithinDays: Int?
    var assetUuid: String?

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) { if let value { items.append(URLQueryItem(name: name, value: value)) } }
        add("date_from", dateFrom)
        add("date_to", dateTo)
        add("months", months.map(String.init))
        add("weeks", weeks.map(String.init))
        add("expiring_within_days", expiringWithinDays.map(String.init))
        add("asset_uuid", assetUuid)
        return items
    }
}

struct SimproStatus: Sendable, Decodable {
    struct Connection: Sendable, Decodable {
        var name: String?
        var baseUrl: String?
        var mode: String?
        var pushEnabled: Bool?
        var lastPullAt: String?
        var lastPushAt: String?
    }

    struct Counts: Sendable, Decodable {
        var synced: Int
        var pending: Int
        var errored: Int
        var localOnly: Int
        var total: Int

        enum CodingKeys: String, CodingKey { case synced, pending, errored, localOnly, total }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            synced = c.decodeFlexibleInt(forKey: .synced) ?? 0
            pending = c.decodeFlexibleInt(forKey: .pending) ?? 0
            errored = c.decodeFlexibleInt(forKey: .errored) ?? 0
            localOnly = c.decodeFlexibleInt(forKey: .localOnly) ?? 0
            total = c.decodeFlexibleInt(forKey: .total) ?? 0
        }
    }

    var connected: Bool
    var connection: Connection?
    var counts: [String: Counts]
}

// MARK: - Formatting

enum SimproDates {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Parses "2026-09-17", "2026-09-17 10:30:00" and ISO-8601 stamps.
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.count == 10 { return dayFormatter.date(from: raw) }
        let trimmed = String(raw.prefix(19))
        if let d = stampFormatter.date(from: trimmed.replacingOccurrences(of: "T", with: " ")) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func day(_ raw: String?) -> Date? {
        guard let raw, raw.count >= 10 else { return nil }
        return dayFormatter.date(from: String(raw.prefix(10)))
    }

    static func display(_ raw: String?, withTime: Bool = false) -> String {
        guard let date = parse(raw) else { return "—" }
        return withTime
            ? date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

enum ReportFormat {
    static func summaryLabel(_ key: String) -> String {
        var text = key.hasSuffix("_pct") ? String(key.dropLast(4)) + " %" : key
        text = text.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// One cell, formatted the same on screen and in the PDF.
    static func cell(_ value: JSONValue?, type: String) -> String {
        guard let value else { return "—" }
        switch value {
        case .null: return "—"
        case .bool(let b): return b ? "Yes" : "No"
        case .string(let s) where s.isEmpty: return "—"
        default: break
        }
        switch type {
        case "money":
            guard let n = number(value) else { return value.stringValue ?? "—" }
            return n.formatted(.currency(code: "GBP").locale(Locale(identifier: "en_GB")))
        case "number", "hours":
            guard let n = number(value) else { return value.stringValue ?? "—" }
            let text = n.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_GB")))
            return type == "hours" ? "\(text) h" : text
        case "date":
            return SimproDates.display(value.stringValue)
        case "datetime":
            return SimproDates.display(value.stringValue, withTime: true)
        default:
            return value.stringValue ?? "—"
        }
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }
}
