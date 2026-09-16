import Foundation

enum Formatters {
    static func dateTime(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(_ date: Date?) -> String? {
        date?.formatted(date: .omitted, time: .shortened)
    }

    static func day(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    /// Used when a total carries no currency of its own (dashboard roll-ups). The server sends
    /// no workspace currency, so the device's own is a better guess than assuming sterling.
    static let fallbackCurrency = Locale.current.currency?.identifier ?? "GBP"

    /// The common currencies plus whatever this record already uses, so a tenant billing in,
    /// say, AED never has to change it to something from a fixed list.
    static func currencyChoices(including current: String?) -> [String] {
        var codes = ["GBP", "EUR", "USD"]
        for code in [fallbackCurrency, current?.uppercased()].compactMap({ $0 }) where !codes.contains(code) {
            codes.insert(code, at: 0)
        }
        return codes
    }

    static func money(_ amount: Decimal?, currency: String?) -> String? {
        guard let amount else { return nil }
        let code = (currency?.isEmpty == false ? currency! : Self.fallbackCurrency).uppercased()
        return amount.formatted(.currency(code: code))
    }

    static func hours(_ hours: Decimal?) -> String? {
        guard let hours else { return nil }
        return "\(hours.formatted(.number.precision(.fractionLength(0...2)))) h"
    }

    /// `in_progress` → `In progress`
    static func humanize(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let spaced = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}


extension String {
    /// Trimmed, or nil when there is nothing left — the API treats "" as "clear this field".
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
