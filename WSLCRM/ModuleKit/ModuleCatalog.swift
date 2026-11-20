import SwiftUI

/// One area of the app (the shop, workspace admin, tax, chat…): its described resources, reports,
/// hand-built screens, and which server menu items (`menu_items.key`) it opens.
///
/// Each group lives in its own file (`Catalog/ModuleGroup+Shop.swift`, …) and is listed once in
/// `ModuleCatalog.groups`, so areas are built side by side without touching each other's code.
struct ModuleGroup: Sendable {
    let id: String
    var descriptors: [ResourceDescriptor] = []
    var reports: [ReportSpec] = []
    /// Menu key → a module kit list (descriptor id).
    var resources: [String: String] = [:]
    /// Menu key → a hand-built screen (screen id, drawn by `screen`).
    var screens: [String: String] = [:]
    /// The group's hand-built screens by id (`NativeScreenRoute`). nil for an id it doesn't own.
    var screen: @MainActor @Sendable (String) -> AnyView? = { _ in nil }
}

/// Opens a group's hand-built screen by id (`NavigationLink(value: NativeScreenRoute("chat.home"))`).
struct NativeScreenRoute: Hashable, Sendable {
    let id: String
    init(_ id: String) { self.id = id }
}

/// Every module the app shows natively, gathered from the groups.
enum ModuleCatalog {
    /// Add a new area here (one line), and its file under `Catalog/`.
    static let groups: [ModuleGroup] = [.shop, .chat, .tax]

    static let all: [ResourceDescriptor] = groups.flatMap(\.descriptors)

    static let byID: [String: ResourceDescriptor] = {
        var table: [String: ResourceDescriptor] = [:]
        for descriptor in all {
            precondition(table[descriptor.id] == nil, "Duplicate resource id \(descriptor.id)")
            table[descriptor.id] = descriptor
        }
        return table
    }()

    static func descriptor(_ id: String) -> ResourceDescriptor? { byID[id] }

    /// Read-only reports (`ResourceReportView`).
    static let reports: [ReportSpec] = groups.flatMap(\.reports)

    static func report(_ id: String) -> ReportSpec? { reports.first { $0.id == id } }

    /// Menu key → descriptor id, across every group.
    static let resourceKeys: [String: String] = groups.reduce(into: [:]) { table, group in
        table.merge(group.resources) { first, _ in first }
    }

    /// Menu key → hand-built screen id, across every group.
    static let screenKeys: [String: String] = groups.reduce(into: [:]) { table, group in
        table.merge(group.screens) { first, _ in first }
    }

    /// A hand-built screen by id, from whichever group owns it.
    @MainActor
    static func screen(_ id: String) -> AnyView? {
        for group in groups {
            if let view = group.screen(id) { return view }
        }
        return nil
    }
}

/// Draws a `NativeScreenRoute`.
struct NativeScreenView: View {
    let route: NativeScreenRoute

    var body: some View {
        if let screen = ModuleCatalog.screen(route.id) {
            screen
        } else {
            // Never shipped: NativeModulesTests checks every screen id resolves.
            ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
        }
    }
}

/// A module kit list, by descriptor id (pushed with `NavigationLink(value:)`).
struct ResourceListRoute: Hashable, Sendable {
    let descriptorID: String
    /// Extra list query (`customer_uuid=…`) for related lists.
    var query: [String: String] = [:]
    /// Overrides the descriptor's title ("Orders for Acme Ltd").
    var title: String?

    init(_ descriptorID: String, query: [String: String] = [:], title: String? = nil) {
        self.descriptorID = descriptorID
        self.query = query
        self.title = title
    }
}

/// One record's detail screen.
struct ResourceRoute: Hashable, Sendable {
    let descriptorID: String
    let recordID: String
    /// The list row, shown at once while the full record loads.
    var seed: Record?
}
