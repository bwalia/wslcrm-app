import SwiftUI

// The order page's newer parts: the private deal, payment by bank transfer (mark paid, invoice),
// proof of delivery (the customer signs on this screen), updates the customer sees, and their delivery
// change requests.

// MARK: - Payment and paperwork

struct ShopOrderPaperworkSection: View {
    let order: ShopOrder
    let extras: ShopOrderExtras
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var markingPaid = false
    @State private var confirmingInvoice = false
    @State private var busy = false
    @State private var notice: String?
    @State private var error: APIError?

    private var canInvoice: Bool {
        session.shopPolicy.canUpdate && session.permissions.can(.create, .invoices)
            && ![.pendingPayment, .cancelled, .paymentFailed, .unknown].contains(order.status)
    }

    var body: some View {
        DetailSection {
            DetailRow(label: "Paid by", value: extras.paymentMethod.map(Self.methodLabel))
            if extras.bankTransferDue {
                Label("Waiting for a bank transfer" + (extras.daysWaiting.map { " (\($0) day\($0 == 1 ? "" : "s"))" } ?? ""),
                      systemImage: "clock")
                    .foregroundStyle(Tone.warning.textColor)
            }
            DetailRow(label: "Payment reference", value: extras.paidReference)
            if order.status == .pendingPayment && isBankTransfer {
                ForEach(extras.paymentMethods) { method in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Asked to pay into: \(method.heading)").font(.wsSubheadline.weight(.semibold))
                        ForEach(method.rows, id: \.0) { row in CopyableRow(label: row.0, value: row.1) }
                        if let instructions = method.instructions { Text(instructions).font(.wsFootnote) }
                    }
                }
                if let reference = extras.paymentReference { CopyableRow(label: "With the reference", value: reference) }
            }
            DetailRow(label: "Customer's PO number", value: extras.customerPoNumber)
            if let code = extras.dealCode {
                NavigationLink {
                    ShopDealDetailView(code: code)
                } label: {
                    LabeledContent("Deal", value: code)
                }
                .accessibilityIdentifier("shopOrder.deal")
            }
            if let invoiceUuid = extras.invoiceUuid {
                NavigationLink {
                    InvoiceDetailView(invoiceUuid: invoiceUuid)
                } label: {
                    Label("Open the invoice", systemImage: "doc.text")
                }
            } else if canInvoice {
                Button {
                    confirmingInvoice = true
                } label: {
                    Label("Create invoice", systemImage: "doc.badge.plus")
                }
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityIdentifier("shopOrder.invoice")
            }
            if order.status == .pendingPayment && session.shopPolicy.canManage && isBankTransfer {
                Button {
                    markingPaid = true
                } label: {
                    Label("Mark as paid", systemImage: "checkmark.circle")
                }
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityIdentifier("shopOrder.markPaid")
            } else if order.status == .pendingPayment && !isBankTransfer {
                Text("Waiting for the customer's card payment. The order is marked paid by itself once it goes through.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let notice { Text(notice).font(.wsFootnote).foregroundStyle(.secondaryText) }
            if let error { InlineErrorRow(error: error) }
        } header: {
            Text("Payment and paperwork")
                // On the header (one view): on the Section they would be copied onto every row and clash.
                .confirmationDialog("Create an invoice for \(order.orderNumber)?", isPresented: $confirmingInvoice, titleVisibility: .visible) {
                    Button("Create invoice") { Task { await createInvoice() } }
                } message: {
                    Text("A draft invoice with the customer, lines, delivery and VAT from this order. You can check it before sending.")
                }
                .sheet(isPresented: $markingPaid) {
                    NavigationStack {
                        ShopMarkPaidForm(order: order, reference: extras.paymentReference) { body in
                            do {
                                try await services.shop.markPaid(orderUuid: order.uuid, body)
                                notice = "Marked as paid: \(ShopMoney.format(body.amountMinor ?? order.totalMinor, currency: order.currency) ?? "") "
                                    + "received. The order goes ahead."
                                error = nil
                                await onChange()
                                return nil
                            } catch {
                                return error.asAPIError
                            }
                        }
                    }
                }
        } footer: {
            if order.status == .pendingPayment && session.shopPolicy.canManage && isBankTransfer {
                Text("Mark as paid when the whole amount has arrived: the order then goes ahead like a card payment.")
            }
        }
    }

    /// Card orders are paid through Stripe (the server refuses marking one paid by hand while it is).
    private var isBankTransfer: Bool { extras.paymentMethod == "bank_transfer" }

    static func methodLabel(_ raw: String) -> String {
        switch raw {
        case "card": "Card"
        case "bank_transfer": "Bank transfer"
        case "cheque": "Cheque"
        case "pos", "cash": "In person"
        default: Formatters.humanize(raw)
        }
    }

    private func createInvoice() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await services.shop.createInvoice(orderUuid: order.uuid)
            error = nil
            notice = result.existing == true
                ? "This order already has invoice \(result.invoiceNumber ?? "")."
                : "Invoice \(result.invoiceNumber ?? "") created as a draft."
            await onChange()
        } catch {
            self.error = error.asAPIError
        }
    }
}

