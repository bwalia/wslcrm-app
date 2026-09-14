import Foundation

/// Date handling for OpsAPI.
///
/// The API emits naive UTC timestamps such as `"2026-09-12 08:00:00"` or
/// `"2026-09-12 08:00:00.861944"` with no zone designator. We normalise them to
/// ISO-8601 (`T` separator, fractional seconds truncated to milliseconds, `Z`
/// appended) before parsing. Values that already carry `Z` or an offset are
/// accepted as-is. When sending, we always emit ISO-8601 UTC.
enum APIDate {
    private static let parser = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    private static let outputStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt)

    static func parse(_ string: String) -> Date? {
        guard let normalized = normalize(string) else { return nil }
        return try? parser.parse(normalized)
    }

    /// ISO-8601 UTC without fractional seconds, e.g. `2026-09-12T08:00:00Z`.
    static func string(from date: Date) -> String {
        date.formatted(outputStyle)
    }

    /// Converts the API's timestamp variants into `yyyy-MM-ddTHH:mm:ss.SSS±zone`.
    /// Date-only values (`yyyy-MM-dd`) are treated as midnight UTC.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespaces)
        guard s.count >= 10 else { return nil }

        if s.count == 10 {
            s += "T00:00:00"
        }

        let chars = Array(s)
        guard chars.count >= 19 else { return nil }
        var datePart = String(chars[0..<10])
        var timePart = String(chars[11...])
        guard chars[10] == " " || chars[10] == "T" else { return nil }
        datePart = datePart.replacingOccurrences(of: "/", with: "-")

        // Split off the zone designator, if any.
        var zone = "Z"
        if timePart.hasSuffix("Z") || timePart.hasSuffix("z") {
            timePart.removeLast()
        } else if let signIndex = timePart.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            zone = String(timePart[signIndex...])
            timePart = String(timePart[..<signIndex])
            if zone.count == 3 { zone += ":00" }                         // +01 → +01:00
            else if zone.count == 5, !zone.contains(":") {                // +0100 → +01:00
                zone.insert(":", at: zone.index(zone.startIndex, offsetBy: 3))
            }
        }

        // Normalise fractional seconds to exactly three digits.
        var seconds = timePart
        var fraction = "000"
        if let dot = timePart.firstIndex(of: ".") {
            seconds = String(timePart[..<dot])
            let digits = timePart[timePart.index(after: dot)...].prefix(3)
            guard digits.allSatisfy(\.isNumber) else { return nil }
            fraction = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
        }
        guard seconds.count == 8 else { return nil }

        return "\(datePart)T\(seconds).\(fraction)\(zone)"
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let opsAPI: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            if let date = APIDate.parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised date string '\(string)'")
        }
        // Some endpoints emit epoch seconds.
        let seconds = try container.decode(Double.self)
        return Date(timeIntervalSince1970: seconds)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static let opsAPI: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(APIDate.string(from: date))
    }
}

/// A calendar day with no time or zone (e.g. an invoice due date `"2026-09-30"`).
/// Kept as a string so it never shifts across time zones.
struct CalendarDay: Codable, Hashable, Sendable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(string: String) {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CalendarDay(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day '\(raw)'")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }

    var isoString: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Local-midnight `Date` for display and pickers.
    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
