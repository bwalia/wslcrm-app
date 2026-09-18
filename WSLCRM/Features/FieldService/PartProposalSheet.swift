import PhotosUI
import SwiftUI
import UIKit

/// "Replace part" on site: pick the part from the namespace's catalogue, say what it is fixing,
/// photograph the fault, and send all three together (opsapi #619).
///
/// The engineer does not type a price and cannot invent a part: both come from the catalogue, so
/// what a manager later approves is the catalogue's arithmetic on a part that exists. The photo is
/// not optional here because it is not optional on the server — a proposal whose evidence fails to
/// upload is rolled back — and it is better to say so before the form is filled in.
@MainActor
@Observable
final class PartProposalModel: Identifiable {
    let id = UUID()
    let jobUuid: String
    let visitUuid: String?

    var selected: FsPart?
    var quantity: Decimal = 1
    var reason = ""
    var photo: UIImage?
    private(set) var submitting = false
    var error: APIError?

    @ObservationIgnored private let api: FieldServiceAPI

    init(jobUuid: String, visitUuid: String?, api: FieldServiceAPI) {
        self.jobUuid = jobUuid
        self.visitUuid = visitUuid
        self.api = api
    }

    var canSubmit: Bool {
        selected != nil && photo != nil && !reason.trimmingCharacters(in: .whitespaces).isEmpty
            && quantity > 0 && !submitting
    }

    /// What the line comes to, so the engineer sees the size of what they are proposing.
    var lineTotal: Decimal? {
        guard let price = selected?.unitPrice else { return nil }
        return price * quantity
    }

    func submit() async -> JobItem? {
        guard let part = selected, let photo, let jpeg = JobPhotosModel.jpeg(from: photo) else { return nil }
        submitting = true
        defer { submitting = false }
        do {
            return try await api.proposePart(jobUuid: jobUuid, partUuid: part.uuid, quantity: quantity,
                                             reason: reason, unitPrice: part.unitPrice, taxRate: part.taxRate,
                                             visitUuid: visitUuid, jpeg: jpeg)
        } catch {
            self.error = error.asAPIError
            return nil
        }
    }
}

struct PartProposalSheet: View {
    @Bindable var model: PartProposalModel
    /// Prices are a manager concern on the quote sheet, but a part's own price is on the shelf
    /// label; showing it here is what stops an engineer proposing a £900 compressor by accident.
    let currency: String?
    let onProposed: () -> Void

    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State private var pickingPart = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false

    var body: some View {
        NavigationStack {
            Form {
                if !connectivity.isOnline {
                    Section {
                        Label("You're offline. A part proposal travels with its photo, so this one needs a connection.",
                              systemImage: "wifi.slash")
                            .font(.subheadline)
                            .accessibilityIdentifier("partProposal.offline")
                    }
                }

                partSection
                detailSection
                photoSection

                if let error = model.error {
                    Section { InlineErrorRow(error: error) }
                }
            }
            .navigationTitle("Replace part")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Propose") { submit() }
                        .disabled(!model.canSubmit || !connectivity.isOnline)
                        .accessibilityIdentifier("partProposal.submit")
                }
            }
            .sheet(isPresented: $pickingPart) {
                PartPickerSheet { part in model.selected = part }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCapture { image in
                    showingCamera = false
                    if let image { model.photo = image }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        model.photo = image
                    }
                }
            }
        }
    }

    private var partSection: some View {
        Section {
            Button {
                pickingPart = true
            } label: {
                Label(model.selected == nil ? "Pick from the stock list" : "Pick a different part",
                      systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("partProposal.pickPart")

            if let part = model.selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.name).font(.headline)
                    if let subtitle = part.subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondaryText)
                    }
                    if let price = Formatters.money(part.unitPrice, currency: currency) {
                        Text("\(price) each, from the catalogue")
                            .font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    if part.isLowStock {
                        StatusBadge(text: "Low stock", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                }
                .accessibilityIdentifier("partProposal.selectedPart")
            }
        } header: {
            Text("Part")
        } footer: {
            if model.selected == nil {
                Text("Only parts in the workspace's catalogue can be fitted.")
            }
        }
    }

    private var detailSection: some View {
        Section("What you're fixing") {
            TextField("e.g. Condenser fan motor seized, unit tripping on high head", text: $model.reason, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("partProposal.reason")
            Stepper(value: $model.quantity, in: 1...99, step: 1) {
                Text("Quantity \(model.quantity.formatted())")
            }
            .accessibilityIdentifier("partProposal.quantity")
            if let total = Formatters.money(model.lineTotal, currency: currency) {
                LabeledContent("Line total", value: total)
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    private var photoSection: some View {
        Section {
            if let photo = model.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Fault photo")
                    .accessibilityIdentifier("partProposal.photo")
                Button("Retake", systemImage: "arrow.counterclockwise") { model.photo = nil }
            } else {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take photo of the fault", systemImage: "camera.fill") { showingCamera = true }
                        .accessibilityIdentifier("partProposal.takePhoto")
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("partProposal.libraryPhoto")
                #if DEBUG
                // A simulator has no camera and a UI test has no library worth driving, so test
                // runs get a generated photo. Debug-only: this is compiled out of Release.
                if ProcessInfo.processInfo.arguments.contains(UITestSupport.samplePhotoArgument) {
                    Button("Use sample photo", systemImage: "photo") {
                        model.photo = UITestSupport.samplePhoto()
                    }
                    .accessibilityIdentifier("partProposal.samplePhoto")
                }
                #endif
            }
        } header: {
            Text("Evidence")
        } footer: {
            Text("A photo of the fault is required — it is what the manager approves the part on.")
        }
    }

    private func submit() {
        Task {
            if await model.submit() != nil {
                onProposed()
                dismiss()
            }
        }
    }
}
