import SwiftUI

/// What the shop's AI assistant can search (dashboard /dashboard/shop/knowledge): products, blog posts, FAQs,
/// manuals and web pages. Re-index products or posts, add a document, read and remove one (RBAC `shop`).
struct ShopKnowledgeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var source: ShopKnowledgeSource?
    @State private var reindexing: String?
    @State private var adding = false
    @State private var notice: String?
    @State private var actionError: APIError?
    @State private var reloadToken = 0
    @State private var removing: ShopKnowledgeEntry?

    var body: some View {
        ModelHost(make: { [shop = services.shop, source] in
            PagedListModel<ShopKnowledgeEntry> { search, page in
                try await shop.knowledgeEntries(search: search, source: source, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Title or text", emptyTitle: source.map { "No \($0.label.lowercased())" } ?? "Nothing indexed",
                      emptySystemImage: "books.vertical",
                      emptyDescription: "Re-index products or blog posts, or add an FAQ, a manual or a web page.") { entry in
                NavigationLink {
                    ShopKnowledgeDetailView(entry: entry, canDelete: session.shopPolicy.canDelete) { reloadToken += 1 }
                } label: {
                    ShopKnowledgeRow(entry: entry)
                }
                .swipeActions(allowsFullSwipe: false) {
                    if session.shopPolicy.canDelete {
                        Button("Remove", role: .destructive) { removing = entry }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    sourcePicker
                    if let actionError {
                        InlineErrorRow(error: actionError).padding(.horizontal)
                    } else if let notice {
                        Label(notice, systemImage: "checkmark.circle.fill").font(.wsSubheadline)
                            .foregroundStyle(Tone.success.textColor)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 6)
                    }
                }
                .background(.bar)
            }
            .confirmationDialog("Remove “\(removing?.title ?? "")” from the knowledge base?",
                                isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { entry in
                Button("Remove document", role: .destructive) {
                    Task {
                        do {
                            try await services.shop.deleteKnowledgeEntry(entry)
                            model.remove(id: entry.id)
                            actionError = nil
                            notice = "“\(entry.title)” was removed. The assistant can no longer find it."
                        } catch {
                            actionError = error.asAPIError
                        }
                    }
                }
            } message: { _ in
                Text("The assistant stops using it at once. Products and blog posts come back the next time you re-index.")
            }
        }
        .id("\(source?.rawValue ?? "all")-\(reloadToken)")
        .navigationTitle("Assistant knowledge")
        .toolbar {
            if session.shopPolicy.canUpdate {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Products and blog posts") { Task { await reindex(["products", "cms_posts"]) } }
                        Button("Products only") { Task { await reindex(["products"]) } }
                        Button("Blog posts only") { Task { await reindex(["cms_posts"]) } }
                    } label: {
                        if reindexing != nil { ProgressView() } else { Label("Re-index", systemImage: "arrow.clockwise.circle") }
                    }
                    .disabled(reindexing != nil)
                    .accessibilityIdentifier("shop.knowledge.reindex")
                }
            }
            if session.shopPolicy.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add document", systemImage: "plus") }
                        .accessibilityIdentifier("shop.knowledge.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ShopKnowledgeForm { title in
                    notice = "“\(title)” was added and indexed."
                    actionError = nil
                    reloadToken += 1
                }
            }
        }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", selected: source == nil) { source = nil }
                ForEach(ShopKnowledgeSource.allCases) { item in
                    chip(item.label, selected: source == item) { source = item }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("shop.knowledge.sources")
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.wsSubheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color(.label))
                .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func reindex(_ sources: [String]) async {
        reindexing = sources.joined(separator: ",")
        defer { reindexing = nil }
        do {
            let result = try await services.shop.reindexKnowledge(sources: sources)
            actionError = nil
            notice = "Re-indexed. " + ShopHomeView.describe(result)
            reloadToken += 1
        } catch {
            actionError = error.asAPIError
        }
    }
}

