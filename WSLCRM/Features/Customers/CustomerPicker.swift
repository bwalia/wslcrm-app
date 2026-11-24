import SwiftUI

// "Choose a customer": pick one of the workspace's customers (`GET /api/v2/customers?search=`, RBAC
// customers.read) to fill an invoice, a store order or a quote. Typing the details by hand still works.

/// The customer's details in the shapes the sales forms use.
struct PickedCustomer: Equatable, Sendable {
    var name: String
    var firstName: String
    var lastName: String
    var email: String
    var phone: String
    var company: String
    var line1: String
    var line2: String
    var city: String
    var county: String
    var postcode: String
    var country: String

    init(_ customer: Customer) {
        let address = customer.primaryAddress
        name = customer.displayName
        firstName = customer.firstName?.trimmedOrNil ?? ""
        lastName = customer.lastName?.trimmedOrNil ?? ""
        email = customer.email
        phone = customer.phone?.trimmedOrNil ?? ""
        company = address?.company?.trimmedOrNil ?? ""
        line1 = address?.address1?.trimmedOrNil ?? ""
        line2 = address?.address2?.trimmedOrNil ?? ""
        city = address?.city?.trimmedOrNil ?? ""
        county = address?.province?.trimmedOrNil ?? ""
        postcode = address?.zip?.trimmedOrNil ?? ""
        country = address?.country?.trimmedOrNil ?? ""
    }

    /// One line per part, for an invoice's "Bill to".
    var addressText: String {
        [line1, line2, city, county, postcode, country].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The shop's customer form (country as two letters; a longer name is left for the person to fix).
    var shopDraft: ShopCustomerDraft {
        var d = ShopCustomerDraft()
        d.name = name
        d.email = email
        d.company = company
        d.phone = phone
        d.line1 = line1
        d.line2 = line2
        d.city = city
        d.postalCode = postcode
        d.country = Self.countryCode(country) ?? "GB"
        return d
    }

    var storeOrderAddress: StoreOrderAddress {
        StoreOrderAddress(name: name, company: company.trimmedOrNil, line1: line1.trimmedOrNil, line2: line2.trimmedOrNil,
                          city: city.trimmedOrNil, county: county.trimmedOrNil, postcode: postcode.trimmedOrNil,
                          country: country.trimmedOrNil, phone: phone.trimmedOrNil)
    }

    var hasAddress: Bool { !(line1.isEmpty && city.isEmpty && postcode.isEmpty) }

    static func countryCode(_ country: String) -> String? {
        let t = country.trimmingCharacters(in: .whitespaces)
        if t.count == 2 { return t.uppercased() }
        switch t.lowercased() {
        case "united kingdom", "uk", "great britain", "england", "scotland", "wales", "northern ireland": return "GB"
        case "ireland": return "IE"
        default: return nil
        }
    }
}

/// A row that opens the picker. Hidden for people who can't read customers (the list would 403).
struct ChooseCustomerButton: View {
    var title = "Choose an existing customer"
    let pick: (PickedCustomer) -> Void
    @Environment(SessionStore.self) private var session
    @State private var choosing = false

    var body: some View {
        if session.permissions.can(.read, .customers) {
            Button {
                choosing = true
            } label: {
                Label(title, systemImage: "person.crop.circle.badge.magnifyingglass")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("chooseCustomer")
            .sheet(isPresented: $choosing) {
                ShopCustomerPickerSheet { pick(PickedCustomer($0)) }
            }
        }
    }
}

struct ShopCustomerPickerSheet: View {
    let pick: (Customer) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ModelHost(make: { [commerce = services.commerce] in
                PagedListModel<Customer> { search, page in
                    try await commerce.customers(search: search, orderBy: "name", orderDir: "asc", page: page)
                }
            }) { model in
                PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No customers yet",
                          emptySystemImage: "person.crop.rectangle.stack",
                          emptyDescription: "Close this and type the customer's details instead.") { customer in
                    Button {
                        pick(customer)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(customer.displayName).font(.wsHeadline).foregroundStyle(Color.primary)
                            if let line = [customer.email.trimmedOrNil, customer.phone, customer.primaryAddress?.city]
                                .compactMap({ $0?.trimmedOrNil }).joined(separator: " · ").trimmedOrNil {
                                Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("chooseCustomer.row.\(customer.uuid)")
                }
            }
            .navigationTitle("Choose a customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
