import SwiftUI
import UIKit

/// The items in a supplier's price list, and which of our products each one is linked to.
struct ShopSupplierItemsView: View {
    let supplier: ShopSupplier
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var search = ""
    @State private var linked: Bool?
    @State private var changedOnly = false
    @State private var includeInactive = false
    @State private var items: [ShopSupplierItem] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var error: APIError?
    @State private var linking: ShopSupplierItem?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $linked) {
                    Text("All items").tag(Bool?.none)
                    Text("Linked to a product").tag(Bool?.some(true))
                    Text("Not linked").tag(Bool?.some(false))
                }
                .accessibilityIdentifier("supplierItems.linked")
                Toggle("Cost changed in the last 7 days", isOn: $changedOnly)
                Toggle("Include items no longer in their list", isOn: $includeInactive)
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
            }
            if let error {
                Section { InlineErrorRow(error: error) { Task { await reload() } } }
            }
            Section {
                ForEach(items) { item in
                    Button {
                        if session.shopPolicy.canUpdate { linking = item }
                    } label: {
                        ShopSupplierItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(session.shopPolicy.canUpdate ? "Link it to one of your products" : "")
                    .task {
                        if item.id == items.last?.id, items.count < total, !loading { await loadMore() }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            } header: {
                if total > 0 { Text("\(total.formatted()) item\(total == 1 ? "" : "s")") }
            } footer: {
                if !items.isEmpty, session.shopPolicy.canUpdate {
                    Text("Tap an item to link it to one of your products. A linked product can follow this supplier’s cost plus your margin.")
                }
            }
        }
        .overlay {
            if !loading, error == nil, items.isEmpty {
                ContentUnavailableView("No items", systemImage: "list.bullet.rectangle",
                                       description: Text(search.isEmpty && linked == nil && !changedOnly
                                                         ? "Update their price list or upload their file to see their items here."
                                                         : "Nothing matches. Clear the search or the filters."))
            }
        }
        .searchable(text: $search, prompt: "Their code, part number or name")
        .navigationTitle("\(supplier.name) items")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(search)|\(String(describing: linked))|\(changedOnly)|\(includeInactive)") {
            if !items.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
        .wsRefreshable { await reload() }
        .sheet(item: $linking) { item in
            NavigationStack {
                ShopSupplierLinkSheet(item: item) { message in
                    notice = message
                    Task { await reload() }
                }
            }
        }
    }

    private func reload() async {
        page = 1
        await fetch(page: 1, replacing: true)
    }

    private func loadMore() async {
        await fetch(page: page + 1, replacing: false)
    }

    private func fetch(page next: Int, replacing: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let result = try await services.shop.supplierItems(supplier.uuid, search: search, linked: linked,
                                                               changedOnly: changedOnly, includeInactive: includeInactive, page: next)
            items = replacing ? result.items : items + result.items
            total = result.total
            page = next
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }
}

