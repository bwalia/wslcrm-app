import SwiftUI

/// Marketing → Getting started: everything needed to send a first email, step by step, with a live
/// checklist that ticks itself from what the workspace has really done, and help topics that open
/// the app's own screens. `focus` opens it at one topic (the "How does this work?" links).
struct MktGuideView: View {
    var focus: String?
    /// Off when shown inside a sheet (adding people): it explains, and doesn't open other screens there.
    var opensScreens = true
    @Environment(\.services) private var services
    @State private var progress: MktGuideProgress?
    @State private var scrolledTo: String?

    init(focus: String? = nil, opensScreens: Bool = true) {
        self.focus = focus
        self.opensScreens = opensScreens
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MktGuideCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How it works, in one minute").font(.wsHeadline).accessibilityAddTraits(.isHeader)
                            MktGuideBlocks(opensScreens: opensScreens, blocks: [
                                .steps([
                                    "You connect your email account once, so emails come from you.",
                                    "You make a **list** — a group of people, like “Customers”.",
                                    "You add people to the list (type them, upload a spreadsheet, or tick them in your contacts).",
                                    "You write an **email** and send it to the list.",
                                ]),
                                .text("Every email gets an unsubscribe link automatically. Anyone who presses it is never "
                                      + "emailed again — you don’t need to do anything."),
                            ]) { scroll(proxy, to: $0) }
                        }
                    }
                    .id("top")
                    MktGuideChecklist(progress: progress, opensScreens: opensScreens) { scroll(proxy, to: $0) }
                    MktGuideCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Help topics").font(.wsHeadline).accessibilityAddTraits(.isHeader)
                            ForEach(MktGuideContent.topics) { topic in
                                Button { scroll(proxy, to: topic.id) } label: {
                                    HStack {
                                        Text(topic.title).multilineTextAlignment(.leading)
                                        Spacer()
                                        Image(systemName: "chevron.down").font(.wsCaption).foregroundStyle(.secondaryText)
                                    }
                                    .frame(minHeight: 36)
                                }
                                .accessibilityIdentifier("mkt.guide.topic.\(topic.id)")
                            }
                        }
                    }
                    ForEach(MktGuideContent.topics) { topic in
                        MktGuideCard(highlighted: scrolledTo == topic.id) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(topic.title).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                                MktGuideBlocks(opensScreens: opensScreens, blocks: topic.blocks) { scroll(proxy, to: $0) }
                                Button("Back to the top") { scroll(proxy, to: "top") }
                                    .font(.wsFootnote)
                                    .buttonStyle(.borderless)
                            }
                        }
                        .id(topic.id)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                guard let focus, scrolledTo == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scroll(proxy, to: focus) }
            }
        }
        .navigationTitle("Getting started")
        .navigationBarTitleDisplayMode(.inline)
        .task { progress = await MktGuideProgress.load(MktAudienceAPI(services)) }
        .refreshable { progress = await MktGuideProgress.load(MktAudienceAPI(services)) }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        withAnimation { proxy.scrollTo(id, anchor: .top) }
        scrolledTo = id == "top" ? nil : id
    }
}

/// A rounded card on the guide.
private struct MktGuideCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(highlighted ? Color.accentColor : Color.clear, lineWidth: 2)
            }
    }
}

// MARK: - Progress (the checklist)

/// What the workspace has really done, for the checklist (each part is best effort).
struct MktGuideProgress: Hashable, Sendable {
    var via: String?
    var addressSet: Bool?
    var dryRun: Bool?
    var lists = 0
    var people = 0
    var templates = 0
    var campaigns = 0
    var sent = 0

    static func load(_ api: MktAudienceAPI) async -> MktGuideProgress {
        async let sending = api.sendingIfPossible()
        async let lists = api.listsIfPossible()
        async let counts = api.listCounts()
        async let templates = api.templatesCount()
        async let statuses = api.campaignStatuses()
        let info = await sending
        let campaignStatuses = await statuses ?? []
        return MktGuideProgress(via: info?.via, addressSet: info?.senderAddressSet, dryRun: info?.dryRun,
                                lists: await lists?.count ?? 0, people: await counts.values.reduce(0, +),
                                templates: await templates, campaigns: campaignStatuses.count,
                                sent: campaignStatuses.filter { $0 == "sending" || $0 == "completed" }.count)
    }
}

