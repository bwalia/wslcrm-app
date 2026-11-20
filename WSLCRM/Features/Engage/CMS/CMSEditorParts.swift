import SwiftUI

/// Featured image: choose (or upload and crop) from the media library, paste a link, or remove it.
struct CMSFeaturedImageField: View {
    @Binding var url: String
    let siteURL: String?
    var readOnly = false
    @State private var choosing = false
    @State private var showingLink = false

    var body: some View {
        Section {
            if !url.isEmpty {
                if let display = CMSMedia.displayURL(url, siteURL: siteURL) {
                    RichImage(url: display, alt: "Featured image")
                        .frame(maxHeight: 180)
                } else {
                    Text("No preview here. The image is: \(url)").font(.wsFootnote).foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                }
            }
            if !readOnly {
                Button { choosing = true } label: {
                    Label(url.isEmpty ? "Choose image" : "Change image", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("cms.featured.choose")
                // On the row, never on the Section (a Section's modals are copied onto every row).
                .sheet(isPresented: $choosing) {
                    NavigationStack {
                        CMSMediaLibraryView(pick: { asset in url = asset.string("url") ?? url })
                    }
                }
                if !url.isEmpty {
                    Button(role: .destructive) { url = "" } label: { Label("Remove image", systemImage: "xmark.circle") }
                        .accessibilityIdentifier("cms.featured.remove")
                }
                DisclosureGroup("Paste a link", isExpanded: $showingLink) {
                    TextField("https://… or /img/…", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cms.featured.link")
                }
            }
        } header: {
            Text("Featured image")
        } footer: {
            if !readOnly {
                Text("Upload, crop and reuse images from the media library. Save to keep your choice.")
            }
        }
    }
}

/// Search engine settings: the title and description shown in search results, and keywords.
struct CMSSEOSection: View {
    @Binding var draft: CMSDraft
    var readOnly = false
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup("Search engines (SEO)", isExpanded: $expanded) {
                TextField("SEO title", text: $draft.seoTitle, axis: .vertical)
                    .accessibilityIdentifier("cms.seo.title")
                TextField("Description shown in search results", text: $draft.seoDescription, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("cms.seo.description")
                TextField("Keywords, separated by commas", text: $draft.seoKeywords, axis: .vertical)
                    .accessibilityIdentifier("cms.seo.keywords")
            }
            .disabled(readOnly)
        } footer: {
            Text("Leave these empty to use the title and summary.")
        }
    }
}

/// Tags typed one at a time, shown as chips that can be removed.
struct CMSTagsSection: View {
    @Binding var draft: CMSDraft
    var readOnly = false
    @State private var typing = ""

    var body: some View {
        Section {
            if draft.tags.isEmpty {
                Text("No tags yet.").foregroundStyle(.secondaryText)
            }
            ForEach(draft.tags, id: \.self) { tag in
                HStack {
                    Label(tag, systemImage: "tag")
                    Spacer()
                    if !readOnly {
                        Button {
                            draft.tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                }
            }
            if !readOnly {
                HStack {
                    TextField("Add a tag", text: $typing)
                        .onSubmit(add)
                        .submitLabel(.done)
                        .accessibilityIdentifier("cms.tags.input")
                    Button("Add", action: add)
                        .disabled(typing.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("cms.tags.add")
                }
            }
        } header: {
            Text("Tags")
        } footer: {
            if !readOnly { Text("Short labels for topics. A tag that doesn’t exist yet is created when you save.") }
        }
    }

    private func add() {
        // A comma ends a tag, as on the web.
        for part in typing.split(separator: ",") { draft.addTag(String(part)) }
        typing = ""
    }
}

/// After publishing: which connected websites to tell now (never automatic). Shows each one's result.
struct CMSWebsiteUpdateSheet: View {
    let webhooks: [Record]
    let post: (uuid: String?, slug: String?)
    let onFinished: () -> Void

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var sending = false
    @State private var results: [(name: String, ok: Bool, text: String)] = []
    @State private var prepared = false

    var body: some View {
        Form {
            Section {
                Text("Your post is published in OpsAPI. Your website shows it once it’s updated. Pick the websites to "
                     + "update now, or choose Not now and update them later from Website updates, for example after a few more edits.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if results.isEmpty {
                Section("Websites") {
                    ForEach(webhooks) { hook in
                        let active = hook.bool("active") ?? false
                        Toggle(isOn: Binding(get: { chosen.contains(hook.id) },
                                             set: { on in if on { chosen.insert(hook.id) } else { chosen.remove(hook.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hook.string("name") ?? hook.string("url") ?? "Website")
                                if !active {
                                    Text("Paused: turn it on in Website updates").font(.wsFootnote).foregroundStyle(.secondaryText)
                                }
                            }
                        }
                        .disabled(!active)
                        .accessibilityIdentifier("cms.update.choose.\(hook.id)")
                    }
                }
            } else {
                Section("What happened") {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).font(.wsHeadline)
                                Text(result.ok ? "Updated" : result.text).font(.wsSubheadline)
                            }
                        } icon: {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.ok ? Tone.success.textColor : Tone.danger.textColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Update your website now?")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(sending)
        .toolbar {
            if results.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { finish() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Update website") { Task { await send() } }
                        .disabled(sending || chosen.isEmpty)
                        .accessibilityIdentifier("cms.update.send")
                }
            } else {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } }
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            chosen = Set(webhooks.filter { $0.bool("active") ?? false }.map(\.id))
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        var out: [(String, Bool, String)] = []
        for hook in webhooks where chosen.contains(hook.id) {
            let name = hook.string("name") ?? hook.string("url") ?? "Your website"
            do {
                let result = try await services.cms.trigger(hook.id, event: "post.published", post: post).explanation
                out.append((name, result.ok, result.text))
            } catch {
                out.append((name, false, "The update could not be sent. Try again from Website updates."))
            }
        }
        results = out.map { (name: $0.0, ok: $0.1, text: $0.2) }
    }

    private func finish() {
        dismiss()
        onFinished()
    }
}