struct ShopSupplierItemRow: View {
    let item: ShopSupplierItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.wsHeadline).lineLimit(2)
                Spacer()
                Text(ShopMoney.format(item.costMinor) ?? "—").font(.wsSubheadline.monospacedDigit())
            }
            Text([item.supplierSku, item.mpn, item.brand].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote.monospaced()).foregroundStyle(.secondaryText)
            if let change = item.costChangePct, item.costChangedAt != nil {
                Text("\(change > 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1))))% since "
                     + (ShopMoney.format(item.previousCostMinor) ?? "before"))
                    .font(.wsFootnote)
                    .foregroundStyle(change > 0 ? Tone.danger.textColor : Tone.success.textColor)
            }
            if let stock = item.stockLine {
                Text(stock).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if item.isLinked {
                Label("\(item.productName ?? "Linked product") · \(ShopMoney.format(item.productPriceMinor) ?? "—") · "
                      + (item.pricingSource == "supplier" ? "follows this supplier" : "price set by you"),
                      systemImage: "link")
                    .font(.wsFootnote)
            } else {
                Label("Not linked", systemImage: "link.badge.plus").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if !item.isActive {
                StatusBadge(text: "No longer in their list", systemImage: "archivebox", tone: .neutral)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Link a supplier item to one of our products, choose how it's priced, or unlink it.
struct ShopSupplierLinkSheet: View {
    let item: ShopSupplierItem
    let onDone: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var product: ShopBuyingProductChoice?
    @State private var pricing: String
    @State private var margin: String
    @State private var choosing = false
    @State private var saving = false
    @State private var error: APIError?

    init(item: ShopSupplierItem, onDone: @escaping (String) -> Void) {
        self.item = item
        self.onDone = onDone
        _product = State(initialValue: item.productUuid.map {
            ShopBuyingProductChoice(uuid: $0, name: item.productName ?? "Linked product", sku: item.productSku)
        })
        _pricing = State(initialValue: item.pricingSource ?? "supplier")
        _margin = State(initialValue: item.productMarginPct.map(ShopSupplierDraft.number) ?? "")
    }

    private var marginValue: Double? {
        Double(margin.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private var marginProblem: Bool {
        guard pricing == "supplier", margin.trimmedOrNil != nil else { return false }
        guard let value = marginValue else { return true }
        return !(-50...500).contains(value)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Their code", value: item.supplierSku)
                LabeledContent("Cost ex VAT", value: ShopMoney.format(item.costMinor) ?? "—")
            } header: {
                Text(item.name)
            }
            Section("Your product") {
                Button {
                    choosing = true
                } label: {
                    LabeledContent("Product") {
                        Text(product.map { [$0.name, $0.sku].compactMap { $0 }.joined(separator: " · ") } ?? "Choose…")
                            .foregroundStyle(product == nil ? Color.secondaryText : Color.primary)
                    }
                }
                .accessibilityIdentifier("supplierLink.product")
            }
            Section {
                Picker("Price", selection: $pricing) {
                    Text("Follow this supplier (cost + margin)").tag("supplier")
                    Text("I set the price myself").tag("manual")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if pricing == "supplier" {
                    LabeledContent("Margin %") {
                        TextField("Default", text: $margin)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("supplierLink.margin")
                    }
                }
            } header: {
                Text("Price")
            } footer: {
                if pricing == "supplier" {
                    if marginProblem {
                        Text("The margin is a percentage between −50 and 500.").foregroundStyle(Tone.danger.textColor)
                    } else if let value = marginValue {
                        Text("Shop price \(ShopMoney.format(Int((Double(item.costMinor) * (1 + value / 100)).rounded())) ?? "—") ex VAT. "
                             + "Changes bigger than the supplier’s threshold wait in Price changes.")
                    } else {
                        Text("Empty uses the category’s margin, then the supplier’s default. Changes bigger than the supplier’s threshold wait in Price changes.")
                    }
                } else {
                    Text("Their cost is shown on the product for reference; its price stays as you set it.")
                }
            }
            if item.isLinked {
                Section {
                    Button(role: .destructive) { Task { await save(unlink: true) } } label: {
                        Label("Unlink from \(item.productName ?? "the product")", systemImage: "link.badge.minus")
                    }
                    .disabled(saving)
                }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle(item.isLinked ? "Change link" : "Link to a product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save(unlink: false) } }
                    .disabled(saving || product == nil || marginProblem)
                    .accessibilityIdentifier("supplierLink.save")
            }
        }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                ShopBuyingProductPicker(title: "Choose a product") { product = $0 }
            }
        }
    }

    private func save(unlink: Bool) async {
        saving = true
        defer { saving = false }
        let body = ShopSupplierLinkBody(productUuid: unlink ? nil : product?.uuid, pricingSource: pricing,
                                        marginPct: pricing == "supplier" ? marginValue : nil)
        do {
            let result = try await services.shop.linkSupplierItem(item.uuid, body)
            onDone(result.message)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A product picked from the shop's catalogue.
struct ShopBuyingProductChoice: Hashable, Sendable, Identifiable {
    let uuid: String
    var name: String
    var sku: String?
    var id: String { uuid }
}

/// Search the shop's catalogue and pick one product.
struct ShopBuyingProductPicker: View {
    let title: String
    let onPick: (ShopBuyingProductChoice) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var state: LoadState<[ShopProductSummary]> = .idle

    var body: some View {
        List {
            switch state {
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No products yet" : "Nothing matches", systemImage: "shippingbox",
                                           description: Text(search.isEmpty ? "Add products to the shop first." : "Try another name or SKU."))
                }
                ForEach(rows) { product in
                    Button {
                        onPick(ShopBuyingProductChoice(uuid: product.uuid, name: product.name, sku: product.sku))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name).font(.wsHeadline).foregroundStyle(Color.primary)
                            Text([product.sku, ShopMoney.format(product.basePriceMinor, currency: product.currency),
                                  product.status == "active" ? nil : Formatters.humanize(product.status)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("productPicker.\(product.sku)")
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $search, prompt: "Name or SKU")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task(id: search) {
            if state.value != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.products(search: search, status: nil, lowStockOnly: false, page: 1, limit: 50).items)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// The supplier's own logins to the supplier portal. Nothing is emailed from here: staff pass the link on.
struct ShopSupplierPortalView: View {
    let supplier: ShopSupplier
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopPortalUsers> = .idle
    @State private var email = ""
    @State private var name = ""
    @State private var busy: String?
    @State private var issued: (url: String, message: String)?
    @State private var error: APIError?
    @State private var confirmOff: ShopPortalUser?
    @State private var confirmLink: ShopPortalUser?
    @State private var dashboard: URL?

    var body: some View {
        let canUpdate = session.shopPolicy.canUpdate
        List {
            if let data = state.value {
                Section {
                    if !data.portalEnabled {
                        Label("The supplier portal is switched off, so they’ll see “not available yet”. Turn it on in Shop settings.",
                              systemImage: "exclamationmark.triangle")
                            .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    }
                    if let issued {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(issued.message).font(.wsFootnote)
                            if !issued.url.isEmpty {
                                Text(issued.url).font(.wsCaption.monospaced()).textSelection(.enabled)
                                HStack {
                                    Button("Copy link") { UIPasteboard.general.string = issued.url }
                                        .buttonStyle(.bordered)
                                    ShareLink(item: issued.url) { Label("Send", systemImage: "square.and.arrow.up") }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    if let error { InlineErrorRow(error: error) }
                } footer: {
                    Text("People at \(supplier.name) who can sign in to see their purchase orders, upload proformas and invoices, enter dispatch and message you. They only ever see \(supplier.name)’s purchase orders.")
                }
                Section("Logins") {
                    if data.users.isEmpty {
                        Text("No portal logins yet.").foregroundStyle(.secondaryText)
                    }
                    ForEach(data.users) { user in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(user.name?.trimmedOrNil ?? user.email).font(.wsHeadline)
                                Spacer()
                                StatusBadge(text: user.statusLabel, systemImage: user.status == "active" ? "checkmark.circle" : "circle",
                                            tone: user.tone)
                            }
                            Text([user.name?.trimmedOrNil == nil ? nil : user.email,
                                  user.lastSeenAt.flatMap { Formatters.dateTime($0) }.map { "Last seen \($0)" }
                                    ?? (user.status == "invited" ? "Hasn’t signed in yet" : "Not seen yet")]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                            if canUpdate {
                                HStack {
                                    if user.status != "disabled" {
                                        Button("New sign-in link") { confirmLink = user }.buttonStyle(.bordered)
                                    }
                                    Button(user.status == "disabled" ? "Switch back on" : "Switch off") {
                                        if user.status == "disabled" { Task { await setEnabled(user, true) } } else { confirmOff = user }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .disabled(busy != nil)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if canUpdate {
                    Section {
                        TextField("Their email", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("supplierPortal.email")
                        TextField("Their name (optional)", text: $name)
                        Button { Task { await invite() } } label: {
                            HStack {
                                Label("Create login", systemImage: "person.badge.plus")
                                if busy == "invite" { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(busy != nil || email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil)
                    } header: {
                        Text("Add a login")
                    } footer: {
                        Text("Nothing is emailed: you get a link to set their password, to pass on yourself.")
                    }
                }
            } else if let loadError = state.error {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Portal logins")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            dashboard = DashboardURL.forAPI(await services.shop.client.currentBaseURL)
            await load()
        }
        .wsRefreshable { await load() }
        .confirmationDialog("Switch off \(confirmOff?.email ?? "")?", isPresented: .init(get: { confirmOff != nil }, set: { if !$0 { confirmOff = nil } }),
                            titleVisibility: .visible, presenting: confirmOff) { user in
            Button("Switch off", role: .destructive) { Task { await setEnabled(user, false) } }
        } message: { _ in
            Text("They are signed out and can’t sign in to the supplier portal until you switch them back on.")
        }
        .confirmationDialog("New sign-in link for \(confirmLink?.email ?? "")?", isPresented: .init(get: { confirmLink != nil }, set: { if !$0 { confirmLink = nil } }),
                            titleVisibility: .visible, presenting: confirmLink) { user in
            Button("Create link") { Task { await newLink(user) } }
        } message: { _ in
            Text("Their previous link stops working. Nothing is emailed: copy the new link and pass it on.")
        }
    }

    /// The supplier opens the set-password page on the dashboard host in their own browser.
    private func fullLink(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        if path.hasPrefix("http") { return path }
        guard let dashboard else { return path }
        return dashboard.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (path.hasPrefix("/") ? path : "/" + path)
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.portalUsers(supplierUuid: supplier.uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if case .notFound = apiError {
                state = .failed(ResourceService.problem(404, "The supplier portal isn’t available for this workspace yet."))
            } else if state.value == nil {
                state = .failed(apiError)
            } else {
                self.error = apiError
            }
        }
    }

    private func invite() async {
        busy = "invite"
        defer { busy = nil }
        do {
            let result = try await services.shop.invitePortalUser(supplierUuid: supplier.uuid,
                                                                   email: email.trimmingCharacters(in: .whitespaces), name: name)
            let link = fullLink(result.setPasswordPath)
            let days = result.expiresInDays.map { " The link works for \($0) days." } ?? ""
            issued = (link, (result.message ?? "Login created.") + days)
            email = ""
            name = ""
            error = nil
            await load()
        } catch {
            self.error = error.asAPIError
        }
    }

    private func newLink(_ user: ShopPortalUser) async {
        busy = user.id
        defer { busy = nil }
        do {
            let result = try await services.shop.newPortalLink(supplierUuid: supplier.uuid, userId: user.id)
            let link = fullLink(result.setPasswordPath)
            if link.isEmpty {
                error = ResourceService.problem(400, "The link couldn’t be created. Try again.")
            } else {
                issued = (link, "New sign-in link for \(user.email). Nothing has been emailed: copy it and pass it on."
                          + (result.expiresInDays.map { " It works for \($0) days." } ?? ""))
                error = nil
            }
        } catch {
            self.error = error.asAPIError
        }
    }

    private func setEnabled(_ user: ShopPortalUser, _ enabled: Bool) async {
        busy = user.id
        defer { busy = nil }
        do {
            state = .loaded(try await services.shop.setPortalUser(supplierUuid: supplier.uuid, userId: user.id, enabled: enabled))
            issued = (url: "", message: enabled ? "\(user.email) can sign in again." : "\(user.email) is switched off.")
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}
