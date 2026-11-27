import XCTest
@testable import WSLCRM

/// The ⌘K search: records the server found come first, grouped by kind, then the person's pages, then "Ask AI";
/// only rows that open natively are listed; recent searches are kept per person.
final class CommandPaletteTests: XCTestCase {
    private let menu = AppMenu(sections: [AppMenu.Section(key: "sales", title: "Sales", items: [
        AppMenu.Item(key: "customers", name: "Customers", icon: nil, path: "/dashboard/customers"),
        AppMenu.Item(key: "invoices", name: "Invoices", icon: nil, path: "/dashboard/invoices"),
        AppMenu.Item(key: "crm_leads", name: "Leads", icon: nil, path: "/dashboard/leads"),
        AppMenu.Item(key: "chat", name: "AI Navigator", icon: nil, path: "/dashboard/chat"),
    ])], secondary: [])

    private let searchJSON = """
    {"success":true,"data":{"query":"acme","groups":[
      {"key":"customers","label":"Customers","items":[
        {"title":"Acme Ltd","subtitle":"jo@acme.test","path":"/dashboard/customers/5b1c2d3e-aaaa-bbbb-cccc-111122223333"}]},
      {"key":"invoices","label":"Invoices","items":[
        {"title":"INV-0042","subtitle":"Acme Ltd · GBP 120.00 · sent","path":"/dashboard/invoices/9f8e7d6c-1111-2222-3333-444455556666"}]},
      {"key":"employees","label":"Employees","items":[{"title":"Acme Jo","path":"/dashboard/employees"}]}
    ]}}
    """

    private func items(_ query: String, recents: [String] = [], canAsk: Bool = true) throws -> [CommandPaletteItem] {
        let groups = RecordSearchGroup.parse(try ResourceService.decode(Data(searchJSON.utf8)))
        return CommandPaletteItem.build(query: query, records: groups, catalog: AppCatalog(menu: menu), menu: menu,
                                        recents: recents, canAsk: canAsk)
    }

    func testRecordsComeFirstGroupedThenPagesThenAskAI() throws {
        let list = try items("in")
        XCTAssertEqual(list.map(\.section), ["Customers", "Invoices", "Pages", "Ask AI"],
                       "the employee has no screen of its own nor a menu page here, so it isn't offered")
        XCTAssertEqual(list[0].action, .record(.customer("5b1c2d3e-aaaa-bbbb-cccc-111122223333")))
        XCTAssertEqual(list[1].subtitle, "Acme Ltd · £120.00 · sent", "pounds as £")
        XCTAssertEqual(list[1].systemImage, "doc.text")
        XCTAssertEqual(list[2].title, "Invoices", "the page whose name starts with what was typed")
        XCTAssertEqual(list.last?.action, .ask("in"))
        XCTAssertEqual(list.last?.title, "Ask AI about “in”")
    }

    func testOneLetterSearchesPagesOnlyAndAskIsOnlyForPeopleWithTheAssistant() throws {
        let list = try items("l", canAsk: false)
        XCTAssertTrue(list.allSatisfy { $0.section == "Pages" }, "records need two letters, as the server does")
        XCTAssertEqual(list.first?.title, "Leads")
        XCTAssertFalse(list.contains { if case .ask = $0.action { true } else { false } })
    }

    func testNothingTypedShowsRecentSearchesThenEveryPage() throws {
        let list = try items("  ", recents: ["acme", "INV-0042"])
        XCTAssertEqual(list.prefix(2).map(\.action), [.recent("acme"), .recent("INV-0042")])
        XCTAssertEqual(list.dropFirst(2).map(\.title), ["Customers", "Invoices", "Leads"],
                       "every page, but the assistant has its own entry")
    }

    func testPagesRankLikeTheWeb() {
        XCTAssertEqual(CommandPaletteItem.score("leads", name: "Leads", key: "crm_leads"), 100)
        XCTAssertEqual(CommandPaletteItem.score("lea", name: "Leads", key: "crm_leads"), 80)
        XCTAssertEqual(CommandPaletteItem.score("ead", name: "Leads", key: "crm_leads"), 60)
        XCTAssertEqual(CommandPaletteItem.score("crm", name: "Leads", key: "crm_leads"), 40)
        XCTAssertEqual(CommandPaletteItem.score("lds", name: "Leads", key: "crm_leads"), 10)
        XCTAssertEqual(CommandPaletteItem.score("xyz", name: "Leads", key: "crm_leads"), 0)
    }

    func testRecentSearchesAreNewestFirstWithoutRepeatsAndPerPerson() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "palette-\(UUID().uuidString)"))
        RecentSearches.add("acme", user: "u-1", defaults: defaults)
        RecentSearches.add("x", user: "u-1", defaults: defaults) // too short to be worth keeping
        RecentSearches.add("boiler", user: "u-1", defaults: defaults)
        RecentSearches.add("ACME", user: "u-1", defaults: defaults)
        XCTAssertEqual(RecentSearches.load(user: "u-1", defaults: defaults), ["ACME", "boiler"])
        XCTAssertEqual(RecentSearches.load(user: "u-2", defaults: defaults), [])
        for n in 0..<10 { RecentSearches.add("query \(n)", user: "u-1", defaults: defaults) }
        XCTAssertEqual(RecentSearches.load(user: "u-1", defaults: defaults).count, RecentSearches.limit)
        RecentSearches.clear(user: "u-1", defaults: defaults)
        XCTAssertEqual(RecentSearches.load(user: "u-1", defaults: defaults), [])
    }
}
