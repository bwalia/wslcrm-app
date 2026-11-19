import SwiftUI

/// UK and international numbers as WhatsApp wants them (447700900456): a leading 0 is a UK number,
/// 00 is the international prefix. nil when it isn't a usable number. Same rules as the server.
enum ShopPhone {
    static func international(_ phone: String?) -> String? {
        guard let phone = phone?.trimmedOrNil else { return nil }
        var digits = phone.filter(\.isNumber)
        if !phone.hasPrefix("+") {
            if digits.hasPrefix("00") {
                digits.removeFirst(2)
            } else if digits.hasPrefix("0") {
                digits = "44" + digits.dropFirst()
            }
        }
        return (8...15).contains(digits.count) ? digits : nil
    }

    static func whatsApp(_ phone: String?) -> URL? {
        international(phone).flatMap { URL(string: "https://wa.me/\($0)") }
    }

    static func sms(_ phone: String?) -> URL? {
        international(phone).flatMap { URL(string: "sms:+\($0)") }
    }
}

/// Message a supplier from a quote or a product: pick the supplier and the message is ready ("Hello Sam",
/// what's needed, then the questions). Edit it, then email it from here, or open WhatsApp or Messages
/// on this phone with it ready to send. Every message is recorded on the deal (or the product).
struct ShopSupplierMessageSheet: View {
    let kind: ShopSupplierMessageKind
    /// Called after sending with a line to show on the page it came from.
    var onSent: (String) -> Void = { _ in }

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var suppliers: LoadState<[ShopSupplier]> = .idle
    @State private var supplierUuid = ""
    @State private var templateId = ""
    @State private var qty = 1
    @State private var draft: ShopSupplierMessageDraft?
    @State private var subject = ""
    @State private var message = ""
    @State private var loadingDraft = false
    @State private var sending: ShopMessageChannel?
    @State private var error: APIError?
    @State private var customerAgreed = false
    @State private var ccCustomer = true
    @State private var editingSupplier: ShopSupplier?

    private var isIntroduction: Bool {
        if case .introduction = kind { return true }
        return false
    }

    private var isStockEnquiry: Bool {
        if case .stockEnquiry = kind { return true }
        return false
    }

