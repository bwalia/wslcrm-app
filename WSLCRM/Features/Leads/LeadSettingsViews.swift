import SwiftUI

// MARK: - What the shop and website forms saved on a lead

/// `metadata.shop` (the "What do I need?" survey, quotes, AI chats, requirements) and `metadata.consent`
/// (statements ticked on a website form). Nothing shows when the lead didn't come from either.
struct LeadShopSections: View {
    let metadata: [String: JSONValue]

    private static let questions: [(String, String, [String: String])] = [
        ("job", "What will your AI do?", ["team": "Private AI for my team", "tune": "Fine-tune models", "train": "Train models",
                                          "sell": "Sell GPU capacity", "unsure": "Not sure yet"]),
        ("who", "Who will use it?", ["pilot": "A pilot (1–10 people)", "team": "A team (10–100)",
                                     "company": "The whole company (100–1,000)", "platform": "A platform (1,000+)"]),
        ("size", "How big are the models?", ["small": "Small (up to 30B)", "medium": "Medium (around 70B)",
                                             "large": "Large (120B–400B)", "frontier": "Frontier (400B+)", "unsure": "Not sure"]),
        ("where", "Where will it live?", ["office": "Our office or server room", "colo": "A colocation rack",
                                          "site": "We need a site and power", "open": "Not decided"]),
        ("cond", "New or refurbished?", ["new": "New only", "mix": "Best value mix", "refurb": "Refurbished first"]),
        ("budget", "Budget", ["b25": "Up to £25k", "b100": "£25k–£100k", "b500": "£100k–£500k", "b2m": "£500k–£2m",
                              "bmax": "£2m+", "help": "Help me set one"]),
        ("when", "When do they need it?", ["d6": "Within 6 weeks", "d3": "Within 3 months", "d12": "Within 12 months",
                                           "d13": "12 months or more"]),
    ]

    private static let requirements: [(String, String)] = [
        ("goal", "Goal"), ("workloads", "Workloads"), ("models", "Models"), ("data_size", "Data"), ("team_size", "Team"),
        ("budget_gbp", "Budget (£)"), ("deadline", "Deadline"), ("in_house", "Already has"), ("sector", "Sector"),
        ("constraints", "Constraints"), ("delivery_postcode", "Delivery postcode"), ("delivery_country", "Delivery country"),
    ]

    private static let documents = [
        "terms-of-sale": "Terms of Sale", "trade-terms": "Trade terms", "privacy-notice": "Privacy notice",
        "ai-assistant": "AI assistant notice", "important-information": "Important information",
    ]

    private var shop: Record? { object(metadata["shop"]) }
    private var survey: Record? { shop?.object("survey") }
    private var consent: Record? { object(metadata["consent"]) }

    private func object(_ value: JSONValue?) -> Record? {
        if case .object(let o)? = value { return Record(o) }
        return nil
    }

    /// "2026-11-09 16:50 UTC", as the shop wrote it.
    private func when(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
    }

    var body: some View {
        if let survey { surveySection(survey) }
        if let shop { shopSection(shop) }
        if let consent { consentSection(consent) }
    }

