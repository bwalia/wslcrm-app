import PhotosUI
import SwiftUI

/// Quick capture: a seller lead, a property, or both, from the doorstep — name and situation,
/// address from GPS, photos and a dictated note. Saved as one queued chain, so it works with no
/// signal and sends when the phone is back online.
struct PDQuickCaptureView: View {
    /// Tells Today what happened ("Sent" / "Saved on this phone").
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity

    @State private var draft = PDCaptureDraft()
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var showingCamera = false
    @State private var isLocating = false
    @State private var locationMessage: String?
    @State private var dictation = PDDictation()
    @State private var notesBeforeDictation = ""
    @State private var isSaving = false
    @State private var error: String?

    private var access: PDAccess? { session.propertyDeals }
    private var canCaptureLead: Bool { access?.can(.create, .deals) ?? false }
    private var canCaptureProperty: Bool { access?.can(.create, .properties) ?? false }

    var body: some View {
        NavigationStack {
            Form {
                whatSection
                if draft.includeLead && canCaptureLead { sellerSection }
                if draft.includeProperty && canCaptureProperty {
                    propertySection
                    photosSection
                }
                notesSection
                if let problem = draft.problem {
                    Section {
                        Label(problem, systemImage: "info.circle")
                            .foregroundStyle(.secondaryText)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("pd.capture.problem")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Tone.warning.textColor)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Quick capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { discardPhotosAndClose() }
                        .accessibilityIdentifier("pd.capture.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(draft.problem != nil || isSaving)
                        .accessibilityIdentifier("pd.capture.save")
                }
            }
            .onAppear {
                draft.includeLead = canCaptureLead
                draft.includeProperty = canCaptureProperty
            }
            .onChange(of: pickerItems) { _, items in Task { await addPicked(items) } }
            .onChange(of: dictation.transcript) { _, text in
                guard dictation.isListening || !text.isEmpty else { return }
                draft.notes = [notesBeforeDictation, text].filter { !$0.isEmpty }.joined(separator: notesBeforeDictation.isEmpty ? "" : "\n")
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCapture { image in
                    showingCamera = false
                    if let image { addPhoto(image) }
                }
                .ignoresSafeArea()
            }
            .interactiveDismissDisabled(isSaving || !draft.photoFiles.isEmpty || draft.hasLead)
        }
    }

    // MARK: Sections

    private var whatSection: some View {
        Section {
            if canCaptureLead {
                Toggle("Seller", isOn: $draft.includeLead)
                    .accessibilityIdentifier("pd.capture.includeLead")
            }
            if canCaptureProperty {
                Toggle("Property", isOn: $draft.includeProperty)
                    .accessibilityIdentifier("pd.capture.includeProperty")
            }
        } header: {
            Text("What are you capturing?")
        } footer: {
            if !connectivity.isOnline {
                Label("No signal: it's saved on this phone and sent when you're back online.", systemImage: "wifi.slash")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pd.capture.offline")
            }
        }
    }

    private var sellerSection: some View {
        Section("Seller") {
            TextField("First name", text: $draft.firstName)
                .textContentType(.givenName)
                .accessibilityIdentifier("pd.capture.firstName")
            TextField("Last name", text: $draft.lastName)
                .textContentType(.familyName)
                .accessibilityIdentifier("pd.capture.lastName")
            TextField("Phone", text: $draft.phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .accessibilityIdentifier("pd.capture.phone")
            TextField("Email", text: $draft.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Situation", selection: $draft.situation) {
                Text("Not known yet").tag(PDSituation?.none)
                ForEach(PDSituation.allCases) { Text($0.label).tag(PDSituation?.some($0)) }
            }
            .accessibilityIdentifier("pd.capture.situation")
            Toggle("They need to sell by a date", isOn: $hasDeadline)
                .onChange(of: hasDeadline) { _, on in draft.deadline = on ? deadline : nil }
            if hasDeadline {
                DatePicker("Sell by", selection: $deadline, in: Date()..., displayedComponents: .date)
                    .onChange(of: deadline) { _, value in draft.deadline = value }
            }
            Toggle("May be vulnerable", isOn: $draft.vulnerable)
                .accessibilityIdentifier("pd.capture.vulnerable")
            if draft.vulnerable {
                TextField("Why (e.g. recently bereaved)", text: $draft.vulnerabilityNote, axis: .vertical)
                    .accessibilityIdentifier("pd.capture.vulnerabilityNote")
            }
        }
    }

    private var propertySection: some View {
        Section {
            Button {
                Task { await useLocation() }
            } label: {
                if isLocating {
                    HStack { ProgressView(); Text("Finding the address…") }
                } else {
                    Label(draft.latitude == nil ? "Use my location" : "Update from my location", systemImage: "location.fill")
                }
            }
            .disabled(isLocating)
            .accessibilityIdentifier("pd.capture.useLocation")
            if let locationMessage {
                Text(locationMessage).font(.footnote).foregroundStyle(.secondaryText)
            }
            TextField("Address", text: $draft.addressLine1)
                .textContentType(.streetAddressLine1)
                .accessibilityIdentifier("pd.capture.address")
            TextField("Town", text: $draft.town)
                .textContentType(.addressCity)
                .accessibilityIdentifier("pd.capture.town")
            TextField("Postcode", text: $draft.postcode)
                .textContentType(.postalCode)
                .textInputAutocapitalization(.characters)
                .accessibilityIdentifier("pd.capture.postcode")
        } header: {
            Text("Property")
        } footer: {
            if let latitude = draft.latitude, let longitude = draft.longitude {
                Text("Pinned at \(latitude, specifier: "%.5f"), \(longitude, specifier: "%.5f").")
            }
        }
    }

    private var photosSection: some View {
        Section {
            if !draft.photoFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.photoFiles, id: \.self) { file in
                            ZStack(alignment: .topTrailing) {
                                if let image = thumbnails[file] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .accessibilityLabel("Property photo")
                                }
                                Button { removePhoto(file) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .accessibilityLabel("Remove photo")
                                .padding(4)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("pd.capture.photos")
            }
            HStack {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take photo", systemImage: "camera.fill") { showingCamera = true }
                        .buttonStyle(.bordered)
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains(UITestSupport.samplePhotoArgument) {
                    Button("Sample", systemImage: "photo") { addPhoto(UITestSupport.samplePhoto()) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pd.capture.samplePhoto")
                }
                #endif
            }
        } header: {
            Text("Photos (\(draft.photoFiles.count))")
        } footer: {
            Text("Kept on this phone until they've uploaded.")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("What did they tell you?", text: $draft.notes, axis: .vertical)
                .lineLimit(3...10)
                .accessibilityIdentifier("pd.capture.notes")
            Button {
                if !dictation.isListening { notesBeforeDictation = draft.notes }
                Task { await dictation.toggle() }
            } label: {
                Label(dictation.isListening ? "Stop dictating" : "Dictate a voice note",
                      systemImage: dictation.isListening ? "stop.circle.fill" : "mic.fill")
            }
            .accessibilityIdentifier("pd.capture.dictate")
            if case .unavailable(let reason) = dictation.state {
                Text(reason).font(.footnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("Speech is turned into text on this phone. The recording isn't kept or uploaded.")
        }
    }

    // MARK: Actions

    private func useLocation() async {
        isLocating = true
        defer { isLocating = false }
        guard let place = await PDPlaceFinder().currentPlace() else {
            locationMessage = "Couldn't get your location. Check Location access in Settings, or type the address."
            return
        }
        draft.latitude = place.latitude
        draft.longitude = place.longitude
        if let line = place.addressLine1 { draft.addressLine1 = line }
        if let town = place.town { draft.town = town }
        if let postcode = place.postcode { draft.postcode = postcode }
        locationMessage = place.addressLine1 == nil
            ? "Pinned your location. No address was found for it (that needs a signal); type it if you know it."
            : "Check the house number: GPS can be a few doors out."
    }

    private func addPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                addPhoto(image)
            }
        }
        pickerItems = []
    }

    private func addPhoto(_ image: UIImage) {
        guard let jpeg = JobPhotosModel.jpeg(from: image), let file = try? PendingUploads.store(jpeg, ext: "jpg") else {
            error = "Couldn't keep that photo on the phone. Is storage full?"
            return
        }
        draft.photoFiles.append(file)
        thumbnails[file] = image.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? image
    }

    private func removePhoto(_ file: String) {
        draft.photoFiles.removeAll { $0 == file }
        thumbnails[file] = nil
        try? FileManager.default.removeItem(at: PendingUploads.defaultDirectory().appendingPathComponent(file))
    }

    private func discardPhotosAndClose() {
        dictation.stop()
        for file in draft.photoFiles { removePhoto(file) }
        dismiss()
    }

    private func save() async {
        guard draft.problem == nil, let context = session.mutationContext else { return }
        dictation.stop()
        isSaving = true
        var toSave = draft
        if !canCaptureLead { toSave.includeLead = false }
        if !canCaptureProperty { toSave.includeProperty = false }
        await sync.enqueue(PropertyDealsAPI.Mutations.capture(toSave, context: context))
        onSaved(connectivity.isOnline
                ? "Captured \(toSave.summary). Sending now."
                : "Captured \(toSave.summary). Saved on this phone; it'll send when you're back online.")
        dismiss()
    }
}
