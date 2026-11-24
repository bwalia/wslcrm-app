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
    /// The first photo goes up with the proposal; the rest are tied to the new line afterwards.
    var photos: [UIImage] = []
    private(set) var submitting = false
    var error: APIError?

    @ObservationIgnored private let api: FieldServiceAPI

    init(jobUuid: String, visitUuid: String?, api: FieldServiceAPI) {
        self.jobUuid = jobUuid
        self.visitUuid = visitUuid
        self.api = api
    }

    var canSubmit: Bool {
        selected != nil && !photos.isEmpty && !reason.trimmingCharacters(in: .whitespaces).isEmpty
            && quantity > 0 && !submitting
    }

    /// What the line comes to, so the engineer sees the size of what they are proposing.
    var lineTotal: Decimal? {
        guard let price = selected?.unitPrice else { return nil }
        return price * quantity
    }

    /// Sends the proposal with its first photo (`POST /jobs/{uuid}/part-proposals`), then each other
    /// photo to `POST /jobs/{uuid}/photos` with the new line's `item_uuid`. Returns what to tell the
    /// engineer, or nil when the proposal itself failed (the error is shown on the sheet).
    func submit() async -> String? {
        guard let part = selected, let first = photos.first, let jpeg = JobPhotosModel.jpeg(from: first) else { return nil }
        submitting = true
        defer { submitting = false }
        let item: JobItem
        do {
            item = try await api.proposePart(jobUuid: jobUuid, partUuid: part.uuid, quantity: quantity,
                                             reason: reason, unitPrice: part.unitPrice, taxRate: part.taxRate,
                                             visitUuid: visitUuid, jpeg: jpeg)
        } catch {
            self.error = error.asAPIError
            return nil
        }
        var failed = 0
        for extra in photos.dropFirst() {
            guard let data = JobPhotosModel.jpeg(from: extra),
                  (try? await api.uploadPhoto(jobUuid: jobUuid, jpeg: data, visitUuid: visitUuid, caption: nil,
                                              itemUuid: item.uuid)) != nil else {
                failed += 1
                continue
            }
        }
        return Self.sentMessage(photos: photos.count, failed: failed)
    }

    nonisolated static func sentMessage(photos: Int, failed: Int) -> String {
        guard failed > 0 else { return "Part sent to the office for approval." }
        return "Part sent to the office for approval, but \(failed) of \(photos) photos didn't upload. "
            + "Add them again from Photos."
    }
}

struct PartProposalSheet: View {
    @Bindable var model: PartProposalModel
    /// Prices are a manager concern on the quote sheet, but a part's own price is on the shelf
    /// label; showing it here is what stops an engineer proposing a £900 compressor by accident.
    let currency: String?
    /// Called with what to tell the engineer once the proposal is in.
    let onProposed: (String) -> Void

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
                            .font(.wsSubheadline)
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
                    if let image { model.photos.append(image) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        model.photos.append(image)
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
                    Text(part.name).font(.wsHeadline)
                    if let subtitle = part.subtitle {
                        Text(subtitle).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let price = Formatters.money(part.unitPrice, currency: currency) {
                        Text("\(price) each, from the catalogue")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
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
            if !model.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.photos.enumerated()), id: \.offset) { index, photo in
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        model.photos.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.wsTitle3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove photo \(index + 1)")
                                }
                                .accessibilityLabel("Fault photo \(index + 1)")
                                .accessibilityIdentifier(index == 0 ? "partProposal.photo" : "partProposal.photo.\(index)")
                        }
                    }
                }
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(model.photos.isEmpty ? "Take photo of the fault" : "Take another photo", systemImage: "camera.fill") {
                    showingCamera = true
                }
                .accessibilityIdentifier("partProposal.takePhoto")
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(model.photos.isEmpty ? "Choose from library" : "Add from library", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("partProposal.libraryPhoto")
            #if DEBUG
            // A simulator has no camera and a UI test has no library worth driving, so test
            // runs get a generated photo. Debug-only: this is compiled out of Release.
            if ProcessInfo.processInfo.arguments.contains(UITestSupport.samplePhotoArgument) {
                Button("Use sample photo", systemImage: "photo") {
                    model.photos.append(UITestSupport.samplePhoto())
                }
                .accessibilityIdentifier("partProposal.samplePhoto")
            }
            #endif
        } header: {
            Text(model.photos.count > 1 ? "Evidence (\(model.photos.count) photos)" : "Evidence")
        } footer: {
            Text("At least one photo of the fault is needed — it is what the manager approves the part on. Add more to show it from other sides.")
        }
    }

    private func submit() {
        Task {
            if let message = await model.submit() {
                onProposed(message)
                dismiss()
            }
        }
    }
}
