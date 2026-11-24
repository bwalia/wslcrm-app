import SwiftUI

// "My deliveries" for delivery partners (lapis/routes/delivery-assignments.lua): the jobs assigned to the
// signed-in person's delivery-partner profile, no workspace needed. Each step moves the delivery on
// (`PUT /api/v2/delivery-assignments/:uuid/status`); "delivered" takes the customer's signature.
// A store's request to deliver an order (routes/delivery-requests.lua) only becomes a delivery once the
// partner accepts it, so the requests waiting for them are listed first ("Requests for you").
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

    /// Plain words for a failed step. "Cancel the delivery" fails on servers whose table doesn't allow
    /// `cancelled` yet (a 500), so say what to do instead of "something went wrong".
    static func failure(_ step: Step, _ error: APIError) -> APIError {
        guard step.status == "cancelled", let status = error.serverError?.status, status >= 500 else { return error }
        return ResourceService.problem(400, "This delivery can't be cancelled from the app yet. "
                                           + "Call the store and ask them to take it back.")
    }
}

/// The partner's answer to a delivery request: a store's request (`seller_to_partner`) is accepted or
/// declined; the partner's own offer (`partner_to_seller`) can be withdrawn (`PUT …/:uuid/<answer>`).
enum MyDeliveryRequestAnswer: String, Sendable {
    case accept, reject, cancel

    static func choices(for request: Record) -> [MyDeliveryRequestAnswer] {
        guard request.string("status") ?? "pending" == "pending" else { return [] }
        return request.string("request_type") == "partner_to_seller" ? [.cancel] : [.accept, .reject]
    }

    var title: String {
        switch self {
        case .accept: "Accept"
        case .reject: "Decline"
        case .cancel: "Withdraw my offer"
        }
    }

    func done(_ order: String) -> String {
        switch self {
        case .accept: "Accepted. \(order) is now in your deliveries to do."
        case .reject: "Declined. The store has been told."
        case .cancel: "Your offer to deliver \(order) is withdrawn."
        }
    }
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

    /// Requests waiting for the partner's answer (`GET /api/v2/delivery-requests/partner?status=pending`; the
    /// latest 20, expired ones left out). 404 = not a partner.
    func myRequests() async throws -> [Record] {
        Self.rows(try await partnerGet("/api/v2/delivery-requests/partner", query: [URLQueryItem(name: "status", value: "pending")]),
                  "requests")
    }

