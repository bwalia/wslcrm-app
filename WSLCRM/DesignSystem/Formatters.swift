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

    /// The app's one currency (Settings › Currency), pounds sterling unless the person changes it. OpsAPI
    /// has no workspace currency, so this is used wherever an amount carries none of its own: a new record,
    /// a roll-up, a form's label. An amount that comes with its own currency (an invoice in EUR) shows that.
    static var defaultCurrency: String {
        UserDefaults.standard.string(forKey: currencyKey)?.trimmedOrNil?.uppercased() ?? standardCurrency
    }
    static let currencyKey = "app.currency"
    static let standardCurrency = "GBP"

    /// `defaultCurrency`'s symbol for labels such as "Price (£)".
    static var currencySymbol: String {
        let format = NumberFormatter()
        format.numberStyle = .currency
        format.currencyCode = defaultCurrency
        return format.currencySymbol
    }

    /// The common currencies plus whatever this record already uses, so a tenant billing in,
    /// say, AED never has to change it to something from a fixed list.
    static func currencyChoices(including current: String?) -> [String] {
        var codes = ["GBP", "EUR", "USD"]
        for code in [defaultCurrency, current?.uppercased()].compactMap({ $0 }) where !codes.contains(code) {
            codes.insert(code, at: 0)
        }
        return codes
    }

    static func money(_ amount: Decimal?, currency: String?) -> String? {
        guard let amount else { return nil }
        let code = (currency?.isEmpty == false ? currency! : Self.defaultCurrency).uppercased()
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
