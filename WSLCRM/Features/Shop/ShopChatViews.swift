import QuickLook
import SwiftUI

// The shop AI assistant's chats (dashboard /dashboard/shop/chats and /chats/[uuid]): every transcript, who the
// visitor was, and what the chat led to. Read only (RBAC `shop` read).

struct ShopChatsListView: View {
    @Environment(\.services) private var services
    @State private var consentOnly = false

    var body: some View {
        ModelHost(make: { [shop = services.shop, consentOnly] in
            PagedListModel<ShopChatRecord> { search, page in
                try await shop.chatRecords(search: search, consentOnly: consentOnly, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Email, phone or message text", emptyTitle: "No chats",
                      emptySystemImage: "bubble.left.and.bubble.right",
                      emptyDescription: consentOnly
                          ? "No customer has agreed yet that their chat may be used to improve the advice."
                          : "Conversations customers have with the shop assistant appear here.",
                      destination: { chat in
                    ShopChatDetailView(uuid: chat.uuid, seed: chat)
                }) { chat in
                ShopChatRow(chat: chat)
            }
        }
        .id(consentOnly)
        .navigationTitle("AI assistant chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $consentOnly) {
                        Text("All chats").tag(false)
                        Text("Customer agreed we may learn from it").tag(true)
                    }
                } label: {
                    Label("Filter", systemImage: consentOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("shop.chats.filter")
            }
        }
    }
}

private struct ShopChatRow: View {
    let chat: ShopChatRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(chat.email ?? chat.contactName ?? "Anonymous visitor").font(.wsHeadline).lineLimit(1)
                Spacer()
                Text(Formatters.relative(chat.updatedAt ?? chat.createdAt) ?? "").font(.wsCaption).foregroundStyle(.secondaryText)
            }
            Text(chat.opening ?? "No messages").font(.wsSubheadline).lineLimit(2)
                .foregroundStyle(chat.opening == nil ? .secondaryText : .primary)
            HStack(spacing: 6) {
                ForEach(chat.outcomes, id: \.self) { outcome in
                    StatusBadge(text: outcome, systemImage: outcome == "Order" ? "cart.fill" : outcome == "Quote" ? "doc.text" : "basket",
                                tone: outcome == "Order" ? .success : outcome == "Quote" ? .info : .neutral)
                }
                Text(["\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s")", chat.countryName, chat.clientIp]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One chat: the transcript, the visitor, and the cart, quote, order and CRM lead it is linked to.
struct ShopChatDetailView: View {
    let uuid: String
    var seed: ShopChatRecord?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<ShopChatRecord> = .idle
    @State private var makingLead = false
    @State private var notice: String?
    @State private var transcriptURL: URL?
    @State private var loadingTranscript = false
    @State private var transcriptError: APIError?

    var body: some View {
        List {
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let chat = state.value ?? seed {
                content(chat)
            }
            if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            } else if state.value == nil {
                Section { ProgressView("Loading the transcript…").frame(maxWidth: .infinity) }
            }
        }
        .wsDetailList()
        .listStyle(.insetGrouped)
        .navigationTitle("Chat transcript")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $makingLead) {
            if let chat = state.value { MakeChatLeadSheet(chat: chat) { await made() } }
        }
        // The system's PDF preview: Share saves it to Files, mails it or AirDrops it.
        .quickLookPreview($transcriptURL)
    }

    private func downloadTranscript(_ chat: ShopChatRecord) async {
        loadingTranscript = true
        transcriptError = nil
        defer { loadingTranscript = false }
        do {
            let data = try await services.shop.chatTranscript(chat.uuid)
            let who = (chat.contactName ?? chat.email ?? "visitor").replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Chat with \(who).pdf")
            try data.write(to: url, options: .atomic)
            transcriptURL = url
        } catch {
            transcriptError = error.asAPIError
        }
    }

    private func made() async {
        notice = "Lead made. The AI is reading it now."
        await load()
    }

    @ViewBuilder
    private func content(_ chat: ShopChatRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.email ?? "Anonymous visitor").font(.wsTitle3)
                if let started = Formatters.dateTime(chat.createdAt) {
                    Text("Started \(started)").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            if let summary = chat.summary?.trimmedOrNil {
                Label(summary, systemImage: "text.alignleft").font(.wsSubheadline)
            }
            if state.value != nil {
                Button { Task { await downloadTranscript(chat) } } label: {
                    if loadingTranscript {
                        ProgressView().frame(minHeight: 44)
                    } else {
                        Label("Download the transcript (PDF)", systemImage: "arrow.down.doc").frame(minHeight: 44)
                    }
                }
                .disabled(loadingTranscript)
                .accessibilityIdentifier("shop.chat.transcript")
                if let transcriptError { InlineErrorRow(error: transcriptError) { Task { await downloadTranscript(chat) } } }
            }
        }

        if state.value != nil {
            Section("\(chat.messages.count) message\(chat.messages.count == 1 ? "" : "s")") {
                if chat.messages.isEmpty {
                    Text("No messages recorded.").foregroundStyle(.secondaryText)
                }
                ForEach(chat.messages.filter { !$0.content.isEmpty || !$0.tools.isEmpty }) { message in
                    ShopChatMessageRow(message: message)
                        .listRowSeparator(.hidden)
                }
            }
        }

        Section("Visitor") {
            if let email = chat.email { EmailLinkRow(email: email) } else { DetailRow(label: "Email", value: "—") }
            DetailRow(label: "Name", value: chat.contactName ?? "—")
            if let phone = chat.contactPhone {
                PhoneLinkRow(name: chat.contactName, phone: phone)
            } else {
                DetailRow(label: "Phone", value: "—")
            }
            DetailRow(label: "Signed in", value: chat.isMember ? "Yes, member" : "No")
            DetailRow(label: "IP address", value: chat.clientIp ?? "—")
            DetailRow(label: "Country", value: chat.countryName ?? "Unknown")
            DetailRow(label: "May use to improve advice", value: chat.improveConsent
                      ? "Yes\(Formatters.day(chat.consentAt).map { ", since \($0)" } ?? "")" : "No")
        }

        if let requirements = chat.requirements, let text = FieldFormatter.describe(requirements) {
            Section("What they need") {
                Text(text).font(.wsSubheadline).textSelection(.enabled)
            }
        }

        Section("Linked") {
            DetailRow(label: "Cart", value: chat.cartUuid ?? "—")
            if let quote = chat.quoteUuid {
                NavigationLink { ShopQuoteDetailView(uuid: quote) } label: {
                    LabeledContent("Quote", value: chat.quoteNumber ?? "Open")
                }
            } else {
                DetailRow(label: "Quote", value: "—")
            }
            if let order = chat.orderUuid {
                NavigationLink { ShopOrderDetailView(uuid: order) } label: {
                    LabeledContent("Order", value: chat.orderNumber ?? "Open")
                }
            } else {
                DetailRow(label: "Order", value: "—")
            }
            if let lead = chat.crmLeadUuid {
                if session.shopPolicy.canOpenLeads {
                    NavigationLink { LeadDetailView(leadUuid: lead) } label: {
                        Label("Open their lead", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } else if session.shopPolicy.canMakeLeads, state.value != nil {
                Button { makingLead = true } label: {
                    Label("Make this a lead", systemImage: "person.crop.circle.badge.plus").frame(minHeight: 44)
                }
                .accessibilityIdentifier("shop.chat.makeLead")
            }
            DetailRow(label: "Messages", value: "\(chat.messageCount)")
            if let last = Formatters.dateTime(chat.updatedAt) { DetailRow(label: "Last activity", value: last) }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.shop.chatRecord(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// The team has the visitor's email or number (they rang, or wrote in): make the chat a CRM lead.
private struct MakeChatLeadSheet: View {
    let chat: ShopChatRecord
    let onMade: () async -> Void
    @Environment(\.services) private var services
    @State private var email: String
    @State private var phone: String
    @State private var name: String
    @State private var note = ""

    init(chat: ShopChatRecord, onMade: @escaping () async -> Void) {
        self.chat = chat
        self.onMade = onMade
        _email = State(initialValue: chat.email ?? "")
        _phone = State(initialValue: chat.contactPhone ?? "")
        _name = State(initialValue: chat.contactName ?? "")
    }

    var body: some View {
        LeadSheet(title: "Make this a lead", action: "Make the lead", canSave: email.trimmedOrNil != nil || phone.trimmedOrNil != nil,
                  save: save) {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("shop.chat.lead.email")
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad).textContentType(.telephoneNumber)
                    .accessibilityIdentifier("shop.chat.lead.phone")
                TextField("Name", text: $name).textContentType(.name)
            } footer: {
                Text("One of email or phone is enough. What they asked the assistant goes on the lead.")
            }
            Section("Note (optional)") {
                TextField("e.g. Rang the shop; wants a call back on Monday", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    private func save() async throws {
        _ = try await services.shop.makeChatLead(chat.uuid, ShopChatLeadBody(
            email: email.trimmedOrNil, phone: phone.trimmedOrNil, name: name.trimmedOrNil, note: note.trimmedOrNil))
        await onMade()
    }
}

/// A transcript line: the customer on the right, the assistant (Markdown) on the left, tool steps in amber.
private struct ShopChatMessageRow: View {
    let message: ShopChatEntry

    var body: some View {
        HStack(alignment: .top) {
            if message.isCustomer { Spacer(minLength: 32) }
            VStack(alignment: message.isCustomer ? .trailing : .leading, spacing: 4) {
                if !message.content.isEmpty {
                    Text(message.attributed)
                        .font(.wsSubheadline)
                        .padding(10)
                        .foregroundStyle(message.isCustomer ? Color.white : Color(.label))
                        .background(background, in: RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                }
                Text(caption).font(.wsCaption2).foregroundStyle(.secondaryText)
            }
            if !message.isCustomer { Spacer(minLength: 32) }
        }
        .accessibilityElement(children: .combine)
    }

    private var background: Color {
        if message.isCustomer { return Tone.info.solidColor }
        if message.isAssistant { return Color(.secondarySystemBackground) }
        return Tone.warning.color.opacity(0.15)
    }

    private var caption: String {
        let who = message.isCustomer ? "Customer" : message.isAssistant ? "Assistant" : Formatters.humanize(message.role)
        let tools = message.tools.isEmpty ? nil : "tools: \(message.tools.map { ShopAnalyticsToolUse.labels[$0] ?? $0 }.joined(separator: ", "))"
        return [who, Formatters.dateTime(message.at), tools].compactMap { $0 }.joined(separator: " · ")
    }
}