private struct ShopKnowledgeRow: View {
    let entry: ShopKnowledgeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).font(.wsHeadline).lineLimit(2)
                Spacer()
                Text(entry.sourceLabel).font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
            }
            if let preview = entry.preview?.trimmedOrNil {
                Text(preview).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Text("\(entry.chunks) chunk\(entry.chunks == 1 ? "" : "s") · \(entry.embeddedChunks) embedded")
                .font(.wsCaption).foregroundStyle(entry.unembedded > 0 ? Tone.warning.textColor : .secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One knowledge document: what the assistant reads, how it is indexed, where it came from.
private struct ShopKnowledgeDetailView: View {
    let entry: ShopKnowledgeEntry
    let canDelete: Bool
    let onRemoved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var error: APIError?

    var body: some View {
        List {
            Section {
                Text(entry.title).font(.wsTitle3)
                DetailRow(label: "Kind", value: entry.sourceLabel)
                CopyableRow(label: "Reference", value: entry.sourceRef)
                if let url = entry.url { CopyableRow(label: "Source address (cited by the assistant)", value: url) }
                DetailRow(label: "Size", value: "\(entry.characters.formatted()) characters")
                DetailRow(label: "Updated", value: Formatters.dateTime(entry.updatedAt) ?? "—")
            }
            Section {
                DetailRow(label: "Chunks", value: "\(entry.chunks)")
                DetailRow(label: "Embedded", value: "\(entry.embeddedChunks)")
                if entry.unembedded > 0 {
                    Label("\(entry.unembedded) chunk\(entry.unembedded == 1 ? "" : "s") without an embedding (found by text search only).",
                          systemImage: "exclamationmark.triangle")
                        .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            } header: {
                Text("Index")
            } footer: {
                Text("Documents are split into chunks of about 800 characters. Embedded chunks can be found by meaning, not only by words.")
            }
            Section("Start of the text") {
                Text((entry.preview ?? "—") + (entry.isTruncated ? "…" : "")).font(.wsSubheadline).textSelection(.enabled)
            }
            if canDelete {
                Section {
                    Button("Remove from the knowledge base", role: .destructive) { confirming = true }
                        .accessibilityIdentifier("shop.knowledge.remove")
                    if let error { InlineErrorRow(error: error) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this document?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove document", role: .destructive) { Task { await remove() } }
        } message: {
            Text("The assistant stops using it at once.")
        }
    }

    private func remove() async {
        do {
            try await services.shop.deleteKnowledgeEntry(entry)
            onRemoved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// Add an FAQ, a manual or a web page: split into ~800-character chunks and embedded for the assistant.
private struct ShopKnowledgeForm: View {
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var input = ShopKnowledgeDocumentInput(sourceType: ShopKnowledgeSource.faq.rawValue, title: "", url: nil, content: "")
    @State private var url = ""
    @State private var saving = false
    @State private var error: APIError?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $input.sourceType) {
                    Text("FAQ").tag(ShopKnowledgeSource.faq.rawValue)
                    Text("Manual or document").tag(ShopKnowledgeSource.manual.rawValue)
                    Text("Web page").tag(ShopKnowledgeSource.url.rawValue)
                }
                .accessibilityIdentifier("shop.knowledge.type")
                TextField("Title", text: $input.title)
                    .accessibilityIdentifier("shop.knowledge.title")
                TextField(input.sourceType == ShopKnowledgeSource.url.rawValue ? "Address (https://…)" : "Address (optional, cited by the assistant)",
                          text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("shop.knowledge.url")
            }
            Section {
                TextField(input.sourceType == ShopKnowledgeSource.faq.rawValue ? "Q: What warranty do workstations have?\nA: …"
                          : "Paste the document text…", text: $input.content, axis: .vertical)
                    .lineLimit(8...30)
                    .accessibilityIdentifier("shop.knowledge.content")
            } header: {
                Text("Content")
            } footer: {
                Text("The shop assistant quotes this to customers, so write it as you’d want it said.")
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.textColor) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
        }
        .navigationTitle("Add knowledge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add and index") { Task { await save() } }
                    .disabled(saving)
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        var body = input
        body.title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        body.content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        body.url = url.trimmedOrNil
        if let problem = body.problem {
            self.problem = problem
            return
        }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            try await services.shop.addKnowledgeDocument(body)
            onSaved(body.title)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
