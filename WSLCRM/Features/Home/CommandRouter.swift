import Foundation

/// Reads what someone typed into the command box (Home, or the assistant itself) and decides whether it is a place
/// to go — "open shop", "leads", "show me my tasks" — which opens at once, or a job for the AI agent.
///
/// Pure and synchronous, so typing stays instant and the rules are unit-tested (`CommandRouterTests`).
enum CommandRouter {
    /// Somewhere the app can open, as the command box knows it.
    struct Place: Hashable, Sendable {
        let key: String
        let name: String
        let systemImage: String
        /// Other words people use for it ("stock" for Products, "jobs" for Field Service).
        var aliases: [String] = []
    }

    enum Decision: Equatable {
        /// Open this place now; nothing goes to the agent.
        case open(Place)
        /// Hand the whole sentence to the AI agent.
        case ask(String)
    }

    /// Words in front of a place that only mean "take me there".
    static let openVerbs = ["take me to", "switch to", "show me", "go to", "open up", "open", "show", "launch",
                            "view", "see", "find", "my"]
    /// Words after a place that add nothing ("shop page", "leads screen").
    static let fillers = ["page", "screen", "app", "tab", "area", "section", "please", "list", "dashboard"]

    /// What to do with a sentence. Only an exact place (after the "open"/"show me" words) navigates: anything with
    /// more to it — "show me overdue quotes for Acme" — is a request for the agent.
    static func decide(_ text: String, places: [Place]) -> Decision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wanted = placePhrase(trimmed)
        if !wanted.isEmpty, let place = places.first(where: { matches($0, exactly: wanted) }) {
            return .open(place)
        }
        return .ask(trimmed)
    }

    /// Places whose name or alias contains what's typed, best first: shown under the box as "Jump to".
    static func search(_ text: String, places: [Place], limit: Int = 6) -> [Place] {
        let query = normalise(placePhrase(text))
        guard query.count >= 2 else { return [] }
        let scored: [(Place, Int)] = places.compactMap { place in
            let names = ([place.name] + place.aliases).map(normalise)
            if names.contains(query) { return (place, 0) }
            if names.contains(where: { $0.hasPrefix(query) }) { return (place, 1) }
            if names.contains(where: { $0.split(separator: " ").contains { $0.hasPrefix(query) } }) { return (place, 2) }
            if names.contains(where: { $0.contains(query) }) { return (place, 3) }
            return nil
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 < $1.1 }.map(\.0).filter { seen.insert($0.key).inserted }.prefix(limit).map { $0 }
    }

    /// "Open the shop page please" → "shop".
    static func placePhrase(_ text: String) -> String {
        var phrase = normalise(text)
        var changed = true
        while changed {
            changed = false
            for verb in openVerbs where phrase.hasPrefix(verb + " ") {
                phrase = String(phrase.dropFirst(verb.count + 1))
                changed = true
            }
            for article in ["the ", "a ", "all ", "our "] where phrase.hasPrefix(article) {
                phrase = String(phrase.dropFirst(article.count))
                changed = true
            }
            for filler in fillers where phrase.hasSuffix(" " + filler) {
                phrase = String(phrase.dropLast(filler.count + 1))
                changed = true
            }
        }
        return phrase
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func matches(_ place: Place, exactly phrase: String) -> Bool {
        ([place.name] + place.aliases).map(normalise).contains { $0 == phrase || singular($0) == singular(phrase) }
    }

    private static func singular(_ word: String) -> String {
        word.hasSuffix("s") && word.count > 3 ? String(word.dropLast()) : word
    }

    /// Everyday words for the app's areas, by menu key.
    static let aliases: [String: [String]] = [
        "shop": ["store", "shop admin", "orders and quotes"],
        "orders": ["sales orders"],
        "products": ["stock", "inventory", "catalogue", "catalog"],
        "crm_leads": ["lead", "enquiries", "prospects"],
        "customers": ["clients", "contacts"],
        "my_tasks": ["tasks", "todo", "to do", "to dos", "todos"],
        "projects": ["boards", "kanban"],
        "invoices": ["bills", "billing"],
        "timesheets": ["time", "hours", "time sheets"],
        "field_service_jobs": ["jobs", "field service", "engineers"],
        "field_service_requests": ["requests", "service requests", "tickets"],
        "field_service_visits": ["visits", "schedule"],
        "purchase_orders": ["pos", "purchase orders", "suppliers orders"],
        "chat": ["chat", "messages", "ai navigator", "assistant"],
    ]
}

// MARK: - Agent actions → screens

/// The screens an agent's actions touched, so a reply can offer "Open Leads" next to what it did.
enum AgentActionScreens {
    /// API prefixes (and tool names) → the menu key of the screen that shows those records. Most specific first.
    static let rules: [(needle: String, key: String)] = [
        ("shop/admin/orders", "shop"), ("shop/admin/quotes", "shop"), ("shop/admin/stock", "shop"),
        ("shop/admin", "shop"),
        ("crm/leads", "crm_leads"), ("/leads", "crm_leads"), ("lead", "crm_leads"),
        ("crm/", "crm"),
        ("customers", "customers"),
        ("purchase-orders", "purchase_orders"), ("purchase_orders", "purchase_orders"),
        ("invoices", "invoices"), ("invoice", "invoices"),
        ("timesheets", "timesheets"), ("timesheet", "timesheets"),
        ("kanban/tasks", "my_tasks"), ("my_tasks", "my_tasks"),
        ("kanban/projects", "projects"), ("project", "projects"),
        ("service-requests", "field_service_requests"),
        ("field-service/jobs", "field_service_jobs"), ("field_service/jobs", "field_service_jobs"),
        ("products", "products"), ("orders", "orders"),
    ]

    /// Menu keys for a turn's successful actions, in the order they were first touched, at most `limit`.
    static func keys(for actions: [ChatAgentAction], limit: Int = 3) -> [String] {
        var out: [String] = []
        for action in actions where action.error == nil && action.name != "ask_user" {
            let haystack = ((action.label ?? "") + " " + action.name).lowercased()
            guard let key = rules.first(where: { haystack.contains($0.needle) })?.key, !out.contains(key) else { continue }
            out.append(key)
            if out.count == limit { break }
        }
        return out
    }
}

extension AppCatalog {
    /// Every native screen in the person's menu, as places the command box can open.
    var places: [CommandRouter.Place] {
        groups.flatMap(\.entries).map {
            CommandRouter.Place(key: $0.key, name: $0.name, systemImage: $0.systemImage,
                                aliases: CommandRouter.aliases[$0.key] ?? [])
        }
    }
}