/// One step of getting started: what it is, why, where to do it, and when it counts as done.
struct MktGuideStep: Identifiable, Hashable, Sendable {
    let title: String
    let why: String
    let action: String
    /// The app screen that does it (nil: only the help topic, e.g. connecting email in Workspace → Email).
    let screen: String?
    let guide: String
    var optional = false
    let done: @Sendable (MktGuideProgress) -> Bool

    var id: String { title }

    static func == (lhs: MktGuideStep, rhs: MktGuideStep) -> Bool { lhs.title == rhs.title }
    func hash(into hasher: inout Hasher) { hasher.combine(title) }

    static let all: [MktGuideStep] = [
        MktGuideStep(title: "Connect your email account",
                     why: "So your emails come from your own address, like hello@yourbusiness.co.uk.",
                     action: "Show me how", screen: nil, guide: "connect-email", done: { $0.via == "workspace" }),
        MktGuideStep(title: "Add your business name and address",
                     why: "The law says every promotional email must show who sent it.",
                     action: "Add address", screen: Marketing.Screen.settings, guide: "business-address",
                     done: { $0.addressSet == true }),
        MktGuideStep(title: "Make a list", why: "A list is the group of people who will get your email.",
                     action: "Make a list", screen: Marketing.Screen.lists, guide: "make-list", done: { $0.lists > 0 }),
        MktGuideStep(title: "Add people to your list",
                     why: "Type their email addresses, upload a spreadsheet, or tick people in your contacts.",
                     action: "Add people", screen: Marketing.Screen.lists, guide: "add-people", done: { $0.people > 0 }),
        MktGuideStep(title: "Design an email template",
                     why: "A ready-made design you can reuse for every email. You can skip this.",
                     action: "Open the Studio", screen: Marketing.Screen.studio, guide: "templates", optional: true,
                     done: { $0.templates > 0 }),
        MktGuideStep(title: "Write your email", why: "Give it a subject and the words you want to say.",
                     action: "Write an email", screen: Marketing.Screen.campaigns, guide: "write-email",
                     done: { $0.campaigns > 0 }),
        MktGuideStep(title: "Switch off test mode",
                     why: "While test mode is on, nothing is really sent. Switch it off when you are ready.",
                     action: "Open settings", screen: Marketing.Screen.settings, guide: "test-mode",
                     done: { $0.dryRun == false }),
        MktGuideStep(title: "Send yourself a test, then send to your list",
                     why: "Check it in your own inbox first, then press Send now (or pick a time).",
                     action: "Go to my emails", screen: Marketing.Screen.campaigns, guide: "send", done: { $0.sent > 0 }),
    ]

    /// The first required step not done yet.
    static func next(_ progress: MktGuideProgress) -> MktGuideStep? {
        all.first { !$0.optional && !$0.done(progress) }
    }

    static func doneCount(_ progress: MktGuideProgress) -> (done: Int, of: Int) {
        let required = all.filter { !$0.optional }
        return (required.filter { $0.done(progress) }.count, required.count)
    }
}

/// The getting-started checklist, ticked from what the workspace has really done.
private struct MktGuideChecklist: View {
    let progress: MktGuideProgress?
    let opensScreens: Bool
    let showTopic: (String) -> Void

