import SwiftUI

// Refunds from the app (`POST /api/v2/shop/admin/orders/{uuid}/refund`, shop.update): the whole order or
// the value of goods returned (pence ex VAT). A preview (`dry_run: true`) shows what goes back to the card
// after any VIP Trade discount clawback; confirming sends the refund through Stripe.

struct ShopRefundBody: Encodable, Sendable, Equatable {
    var full: Bool?
    var amountNetMinor: Int?
    var reason: String?
    var dryRun: Bool?

    static func of(full: Bool, returnedNet: String, reason: String, preview: Bool) -> ShopRefundBody {
        ShopRefundBody(full: full ? true : nil, amountNetMinor: full ? nil : ShopMoney.minor(from: returnedNet),
                       reason: reason.trimmedOrNil, dryRun: preview ? true : nil)
    }
}

/// What the server worked out (`ShopOrderQueries.adminRefund`).
struct ShopRefundResult: Decodable, Sendable, Equatable {
    var dryRun: Bool
    var full: Bool
    var refundMinor: Int
    var clawbackMinor: Int
    var clawbackGrossMinor: Int
    var returnedNetMinor: Int
    var refundedBeforeMinor: Int
    var stripeRefundId: String?

    enum CodingKeys: String, CodingKey {
        case dryRun, full, refundMinor, clawbackMinor, clawbackGrossMinor, returnedNetMinor, refundedBeforeMinor, stripeRefundId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dryRun = c.decodeFlexibleBool(forKey: .dryRun) ?? false
        full = c.decodeFlexibleBool(forKey: .full) ?? false
        refundMinor = c.decodeFlexibleInt(forKey: .refundMinor) ?? 0
        clawbackMinor = c.decodeFlexibleInt(forKey: .clawbackMinor) ?? 0
        clawbackGrossMinor = c.decodeFlexibleInt(forKey: .clawbackGrossMinor) ?? 0
        returnedNetMinor = c.decodeFlexibleInt(forKey: .returnedNetMinor) ?? 0
        refundedBeforeMinor = c.decodeFlexibleInt(forKey: .refundedBeforeMinor) ?? 0
        stripeRefundId = c.decodeFlexibleString(forKey: .stripeRefundId)?.trimmedOrNil
    }
}

extension ShopAPI {
    func refund(orderUuid: String, _ body: ShopRefundBody) async throws -> ShopRefundResult {
        let endpoint = Endpoint.post("/api/v2/shop/admin/orders/\(orderUuid)/refund", json: body)
        return try await client.send(endpoint, as: Envelope.Standard<ShopRefundResult>.self).data
    }
}

extension ShopOrderStatus {
    /// The statuses the server refunds (paid, processing, shipped, delivered).
    var isRefundable: Bool { [.paid, .processing, .shipped, .delivered].contains(self) }
}

struct ShopRefundSheet: View {
    let order: ShopOrder
    /// Called with what was refunded, after it went through.
    let onDone: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var full = true
    @State private var returnedNet = ""
    @State private var reason = ""
    @State private var preview: ShopRefundResult?
    @State private var working = false
    @State private var confirming = false
    @State private var error: APIError?

    private var money: (Int) -> String { { ShopMoney.format($0, currency: order.currency) ?? "" } }

    private var problem: String? {
        if !full {
            guard let minor = ShopMoney.minor(from: returnedNet), minor >= 1 else {
                return "Enter the value of the goods returned, before VAT, like 25.00"
            }
        }
        if reason.trimmingCharacters(in: .whitespaces).count < 3 { return "Say why (at least 3 letters)" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Refund", selection: $full) {
                        Text("Whole order").tag(true)
                        Text("Goods returned").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !full {
                        LabeledContent("Value returned (£ ex VAT)") {
                            TextField("0.00", text: $returnedNet).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("refund.amount")
                        }
                    }
                    TextField("Why (the customer sees nothing of this)", text: $reason, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("refund.reason")
                } footer: {
                    Text(full ? "Refunds what's left of \(money(order.totalMinor)) and marks the order refunded."
                         : "VAT is added, then any VIP Trade discount the order no longer qualifies for is taken off.")
                }
                if let preview { previewSection(preview) }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Refund \(order.orderNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: full) { preview = nil }
            .onChange(of: returnedNet) { preview = nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if preview == nil {
                        Button("Check") { Task { await check() } }
                            .disabled(working || problem != nil)
                            .accessibilityIdentifier("refund.check")
                    } else {
                        Button("Refund") { confirming = true }
                            .disabled(working || problem != nil || (preview?.refundMinor ?? 0) <= 0 && !full)
                            .accessibilityIdentifier("refund.confirm")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem, !reason.isEmpty || !returnedNet.isEmpty {
                    Text(problem).font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .confirmationDialog("Refund \(money(preview?.refundMinor ?? 0)) to the customer's card?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Refund \(money(preview?.refundMinor ?? 0))", role: .destructive) { Task { await refund() } }
            } message: {
                Text("The money goes back through Stripe. This can't be undone.")
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func previewSection(_ p: ShopRefundResult) -> some View {
        Section {
            if p.returnedNetMinor > 0 { LabeledContent("Goods returned (ex VAT)", value: money(p.returnedNetMinor)) }
            if p.clawbackGrossMinor > 0 {
                LabeledContent("VIP Trade discount taken back", value: "−" + money(p.clawbackGrossMinor))
            }
            if p.refundedBeforeMinor > 0 { LabeledContent("Already refunded", value: money(p.refundedBeforeMinor)) }
            LabeledContent("Back to the customer", value: money(p.refundMinor)).font(.wsHeadline)
        } header: {
            Text("What happens")
        } footer: {
            Text(p.refundMinor > 0 ? "Tap Refund to send it." : "Nothing would be paid back after the discount clawback.")
        }
    }

    private func check() async {
        working = true
        defer { working = false }
        do {
            preview = try await services.shop.refund(orderUuid: order.uuid,
                                                     .of(full: full, returnedNet: returnedNet, reason: reason, preview: true))
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func refund() async {
        working = true
        defer { working = false }
        do {
            let done = try await services.shop.refund(orderUuid: order.uuid,
                                                      .of(full: full, returnedNet: returnedNet, reason: reason, preview: false))
            await onDone("Refunded \(money(done.refundMinor)) to the customer's card"
                         + (full ? " and marked the order refunded." : "."))
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
