import SwiftUI

/// The job form (`POST /jobs`, `PUT /jobs/:uuid`), as on the web: the site is chosen from the
/// customer's own sites (or a new one), changing the customer clears it, and choosing a site fills
/// the service address and postcode. Every other field is the kit's (`ModuleCatalog.fsJobs`).
struct JobFormView: View {
    let existing: Record?
    let onSaved: (Record?) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: JobFormState
    @State private var problems: [String: String] = [:]
    @State private var error: APIError?
    @State private var saving = false

    private static let descriptor = ModuleCatalog.fsJobs

    init(existing: Record?, onSaved: @escaping (Record?) -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        _form = State(initialValue: JobFormState(fields: Self.descriptor.form?.fields ?? [], record: existing))
    }

    var body: some View {
        Form {
            if let error {
                Section { InlineErrorRow(error: error) }
            }
            ForEach(Self.descriptor.form?.sections ?? []) { section in
                let editable = section.fields.filter { !$0.readOnly && $0.kind.isEditable }
                if !editable.isEmpty {
                    Section {
                        ForEach(editable) { field in
                            if field.key == JobFormState.siteKey {
                                SitePickerRow(customerUuid: form.customerUuid, selection: siteBinding,
                                              canCreate: session.permissions.can(.update, .fsServiceRequests))
                            } else {
                                FieldEditor(field: field, value: binding(for: field), problem: problems[field.key])
                            }
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    } footer: {
                        if section.fields.contains(where: { $0.key == JobFormState.siteKey }) {
                            Text("Choosing a site fills in the service address. Change the customer and the site is cleared.")
                        }
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? "New job" : "Edit job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("resource.save")
            }
        }
        .interactiveDismissDisabled(saving || form.values != form.original)
    }

    private var siteBinding: Binding<FsSite?> {
        Binding(get: { form.site }, set: { form.choose($0) })
    }

    private func binding(for field: FieldSpec) -> Binding<FormValue> {
        Binding(get: { form.values[field.key] ?? FormCoding.initialValue(field, record: existing) },
                set: { value in
                    form.set(field.key, value)
                    problems[field.key] = nil
                })
    }

    private func save() async {
        let fields = (Self.descriptor.form?.fields ?? []).filter(\.kind.isEditable)
        var found: [String: String] = [:]
        for field in fields {
            if let problem = FormCoding.problem(field, form.values[field.key] ?? .text("")) { found[field.key] = problem }
        }
        problems = found
        guard found.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let saved = try await services.resources.save(Self.descriptor, existing: existing, values: form.body(isNew: existing == nil))
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// What the job form holds, kept apart from the view so the site rules are unit-tested.
struct JobFormState: Equatable {
    static let customerKey = "customer_uuid"
    static let siteKey = "site_uuid"

    let fields: [FieldSpec]
    private(set) var values: [String: FormValue] = [:]
    private(set) var original: [String: FormValue] = [:]
    private(set) var site: FsSite?

    init(fields: [FieldSpec], record: Record?) {
        self.fields = fields
        for field in fields { values[field.key] = FormCoding.initialValue(field, record: record) }
        original = values
        if let uuid = record?.string(Self.siteKey) {
            site = FsSite(uuid: uuid, customerUuid: record?.string(Self.customerKey),
                          name: record?.string("site_name") ?? "Site", jobCount: 0)
        }
    }

    var customerUuid: String? {
        if case .picked(let value, _)? = values[Self.customerKey], !value.isEmpty { return value }
        return nil
    }

    /// Changing the customer clears a site that belonged to the old one.
    mutating func set(_ key: String, _ value: FormValue) {
        let before = customerUuid
        values[key] = value
        if key == Self.customerKey, customerUuid != before, site != nil {
            choose(nil)
        }
    }

    /// The chosen site, and its address as the job's service address (as the web's `siteToAddress`).
    mutating func choose(_ chosen: FsSite?) {
        site = chosen
        values[Self.siteKey] = .picked(value: chosen?.uuid ?? "", label: chosen?.name ?? "")
        guard let chosen else { return }
        let address = [chosen.addressLine1, chosen.addressLine2, chosen.city, chosen.county]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        values["service_address"] = .text(address)
        values["service_postcode"] = .text(chosen.postalCode ?? "")
    }

    func body(isNew: Bool) -> [String: JSONValue] {
        FormCoding.body(fields: fields.filter(\.kind.isEditable), values: values, original: original, isNew: isNew,
                        sendOnlyChanges: true)
    }
}
