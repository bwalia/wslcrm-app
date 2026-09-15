import SwiftUI

// Customer sites (opsapi #610 `SitePicker` + `/api/v2/field-service/sites`).
// A site is its own address under a customer; requests and jobs point at one.

/// Chooses a site for a customer, or creates one inline.
struct SitePickerRow: View {
    let customerUuid: String?
    @Binding var selection: FsSite?
    var canCreate = true

    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            LabeledContent {
                if let selection {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(selection.name).foregroundStyle(.primary)
                        if let address = selection.displayAddress {
                            Text(address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(customerUuid == nil ? "Choose a customer first" : "None").foregroundStyle(.secondary)
                }
            } label: {
                Label("Site", systemImage: "building.2")
            }
        }
        .disabled(customerUuid == nil)
        .accessibilityIdentifier("request.site")
        .sheet(isPresented: $picking) {
            if let customerUuid {
                SitePickerSheet(customerUuid: customerUuid, selection: $selection, canCreate: canCreate)
            }
        }
    }
}

private struct SitePickerSheet: View {
    let customerUuid: String
    @Binding var selection: FsSite?
    let canCreate: Bool
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[FsSite]> = .idle
    @State private var search = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if selection != nil {
                    Button("No site", role: .destructive) {
                        selection = nil
                        dismiss()
                    }
                }
                switch state {
                case .idle, .loading:
                    ProgressView()
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let sites):
                    if sites.isEmpty {
                        Text("This customer has no saved sites yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sites) { site in
                        Button {
                            selection = site
                            dismiss()
                        } label: {
                            SiteRow(site: site, selected: selection?.uuid == site.uuid)
                        }
                        .accessibilityIdentifier("site.row.\(site.name)")
                    }
                }
            }
            .searchable(text: $search, prompt: "Name, street, town or postcode")
            .navigationTitle("Choose site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if canCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New site", systemImage: "plus") { creating = true }
                            .accessibilityIdentifier("site.new")
                    }
                }
            }
            .task(id: search) {
                if case .loaded = state { try? await Task.sleep(for: .milliseconds(300)) }
                await load()
            }
            .sheet(isPresented: $creating) {
                SiteFormSheet(site: nil, customerUuid: customerUuid) { created in
                    selection = created
                    dismiss()
                }
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.fieldService.sites(customerUuid: customerUuid, search: search, perPage: 200).items)
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

struct SiteRow: View {
    let site: FsSite
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.fill")
                .frame(width: 36, height: 36)
                .background(Tone.info.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Tone.info.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(.headline).foregroundStyle(.primary)
                if let address = site.displayAddress { Text(address).font(.subheadline).foregroundStyle(.secondary) }
                Text([site.customerName, site.jobCount > 0 ? "\(site.jobCount) job\(site.jobCount == 1 ? "" : "s")" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Selected")
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

struct SiteFormSheet: View {
    let site: FsSite?
    let customerUuid: String?
    let onSaved: (FsSite) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var body_: SiteBody
    @State private var saving = false
    @State private var error: APIError?

    init(site: FsSite?, customerUuid: String?, onSaved: @escaping (FsSite) -> Void) {
        self.site = site
        self.customerUuid = customerUuid
        self.onSaved = onSaved
        _body_ = State(initialValue: SiteBody(customerUuid: customerUuid ?? site?.customerUuid, name: site?.name ?? "",
                                              addressLine1: site?.addressLine1, city: site?.city, postalCode: site?.postalCode,
                                              contactName: site?.contactName, contactPhone: site?.contactPhone,
                                              accessNotes: site?.accessNotes))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Site name, e.g. St Mary's — Ward 5", text: $body_.name)
                        .accessibilityIdentifier("site.name")
                    OptionalTextField("Street / building", text: $body_.addressLine1).textContentType(.streetAddressLine1)
                        .accessibilityIdentifier("site.address")
                    OptionalTextField("Town / city", text: $body_.city).textContentType(.addressCity)
                    OptionalTextField("Postcode", text: $body_.postalCode).textContentType(.postalCode)
                        .textInputAutocapitalization(.characters)
                }
                Section("On site") {
                    OptionalTextField("Contact name", text: $body_.contactName).textContentType(.name)
                    OptionalTextField("Contact phone", text: $body_.contactPhone).keyboardType(.phonePad)
                    TextField("Access notes — parking, keys, who to ask for", text: Binding(get: { body_.accessNotes ?? "" },
                                                                                          set: { body_.accessNotes = $0 }), axis: .vertical)
                        .lineLimit(2...5)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(site == nil ? "New site" : "Edit site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(body_.name.trimmingCharacters(in: .whitespaces).isEmpty || saving || (site == nil && body_.customerUuid == nil))
                        .accessibilityIdentifier("site.save")
                }
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let saved = if let site {
                    try await services.fieldService.updateSite(site.uuid, body_)
                } else {
                    try await services.fieldService.createSite(body_)
                }
                onSaved(saved)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

/// Browse every site in the workspace.
struct SitesListView: View {
    @Environment(\.services) private var services

    var body: some View {
        ModelHost(make: { [api = services.fieldService] in
            PagedListModel<FsSite> { search, page in try await api.sites(search: search, page: page, perPage: 50) }
        }) { model in
            PagedList(model: model, searchPrompt: "Name, street, town or postcode", emptyTitle: "No sites",
                      emptySystemImage: "building.2", emptyDescription: "Sites are added from a service request's customer.") { site in
                NavigationLink(value: SiteRoute(site: site)) {
                    SiteRow(site: site)
                }
            }
        }
        .navigationTitle("Sites")
    }
}

struct SiteDetailView: View {
    @State var site: FsSite
    var onChange: (FsSite) -> Void = { _ in }
    @Environment(SessionStore.self) private var session
    @State private var editing = false

    var body: some View {
        List {
            Section {
                Text(site.name).font(.title2.bold())
                if let customer = site.customerName { Label(customer, systemImage: "person") }
                if let address = site.displayAddress { MapsLinkRow(address: address) }
            }
            if site.contactName != nil || site.contactPhone != nil {
                Section("Contact on site") {
                    DetailRow(label: "Name", value: site.contactName)
                    if let phone = site.contactPhone { PhoneLinkRow(name: site.contactName, phone: phone) }
                }
            }
            if let notes = site.accessNotes, !notes.isEmpty {
                Section("Access notes") { Label(notes, systemImage: "key.fill") }
            }
            Section { DetailRow(label: "Jobs at this site", value: String(site.jobCount)) }
        }
        .navigationTitle("Site")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.permissions.can(.update, .fsServiceRequests) {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            SiteFormSheet(site: site, customerUuid: nil) { updated in
                site = updated
                onChange(updated)
            }
        }
    }
}