struct ShopMarkPaidForm: View {
    let order: ShopOrder
    let save: (ShopMarkPaidBody) async -> APIError?
    @Environment(\.dismiss) private var dismiss
    @State private var method = "bank_transfer"
    @State private var reference: String
    @State private var amount: String
    @State private var paidOn = Date()
    @State private var saving = false
    @State private var error: APIError?

    init(order: ShopOrder, reference: String? = nil, save: @escaping (ShopMarkPaidBody) async -> APIError?) {
        self.order = order
        self.save = save
        _reference = State(initialValue: reference ?? order.orderNumber)
        _amount = State(initialValue: ShopMoney.amount(order.totalMinor).map { "\($0)" } ?? "")
    }

    /// Pence typed, or nil when it isn't an amount.
    private var amountMinor: Int? { ShopMoney.minor(from: amount) }

    static func shortfall(_ minor: Int?, total: Int) -> Int? {
        guard let minor, minor < total else { return nil }
        return total - minor
    }

    var body: some View {
        Form {
            DetailSection {
                Picker("Paid by", selection: $method) {
                    Text("Bank transfer").tag("bank_transfer")
                    Text("Cheque").tag("cheque")
                    Text("Other").tag("other")
                }
                LabeledContent("Amount received") {
                    TextField("0.00", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("markPaid.amount")
                }
                TextField("Reference", text: $reference)
                    .autocorrectionDisabled()
                DatePicker("Arrived on", selection: $paidOn, in: ...Date(), displayedComponents: .date)
            } footer: {
                Text("\(order.orderNumber) for \(ShopMoney.format(order.totalMinor, currency: order.currency) ?? ""). The order goes ahead as paid, the same as a card payment.")
            }
            if amountMinor == nil {
                DetailSection { Label("Enter the amount that arrived, like 120.00.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Tone.warning.textColor) }
            } else if let short = Self.shortfall(amountMinor, total: order.totalMinor) {
                DetailSection {
                    Label("That's \(ShopMoney.format(short, currency: order.currency) ?? "") less than the order total. "
                          + "Mark it paid once the whole amount has arrived.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
            if let error { DetailSection { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Mark as paid")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Mark paid") {
                    saving = true
                    Task {
                        error = await save(ShopMarkPaidBody(method: method, reference: reference.trimmedOrNil,
                                                            paidAt: Self.paidAt(paidOn), amountMinor: amountMinor))
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(saving || amountMinor == nil || Self.shortfall(amountMinor, total: order.totalMinor) != nil)
                .accessibilityIdentifier("markPaid.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    /// Today: nothing, so the server records the time it was marked (a date alone is midnight UTC, which
    /// showed "paid at 5:30 AM", before the order was placed). An earlier day: that date.
    static func paidAt(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        if calendar.isDate(day, inSameDayAs: now) { return nil }
        return day.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }
}

// MARK: - Proof of delivery

struct ShopOrderSignatureSection: View {
    let order: ShopOrder
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: ShopOrderSignatureState?
    @State private var image: UIImage?
    @State private var signing = false
    @State private var voiding = false
    @State private var voidReason = ""
    @State private var error: APIError?

    var body: some View {
        DetailSection {
            if let signature = state?.signature {
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
                if session.shopPolicy.canUpdate {
                    Button("Void this signature", role: .destructive) { voiding = true }
                        .frame(minHeight: 44)
                }
            } else if state?.canSign == true && session.shopPolicy.canUpdate {
                Button {
                    signing = true
                } label: {
                    Label("Customer signs for the order", systemImage: "signature")
                }
                .buttonStyle(.large(.progress, prominent: false))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("shopOrder.sign")
            } else if state != nil {
                Text("Not signed for.").foregroundStyle(.secondaryText)
            }
            if let error { InlineErrorRow(error: error) }
        } header: {
            Text("Proof of delivery")
                // On the header (one view): on the Section they would be copied onto every row and clash.
                .task(id: order.uuid) { await load() }
                .fullScreenCover(isPresented: $signing) {
                    NavigationStack {
                        ShopSignatureCaptureView(order: order) { capture in
                            do {
                                try await services.shop.captureSignature(orderUuid: order.uuid, capture)
                                await load()
                                await onChange()
                                return nil
                            } catch {
                                return error.asAPIError
                            }
                        }
                    }
                }
                .alert("Void this signature?", isPresented: $voiding) {
                    TextField("Why (e.g. wrong person signed)", text: $voidReason)
                    Button("Void", role: .destructive) { Task { await void() } }
                    Button("Cancel", role: .cancel) { voidReason = "" }
                } message: {
                    Text("It's kept for the record and hidden from the customer. A new signature can then be taken.")
                }
        } footer: {
            if state?.signature == nil && state?.canSign == true {
                Text("Hand over the goods, then the customer signs on this screen. It marks the order delivered and tells the customer.")
            }
        }
    }

    private func load() async {
        do {
            let s = try await services.shop.signature(orderUuid: order.uuid)
            state = s
            image = nil
            if s.signature != nil, let data = try? await services.shop.signatureImage(orderUuid: order.uuid) {
                image = UIImage(data: data)
            }
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func void() async {
        let reason = voidReason.trimmingCharacters(in: .whitespacesAndNewlines)
        voidReason = ""
        do {
            try await services.shop.voidSignature(orderUuid: order.uuid, reason: reason)
            await load()
            await onChange()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// The signing screen: the customer's name, their signature with a finger, an optional note.
private struct ShopSignatureCaptureView: View {
    let order: ShopOrder
    let save: (ShopSignatureCapture) async -> APIError?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note = ""
    @State private var markDelivered = true
    @State private var strokes: [[CGPoint]] = []
    @State private var padSize: CGSize = .zero
    @State private var saving = false
    @State private var error: APIError?
    @State private var problem: String?

    init(order: ShopOrder, save: @escaping (ShopSignatureCapture) async -> APIError?) {
        self.order = order
        self.save = save
        _name = State(initialValue: order.customer?.name ?? "")
    }

    private var hasSignature: Bool { strokes.contains { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(order.orderNumber) · \(order.itemCount) item\(order.itemCount == 1 ? "" : "s")")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            TextField("Name of the person signing", text: $name)
                .textContentType(.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("signature.name")
            ZStack(alignment: .bottomLeading) {
                SignaturePad(strokes: $strokes)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { padSize = $0 }
                    .frame(height: 220)
                    .accessibilityIdentifier("signature.pad")
                if !hasSignature {
                    Text("Sign here")
                        .font(.wsTitle3)
                        .foregroundStyle(.gray)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Button("Clear") { strokes = [] }
                    .disabled(!hasSignature || saving)
                Spacer()
                Toggle("Mark as delivered", isOn: $markDelivered)
                    .fixedSize()
            }
            TextField("Note (optional), e.g. left with reception", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
            if let error { InlineErrorRow(error: error) }
            Spacer(minLength: 0)
            Button {
                Task { await submit() }
            } label: {
                if saving { ProgressView() } else { Label("Save signature", systemImage: "checkmark") }
            }
            .buttonStyle(.large(.progress, prominent: true))
            .disabled(saving || !hasSignature || name.trimmingCharacters(in: .whitespaces).count < 2)
            .accessibilityIdentifier("signature.save")
        }
        .padding()
        .navigationTitle("Sign for the order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
        }
    }

    private func submit() async {
        guard let png = SignaturePad.png(strokes: strokes, size: padSize) else {
            problem = "Couldn't read the signature. Clear it and sign again."
            return
        }
        problem = nil
        saving = true
        defer { saving = false }
        let capture = ShopSignatureCapture(signerName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                           image: "data:image/png;base64," + png.base64EncodedString(),
                                           note: note.trimmedOrNil, markDelivered: markDelivered)
        error = await save(capture)
        if error == nil { dismiss() }
    }
}

/// Draw with a finger. Black ink on white, like paper, in light and dark mode.
struct SignaturePad: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []

    var body: some View {
        Canvas { context, _ in
            Self.draw(strokes + [current], in: &context)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.5)))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { current.append($0.location) }
                .onEnded { _ in
                    if !current.isEmpty { strokes.append(current) }
                    current = []
                }
        )
        .accessibilityLabel("Signature area")
        .accessibilityHint("Sign with your finger")
    }

    static func draw(_ strokes: [[CGPoint]], in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        for stroke in strokes where !stroke.isEmpty {
            if stroke.count == 1, let p = stroke.first {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.black))
                continue
            }
            var path = Path()
            path.addLines(stroke)
            context.stroke(path, with: .color(.black), style: style)
        }
    }

    /// The signature as a PNG, on white, at the size it was drawn.
    @MainActor
    static func png(strokes: [[CGPoint]], size: CGSize) -> Data? {
        guard size.width > 10, size.height > 10 else { return nil }
        let drawing = Canvas { context, _ in draw(strokes, in: &context) }
            .frame(width: size.width, height: size.height)
            .background(Color.white)
        let renderer = ImageRenderer(content: drawing)
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }
}

// MARK: - Updates for the customer

struct ShopOrderCustomerUpdatesSection: View {
    let order: ShopOrder
    let updates: [ShopCustomerUpdate]
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var adding = false
    @State private var removing: ShopCustomerUpdate?
    @State private var error: APIError?

    var body: some View {
        DetailSection {
            if updates.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondaryText)
            }
            ForEach(updates.prefix(15)) { update in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(update.headline).font(.wsSubheadline.weight(.semibold))
                        Spacer()
                        Text(Formatters.dateTime(update.at) ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let message = update.message?.trimmedOrNil {
                        Text(message).font(.wsSubheadline).lineLimit(6)
                    }
                    if let author = update.author { Text(author).font(.wsFootnote).foregroundStyle(.secondaryText) }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .swipeActions(allowsFullSwipe: false) {
                    if update.removable && update.kind == "comment" && session.shopPolicy.canUpdate {
                        Button("Remove", role: .destructive) { removing = update }
                    }
                }
                // A Mac has no swipe: the same as a right-click.
                .contextMenu {
                    if update.removable && update.kind == "comment" && session.shopPolicy.canUpdate {
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = update }
                    }
                }
            }
            if session.shopPolicy.canUpdate {
                Button {
                    adding = true
                } label: {
                    Label("Add an update for the customer", systemImage: "text.bubble")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("shopOrder.addUpdate")
            }
            if let error { InlineErrorRow(error: error) }
        } header: {
            Text("Updates for the customer")
                // On the header (one view): on the Section they would be copied onto every row and clash.
                .sheet(isPresented: $adding) {
                    NavigationStack {
                        ShopCustomerUpdateForm { message in
                            do {
                                try await services.shop.addCustomerUpdate(orderUuid: order.uuid, message: message)
                                error = nil
                                await onChange()
                                return nil
                            } catch {
                                return error.asAPIError
                            }
                        }
                    }
                }
                .confirmationDialog("Remove this update?", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                    titleVisibility: .visible, presenting: removing) { update in
                    Button("Remove", role: .destructive) { Task { await remove(update) } }
                } message: { _ in
                    Text("The customer won't see it on their order page any more.")
                }
        } footer: {
            Text("The customer sees these on their order page. To email them, use Update emails above.")
        }
    }

    private func remove(_ update: ShopCustomerUpdate) async {
        do {
            try await services.shop.removeCustomerUpdate(orderUuid: order.uuid, updateUuid: update.uuid)
            error = nil
            await onChange()
        } catch {
            self.error = error.asAPIError
        }
    }
}

private struct ShopCustomerUpdateForm: View {
    let save: (String) async -> APIError?
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        Form {
            DetailSection {
                TextField("e.g. Your server is built and being tested", text: $message, axis: .vertical)
                    .lineLimit(4...10)
                    .accessibilityIdentifier("customerUpdate.message")
            } footer: {
                Text("Shown to the customer on their order page.")
            }
            if let error { DetailSection { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Update for the customer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    saving = true
                    Task {
                        error = await save(message.trimmingCharacters(in: .whitespacesAndNewlines))
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(saving || message.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                .accessibilityIdentifier("customerUpdate.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }
}

// MARK: - Delivery change requests

struct ShopOrderDeliveryChangesSection: View {
    let order: ShopOrder
    let requests: [ShopDeliveryChangeRequest]
    let onChange: () async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var declining: ShopDeliveryChangeRequest?
    @State private var reason = ""
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        DetailSection {
            ForEach(requests.prefix(5)) { request in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(request.isPending ? "Waiting for you" : Formatters.humanize(request.status))
                            .font(.wsSubheadline.weight(.semibold))
                            .foregroundStyle(request.isPending ? Tone.warning.textColor : .primary)
                        Spacer()
                        Text(Formatters.dateTime(request.createdAt) ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    if let address = ShopAnyAddress.format(request.requestedAddress) {
                        Text("Deliver to: \(address)").font(.wsSubheadline)
                    }
                    let when = [request.requestedDate, request.windowLabel].compactMap { $0 }
                    if !when.isEmpty { Text("When: \(when.joined(separator: ", "))").font(.wsSubheadline) }
                    if let note = request.customerNote { Text("“\(note)”").font(.wsSubheadline).foregroundStyle(.secondaryText) }
                    if let staffNote = request.staffNote { Text("Our note: \(staffNote)").font(.wsFootnote).foregroundStyle(.secondaryText) }
                    if request.isPending && session.shopPolicy.canUpdate {
                        HStack {
                            Button("Approve") { Task { await decide(request, approve: true, note: nil) } }
                                .buttonStyle(.borderedProminent)
                            Button("Decline", role: .destructive) { declining = request }
                                .buttonStyle(.bordered)
                        }
                        .disabled(busy)
                    }
                }
                .padding(.vertical, 4)
            }
            if let error { InlineErrorRow(error: error) }
        } header: {
            Text("Delivery change requests")
                // On the header (one view): on the Section they would be copied onto every row and clash.
                .alert("Decline the change?", isPresented: .init(get: { declining != nil }, set: { if !$0 { declining = nil } })) {
                    TextField("Why (the customer sees this)", text: $reason)
                    Button("Decline", role: .destructive) {
                        if let request = declining { Task { await decide(request, approve: false, note: reason) } }
                    }
                    Button("Cancel", role: .cancel) { reason = "" }
                }
        } footer: {
            Text("The customer asked to change where or when it's delivered. Approving updates the order and tells them.")
        }
    }

    private func decide(_ request: ShopDeliveryChangeRequest, approve: Bool, note: String?) async {
        busy = true
        defer { busy = false }
        reason = ""
        do {
            try await services.shop.decideDeliveryChange(orderUuid: order.uuid, requestUuid: request.uuid, approve: approve, staffNote: note)
            error = nil
            await onChange()
        } catch {
            self.error = error.asAPIError
        }
    }
}
