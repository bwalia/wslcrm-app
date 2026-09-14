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

    static func money(_ amount: Decimal?, currency: String?) -> String? {
        guard let amount else { return nil }
        let code = (currency?.isEmpty == false ? currency! : "GBP").uppercased()
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