    var body: some View {
        MktGuideCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your checklist").font(.wsHeadline).accessibilityAddTraits(.isHeader)
                if let progress {
                    let count = MktGuideStep.doneCount(progress)
                    let next = MktGuideStep.next(progress)
                    Text(next == nil ? "All done — you’re ready to send emails whenever you like."
                         : "\(count.done) of \(count.of) steps done. Steps tick themselves when you finish them.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    ProgressView(value: Double(count.done), total: Double(max(count.of, 1)))
                        .accessibilityLabel("Getting started progress")
                    ForEach(Array(MktGuideStep.all.enumerated()), id: \.element.id) { index, step in
                        MktGuideStepRow(index: index, step: step, done: step.done(progress), isNext: step == next,
                                        opensScreens: opensScreens, showTopic: showTopic)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct MktGuideStepRow: View {
    let index: Int
    let step: MktGuideStep
    let done: Bool
    let isNext: Bool
    let opensScreens: Bool
    let showTopic: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(circleFill).frame(width: 30, height: 30)
                    if done {
                        Image(systemName: "checkmark").font(.wsCaption.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(index + 1)").font(.wsCaption.bold()).foregroundStyle(isNext ? Color.white : Color.primary)
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title + (step.optional ? " (optional)" : "")).font(.wsBody.weight(.semibold))
                    Text(step.why).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            HStack(spacing: 12) {
                Button("Show me how") { showTopic(step.guide) }
                    .buttonStyle(.bordered)
                if !done, opensScreens, let screen = step.screen {
                    NavigationLink(value: NativeScreenRoute(screen)) {
                        Text(step.action)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isNext ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("mkt.guide.step.\(step.guide)")
                }
            }
            .padding(.leading, 42)
        }
        .padding(10)
        .background(isNext ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.title)\(done ? ", done" : isNext ? ", do this next" : ", not done yet")")
    }

    private var circleFill: Color {
        if done { return Tone.success.solidColor }
        return isNext ? Tone.brand.solidColor : Color.secondary.opacity(0.2)
    }
}

/// "Next: …" — the one card other marketing screens can show at the top (the web's journey bar).
struct MktGuideNextStepCard: View {
    @Environment(\.services) private var services
    @State private var progress: MktGuideProgress?

    var body: some View {
        Group {
            if let progress, let next = MktGuideStep.next(progress) {
                let count = MktGuideStep.doneCount(progress)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Getting started: \(count.done) of \(count.of) steps done")
                        .font(.wsFootnote.weight(.semibold)).foregroundStyle(Tone.brand.textColor)
                    ProgressView(value: Double(count.done), total: Double(max(count.of, 1)))
                    Text("Next: \(next.title)").font(.wsHeadline)
                    Text(next.why).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    HStack {
                        if let screen = next.screen {
                            NavigationLink(value: NativeScreenRoute(screen)) { Text(next.action) }
                                .buttonStyle(.borderedProminent)
                        }
                        NavigationLink {
                            MktGuideView(focus: next.screen == nil ? next.guide : nil)
                        } label: {
                            Text(next.screen == nil ? "Show me how" : "See all the steps")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("mkt.guide.next")
            }
        }
        .task { progress = await MktGuideProgress.load(MktAudienceAPI(services)) }
    }
}

// MARK: - Topics

/// One piece of a help topic.
enum MktGuideBlock: Hashable, Sendable {
    /// A paragraph (Markdown: **bold**, *italic*).
    case text(String)
    case steps([String])
    case bullets([String])
    case tip(String)
    /// A button that opens one of the app's screens.
    case open(String, screen: String)
    /// A link to another help topic.
    case topic(String, id: String)
    /// Where to find the email server settings for the common providers.
    case providers
    /// What a contacts file looks like, and a way to save the example.
    case exampleFile
}

struct MktGuideTopic: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let blocks: [MktGuideBlock]
}

private struct MktGuideBlocks: View {
    var opensScreens = true
    let blocks: [MktGuideBlock]
    let showTopic: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
    }

    @ViewBuilder
    private func view(_ block: MktGuideBlock) -> some View {
        switch block {
        case .text(let text):
            Text(RichMarkdownParser.inline(text)).font(.wsBody).fixedSize(horizontal: false, vertical: true)
        case .steps(let steps):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.wsBody.monospacedDigit()).foregroundStyle(.secondaryText)
                        Text(RichMarkdownParser.inline(step)).font(.wsBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondaryText)
                        Text(RichMarkdownParser.inline(item)).font(.wsBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .tip(let text):
            Text(RichMarkdownParser.inline("**Tip:** " + text))
                .font(.wsBody)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        case .open(let title, let screen):
            if opensScreens {
                NavigationLink(value: NativeScreenRoute(screen)) {
                    Label(title, systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("mkt.guide.open.\(screen)")
            }
        case .topic(let title, let id):
            Button { showTopic(id) } label: { Label(title, systemImage: "arrow.down.circle") }
                .buttonStyle(.borderless)
        case .providers:
            VStack(spacing: 8) {
                ForEach(MktGuideContent.providers, id: \.name) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name).font(.wsHeadline)
                        if let server = provider.server {
                            LabeledContent("Server") { Text(server).font(.system(.footnote, design: .monospaced)) }
                            LabeledContent("Port") { Text("587") }
                            LabeledContent("Security") { Text("STARTTLS") }
                        }
                        Text(RichMarkdownParser.inline(provider.login)).font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    .font(.wsSubheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        case .exampleFile:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(["Email", "First name", "Last name", "Company"], id: \.self) {
                                Text($0).font(.wsFootnote.weight(.semibold))
                            }
                        }
                        Divider()
                        GridRow {
                            ForEach(["jane@example-plumbing.co.uk", "Jane", "Smith", "Example Plumbing Ltd"], id: \.self) {
                                Text($0).font(.wsFootnote)
                            }
                        }
                    }
                    .padding(10)
                }
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                if let url = try? EngageExport.temporaryFile(Data(MktAudienceText.exampleCSV.utf8),
                                                             name: "example-contacts.csv") {
                    ShareLink(item: url) { Label("Download an example file", systemImage: "arrow.down.doc") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("mkt.guide.example")
                }
            }
        }
    }
}

/// The guide's words, written for the app's own screens.
enum MktGuideContent {
    struct Provider: Sendable {
        let name: String
        let server: String?
        let login: String
    }

    static let providers: [Provider] = [
        Provider(name: "Gmail or Google Workspace", server: "smtp.gmail.com",
                 login: "Log in with your full email address and an **app password** (not your normal password): "
                    + "Google Account → Security → 2-Step Verification → App passwords."),
        Provider(name: "Microsoft 365 or Outlook", server: "smtp.office365.com",
                 login: "Log in with your full email address and its password."),
        Provider(name: "Zoho Mail", server: "smtp.zoho.eu (or smtp.zoho.com)",
                 login: "Log in with your full email address and its password."),
        Provider(name: "Anything else", server: nil,
                 login: "Search for “<your email company> SMTP settings”, or ask them for it."),
    ]

    static let topics: [MktGuideTopic] = [
        MktGuideTopic(id: "connect-email", title: "Connect your email account", blocks: [
            .text("Do this once. Until you do, emails go out from the platform’s shared address instead of yours, and "
                  + "people are less likely to trust them."),
            .steps([
                "In the menu, open **Workspace**, then **Email**.",
                "Under **Email server (SMTP)**, fill in the boxes using the details below for your email provider.",
                "Type the address people should see in **From address**, and your business name in **From name**.",
                "Make sure **Use this server** is switched on, then press **Save**.",
                "Type your own email in **Send a test email to** and press **Send test**. Check your inbox (and the spam "
                    + "folder). If it arrived, you’re connected.",
            ]),
            .providers,
            .tip("Gmail sends about 500 emails a day, Google Workspace about 2,000. Tell the system your limit under "
                 + "**Emails per day** in Marketing → Settings, and the rest wait for the next day."),
            .open("Check how your emails are sent", screen: Marketing.Screen.settings),
        ]),
        MktGuideTopic(id: "business-address", title: "Add your business name and address", blocks: [
            .steps([
                "Open **Marketing → Settings**.",
                "In **Business name and postal address (email footer)**, type your business name and full postal address.",
                "Press **Save**.",
            ]),
            .text("It appears at the bottom of every email, next to the unsubscribe link. UK and US law require it."),
            .open("Open Marketing settings", screen: Marketing.Screen.settings),
        ]),
        MktGuideTopic(id: "test-mode", title: "Test mode, and how many emails go out", blocks: [
            .text("**Test mode** lets you practise: everything works, but no email really leaves. It’s the "
                  + "**Test mode: don’t really send** switch in Marketing → Settings."),
            .bullets([
                "Leave it on while you are learning.",
                "Switch it **off** (and press **Save**) when you want emails — including test emails to yourself — to really arrive.",
            ]),
            .text("In the same place you can set:"),
            .bullets([
                "**Emails per day** — your email provider’s daily limit (500 for Gmail). 0 means no limit.",
                "**Email sends per minute** — how fast emails go out. The normal setting is fine.",
                "**Emails sent at once** — leave it at 1 unless your provider allows more.",
            ]),
            .text("The top of Marketing → Settings shows what is set now, under “How your emails are sent”."),
            .open("Open Marketing settings", screen: Marketing.Screen.settings),
        ]),
        MktGuideTopic(id: "make-list", title: "Make a list", blocks: [
            .steps([
                "Open **Marketing → Lists**.",
                "Press **+** (Make a new list). The first time, press **Make a list**.",
                "Type a name you’ll recognise, like “Customers” or “Local businesses”, and press **Create list**.",
            ]),
            .text("Your new list opens straight away, ready for you to add people."),
            .tip("Make a separate list for each group you write to differently — for example one for customers and one "
                 + "for businesses you’d like to win."),
            .open("Open Lists", screen: Marketing.Screen.lists),
        ]),
        MktGuideTopic(id: "add-people", title: "Add people to a list", blocks: [
            .text("Open **Marketing → Lists** and tap your list. Press **Add people to this list** and pick one of the three ways:"),
            .bullets([
                "**Type emails** — type or paste them, one per line, then press **Next**.",
                "**Upload a file** — choose an Excel, CSV or PDF file. See “Upload a spreadsheet” below.",
                "**From my contacts** — search, tick the people you want (or **Tick everyone shown**), then press **Next**.",
            ]),
            .text("Then, on the check screen:"),
            .steps([
                "Answer **Who are these people?** — *Businesses I want to tell about my products*, or *People who asked to get my emails*.",
                "Read how many people will be added, and who is left out and why.",
                "Tick the box to confirm you’re allowed to email them.",
                "Press **Add … to the list**. Done — they appear under **People in this list**.",
            ]),
            .tip("Someone added twice is only added once, and anyone who ever unsubscribed is left out automatically. To "
                 + "take someone off a list, swipe left on them and press **Remove** (they stay in your contacts)."),
            .topic("Upload a spreadsheet (Excel, CSV) or PDF", id: "import-file"),
            .open("Open Lists", screen: Marketing.Screen.lists),
        ]),
        MktGuideTopic(id: "import-file", title: "Upload a spreadsheet (Excel, CSV) or PDF", blocks: [
            .text("The file only needs email addresses. If it also has names and company names, they are used to "
                  + "personalise your emails (“Hi Jane”). It works best like this — one person per row, with a heading on the first row:"),
            .exampleFile,
            .steps([
                "Save it. From Excel, a normal **.xlsx** file is fine. From Google Sheets use *File → Download → Microsoft "
                    + "Excel* or *Comma-separated values (.csv)*. Old *.xls* files: open them and save again as .xlsx.",
                "Put the file in the Files app (or iCloud Drive) so you can pick it.",
                "In your list, choose **Upload a file** and pick the file. Files up to 7 MB work (tens of thousands of people).",
                "Check what will be added, answer the question, tick the box and press Add.",
            ]),
            .text("What gets left out, and why:"),
            .bullets([
                "The same address twice — it’s added once.",
                "People who unsubscribed before — never emailed again.",
                "For *Businesses I want to tell about my products*: personal addresses like Gmail or Hotmail. The law only "
                    + "lets you send those people marketing if they asked for it. If they did, choose *People who asked to get my emails*.",
            ]),
            .tip("Bought a list of companies? Write where it came from in the note box — it’s kept as a record in case anyone asks."),
        ]),
        MktGuideTopic(id: "templates", title: "Make an email template", blocks: [
            .text("A template is a saved email design you can reuse. You don’t need one, but it saves time."),
            .steps([
                "Open **Marketing → Studio**.",
                "New here? Add the ready-made templates to get some designs to start from, then tap one.",
                "Change the words like a normal document: tap a part of the email to change it, and use the picture "
                    + "button to add a photo or logo.",
                "To greet each person by name, add the **First name** merge field. It becomes “Jane” in Jane’s email (or "
                    + "“there” if there’s no name).",
                "Save it as a draft, and **Publish** it when it’s ready to use.",
            ]),
            .open("Open the Studio", screen: Marketing.Screen.studio),
        ]),
        MktGuideTopic(id: "write-email", title: "Write an email", blocks: [
            .steps([
                "The easiest way: in your list, press **Write an email to them**. Or open **Marketing → Campaigns** and start a new one.",
                "On the **Content** tab, choose a ready-made design — or create one with AI: say what the email is about "
                    + "and the AI writes it for you. Anything in [square brackets] is for you to fill in.",
                "Type the **Subject** — the line people see in their inbox. Add the person’s first name if you like.",
                "Change the words in the email, just like a normal document. Add pictures and a big button that links to your website.",
                "The preview shows exactly what people will see. Save the content.",
            ]),
            .tip("You don’t need to add an unsubscribe link or your address — they are added to every email for you."),
            .open("Open Campaigns", screen: Marketing.Screen.campaigns),
        ]),
        MktGuideTopic(id: "send", title: "Send a test, then send to your list", blocks: [
            .steps([
                "Open your email in **Marketing → Campaigns** and go to the **Audience** tab.",
                "Under **Who gets this email**, choose your list (if you came from your list, it’s already chosen).",
                "Under **Send yourself a test**, your own email is already filled in — press **Send test**. It doesn’t add "
                    + "you to the list. (Test mode must be off for it to really arrive.)",
                "Big list? Fill in **Per batch** and **Minutes between batches** — for example 400 and 60 sends 400 "
                    + "emails every hour. Leave them empty to send to everyone at once.",
                "Press **Check it**. It checks everything and tells you how many people will get the email, and why anyone is left out.",
                "Press **Send now** — or **Schedule** to pick a date and time.",
            ]),
            .tip("Emails are not sent at night (quiet hours, 9pm to 8am) — they wait and go out in the morning. You can "
                 + "change the hours in Marketing → Settings."),
            .open("Open Campaigns", screen: Marketing.Screen.campaigns),
        ]),
        MktGuideTopic(id: "results", title: "See how it went", blocks: [
            .text("Open the email in **Campaigns** and go to the **Performance** tab to see how many were sent, opened "
                  + "and clicked, and who unsubscribed. The **Overview** shows all your emails together."),
            .text("“Opened” is an estimate: some email apps hide opens and some count them twice. Clicks are more reliable."),
            .open("Open the Overview", screen: Marketing.Screen.overview),
        ]),
        MktGuideTopic(id: "unsubscribe", title: "Unsubscribes", blocks: [
            .bullets([
                "Every email has an unsubscribe link at the bottom. You never need to add it.",
                "The link opens a page with an **Unsubscribe** button. Once they press it, this workspace never emails them "
                    + "again — even if you upload them again later.",
                "Only they can undo it: the same page has a **Subscribe again** button.",
                "See everyone who unsubscribed under **Marketing → Unsubscribed**. You can also block an address there yourself.",
            ]),
            .open("Open Unsubscribed", screen: Marketing.Screen.unsubscribed),
        ]),
        MktGuideTopic(id: "problems", title: "Something isn’t working", blocks: [
            .bullets([
                "**Nobody got my email.** Is test mode off? Is your email account connected (Workspace → Email → "
                    + "**Send test**)? Did you reach your daily limit? Check Marketing → Settings. Look in spam folders too.",
                "**It’s still sending hours later.** That’s normal with batches, quiet hours or a daily limit — the rest go out on their own.",
                "**Some people were left out.** Press **Check it** on the Audience tab: it lists the reasons "
                    + "(unsubscribed, no permission, already emailed recently).",
                "**My list says “Empty”.** Tap it and use **Add people to this list**.",
                "**My list has no “Add people” button.** It’s a smart list (it has a sparkle icon): it fills itself from "
                    + "your contacts using rules. Press **Make it a regular list** to add people yourself.",
                "**My emails land in spam.** Send from your own connected email, avoid ALL CAPITALS and lots of "
                    + "exclamation marks, and send to people who expect to hear from you.",
            ]),
            .open("Open Marketing settings", screen: Marketing.Screen.settings),
        ]),
    ]
}
