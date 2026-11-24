import SwiftUI
import UIKit

/// The customer signs for the visit with a finger: their name and the signature, handed back to the
/// finish sheet as a PNG (sent with the check-out as `customer_signature`).
struct VisitSignaturePadSheet: View {
    let onSigned: (String, Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var strokes: [[CGPoint]] = []
    @State private var padSize: CGSize = .zero
    @State private var problem: String?

    init(name: String, onSigned: @escaping (String, Data) -> Void) {
        self.onSigned = onSigned
        _name = State(initialValue: name)
    }

    private var hasSignature: Bool { strokes.contains { !$0.isEmpty } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Hand the phone to the customer to sign for the work.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                TextField("Name of the person signing", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("visitSignature.name")
                ZStack(alignment: .bottomLeading) {
                    SignaturePad(strokes: $strokes)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { padSize = $0 }
                        .frame(height: 240)
                        .accessibilityIdentifier("visitSignature.pad")
                    if !hasSignature {
                        Text("Sign here")
                            .font(.wsTitle3)
                            .foregroundStyle(.gray)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
                Button("Clear") { strokes = [] }
                    .disabled(!hasSignature)
                if let problem { Text(problem).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
                Spacer(minLength: 0)
                Button {
                    use()
                } label: {
                    Label("Use this signature", systemImage: "checkmark")
                }
                .buttonStyle(.large(.success))
                .disabled(!hasSignature || trimmedName.count < 2)
                .accessibilityIdentifier("visitSignature.use")
            }
            .padding()
            .navigationTitle("Customer signs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func use() {
        guard let png = SignaturePad.png(strokes: strokes, size: padSize) else {
            problem = "Couldn't read the signature. Clear it and sign again."
            return
        }
        guard png.count <= CheckOutForm.maxSignatureBytes else {
            problem = "The signature is too large. Clear it and sign again."
            return
        }
        onSigned(trimmedName, png)
        dismiss()
    }
}

/// Who signed for a visit and when, with the signature (`GET /visits/:uuid/signature` and `/image`).
struct VisitSignatureCard: View {
    let visitUuid: String
    @Environment(\.services) private var services
    @State private var signature: VisitSignatureStatus.Signature?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Self.caption(signature), systemImage: "signature")
                .font(.wsSubheadline.weight(.semibold))
                .foregroundStyle(Tone.success.textColor)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 100)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("The customer's signature")
            } else if failed {
                Text("The signature couldn't be shown right now.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityIdentifier("visit.signature")
        .task(id: visitUuid) { await load() }
    }

    /// "Signed by Ann Lee · 24 Nov 2026 at 10:15".
    static func caption(_ signature: VisitSignatureStatus.Signature?) -> String {
        guard let signature else { return "Signed by the customer" }
        let who = signature.signerName.map { "Signed by \($0)" } ?? "Signed by the customer"
        return [who, Formatters.dateTime(signature.signedAt)].compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        let api = services.fieldService
        do {
            signature = try await api.visitSignature(visitUuid).signature
            image = UIImage(data: try await api.visitSignatureImage(visitUuid))
        } catch {
            if case .cancelled = error.asAPIError { return }
            failed = true
        }
    }
}
