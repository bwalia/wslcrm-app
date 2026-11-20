import SwiftUI

struct ShopSupplierRow: View {
    let supplier: ShopSupplier

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(supplier.name).font(.wsHeadline).lineLimit(1)
                Spacer()
                if !supplier.isActive {
                    StatusBadge(text: "Inactive", systemImage: "pause.circle", tone: .neutral)
                }
            }
            let contact = [supplier.contactName?.trimmedOrNil, supplier.email, supplier.phone].compactMap { $0 }
            Text(contact.isEmpty ? "No contact details yet" : contact.joined(separator: " · "))
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The shop's suppliers: who to ask for prices and stock, and where purchase orders go.
struct ShopSuppliersListView: View {
    @Environment(\.services) private var services
    @State private var state: LoadState<[ShopSupplier]> = .idle
    @State private var search = ""

    var body: some View {
        List {
            switch state {
            case .loaded(let all):
                let list = filtered(all)
                if all.isEmpty {
                    ContentUnavailableView("No suppliers yet", systemImage: "truck.box",
                                           description: Text("Suppliers you buy from appear here. Their price lists can update your prices too."))
                } else if list.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(list) { supplier in
                    NavigationLink {
                        ShopSupplierDetailView(summary: supplier) { saved in
                            if case .loaded(var rows) = state, let i = rows.firstIndex(where: { $0.uuid == saved.uuid }) {
                                rows[i] = saved
                                state = .loaded(rows)
                            }
                        }
                    } label: {
                        ShopSupplierRow(supplier: supplier)
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                EmptyView()
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .searchable(text: $search, prompt: "Name, contact, email or phone")
        .navigationTitle("Suppliers")
        .toolbar {
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func filtered(_ all: [ShopSupplier]) -> [ShopSupplier] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { s in
            [s.name, s.contactName, s.email, s.phone, s.accountNumber].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.shop.suppliers())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }
}

struct ShopSupplierDetailView: View {
    let summary: ShopSupplier
    var onChange: ((ShopSupplier) -> Void)?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var supplier: ShopSupplier?
    @State private var editing = false
    @State private var loadError: APIError?

    private var current: ShopSupplier { supplier ?? summary }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }

            Section {
                Text(current.name).font(.wsTitle3.bold())
                if let contact = current.contactName?.trimmedOrNil {
                    LabeledContent("Contact", value: contact)
                }
                if let email = current.email { EmailLinkRow(email: email) }
                if let phone = current.phone {
                    PhoneLinkRow(name: current.contactName?.trimmedOrNil ?? current.name, phone: phone)
                    if let whatsApp = ShopPhone.whatsApp(phone) {
                        Link(destination: whatsApp) { Label("Message on WhatsApp", systemImage: "message.circle") }
                            .frame(minHeight: 44)
                    }
                    if let sms = ShopPhone.sms(phone) {
                        Link(destination: sms) { Label("Send a text", systemImage: "message") }
                            .frame(minHeight: 44)
                    }
                }
                if current.email == nil && current.phone == nil {
                    Text("No email or phone yet: add them to ask for prices and stock from the app.")
                        .foregroundStyle(.secondaryText)
                }
                if session.shopPolicy.canUpdate {
                    Button {
                        editing = true
                    } label: {
                        Label("Edit contact details", systemImage: "square.and.pencil")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopSupplier.edit")
                }
            } footer: {
                Text("Price requests and stock enquiries greet the contact by name and go to this email or mobile.")
            }

            Section("Purchase orders") {
                DetailRow(label: "PO email", value: current.poEmail)
                DetailRow(label: "General email", value: current.contactEmail)
                DetailRow(label: "Our account number", value: current.accountNumber)
                DetailRow(label: "Address", value: current.poAddress)
                DetailRow(label: "Notes", value: current.poNotes)
            }

            Section {
                DetailRow(label: "Status", value: current.isActive ? "Active" : "Inactive")
                DetailRow(label: "Supplier portal", value: current.portalEnabled ? "On" : "Off")
                DetailRow(label: "Price list", value: current.feedUrl?.trimmedOrNil == nil ? "None" : (current.lastStatus.map(Formatters.humanize) ?? "Set up"))
                DetailRow(label: "Last updated", value: Formatters.dateTime(current.lastSyncedAt))
            } header: {
                Text("Price list")
            }
        }
        .navigationTitle("Supplier")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                ShopSupplierContactForm(supplier: current) { saved in
                    supplier = saved
                    onChange?(saved)
                }
            }
        }
    }

    private func load() async {
        do {
            supplier = try await services.shop.supplier(summary.uuid)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }
}

private struct ShopSupplierContactForm: View {
    let supplier: ShopSupplier
    let onSaved: (ShopSupplier) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var form: ShopSupplierContactUpdate
    @State private var saving = false
    @State private var error: APIError?

    init(supplier: ShopSupplier, onSaved: @escaping (ShopSupplier) -> Void) {
        self.supplier = supplier
        self.onSaved = onSaved
        _form = State(initialValue: ShopSupplierContactUpdate(
            name: supplier.name, contactName: supplier.contactName ?? "", contactEmail: supplier.contactEmail ?? "",
            poEmail: supplier.poEmail ?? "", poPhone: supplier.poPhone ?? "", poAddress: supplier.poAddress ?? "",
            accountNumber: supplier.accountNumber ?? "", poNotes: supplier.poNotes ?? ""))
    }

    var body: some View {
        Form {
            Section {
                TextField("Supplier name", text: $form.name)
                    .textContentType(.organizationName)
                TextField("Contact name, e.g. Sam", text: $form.contactName)
                    .textContentType(.name)
                    .accessibilityIdentifier("supplierForm.contactName")
            } footer: {
                Text("Messages start \"Hello \(form.contactName.trimmedOrNil ?? form.name.trimmedOrNil ?? "…")\".")
            }
            Section {
                TextField("Email for price requests and POs", text: $form.poEmail)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("supplierForm.poEmail")
                TextField("General email", text: $form.contactEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Mobile (WhatsApp and text)", text: $form.poPhone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityIdentifier("supplierForm.phone")
            } header: {
                Text("How to reach them")
            } footer: {
                if form.poPhone.trimmedOrNil != nil, ShopPhone.international(form.poPhone) == nil {
                    Text("That doesn't look like a phone number WhatsApp can use.")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
            Section("Purchase orders") {
                TextField("Our account number with them", text: $form.accountNumber)
                TextField("Address", text: $form.poAddress, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Notes", text: $form.poNotes, axis: .vertical)
                    .lineLimit(2...6)
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Contact details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || form.name.trimmedOrNil == nil)
                    .accessibilityIdentifier("supplierForm.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body = form
        body.name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved = try await services.shop.updateSupplierContact(supplier.uuid, body)
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
