import Foundation

/// Every resource the app shows through the module kit, by id.
///
/// Descriptors live next to their module (`ModuleCatalog+Shop.swift`, …) and are listed here once.
/// `NativeModules` decides which menu item opens which screen.
enum ModuleCatalog {
    static let all: [ResourceDescriptor] = shop

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
    static let reports: [ReportSpec] = shopReports

    static func report(_ id: String) -> ReportSpec? { reports.first { $0.id == id } }
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
