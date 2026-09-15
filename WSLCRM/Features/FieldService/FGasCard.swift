import SwiftUI

/// F-Gas / refrigerant record for a visit (opsapi `FGasCard`). The on-site engineer logs it —
/// these fields are on the visit's engineer-editable allow-list.
struct FGasCard: View {
    let visit: Visit
    let canEdit: Bool
    let onSaved: (VisitDetail) -> Void

    @Environment(\.services) private var services
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("F-Gas / refrigerant", systemImage: "snowflake")
                    .font(.headline)
                Spacer()
                if canEdit {
                    Button(visit.hasFGasRecord ? "Edit" : "Log F-Gas") { editing = true }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("fgas.edit")
                }
            }
            if visit.hasFGasRecord {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        LabeledValue(label: "Type", value: visit.refrigerantType)
                        LabeledValue(label: "Cylinder", value: visit.fgasCylinderRef)
                    }
                    GridRow {
                        LabeledValue(label: "Charged", value: visit.refrigerantAddedKg.map { "\($0.formatted()) kg" })
                        LabeledValue(label: "Recovered", value: visit.refrigerantRecoveredKg.map { "\($0.formatted()) kg" })
                    }
                }
                if let result = visit.leakCheckResult, !result.isEmpty {
                    LeakCheckBadge(result: result)
                }
                if let notes = visit.leakCheckNotes, !notes.isEmpty {
                    Text(notes).font(.subheadline)
                }
            } else {
                Text("No refrigerant handled on this visit.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $editing) {
            FGasForm(visit: visit) { body in
                do {
                    let updated = try await services.fieldService.updateFGas(visitUuid: visit.uuid, body)
                    onSaved(updated)
                    return nil
                } catch {
                    return error.asAPIError
                }
            }
        }
    }
}

struct LeakCheckBadge: View {
    let result: String

    var body: some View {
        switch result {
        case "pass": StatusBadge(text: "Leak check passed", systemImage: "checkmark.shield.fill", tone: .success)
        case "fail": StatusBadge(text: "Leak check FAILED", systemImage: "exclamationmark.shield.fill", tone: .danger)
        default: StatusBadge(text: "No leak check", systemImage: "minus.circle", tone: .neutral)
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.body)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FGasForm: View {
    let visit: Visit
    let save: (FGasBody) async -> APIError?
    @Environment(\.dismiss) private var dismiss
    @State private var body_: FGasBody
    @State private var saving = false
    @State private var error: APIError?

    init(visit: Visit, save: @escaping (FGasBody) async -> APIError?) {
        self.visit = visit
        self.save = save
        _body_ = State(initialValue: FGasBody(
            refrigerantType: visit.refrigerantType ?? "",
            refrigerantAddedKg: visit.refrigerantAddedKg.map { "\($0)" } ?? "",
            refrigerantRecoveredKg: visit.refrigerantRecoveredKg.map { "\($0)" } ?? "",
            leakCheckResult: visit.leakCheckResult ?? "",
            fgasCylinderRef: visit.fgasCylinderRef ?? "",
            leakCheckNotes: visit.leakCheckNotes ?? ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Refrigerant") {
                    TextField("Type, e.g. R32", text: $body_.refrigerantType)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("fgas.type")
                    TextField("Cylinder ref", text: $body_.fgasCylinderRef)
                    TextField("Charged (kg)", text: $body_.refrigerantAddedKg).keyboardType(.decimalPad)
                    TextField("Recovered (kg)", text: $body_.refrigerantRecoveredKg).keyboardType(.decimalPad)
                }
                Section("Leak check") {
                    Picker("Result", selection: $body_.leakCheckResult) {
                        Text("Not recorded").tag("")
                        Text("Passed").tag("pass")
                        Text("Failed").tag("fail")
                        Text("Not applicable").tag("na")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    TextField("Notes", text: $body_.leakCheckNotes, axis: .vertical)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("F-Gas record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            error = await save(body_)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(saving || !isNumeric(body_.refrigerantAddedKg) || !isNumeric(body_.refrigerantRecoveredKg))
                    .accessibilityIdentifier("fgas.save")
                }
            }
        }
    }

    private func isNumeric(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) != nil
    }
}