    /// Accept / decline a store's request, or withdraw your own offer. The route reads form fields.
    func answerMyRequest(_ uuid: String, _ answer: MyDeliveryRequestAnswer, message: String = "") async throws {
        var form: [(String, String)] = []
        if answer != .cancel, let message = message.trimmedOrNil { form.append(("response_message", message)) }
        var endpoint = Endpoint(.put, "/api/v2/delivery-requests/\(Self.path(uuid))/\(answer.rawValue)").withForm(form)
        endpoint.requiresNamespace = false
        _ = try await client.sendRaw(endpoint)
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
    @State private var requests: [Record] = []
    @State private var requestsError: APIError?
    @State private var answering: (request: Record, answer: MyDeliveryRequestAnswer)?
    @State private var busy = false
    @State private var notice: String?
    @State private var answerError: APIError?

    var body: some View {
        List {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
            }
            if show == "active" { requestsSection }
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
                                                             ? "Deliveries you accept show here."
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
                    if rows.count >= 20 { Text("Showing your latest 20 deliveries.") }
                }
            }
        }
        .disabled(busy)
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
        .confirmationDialog(answering.map { $0.answer == .cancel ? "Withdraw your offer?" : "Decline this request?" } ?? "",
                            isPresented: .init(get: { answering != nil }, set: { if !$0 { answering = nil } }),
                            titleVisibility: .visible, presenting: answering) { item in
            Button(item.answer.title, role: .destructive) { Task { await answer(item.request, item.answer) } }
            Button("Not now", role: .cancel) {}
        } message: { item in
            Text(item.answer == .cancel ? "The store won't see your offer any more."
                 : "\(item.request.string("store_name") ?? "The store") will be told you can't deliver this order.")
        }
    }

    /// Stores' requests waiting for an answer (and the partner's own offers waiting for the store).
    @ViewBuilder
    private var requestsSection: some View {
        if !requests.isEmpty || requestsError != nil || answerError != nil {
            Section {
                if let requestsError { InlineErrorRow(error: requestsError) { Task { await load() } } }
                if let answerError { InlineErrorRow(error: answerError) }
                ForEach(requests) { request in
                    MyDeliveryRequestRow(request: request) { choice in
                        if choice == .accept { Task { await answer(request, .accept) } } else { answering = (request, choice) }
                    }
                }
            } header: {
                Text("Requests for you (\(requests.count))")
            } footer: {
                Text("Accept a request to add it to your deliveries. A request you don't answer runs out after a day.")
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        if show == "active" { await loadRequests() }
        do {
            state = .loaded(try await services.delivery.myAssignments(status: show))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func loadRequests() async {
        do {
            requests = try await services.delivery.myRequests()
            requestsError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            requests = []
            // Not a partner: the deliveries list says so.
            requestsError = apiError.serverError?.status == 404 ? nil : apiError
        }
    }

    private func answer(_ request: Record, _ answer: MyDeliveryRequestAnswer) async {
        busy = true
        defer { busy = false }
        do {
            try await services.delivery.answerMyRequest(request.string("uuid") ?? request.id, answer)
            answerError = nil
            notice = answer.done(request.string("order_number") ?? "The order")
            await load()
        } catch {
            notice = nil
            answerError = error.asAPIError
        }
    }
}

/// One request: the order, the store, the fee offered, where it goes, and the partner's choices.
private struct MyDeliveryRequestRow: View {
    let request: Record
    let choose: (MyDeliveryRequestAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(request.string("order_number") ?? "Order").font(.wsHeadline.monospacedDigit())
                Spacer()
                if let fee = DeliveryWords.money(request, "proposed_fee", currency: nil) {
                    Text("Fee \(fee)").font(.wsSubheadline.monospacedDigit())
                }
            }
            Text([request.string("store_name").map { "From \($0)" },
                  request.string("request_type") == "partner_to_seller" ? "You offered to deliver" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline)
            if let place = Self.address(request) {
                Label(place, systemImage: "mappin").font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
            if let message = request.string("message") { Text("“\(message)”").font(.wsFootnote) }
            if let ends = request.date("expires_at") {
                Text("Answer by \(Formatters.dateTime(ends) ?? "")").font(.wsCaption).foregroundStyle(.secondaryText)
            }
            let choices = MyDeliveryRequestAnswer.choices(for: request)
            if choices == [.cancel] {
                Text("Waiting for the store to answer your offer.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            HStack {
                ForEach(choices, id: \.self) { choice in
                    Button(choice.title, role: choice == .accept ? nil : .destructive) { choose(choice) }
                        .buttonStyle(.bordered)
                        .tint(choice == .accept ? Tone.success.textColor : nil)
                        .accessibilityIdentifier("myDelivery.request.\(choice.rawValue).\(request.id)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The order's delivery address: `shipping_address` is JSON text (address1, city, zip…).
    static func address(_ request: Record) -> String? {
        guard let text = request.string("shipping_address") else { return nil }
        guard let data = text.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return text
        }
        return StoreOrderDetailView.address(json)
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
        } else if let pod = DeliveryProof(a.string("proof_of_delivery")) {
            Section("Proof of delivery") {
                DetailRow(label: "Signed for", value: pod.signedLine)
                DetailRow(label: "Note", value: pod.notes)
            }
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
            let apiError = MyDeliverySteps.failure(step, error.asAPIError)
            if capture == nil { self.error = apiError; notice = nil }
            return apiError
        }
    }
}
