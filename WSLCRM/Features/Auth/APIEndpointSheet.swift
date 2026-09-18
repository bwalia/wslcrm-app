import SwiftUI

/// Point the app at another environment without a rebuild. Reached from the gear on the
/// sign-in screen, because that is the only moment it is safe to change: switching servers
/// ends whatever session is open.
struct APIEndpointSheet: View {
    @Environment(APIEndpointController.self) private var endpoint
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://int-opsapi.workstation.co.uk", text: $text)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(apply)
                        .accessibilityIdentifier("endpoint.field")
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("endpoint.error")
                    }
                } header: {
                    Text("API address")
                } footer: {
                    Text("Signing in, syncing and every screen talk to this server. Changing it signs you out.")
                }

                Section("Currently") {
                    LabeledContent("In use", value: endpoint.current.absoluteString)
                        .accessibilityIdentifier("endpoint.current")
                    LabeledContent("This build ships with", value: endpoint.buildDefault.absoluteString)
                }

                if endpoint.isOverridden {
                    Section {
                        Button("Use this build's default") {
                            apply(url: endpoint.buildDefault)
                        }
                        .accessibilityIdentifier("endpoint.useDefault")
                    }
                }
            }
            .navigationTitle("Environment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: apply)
                        .disabled(isApplying || text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("endpoint.save")
                }
            }
            .onAppear { if text.isEmpty { text = endpoint.current.absoluteString } }
        }
    }

    private func apply() {
        do {
            apply(url: try APIEndpoint.validate(text))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "That address cannot be used."
        }
    }

    private func apply(url: URL) {
        error = nil
        isApplying = true
        Task {
            await endpoint.use(url)
            isApplying = false
            dismiss()
        }
    }
}
