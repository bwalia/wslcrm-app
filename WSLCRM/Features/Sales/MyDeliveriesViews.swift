import SwiftUI

// "My deliveries" for delivery partners (lapis/routes/delivery-assignments.lua): the jobs assigned to the
// signed-in person's delivery-partner profile, no workspace needed. Each step moves the delivery on
// (`PUT /api/v2/delivery-assignments/:uuid/status`); "delivered" takes the customer's signature.
// A person without a partner profile gets 404 from the list, so the entry shows only when it works.

/// `PUT /api/v2/delivery-assignments/:uuid/status` (JSON; the route reads JSON or a form).
struct DeliveryStatusBody: Encodable, Sendable, Equatable {
    var status: String
    var notes: String?
    /// PNG data URL; only with `status = delivered`.
    var signature: String?
    var signerName: String?
}

/// The partner's next steps at each status (the route's state machine, partner side).
enum MyDeliverySteps {
    struct Step: Equatable, Sendable {
        let status: String
        let title: String
        let done: String
        let destructive: Bool
        /// Delivered with the customer's signature.
        let signs: Bool
    }

    static func next(from status: String) -> [Step] {
        switch status {
        case "pending":
            [Step(status: "accepted", title: "Accept the delivery", done: "Accepted. Pick it up from the store next.",
                  destructive: false, signs: false),
             Step(status: "rejected", title: "Decline", done: "Declined. The store has been told.", destructive: true, signs: false)]
        case "accepted":
            [Step(status: "picked_up", title: "I've picked it up", done: "Marked picked up. Set off when you're ready.",
                  destructive: false, signs: false),
             Step(status: "cancelled", title: "Cancel the delivery", done: "Delivery cancelled.", destructive: true, signs: false)]
        case "picked_up":
            [Step(status: "in_transit", title: "On my way", done: "Marked on the way. The customer can expect it soon.",
                  destructive: false, signs: false),
             Step(status: "cancelled", title: "Cancel the delivery", done: "Delivery cancelled.", destructive: true, signs: false)]
        case "in_transit":
            [Step(status: "delivered", title: "Customer signs and delivered", done: "Delivered and signed for.",
                  destructive: false, signs: true),
             Step(status: "delivered", title: "Delivered without a signature", done: "Marked delivered.",
                  destructive: false, signs: false),
             Step(status: "failed", title: "Couldn't deliver", done: "Marked as not delivered. The store has been told.",
                  destructive: true, signs: false)]
        default: []
        }
    }

    static let active = ["pending", "accepted", "picked_up", "in_transit"]
}

extension DeliveryAPI {
    private func partnerGet(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        var endpoint = Endpoint.get(path, query: query)
        endpoint.requiresNamespace = false
        let (data, _) = try await client.sendRaw(endpoint)
        return try ResourceService.decode(data)
    }

    /// The partner's deliveries (the latest 20). `status`: active | completed | a status. 404 = not a partner.
    func myAssignments(status: String) async throws -> [Record] {
        Self.rows(try await partnerGet("/api/v2/delivery-partner/assignments", query: [URLQueryItem(name: "status", value: status)]),
                  "assignments")
    }

    func myAssignment(_ uuid: String) async throws -> Record {
        guard let record = Self.record(try await partnerGet("/api/v2/delivery-assignments/\(Self.path(uuid))"), "assignment") else {
            throw ResourceService.problem(404, "That delivery wasn’t found.")
        }
        return record
    }

    /// Moves the delivery on; returns the server's message.
    @discardableResult
    func moveMyAssignment(_ uuid: String, _ body: DeliveryStatusBody) async throws -> String? {
        var endpoint = Endpoint.put("/api/v2/delivery-assignments/\(Self.path(uuid))/status", json: body)
        endpoint.requiresNamespace = false
        let (data, _) = try await client.sendRaw(endpoint)
        return (try? ResourceService.decode(data))?["message"]?.stringValue
    }

    /// The customer's signature on a delivery (the partner or the store owner).
    func assignmentSignature(_ uuid: String) async throws -> ShopOrderSignatureState {
        var endpoint = Endpoint.get("/api/v2/delivery-assignments/\(Self.path(uuid))/signature")
        endpoint.requiresNamespace = false
        return try await client.send(endpoint, as: Envelope.Standard<ShopOrderSignatureState>.self).data
    }

