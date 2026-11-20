import SwiftUI

/// Ready-made designs, the workspace's saved templates and "Create a design with AI".
/// Calls `onPick` with the chosen design, then closes itself. Present it in a `NavigationStack`.
struct MktDesignGallery: View {
    let onPick: (MktDesign) -> Void
    /// Which designs to show (`email` or `sms`).
    var channel = "email"

    init(channel: String = "email", onPick: @escaping (MktDesign) -> Void) {
        self.channel = channel
        self.onPick = onPick
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var designs: [MktTemplate]?
    @State private var error: APIError?
    @State private var notice: EngageNotice?
    @State private var adding = false

    private var canCreate: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.templates) }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Pick one, then change the words, pictures and buttons. It replaces what’s in this "
                            + "message now.")
            }
            if channel == "email", canCreate {
                Section {
                    NavigationLink {
                        MktDesignAI { design in finish(design) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Create one with AI").font(.wsHeadline)
                                Text("Describe your email and get a design made for it.")
                                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            }
                        } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("mkt.gallery.ai")
                }
            }
            if let error, designs?.isEmpty ?? true {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            if let designs {
                if designs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No ready-made designs yet").font(.wsHeadline)
                            Text("Add them: welcome, newsletter, special offer, event invitation and more.")
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            if canCreate {
                                Button { Task { await addReadyMade() } } label: {
                                    Label("Add ready-made designs", systemImage: "sparkles")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(adding)
                                .accessibilityIdentifier("mkt.gallery.seedEmpty")
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section("Designs") {
                        ForEach(designs) { design in
                            Button { finish(design.design) } label: { MktDesignCard(template: design) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("mkt.gallery.design.\(design.uuid)")
                        }
                    }
                }
            } else if error == nil {
                Section { HStack { Spacer(); ProgressView("Loading designs…"); Spacer() } }
            }
            Section {
                NavigationLink {
                    MktTemplatesListView(mode: .studio, embedded: true)
                } label: {
                    Label("Design your own in the Studio", systemImage: "paintpalette")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle("Choose a design")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await addReadyMade() } } label: {
                        Label("Add the latest ready-made designs", systemImage: "sparkles")
                    }
                    .disabled(adding)
                    .accessibilityIdentifier("mkt.gallery.seed")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func finish(_ design: MktDesign) {
        onPick(design)
        dismiss()
    }

    private func load() async {
        do {
            designs = try await services.marketingDesign.allTemplates(channel: channel)
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
            if designs == nil { designs = [] }
        }
    }

    private func addReadyMade() async {
        adding = true
        defer { adding = false }
        do {
            let added = try await services.marketingDesign.seed()
            notice = .done(added > 0 ? "\(added) new design\(added == 1 ? "" : "s") added."
                                     : "You already have all the ready-made designs.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// A design as a card: a small native picture of the email, its name and subject.
struct MktDesignCard: View {
    let template: MktTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if template.isEmail, !template.bodyHTML.isEmpty {
                    RichTextView(html: MktEmailSample.fill(template.bodyHTML), appearance: .email, linksOpen: false)
                        .frame(width: 560)
                        .scaleEffect(0.5, anchor: .top)
                        .frame(width: 280, height: 220, alignment: .top)
                        .clipped()
                } else {
                    Text(MktEmailSample.fill(template.bodyText))
                        .font(.wsSubheadline)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            Text(template.name).font(.wsHeadline)
            if !template.subject.isEmpty {
                Text(MktEmailSample.fill(template.subject)).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Text("Use this design →").font(.wsFootnote.weight(.semibold)).foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// "Create a design with AI": describe the email, pick a tone, see it, use it or save it.
struct MktDesignAI: View {
    /// Called with the design to use (the gallery passes it on and closes).
    let use: (MktDesign) -> Void

    @Environment(\.services) private var services
    @State private var brief = ""
    @State private var tone = "friendly"
    @State private var busy = false
    @State private var saving = false
    @State private var design: MktDesign?
    @State private var problem: String?
    @State private var notice: EngageNotice?

    static let tones: [(value: String, label: String)] = [
        ("friendly", "Friendly"), ("professional", "Professional"), ("excited", "Exciting"), ("formal", "Formal"),
    ]

    static let ideas = [
        "20% off all garden furniture this weekend only, code GARDEN20",
        "Invite customers to our shop’s 10th birthday on Saturday 14 June, free cake and prizes",
        "Introduce our website design service to local restaurants, ask them to book a free call",
        "Thank customers for their order and ask them to leave a Google review",
    ]

    var body: some View {
        Form {
            if let design {
                Section {
                    LabeledContent("Subject", value: MktEmailSample.fill(design.subject))
                    RichTextView(html: MktEmailSample.fill(design.bodyHTML), appearance: .email, linksOpen: false)
                }
                Section {
                    Button { use(design) } label: { Label("Use this design", systemImage: "checkmark.circle") }
                        .accessibilityIdentifier("mkt.ai.use")
                    Button { Task { await save(design) } } label: { Label("Save as a design", systemImage: "square.and.arrow.down") }
                        .disabled(saving)
                        .accessibilityIdentifier("mkt.ai.save")
                    Button { Task { await create() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        .disabled(busy)
                    Button { self.design = nil } label: { Label("Change the description", systemImage: "pencil") }
                } footer: {
                    Text("Anything in [square brackets] is for you to fill in. You can change every word, picture and "
                         + "button after.")
                }
                Section { MktEmailPreviewLimits() }
            } else {
                Section {
                    TextField("e.g. 20% off all garden furniture this weekend only, code GARDEN20", text: $brief, axis: .vertical)
                        .lineLimit(4...8)
                        .disabled(busy)
                        .onChange(of: brief) { _, value in if value.count > 2000 { brief = String(value.prefix(2000)) } }
                        .accessibilityIdentifier("mkt.ai.brief")
                } header: {
                    Text("What’s the email about?")
                } footer: {
                    Text("Say who it’s for and what you want them to do. Mention any offer, date, price or link.")
                }
                Section("Ideas") {
                    ForEach(Self.ideas, id: \.self) { idea in
                        Button(idea) { brief = idea }
                            .font(.wsSubheadline)
                            .disabled(busy)
                    }
                }
                Section {
                    Picker("Tone", selection: $tone) {
                        ForEach(Self.tones, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("mkt.ai.tone")
                }
                Section {
                    Button { Task { await create() } } label: {
                        if busy {
                            HStack { ProgressView(); Text("Writing your email… This can take up to a minute.") }
                        } else {
                            Label("Create my design", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("mkt.ai.create")
                }
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle("Create a design with AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func create() async {
        guard brief.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else {
            problem = "Say what the email is about in a sentence or two."
            return
        }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            design = try await services.marketingDesign.aiDesign(brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                 tone: tone)
        } catch {
            problem = Self.message(error.asAPIError, fallback: "The AI couldn’t write it this time. Please try again.")
        }
    }

    private func save(_ design: MktDesign) async {
        saving = true
        defer { saving = false }
        do {
            _ = try await services.marketingDesign.create(MktTemplate(name: design.name, channel: "email", subject: design.subject,
                                                                       previewText: design.previewText,
                                                                       bodyHTML: design.bodyHTML, bodyText: design.bodyText))
            notice = .done("Saved as “\(design.name)”. It’s in your designs now.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    /// The server's words when it has them (the daily AI limit), else plain ones.
    static func message(_ error: APIError, fallback: String) -> String {
        if error.isConnectivityProblem { return "Can’t reach the server. Check your internet connection and try again." }
        if let server = error.serverError, !server.message.isEmpty, server.status != 500 { return server.message }
        return fallback
    }
}
