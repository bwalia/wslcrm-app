import SwiftUI

// Routes, status presentation and the pure Today logic for Property Deals.

struct PDTaskRoute: Hashable { let uuid: String }
struct PDDealRoute: Hashable { let uuid: String }
struct PDDealsRoute: Hashable { let filter: PropertyDealsAPI.DealFilter }
struct PDApprovalsRoute: Hashable {}
struct PDApprovalRoute: Hashable { let uuid: String }

// MARK: - Health

extension PDHealth {
    var label: String {
        switch self {
        case .green: "On track"
        case .amber: "At risk"
        case .red: "Late"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .amber: "exclamationmark.triangle.fill"
        case .red: "exclamationmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .green: .success
        case .amber: .warning
        case .red: .danger
        case .unknown: .neutral
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

// MARK: - Task status and urgency

extension PDTaskStatus {
    var label: String {
        switch self {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .waitingThirdParty: "Waiting on a third party"
        case .agentRunning: "AI working on it"
        case .awaitingApproval: "Waiting for approval"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "play.circle.fill"
        case .waitingThirdParty: "hourglass"
        case .agentRunning: "sparkles"
        case .awaitingApproval: "person.crop.circle.badge.questionmark"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .todo, .unknown: .neutral
        case .inProgress, .agentRunning: .progress
        case .waitingThirdParty, .awaitingApproval: .info
        case .done: .success
        case .cancelled: .danger
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

/// How pressing a task is, from the server's urgency score (docs/property-deals/urgency.md).
/// Never shown as colour alone: every level has a word and a symbol.
enum PDUrgency: Equatable, Sendable {
    case overdue, high, medium, low

    init(score: Double?, overdue: Bool) {
        if overdue { self = .overdue; return }
        switch score ?? 0 {
        case 60...: self = .high
        case 30..<60: self = .medium
        default: self = .low
        }
    }

    var label: String {
        switch self {
        case .overdue: "Overdue"
        case .high: "Urgent"
        case .medium: "Soon"
        case .low: "Normal"
        }
    }

    var systemImage: String {
        switch self {
        case .overdue: "alarm.fill"
        case .high: "flame.fill"
        case .medium: "clock.fill"
        case .low: "circle.dotted"
        }
    }

    var tone: Tone {
        switch self {
        case .overdue: .danger
        case .high: .warning
        case .medium: .info
        case .low: .neutral
        }
    }
}

extension PDTaskSummary {
    var urgency: PDUrgency { PDUrgency(score: urgencyScore, overdue: overdue ?? false) }

    /// The short "why" under the title: the factors that add most to the score.
    var shortWhy: String? {
        let lines = urgencyWhy.sorted { ($0.points ?? 0) > ($1.points ?? 0) }.prefix(2).map(\.why)
        return lines.isEmpty ? nil : lines.joined(separator: " · ")
    }
}

extension PDTask {
    var urgency: PDUrgency { PDUrgency(score: urgencyScore, overdue: isOverdue) }
}

// MARK: - Labels

enum PDLabels {
    private static let acronyms = ["epc": "EPC", "id": "ID", "aml": "AML", "pep": "PEP", "ai": "AI"]

    /// A document category or other key as words: `proof_of_funds` → "Proof of funds", `epc` → "EPC".
    static func key(_ raw: String?) -> String {
        guard let raw else { return "—" }
        if let acronym = acronyms[raw.lowercased()] { return acronym }
        return Formatters.humanize(raw)
    }
}

// MARK: - Plain dates

enum PDDates {
    private static let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)

    /// `2026-10-22` → "22 Oct 2026". Plain dates are workspace-local calendar days, so they're
    /// parsed and printed in UTC to keep the day from shifting with the device's zone.
    static func day(_ plain: String?) -> String? {
        guard let plain, let date = APIDate.parse(plain) else { return plain }
        return date.formatted(style)
    }
}

// MARK: - Today layout

/// Splits Today's tasks (already sorted most urgent first by the server) into the screen's
/// sections. Pure, so it's tested without a server.
struct PDTodayLayout: Equatable {
    var overdue: [PDTaskSummary] = []
    var dueToday: [PDTaskSummary] = []
    var waiting: [PDTaskSummary] = []
    var later: [PDTaskSummary] = []

    /// - Parameters:
    ///   - hidden: tasks with a completion or snooze waiting to sync; Today no longer lists them.
    ///   - timeZone: the workspace's zone, which decides what "today" is.
    init(tasks: [PDTaskSummary], now: Date, timeZone: TimeZone, hidden: Set<String> = []) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for task in tasks where !hidden.contains(task.taskUuid) {
            if task.pdStatus.isWaitingOnOthers {
                waiting.append(task)
            } else if task.overdue == true || (task.dueAt.map { $0 < now } ?? false) {
                overdue.append(task)
            } else if let due = task.dueAt, calendar.isDate(due, inSameDayAs: now) {
                dueToday.append(task)
            } else {
                later.append(task)
            }
        }
    }

    var isEmpty: Bool { overdue.isEmpty && dueToday.isEmpty && waiting.isEmpty && later.isEmpty }
}

// MARK: - Contact links

enum PDContact {
    static func phoneURL(_ phone: String) -> URL? {
        URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })")
    }

    /// wa.me wants the number in international form without `+`. A national number (leading 0)
    /// gets the calling code of the device's region when we know it; otherwise it's left alone.
    static func whatsAppURL(_ phone: String, region: String? = Locale.current.region?.identifier) -> URL? {
        var digits = phone.filter(\.isNumber)
        let callingCodes = ["GB": "44", "IE": "353", "FR": "33", "DE": "49", "ES": "34", "IT": "39", "NL": "31"]
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("0"), !digits.isEmpty,
           let code = region.flatMap({ callingCodes[$0] }) {
            digits = code + digits.dropFirst()
        }
        return digits.isEmpty ? nil : URL(string: "https://wa.me/\(digits)")
    }

    static func emailURL(_ email: String, subject: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        if let subject { components.queryItems = [URLQueryItem(name: "subject", value: subject)] }
        return components.url
    }
}