    private func surveySection(_ survey: Record) -> some View {
        Section("“What do I need?” survey") {
            DetailRow(label: "Build", value: survey.string("ref"))
            DetailRow(label: "Recommended", value: survey.string("product_name"))
            ForEach(Self.questions, id: \.0) { key, label, options in
                if let answer = survey.string("answers.\(key)") {
                    DetailRow(label: label, value: options[answer] ?? answer)
                }
            }
            if let marketing = survey.bool("marketing") {
                DetailRow(label: "Marketing emails", value: marketing ? "Yes, opted in" : "No")
            }
            DetailRow(label: "Last activity", value: when(survey.string("last_at")))
            ForEach(survey.records("joins")) { join in
                DetailRow(label: "Started joining Trade",
                          value: [join.string("plan") == "year" ? "Yearly" : "Monthly", join.string("tier").map { "\($0) price" },
                                  when(join.string("at"))].compactMap { $0 }.joined(separator: ", "))
            }
            let chats = survey.records("chats")
            if !chats.isEmpty {
                DisclosureGroup("Asked our AI engineer \(chats.count) question\(chats.count == 1 ? "" : "s")") {
                    ForEach(chats) { chat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.string("question") ?? "").font(.wsSubheadline.weight(.semibold))
                            if let answer = chat.string("answer") { Text(answer).font(.wsSubheadline) }
                            if let at = when(chat.string("at")) { Text(at).font(.wsCaption).foregroundStyle(.secondaryText) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shopSection(_ shop: Record) -> some View {
        let quotes = shop.records("quotes").filter { $0.string("uuid") != nil }
        let sessions = shop.array("chat_sessions").compactMap(\.stringValue)
        let requirements = shop.object("requirements")
        let shown = Self.requirements.filter { requirements?.string($0.0) != nil }
        if !quotes.isEmpty || !sessions.isEmpty || !shown.isEmpty {
            Section("From the shop") {
                ForEach(quotes) { quote in
                    NavigationLink { ShopQuoteDetailView(uuid: quote.string("uuid") ?? "") } label: {
                        LabeledContent("Quote \(quote.string("number") ?? "")") {
                            Text(quote.decimal("total_minor").flatMap { Formatters.money($0 / 100, currency: "GBP") } ?? "")
                        }
                    }
                }
                if !sessions.isEmpty {
                    NavigationLink { ShopChatsListView() } label: {
                        Label(sessions.count == 1 ? "They chatted with the shop's AI" : "They chatted with the shop's AI \(sessions.count) times",
                              systemImage: "bubble.left.and.bubble.right")
                    }
                }
                ForEach(shown, id: \.0) { key, label in
                    DetailRow(label: label, value: requirements?.string(key))
                }
            }
        }
    }

    @ViewBuilder
    private func consentSection(_ consent: Record) -> some View {
        let ticks = consent.records("documents")
        if !ticks.isEmpty {
            Section {
                ForEach(ticks) { tick in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([Self.documents[tick.string("key") ?? ""] ?? tick.string("key"), tick.string("version").map { "version \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsSubheadline.weight(.semibold))
                        if let statement = tick.string("statement") { Text("“\(statement)”").font(.wsSubheadline) }
                    }
                }
            } header: {
                Text("Ticked on the form")
            } footer: {
                Text("\(when(consent.string("accepted_at")).map { "\($0). " } ?? "")The email was typed into the form, so this isn’t proof "
                     + "the owner of that address agreed.")
            }
        }
    }
}

// MARK: - Lead settings

/// How new leads are handled: speed to lead, who gets them (and the rules), the AI, qualifying and losing,
/// meetings and the website form. Only lead managers can change them; everyone else sees them read-only.
struct LeadSettingsView: View {
    @Environment(\.services) private var services
    @State private var bundle: LoadState<LeadSettingsBundle> = .idle
    @State private var settings: LeadSettings?
    @State private var original: LeadSettings?
    @State private var team: [LeadTeamMember] = []
    @State private var rules: [LeadAssignmentRule] = []
    @State private var saving = false
    @State private var error: APIError?
    @State private var notice: String?
    @State private var attemptPlan = ""
    @State private var lostReasons = ""
    @State private var newRule = NewRule()

    struct NewRule: Equatable {
        var name = ""
        var sources = ""
        var keywords = ""
        var assignee: String?
    }

    private static let days = [(1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"), (7, "Sun")]

    private var canEdit: Bool { bundle.value?.canEdit ?? false }

    var body: some View {
        Form {
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let error { Section { InlineErrorRow(error: error) } }
            switch bundle {
            case .idle, .loading:
                Section { SkeletonRow(); SkeletonRow() }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let bundle):
                if !bundle.canEdit {
                    Section { Text("Only lead managers can change these.").foregroundStyle(.secondaryText) }
                }
                if settings != nil { form(bundle) }
            }
        }
        .navigationTitle("Lead settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || (settings == original && attemptPlan == planText(original) && lostReasons == reasonsText(original)))
                        .accessibilityIdentifier("leadSettings.save")
                }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<LeadSettings, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { settings?[keyPath: path] ?? fallback }, set: { settings?[keyPath: path] = $0 })
    }

    private func intField(_ label: String, _ path: WritableKeyPath<LeadSettings, Int>) -> some View {
        LabeledContent(label) {
            TextField("", value: binding(path, 0), format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
        }
    }

    @ViewBuilder
    private func form(_ bundle: LeadSettingsBundle) -> some View {
        Group {
            Section {
                intField("Call within (minutes)", \.firstResponseMinutes)
                intField("Tell managers when late by (minutes)", \.escalateAfterMinutes)
                TextField("Currency", text: binding(\.currency, "GBP")).textInputAutocapitalization(.characters)
                LabeledContent("Opens at") { TextField("09:00", text: binding(\.workingHours.start, "09:00")).multilineTextAlignment(.trailing) }
                LabeledContent("Closes at") { TextField("17:30", text: binding(\.workingHours.end, "17:30")).multilineTextAlignment(.trailing) }
                LabeledContent("Time zone") {
                    TextField("Europe/London", text: binding(\.workingHours.timezone, "Europe/London")).multilineTextAlignment(.trailing)
                }
                HStack {
                    ForEach(Self.days, id: \.0) { day, label in
                        let on = settings?.workingHours.days.contains(day) ?? false
                        Button(label) {
                            guard var days = settings?.workingHours.days else { return }
                            if on { days.removeAll { $0 == day } } else { days = (days + [day]).sorted() }
                            settings?.workingHours.days = days
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                        .font(.wsCaption)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                TextField("Try again after (hours, comma-separated)", text: $attemptPlan)
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("Speed to lead")
            } footer: {
                Text("A new lead gets a call planned for its owner within this many working minutes. With 4, 24, 72 there are four "
                     + "tries: now, 4 hours later, a day later, three days later. Then Nurture is suggested.")
            }
            Section {
                Toggle("Give every new lead an owner automatically", isOn: binding(\.autoAssign, true))
                ForEach(team) { person in
                    let on = settings?.roundRobinUserUuids.contains(person.uuid) ?? false
                    Button {
                        guard var pool = settings?.roundRobinUserUuids else { return }
                        if on { pool.removeAll { $0 == person.uuid } } else { pool.append(person.uuid) }
                        settings?.roundRobinUserUuids = pool
                    } label: {
                        HStack {
                            Text(person.name).foregroundStyle(.primary)
                            Spacer()
                            if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            } header: {
                Text("Who gets new leads — round-robin between")
            } footer: {
                Text("Pick nobody to share leads between everyone who can work leads. Rules below are checked first.")
            }
            rulesSection
            Section {
                Toggle("Analyse new leads automatically", isOn: binding(\.aiEnabled, true))
                if bundle.aiProviders.isEmpty {
                    Text("No AI model is set up for this workspace yet, so leads aren't analysed. Add one under Workspace › AI models.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                } else {
                    Picker("Model", selection: binding(\.aiProviderUuid, nil)) {
                        Text("Any enabled (self-hosted first)").tag(String?.none)
                        ForEach(bundle.aiProviders) { provider in
                            Text(provider.name + (provider.isLocal ? " (self-hosted)" : "")).tag(Optional(provider.uuid))
                        }
                    }
                    LabeledContent("Daily budget (US$)") {
                        TextField("", value: binding(\.aiDailyCostUsd, 5), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                    }
                    intField("“Hot lead” from score", \.aiHotScore)
                }
            } header: {
                Text("AI")
            } footer: {
                Text("The AI reads every new lead, sizes the deal, suggests the next step and partners, and drafts a first reply. "
                     + "It never contacts anyone. "
                     + (bundle.webResearch ? "Deal sizes come from a web price search; only what is wanted is searched, never who wants it."
                        : "Add a Google Gemini provider to size deals from a web price search."))
            }
            Section {
                TextField("e.g. Computers & IT", text: Binding(get: { settings?.businessType ?? "" },
                                                               set: { settings?.businessType = String($0.prefix(60)) }))
                    .accessibilityIdentifier("leads.settings.businessType")
                Menu {
                    ForEach(LeadSettings.businessTypeSuggestions, id: \.self) { type in
                        Button(type) { settings?.businessType = type }
                    }
                } label: {
                    Label("Pick a common one", systemImage: "list.bullet").frame(minHeight: 44)
                }
            } header: {
                Text("Type of business")
            } footer: {
                Text("Shapes the details on each lead. Property shows the property deal fields (kind, situation, the seller's "
                     + "deadline); anything else shows the general ones. Left blank, it counts as property.")
            }
            Section {
                ForEach(Array((settings?.qualificationQuestions ?? []).enumerated()), id: \.offset) { index, _ in
                    TextField("Question \(index + 1)", text: Binding(
                        get: { settings?.qualificationQuestions[safe: index]?.label ?? "" },
                        set: { if settings?.qualificationQuestions.indices.contains(index) == true { settings?.qualificationQuestions[index].label = $0 } }))
                }
                .onDelete { settings?.qualificationQuestions.remove(atOffsets: $0) }
                Button("Add a question", systemImage: "plus") {
                    settings?.qualificationQuestions.append(LeadSettings.Question(key: "", label: ""))
                }
            } header: {
                Text("Qualification questions")
            } footer: {
                Text("The questions your team answers on a call. Swipe one to remove it.")
            }
            Section {
                TextField("One reason per line", text: $lostReasons, axis: .vertical).lineLimit(4...10)
            } header: {
                Text("Lost reasons")
            }
            Section("Stage names") {
                ForEach(LeadStage.allCases, id: \.self) { stage in
                    LabeledContent(bundle.stageLabels[stage.rawValue] ?? stage.label) {
                        TextField("Your name", text: Binding(get: { settings?.stageLabels[stage.rawValue] ?? "" },
                                                             set: { settings?.stageLabels[stage.rawValue] = $0 }))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Section {
                intField("Default length (minutes)", \.meeting.defaultMinutes)
                TextField("Default video link (https://…)", text: binding(\.meeting.defaultLink, ""))
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                intField("Remind the lead (hours before)", \.meeting.leadReminderHours)
                intField("Remind staff (minutes before)", \.meeting.staffReminderMinutes)
                Toggle("Send calendar invites when a meeting is booked", isOn: binding(\.meeting.sendInvites, true))
            } header: {
                Text("Meetings")
            } footer: {
                Text("Invites come from your workspace email, with a calendar file for Google, Outlook and Apple calendars. 0 = no reminder.")
            }
            Section {
                Toggle("Require the “I’m not a robot” check", isOn: binding(\.publicCaptcha, false))
            } header: {
                Text("Website form")
            } footer: {
                Text("Uses the Turnstile key in Forms settings. Turn it on only once your website sends the check.")
            }
        }
        .disabled(!canEdit || saving)
    }

    private var rulesSection: some View {
        Section {
            if rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondaryText) }
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name).font(.wsHeadline)
                    Text(ruleSummary(rule)).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                .swipeActions {
                    if canEdit {
                        Button("Delete", role: .destructive) { Task { await deleteRule(rule) } }
                    }
                }
            }
            if canEdit {
                TextField("New rule name, e.g. Website laptops", text: $newRule.name)
                TextField("Sources (comma-separated)", text: $newRule.sources).textInputAutocapitalization(.never)
                TextField("Words in the message (comma-separated)", text: $newRule.keywords)
                Picker("Give to", selection: $newRule.assignee) {
                    Text("Choose someone").tag(String?.none)
                    ForEach(team) { Text($0.name).tag(Optional($0.uuid)) }
                }
                Button("Add the rule", systemImage: "plus") { Task { await addRule() } }
                    .disabled(newRule.name.trimmingCharacters(in: .whitespaces).isEmpty || newRule.assignee == nil)
                    .accessibilityIdentifier("leadSettings.addRule")
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Checked top to bottom when a lead arrives; if none matches, leads go round-robin. Swipe a rule to delete it.")
        }
    }

    private func ruleSummary(_ rule: LeadAssignmentRule) -> String {
        let when = [rule.sources.isEmpty ? nil : "source: \(rule.sources.joined(separator: ", "))",
                    rule.keywords.isEmpty ? nil : "mentions: \(rule.keywords.joined(separator: ", "))"]
            .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "every lead"
        let who = rule.assigneeUserUuid.map { uuid in team.first { $0.uuid == uuid }?.name ?? "someone who left" }
            ?? "round-robin of \(rule.pool.count)"
        return "\(when) → \(who)"
    }

    static func ruleBody(_ rule: NewRule, position: Int) -> LeadAssignmentRuleBody {
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return LeadAssignmentRuleBody(name: rule.name.trimmingCharacters(in: .whitespaces), position: position,
                                      conditions: .init(sources: list(rule.sources), keywords: list(rule.keywords)),
                                      assigneeUserUuid: rule.assignee)
    }

    private func planText(_ settings: LeadSettings?) -> String {
        (settings?.attemptPlanHours ?? []).map(String.init).joined(separator: ", ")
    }

    private func reasonsText(_ settings: LeadSettings?) -> String {
        (settings?.lostReasons ?? []).joined(separator: "\n")
    }

    private func load() async {
        if bundle.value == nil { bundle = .loading }
        do {
            let loaded = try await services.leads.settings()
            bundle = .loaded(loaded)
            settings = loaded.settings
            original = loaded.settings
            attemptPlan = planText(loaded.settings)
            lostReasons = reasonsText(loaded.settings)
            async let teamResult = try? services.leads.team()
            async let rulesResult = try? services.leads.rules()
            team = await teamResult ?? team
            rules = await rulesResult ?? rules
        } catch {
            if bundle.value == nil { bundle = .failed(error.asAPIError) }
        }
    }

    private func save() async {
        guard var draft = settings else { return }
        draft.attemptPlanHours = attemptPlan.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
        draft.lostReasons = lostReasons.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        draft.qualificationQuestions.removeAll { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        saving = true
        defer { saving = false }
        do {
            let saved = try await services.leads.saveSettings(draft)
            settings = saved
            original = saved
            attemptPlan = planText(saved)
            lostReasons = reasonsText(saved)
            error = nil
            notice = "Settings saved."
        } catch {
            self.error = error.asAPIError
            notice = nil
        }
    }

    private func addRule() async {
        do {
            try await services.leads.createRule(Self.ruleBody(newRule, position: rules.count))
            newRule = NewRule()
            rules = (try? await services.leads.rules()) ?? rules
            error = nil
            notice = "Rule added."
        } catch {
            self.error = error.asAPIError
        }
    }

    private func deleteRule(_ rule: LeadAssignmentRule) async {
        do {
            try await services.leads.deleteRule(rule.uuid)
            rules.removeAll { $0.uuid == rule.uuid }
            notice = "Rule “\(rule.name)” deleted."
        } catch {
            self.error = error.asAPIError
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