    var body: some View {
        Form {
            supplierSection
            if loadingDraft && draft == nil {
                Section { ProgressView("Getting the message ready…") }
            }
            if let draft { draftSections(draft) }
            if let error {
                Section { InlineErrorRow(error: error) }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(sending != nil)
            }
        }
        .safeAreaInset(edge: .bottom) { if draft != nil { sendBar } }
        .interactiveDismissDisabled(sending != nil)
        .task { await loadSuppliers() }
        .navigationDestination(item: $editingSupplier) { supplier in
            ShopSupplierDetailView(summary: supplier) { _ in
                Task {
                    await loadSuppliers(force: true)
                    await loadDraft()
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var supplierSection: some View {
        Section {
            switch suppliers {
            case .loaded(let list) where list.isEmpty:
                Text("You have no suppliers yet. Add them under Shop → Suppliers on the web, then come back.")
                    .foregroundStyle(.secondaryText)
            case .loaded(let list):
                Picker("Supplier", selection: $supplierUuid) {
                    Text("Choose a supplier…").tag("")
                    ForEach(list) { Text($0.pickerLabel).tag($0.uuid) }
                }
                .accessibilityIdentifier("supplierMessage.supplier")
                .onChange(of: supplierUuid) {
                    templateId = ""
                    Task { await loadDraft() }
                }
                if isStockEnquiry {
                    Stepper("How many: \(qty)", value: $qty, in: 1...9_999)
                        .onChange(of: qty) { Task { await loadDraft() } }
                        .accessibilityIdentifier("supplierMessage.qty")
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await loadSuppliers(force: true) } }
            default:
                ProgressView("Loading your suppliers…")
            }
        } header: {
            Text("Supplier")
        } footer: {
            switch kind {
            case .priceRequest:
                Text("Asks if it's available, the price ex VAT, when they could deliver and how long the price is valid. The customer is never named: the deal code is the only reference.")
            case .introduction:
                Text("Puts the customer in touch with the supplier directly. This shares the customer's name, company, email and phone.")
            case .stockEnquiry:
                Text("Asks how many they have or the lead time, their trade price ex VAT and when they could deliver. Our prices are never in the message.")
            }
        }
    }

    @ViewBuilder
    private func draftSections(_ draft: ShopSupplierMessageDraft) -> some View {
        let s = draft.supplier
        Section {
            LabeledContent("To", value: s.contactName?.trimmedOrNil.map { "\($0) at \(s.name)" } ?? s.name)
            LabeledContent("Email", value: s.email ?? "None")
            LabeledContent("Phone", value: s.phone ?? "None")
            if let code = draft.dealCode { LabeledContent("Deal", value: code) }
            if s.contactName?.trimmedOrNil == nil || s.email == nil || s.phoneIntl == nil,
               let supplier = suppliers.value?.first(where: { $0.uuid == s.uuid }) {
                Button {
                    editingSupplier = supplier
                } label: {
                    Label(missingHint(s), systemImage: "square.and.pencil")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("supplierMessage.editSupplier")
            }
        }

        if draft.templates.count > 1 {
            Section {
                Picker("Template", selection: $templateId) {
                    ForEach(draft.templates) { Text($0.name).tag($0.id) }
                }
                .onChange(of: templateId) { old, new in
                    // "" is a new supplier being chosen (that reloads anyway) or the first draft arriving.
                    if !old.isEmpty, !new.isEmpty, old != new { Task { await loadDraft() } }
                }
            } footer: {
                Text("Templates are set up on the web under Shop → Templates.")
            }
        }

        if !draft.customerDetails.isEmpty {
            Section {
                Label("The message shows the customer's \(draft.customerDetails.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")). Remove it before sending: suppliers must not see who the customer is.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Tone.warning.textColor)
            }
        }

        if isIntroduction, let customer = draft.customer {
            Section {
                DetailRow(label: "Customer", value: customer.name)
                DetailRow(label: "Company", value: customer.company)
                DetailRow(label: "Email", value: customer.email)
                DetailRow(label: "Phone", value: customer.phone)
                Toggle("The customer has agreed to be introduced", isOn: $customerAgreed)
                    .accessibilityIdentifier("supplierMessage.customerAgreed")
                if customer.email != nil {
                    Toggle("Copy the customer in (email)", isOn: $ccCustomer)
                }
            } header: {
                Text("Shared with the supplier")
            } footer: {
                Text("Only introduce a customer who has said yes to it.")
            }
        }

        Section("Subject (email)") {
            TextField("Subject", text: $subject)
                .accessibilityIdentifier("supplierMessage.subject")
        }
        Section {
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(8...30)
                .accessibilityIdentifier("supplierMessage.message")
        } header: {
            Text("Message")
        } footer: {
            Text("Email is sent from here and their reply comes to you. WhatsApp and text open on this phone with the message ready: press send there. Each one is recorded \(isStockEnquiry ? "on the product" : "on the deal").")
        }
    }

    private var sendBar: some View {
        let s = draft?.supplier
        let noText = message.trimmedOrNil == nil
        let blocked = sending != nil || loadingDraft || noText || (isIntroduction && !customerAgreed)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await send(.whatsapp) }
                } label: {
                    sendLabel("WhatsApp", systemImage: "message.circle", channel: .whatsapp)
                }
                .buttonStyle(.large(.progress, prominent: false))
                .disabled(blocked || s?.phoneIntl == nil)
                .accessibilityIdentifier("supplierMessage.whatsapp")

                Button {
                    Task { await send(.sms) }
                } label: {
                    sendLabel("Text", systemImage: "message", channel: .sms)
                }
                .buttonStyle(.large(.progress, prominent: false))
                .disabled(blocked || s?.phoneIntl == nil)
                .accessibilityIdentifier("supplierMessage.sms")
            }
            Button {
                Task { await send(.email) }
            } label: {
                sendLabel("Send email", systemImage: "envelope", channel: .email)
            }
            .buttonStyle(.large(.progress, prominent: true))
            .disabled(blocked || s?.email == nil)
            .accessibilityIdentifier("supplierMessage.email")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func sendLabel(_ title: String, systemImage: String, channel: ShopMessageChannel) -> some View {
        if sending == channel {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }

    private func missingHint(_ s: ShopMessageSupplier) -> String {
        var missing: [String] = []
        if s.contactName?.trimmedOrNil == nil { missing.append("a contact name") }
        if s.email == nil { missing.append("an email") }
        if s.phoneIntl == nil { missing.append("a mobile number") }
        return "Add " + ListFormatter.localizedString(byJoining: missing) + " to \(s.name)"
    }

    // MARK: Loading and sending

    private func loadSuppliers(force: Bool = false) async {
        if suppliers.value != nil, !force { return }
        if suppliers.value == nil { suppliers = .loading }
        do {
            suppliers = .loaded(try await services.shop.suppliers().filter(\.isActive))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if suppliers.value == nil { suppliers = .failed(apiError) }
        }
    }

    private func loadDraft() async {
        guard !supplierUuid.isEmpty else {
            draft = nil
            return
        }
        let requested = supplierUuid
        loadingDraft = true
        defer { loadingDraft = false }
        do {
            let template = templateId.isEmpty || templateId == "builtin" ? nil : templateId
            let d = try await services.shop.supplierMessageDraft(kind, supplierUuid: requested, templateUuid: template,
                                                               qty: isStockEnquiry ? qty : nil)
            guard requested == supplierUuid else { return }
            draft = d
            subject = d.subject
            message = d.body
            if templateId.isEmpty { templateId = d.template?.id ?? "builtin" }
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func send(_ channel: ShopMessageChannel) async {
        guard let draft else { return }
        sending = channel
        defer { sending = nil }
        let template = templateId.isEmpty || templateId == "builtin" ? nil : templateId
        let body = ShopSupplierMessageSend(
            supplierUuid: draft.supplier.uuid, channel: channel, subject: subject, message: message,
            templateUuid: template,
            customerAgreed: isIntroduction ? customerAgreed : nil,
            ccCustomer: isIntroduction && channel == .email ? ccCustomer : nil,
            qty: isStockEnquiry ? qty : nil)
        do {
            let result = try await services.shop.sendSupplierMessage(kind, body)
            error = nil
            let place = isStockEnquiry ? "Recorded on the product." : draft.dealCode.map { "Recorded on deal \($0)." } ?? "Recorded on the deal."
            if channel == .email {
                let cc = result.cc.map { ", copied to \($0)" } ?? ""
                onSent("Emailed to \(result.sentTo ?? draft.supplier.email ?? "the supplier")\(cc). \(place)")
                dismiss()
            } else if let link = result.link.flatMap(URL.init(string:)) {
                onSent("\(channel == .whatsapp ? "WhatsApp" : "Messages") opened with the message ready: press send there. \(place)")
                dismiss()
                openURL(link)
            } else {
                onSent(place)
                dismiss()
            }
        } catch {
            self.error = error.asAPIError
        }
    }
}