    func assignmentSignatureImage(_ uuid: String) async throws -> Data {
        var endpoint = Endpoint.get("/api/v2/delivery-assignments/\(Self.path(uuid))/signature/image")
        endpoint.requiresNamespace = false
        return try await client.sendRaw(endpoint).0
    }
}

/// Whether the signed-in person is a delivery partner (the list answers; 404 otherwise). A screen that wants
/// a "My deliveries" entry (Home, Apps, Delivery) checks this from its own `.task` and shows
/// `NavigationLink(value: NativeScreenRoute(SalesScreen.myDeliveries))` when true.
enum MyDeliveries {
    @MainActor
    static func isPartner(_ services: Services) async -> Bool {
        (try? await services.delivery.myAssignments(status: "active")) != nil
    }

    static var entryLabel: some View { Label("My deliveries", systemImage: "truck.box.badge.clock") }
}

struct MyDeliveriesView: View {
    @Environment(\.services) private var services
    @State private var show = "active"
    @State private var state: LoadState<[Record]> = .idle

    var body: some View {
        List {
            switch state {
            case .idle, .loading:
                Section { SkeletonRow() }
            case .failed(let error):
                Section {
                    InlineErrorRow(error: error) { Task { await load() } }
                } footer: {
                    Text(error.serverError?.status == 404
                         ? "This is for delivery partners. Your account isn't set up as one."
                         : "Pull down to try again.")
                }
            case .loaded(let rows):
                if rows.isEmpty {
                    ContentUnavailableView(show == "active" ? "No deliveries to do" : "Nothing delivered yet",
                                           systemImage: "truck.box",
                                           description: Text(show == "active"
                                                             ? "Deliveries a store gives you show here."
                                                             : "Finished deliveries show here."))
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            MyDeliveryDetailView(uuid: row.id) { Task { await load() } }
                        } label: {
                            MyDeliveryRow(row: row)
                        }
                        .accessibilityIdentifier("myDelivery.row.\(row.id)")
                    }
                } footer: {
                    if rows.count >= 20 { Text("Showing the latest 20.") }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $show) {
                Text("To do").tag("active")
                Text("Done").tag("completed")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("myDeliveries.show")
        }
        .navigationTitle("My deliveries")
        .task(id: show) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.delivery.myAssignments(status: show))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

private struct MyDeliveryRow: View {
    let row: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.string("order_number") ?? "Delivery").font(.wsHeadline.monospacedDigit())
                Spacer()
                DeliveryWords.badge(DeliveryWords.assignmentStatus, row.string("status") ?? "pending")
            }
            if let place = MyDeliveryDetailView.address(row) {
                Label(place, systemImage: "mappin").font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Text([row.string("customer_name"), row.string("store_name").map { "from \($0)" },
                  DeliveryWords.money(row, "delivery_fee", currency: nil).map { "fee \($0)" }]
                .compactMap { $0?.trimmedOrNil }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct MyDeliveryDetailView: View {
    let uuid: String
    var onChange: () -> Void = {}
    @Environment(\.services) private var services
    @State private var state: LoadState<Record> = .idle
    @State private var proof: ShopOrderSignatureState?
    @State private var proofImage: UIImage?
    @State private var confirming: MyDeliverySteps.Step?
    @State private var signing: MyDeliverySteps.Step?
    @State private var notes = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var error: APIError?

    /// "1 High St, Leeds, LS1 1AA".
    static func address(_ a: Record) -> String? {
        [a.string("delivery_address"), a.string("delivery_city"), a.string("delivery_postal_code")]
            .compactMap { $0?.trimmedOrNil }.joined(separator: ", ").trimmedOrNil
    }

    var body: some View {
        List {
            switch state {
            case .idle, .loading: Section { SkeletonRow() }
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let a): content(a)
            }
        }
        .disabled(busy)
        .navigationTitle(state.value?.string("order_number") ?? "Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(confirming?.title ?? "", isPresented: .init(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            TextField("Note (optional)", text: $notes)
            Button(confirming?.title ?? "OK", role: confirming?.destructive == true ? .destructive : nil) {
                if let step = confirming { Task { await move(step, capture: nil) } }
            }
            Button("Not now", role: .cancel) {}
        }
        .fullScreenCover(item: Binding(get: { signing.map(SigningStep.init) }, set: { signing = $0?.step })) { item in
            SignatureCaptureSheet(title: "Customer signs", summary: state.value?.string("order_number") ?? "Delivery",
                                  signer: state.value?.string("customer_name"), action: "Save and mark delivered") { capture in
                await move(item.step, capture: capture)
            }
        }
    }

    private struct SigningStep: Identifiable {
        let step: MyDeliverySteps.Step
        var id: String { step.title }
    }

    @ViewBuilder
    private func content(_ a: Record) -> some View {
        let status = a.string("status") ?? "pending"
        Section {
            VStack(alignment: .leading, spacing: 8) {
                DeliveryWords.badge(DeliveryWords.assignmentStatus, status)
                Text(a.string("order_number") ?? "Delivery").font(.wsTitle3.monospacedDigit().weight(.semibold))
                DetailRow(label: "Your fee", value: DeliveryWords.money(a, "delivery_fee", currency: nil))
                DetailRow(label: "Order total", value: DeliveryWords.money(a, "total_amount", currency: nil))
            }
            .padding(.vertical, 4)
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            if let error { InlineErrorRow(error: error) }
        }
        let steps = MyDeliverySteps.next(from: status)
        if !steps.isEmpty {
            Section("Next step") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Button {
                        notes = ""
                        if step.signs { signing = step } else { confirming = step }
                    } label: {
                        Label(step.title, systemImage: step.signs ? "signature"
                              : DeliveryWords.assignmentStatus.symbol(for: step.status))
                    }
                    .buttonStyle(.large(step.destructive ? .danger : .progress, prominent: index == 0))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("myDelivery.step.\(index)")
                }
            }
        }
        Section("Customer") {
            DetailRow(label: "Name", value: a.string("customer_name")?.trimmedOrNil
                      ?? [a.string("customer_first_name"), a.string("customer_last_name")].compactMap { $0 }.joined(separator: " ").trimmedOrNil)
            if let phone = a.string("customer_phone") { PhoneLinkRow(name: a.string("customer_name"), phone: phone) }
            if let address = Self.address(a) { MapsLinkRow(address: address) }
            DetailRow(label: "Their note", value: a.string("customer_notes"))
            DetailRow(label: "Delivery instructions", value: a.string("delivery_instructions"))
        }
        Section("Pick up from") {
            DetailRow(label: "Store", value: a.string("store_name"))
            if let phone = a.string("store_phone") { PhoneLinkRow(name: a.string("store_name"), phone: phone) }
            if let pickup = a.string("pickup_address")?.trimmedOrNil { MapsLinkRow(address: pickup) }
            DetailRow(label: "Pick-up instructions", value: a.string("pickup_instructions"))
        }
        if let proof, let signature = proof.signature {
            Section("Proof of delivery") { SignatureProofRows(signature: signature, image: proofImage) }
        } else if let text = a.string("proof_of_delivery")?.trimmedOrNil {
            Section("Proof of delivery") { Text(text) }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let a = try await services.delivery.myAssignment(uuid)
            state = .loaded(a)
            proof = try? await services.delivery.assignmentSignature(uuid)
            proofImage = nil
            if proof?.signature != nil, let data = try? await services.delivery.assignmentSignatureImage(uuid) {
                proofImage = UIImage(data: data)
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { self.error = apiError }
        }
    }

    /// Runs a step; with a capture the customer's signature goes with "delivered".
    @discardableResult
    private func move(_ step: MyDeliverySteps.Step, capture: SignatureCapture?) async -> APIError? {
        busy = true
        defer { busy = false }
        let body = DeliveryStatusBody(status: step.status, notes: (capture?.note ?? notes).trimmedOrNil,
                                      signature: capture?.image, signerName: capture?.signerName)
        do {
            try await services.delivery.moveMyAssignment(uuid, body)
            error = nil
            notice = capture.map { "Delivered and signed for by \($0.signerName)." } ?? step.done
            await load()
            onChange()
            return nil
        } catch {
            let apiError = error.asAPIError
            if capture == nil { self.error = apiError; notice = nil }
            return apiError
        }
    }
}
