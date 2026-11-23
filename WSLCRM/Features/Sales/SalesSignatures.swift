import SwiftUI

// The customer signs on screen when a store order is handed over (`/api/v2/orders/:uuid/signature`, RBAC
// orders.read / orders.update) or a delivery partner delivers (`PUT /api/v2/delivery-assignments/:uuid/status`
// with `signature` + `signer_name`). Same shapes as the shop's signature (`ShopOrderSignatureState`).

/// `POST /api/v2/orders/:uuid/signature`.
struct StoreOrderSignatureBody: Encodable, Sendable, Equatable {
    var signerName: String
    /// A PNG data URL.
    var image: String
    var note: String?
    /// Also marks the order handed over (fulfilled), in the same step.
    var markHandedOver: Bool?
}

extension SalesAPI {
    func storeOrderSignature(_ uuid: String) async throws -> ShopOrderSignatureState {
        try await client.send(.get("/api/v2/orders/\(uuid)/signature"), as: Envelope.Standard<ShopOrderSignatureState>.self).data
    }

    func storeOrderSignatureImage(_ uuid: String) async throws -> Data {
        try await client.sendRaw(.get("/api/v2/orders/\(uuid)/signature/image")).0
    }

    func signStoreOrder(_ uuid: String, _ body: StoreOrderSignatureBody) async throws -> ShopOrderSignatureState {
        try await client.send(.post("/api/v2/orders/\(uuid)/signature", json: body),
                              as: Envelope.Standard<ShopOrderSignatureState>.self).data
    }

    func voidStoreOrderSignature(_ uuid: String, reason: String) async throws {
        struct Body: Encodable, Sendable { let reason: String }
        try await client.sendDiscardingBody(.post("/api/v2/orders/\(uuid)/signature/void", json: Body(reason: reason)))
    }
}

/// What the person signing gave: their name, the signature (PNG data URL) and a note.
struct SignatureCapture: Sendable, Equatable {
    var signerName: String
    var image: String
    var note: String?

    /// The server's rules: a name of 2 letters or more and a PNG under 300 KB.
    static func problem(name: String, png: Data?) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { return "Type the name of the person signing." }
        guard let png, !png.isEmpty else { return "Couldn't read the signature. Clear it and sign again." }
        if png.count > 300 * 1024 { return "The signature is too large. Clear it and sign a little smaller." }
        return nil
    }
}

/// Full-screen signing: the customer's name, their signature with a finger, an optional note.
struct SignatureCaptureSheet: View {
    let title: String
    let summary: String
    let action: String
    let save: (SignatureCapture) async -> APIError?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var padSize: CGSize = .zero
    @State private var saving = false
    @State private var error: APIError?
    @State private var problem: String?

    init(title: String, summary: String, signer: String?, action: String,
         save: @escaping (SignatureCapture) async -> APIError?) {
        self.title = title
        self.summary = summary
        self.action = action
        self.save = save
        _name = State(initialValue: signer ?? "")
    }

    private var hasSignature: Bool { strokes.contains { !$0.isEmpty } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(summary).font(.wsSubheadline).foregroundStyle(.secondaryText)
                TextField("Name of the person signing", text: $name)
                    .textContentType(.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("salesSignature.name")
                ZStack(alignment: .bottomLeading) {
                    SignaturePad(strokes: $strokes)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { padSize = $0 }
                        .frame(height: 220)
                    if !hasSignature {
                        Text("Sign here").font(.wsTitle3).foregroundStyle(.gray).padding(14).allowsHitTesting(false)
                    }
                }
                Button("Clear") { strokes = [] }.disabled(!hasSignature || saving)
                TextField("Note (optional), e.g. left with reception", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                if let problem { Text(problem).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
                if let error { InlineErrorRow(error: error) }
                Spacer(minLength: 0)
                Button {
                    Task { await submit() }
                } label: {
                    if saving { ProgressView() } else { Label(action, systemImage: "checkmark") }
                }
                .buttonStyle(.large(.progress, prominent: true))
                .disabled(saving || !hasSignature || name.trimmingCharacters(in: .whitespaces).count < 2)
                .accessibilityIdentifier("salesSignature.save")
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
        }
    }

    private func submit() async {
        let png = SignaturePad.png(strokes: strokes, size: padSize)
        problem = SignatureCapture.problem(name: name, png: png)
        guard problem == nil, let png else { return }
        saving = true
        defer { saving = false }
        error = await save(SignatureCapture(signerName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                            image: "data:image/png;base64," + png.base64EncodedString(),
                                            note: note.trimmedOrNil))
        if error == nil { dismiss() }
    }
}

/// A signature on record: the picture, who signed, when, who took it.
struct SignatureProofRows: View {
    let signature: ShopOrderSignature
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Signature of \(signature.signerName)")
        }
        DetailRow(label: "Signed by", value: signature.signerName)
        DetailRow(label: "When", value: Formatters.dateTime(signature.signedAt))
        DetailRow(label: "Taken by", value: signature.capturedBy)
        DetailRow(label: "Note", value: signature.note)
    }
}

/// "Proof of delivery" on a store order: the signature, or the way to take one; void a wrong one.
/// The parent loads `state`/`image` (a section that shows nothing can't load itself).
struct StoreOrderSignatureSection: View {
    let state: ShopOrderSignatureState?
    let image: UIImage?
    let canUpdate: Bool
    let sign: () -> Void
    let void: (String) async -> Void
    @State private var voiding = false
    @State private var reason = ""

    var body: some View {
        if let state {
            Section {
                if let signature = state.signature {
                    SignatureProofRows(signature: signature, image: image)
                    if canUpdate {
                        Button("Void this signature", role: .destructive) { voiding = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("storeOrder.voidSignature")
                    }
                } else if state.canSign && canUpdate {
                    Button(action: sign) { Label("Customer signs", systemImage: "signature") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("storeOrder.signOnly")
                } else {
                    Text("Not signed for.").foregroundStyle(.secondaryText)
                }
            } header: {
                Text("Proof of delivery")
                    // On the header (one view): on the Section it would be copied onto every row.
                    .alert("Void this signature?", isPresented: $voiding) {
                        TextField("Why (e.g. wrong person signed)", text: $reason)
                        Button("Void", role: .destructive) {
                            let why = reason
                            reason = ""
                            Task { await void(why) }
                        }
                        .disabled(reason.trimmingCharacters(in: .whitespaces).count < 3)
                        Button("Cancel", role: .cancel) { reason = "" }
                    } message: {
                        Text("It's kept for the record. A new signature can then be taken.")
                    }
            }
        }
    }
}
