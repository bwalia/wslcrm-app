import SwiftUI

/// Stores (`/api/v2/stores`, RBAC `stores`): the list, a store's details, edit, delete, and adding one.
///
/// The tax rate is entered as a percentage (20 → 20%) when adding and saving a store; the server stores
/// a fraction and reads a value below 1 as one already (0.2 → 20%), so a stored rate saved untouched
/// stays the same (StoreQueries.taxFraction).
enum StoreCatalog {
    static let screenID = "workspace.stores"

    static let status = StatusStyle(tones: ["active": .success, "inactive": .neutral, "suspended": .danger])
    static let statusChoices = [Choice("active"), Choice("inactive"), Choice("suspended")]

    private static let path = "/api/v2/stores"

    static let detailSections: [SectionSpec] = [
        SectionSpec(nil, [
            FieldSpec("status", "Status", .status(status)), FieldSpec("slug", "Web address name"),
            FieldSpec("description", "Description", .multiline), FieldSpec("is_verified", "Verified", .bool),
        ]),
        SectionSpec("Contact", [
            FieldSpec("contact_email", "Email", .email), FieldSpec("contact_phone", "Phone", .phone),
        ]),
        SectionSpec("Address", [
            FieldSpec("address", "Address"), FieldSpec("city", "Town or city"), FieldSpec("state", "County or state"),
            FieldSpec("postal_code", "Postcode"), FieldSpec("country", "Country"),
        ]),
        SectionSpec("Money and time", [
            FieldSpec("currency", "Currency"), FieldSpec("tax_rate", "Tax rate", .percent),
            FieldSpec("timezone", "Time zone"),
        ]),
        SectionSpec("Shipping", [
            FieldSpec("shipping_enabled", "Ships orders", .bool), FieldSpec("can_self_ship", "Delivers itself", .bool),
            FieldSpec("shipping_flat_rate", "Flat delivery charge", .money(currencyKey: "currency", minorUnits: false)),
            FieldSpec("free_shipping_threshold", "Free delivery over",
                      .money(currencyKey: "currency", minorUnits: false)),
        ]),
        SectionSpec("Images", [FieldSpec("logo_url", "Logo address", .url), FieldSpec("banner_url", "Banner address", .url)]),
        SectionSpec(nil, [FieldSpec("created_at", "Added", .dateTime), FieldSpec("updated_at", "Last changed", .dateTime)]),
    ]

    /// Fields both forms share (everything except the tax rate).
    private static func formSections(taxRate: FieldSpec) -> [SectionSpec] {
        [
            SectionSpec(nil, [
                FieldSpec("name", "Store name", required: true),
                FieldSpec("description", "Description", .multiline),
                FieldSpec("slug", "Web address name", placeholder: "my-store",
                          help: "Lower-case letters, numbers and dashes. Made from the name when left empty."),
                FieldSpec("status", "Status", .choice(statusChoices), required: true, defaultValue: .string("active")),
            ]),
            SectionSpec("Contact", [
                FieldSpec("contact_email", "Email", .email), FieldSpec("contact_phone", "Phone", .phone),
            ]),
            SectionSpec("Address", [
                FieldSpec("address", "Address"), FieldSpec("city", "Town or city"),
                FieldSpec("state", "County or state"), FieldSpec("postal_code", "Postcode"),
                FieldSpec("country", "Country"),
            ]),
            SectionSpec("Money and time", [
                FieldSpec("currency", "Currency", placeholder: Formatters.defaultCurrency), taxRate,
                FieldSpec("timezone", "Time zone", placeholder: "Europe/London"),
            ]),
            SectionSpec("Shipping", [
                FieldSpec("shipping_enabled", "Ships orders", .bool),
                FieldSpec("can_self_ship", "Delivers itself", .bool),
                FieldSpec("shipping_flat_rate", "Flat delivery charge (\(Formatters.currencySymbol))", .decimal(places: 2)),
                FieldSpec("free_shipping_threshold", "Free delivery over (\(Formatters.currencySymbol))", .decimal(places: 2)),
            ]),
            SectionSpec("Images", [
                FieldSpec("logo_url", "Logo address", .url, placeholder: "https://"),
                FieldSpec("banner_url", "Banner address", .url, placeholder: "https://"),
            ]),
        ]
    }

    /// The list, a store, editing and deleting.
    static let stores = ResourceDescriptor(
        id: "workspace.stores", title: "Stores", noun: "store", systemImage: "storefront",
        api: ResourceAPISpec(list: path, item: "\(path)/{uuid}", update: "\(path)/{uuid}", paging: .pageAndCamelPerPage,
                             searchParam: nil, idKeys: ["uuid", "id"]),
        permissions: ResourcePermissions(module: "stores"),
        list: ListSpec(title: ["name", "slug"],
                       subtitle: [FieldSpec("city", "Town"), FieldSpec("country", "Country"),
                                  FieldSpec("contact_email", "Email", .email)],
                       badge: FieldSpec("status", "Status", .status(status)),
                       emptyTitle: "No stores yet",
                       emptyDescription: "A store is where your products are sold from, with its own address, "
                           + "currency, tax rate and delivery charges."),
        detail: detailSections,
        form: FormSpec(formSections(taxRate: FieldSpec(
            "tax_rate", "Tax rate (%)", .decimal(places: 4),
            help: "Type the percentage, e.g. 20 for 20%. A saved rate may show as a fraction (0.2 is 20%).")),
                       sendOnlyChanges: true),
        actions: [
            // A delete with its own warning: the store's products, categories and orders go with it.
            ActionSpec("delete", "Delete this store", systemImage: "trash", method: .delete, path: "\(path)/{uuid}",
                       confirm: "This deletes the store and everything in it: its products, categories and orders. "
                           + "It can’t be undone.",
                       destructive: true, action: .delete, done: "Store deleted."),
        ],
        summary: "Where your products are sold from.")

    /// Adding a store: the same fields, with the tax rate as a percentage (the server converts it).
    static let newStore: ResourceDescriptor = {
        var descriptor = stores
        descriptor.api = ResourceAPISpec(list: path, create: path, paging: .pageAndCamelPerPage, searchParam: nil,
                                         idKeys: ["uuid", "id"])
        descriptor.form = FormSpec(formSections(taxRate: FieldSpec(
            "tax_rate", "Tax rate (%)", .decimal(places: 2), placeholder: "20",
            help: "Leave empty for 20%.")))
        return descriptor
    }()
}

/// The stores list with an "Add store" button that uses the percentage form.
struct StoresScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var adding = false
    /// A new id rebuilds the list so a store just added shows straight away.
    @State private var generation = 0

    var body: some View {
        ResourceListView(StoreCatalog.stores)
            .id(generation)
            .toolbar {
                if session.permissions.can(.create, moduleName: "stores") {
                    ToolbarItem(placement: .primaryAction) {
                        Button { adding = true } label: { Label("New store", systemImage: "plus") }
                            .accessibilityIdentifier("stores.new")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    ResourceFormView(descriptor: StoreCatalog.newStore, existing: nil) { _ in generation += 1 }
                }
            }
    }
}
