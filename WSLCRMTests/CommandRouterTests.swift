import XCTest
@testable import WSLCRM

/// Home's command box: a place opens at once, everything else is a job for the agent; "Jump to" finds screens by
/// name or everyday word; an agent's actions point back to the screens it worked in.
final class CommandRouterTests: XCTestCase {
    private let places: [CommandRouter.Place] = [
        .init(key: "shop", name: "Shop", systemImage: "storefront", aliases: CommandRouter.aliases["shop"] ?? []),
        .init(key: "crm_leads", name: "Leads", systemImage: "person", aliases: CommandRouter.aliases["crm_leads"] ?? []),
        .init(key: "my_tasks", name: "My tasks", systemImage: "checklist", aliases: CommandRouter.aliases["my_tasks"] ?? []),
        .init(key: "products", name: "Products", systemImage: "shippingbox", aliases: CommandRouter.aliases["products"] ?? []),
        .init(key: "invoices", name: "Invoices", systemImage: "doc.text", aliases: CommandRouter.aliases["invoices"] ?? []),
    ]

    func testPlaceNamesOpenDirectly() {
        for text in ["shop", "Open shop", "open the Shop page please", "go to leads", "Show me my tasks", "tasks",
                     "take me to the stock screen", "lead", "Invoices."] {
            guard case .open = CommandRouter.decide(text, places: places) else {
                return XCTFail("\(text) should open a screen")
            }
        }
        XCTAssertEqual(CommandRouter.decide("show me my tasks", places: places), .open(places[2]))
        XCTAssertEqual(CommandRouter.decide("stock", places: places), .open(places[3]))
    }

    func testAnythingMoreGoesToTheAgent() {
        for text in ["Which open quotes should I chase first?", "show overdue invoices for Acme",
                     "create a lead for Jane", "open a new task called Fix boiler"] {
            XCTAssertEqual(CommandRouter.decide(text, places: places), .ask(text), text)
        }
        XCTAssertNil(CommandRouter.decide("   ", places: places))
    }

    func testSearchRanksExactThenPrefix() {
        XCTAssertEqual(CommandRouter.search("le", places: places).first?.key, "crm_leads")
        XCTAssertEqual(CommandRouter.search("inventory", places: places).map(\.key), ["products"])
        XCTAssertEqual(CommandRouter.search("open sh", places: places).first?.key, "shop")
        XCTAssertTrue(CommandRouter.search("x", places: places).isEmpty)
    }

    func testSuggestionsLeadWithWhatNeedsThePerson() {
        let signal = HomeSignal(id: "shop.quotes", title: "Open quotes", count: 24, systemImage: "doc", tone: .info,
                                hub: .shop, menuKey: "shop")
        let suggestions = CommandCenter.suggestions(for: [signal])
        XCTAssertEqual(suggestions.first, "Which open quotes should I chase first?")
        XCTAssertLessThanOrEqual(suggestions.count, 5)
    }

    func testAgentActionsMapToScreens() {
        let actions = [
            ChatAgentAction(name: "call_api", label: "GET /api/v2/crm/leads", method: "GET"),
            ChatAgentAction(name: "call_api", label: "GET /api/v2/shop/admin/quotes", method: "GET"),
            ChatAgentAction(name: "call_api", label: "POST /api/v2/crm/leads", method: "POST"),
            ChatAgentAction(name: "call_api", label: "GET /api/v2/invoices", error: "Forbidden"),
            ChatAgentAction(name: "ask_user"),
        ]
        XCTAssertEqual(AgentActionScreens.keys(for: actions), ["crm_leads", "shop"])
    }
}
