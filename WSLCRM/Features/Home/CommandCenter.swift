import SwiftUI

/// The top of Home: one box that asks "What would you like to do?". Typing searches every screen in the workspace
/// ("Jump to"); a place opens at once, anything else goes to the AI agent, which does the job with the person's own
/// permissions and opens the screens it worked in. Suggestions come from what needs the person today.
struct CommandCenter: View {
    let places: [CommandRouter.Place]
    let signals: [HomeSignal]
    /// The person has the AI agent (chat in their menu); without it the box only searches.
    let canAsk: Bool
    /// The person's last request to the all-round assistant, to pick up where they left off.
    let lastRequest: String?
    let agentBusy: Bool
    @Binding var focusRequest: Int
    let onOpen: (CommandRouter.Place) -> Void
    let onAsk: (String) -> Void
    let onContinue: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ChatAssistantAvatar(size: 34, busy: agentBusy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(canAsk ? "What would you like to do?" : "Where would you like to go?")
                        .font(.brandTitle)
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text(canAsk ? "Ask, search or give me a job — I'll open the right screen or do it for you."
                                : "Type the name of any screen in your workspace.")
                        .font(.brandSubheadline)
                        .foregroundStyle(Palette.onDarkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            composer

            if let query = text.trimmedOrNil {
                results(for: query)
            } else {
                if canAsk { suggestionChips }
                if canAsk, let lastRequest {
                    Button(action: onContinue) {
                        HStack(spacing: 10) {
                            Image(systemName: agentBusy ? "ellipsis.bubble" : "arrow.uturn.forward.circle")
                                .font(.brandHeadline)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agentBusy ? "Working on your last request" : "Continue where you left off")
                                    .font(.brandCaption)
                                    .foregroundStyle(Palette.onDarkMuted)
                                Text(lastRequest)
                                    .font(.brandCallout)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.brandCaption)
                        }
                        .foregroundStyle(Palette.onDarkInk)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityIdentifier("home.command.continue")
                }
            }
        }
        .padding(sizeClass == .regular ? 24 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Palette.heroGradient
                RadialGradient(colors: [Color.accentColor.opacity(0.45), .clear], center: .topTrailing,
                               startRadius: 10, endRadius: 320)
                RadialGradient(colors: [Palette.tileColors[1].opacity(0.35), .clear], center: .bottomLeading,
                               startRadius: 10, endRadius: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Palette.indigo.opacity(0.35), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .onChange(of: focusRequest) { focused = true }
        .accessibilityIdentifier("home.command")
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.brandHeadline)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            TextField(canAsk ? "e.g. “Which quotes should I chase?” or “open leads”" : "Search screens…",
                      text: $text, axis: .vertical)
                .font(.brandBody)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityLabel("Ask AI or search")
                .accessibilityIdentifier("home.command.field")
            if text.trimmedOrNil != nil {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Palette.onDarkMuted)
            }
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.brandHeadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(text.trimmedOrNil == nil ? Color.white.opacity(0.15) : Color.accentColor, in: Circle())
            }
            .disabled(text.trimmedOrNil == nil)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Go")
            .accessibilityIdentifier("home.command.go")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(focused ? Color.accentColor.opacity(0.8) : .white.opacity(0.14), lineWidth: focused ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    // MARK: Results while typing

    @ViewBuilder
    private func results(for query: String) -> some View {
        let matches = CommandRouter.search(query, places: places)
        VStack(alignment: .leading, spacing: 4) {
            if canAsk {
                resultRow(systemImage: "sparkles", title: "Ask AI", detail: "“\(query)”", id: "ask") {
                    go(.ask(query))
                }
            } else if matches.isEmpty {
                Text("Nothing in your workspace is called that.")
                    .font(.brandCallout)
                    .foregroundStyle(Palette.onDarkMuted)
                    .padding(6)
            }
            if !matches.isEmpty {
                Text("JUMP TO")
                    .font(.brandEyebrow)
                    .tracking(1.2)
                    .foregroundStyle(Palette.onDarkMuted)
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
                ForEach(matches, id: \.key) { place in
                    resultRow(systemImage: place.systemImage, title: place.name, detail: nil, id: place.key) {
                        go(.open(place))
                    }
                }
            }
        }
    }

    private func resultRow(systemImage: String, title: String, detail: String?, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.brandCallout.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.brandHeadline)
                if let detail {
                    Text(detail).font(.brandCallout).foregroundStyle(Palette.onDarkMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.brandCaption).foregroundStyle(Palette.onDarkMuted)
            }
            .foregroundStyle(Palette.onDarkInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("home.command.result.\(id)")
    }

    // MARK: Suggestions

    private var suggestionChips: some View {
        ChatFlowLayout(spacing: 8) {
            ForEach(Self.suggestions(for: signals), id: \.self) { prompt in
                Button { go(.ask(prompt)) } label: {
                    Text(prompt)
                        .font(.brandFootnote)
                        .foregroundStyle(Palette.onDarkInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12)))
                }
                .buttonStyle(.pressableCard)
                .accessibilityHint("Asks the AI agent")
                .accessibilityIdentifier("home.command.suggestion")
            }
        }
    }

    /// Up to five things to ask, led by what needs the person today.
    static func suggestions(for signals: [HomeSignal]) -> [String] {
        var out = signals.compactMap { prompts[$0.id] }
        for general in ["What should I focus on today?", "Summarise this week's sales", "Create a task for me"]
            where !out.contains(general) {
            out.append(general)
        }
        return Array(out.prefix(5))
    }

    static let prompts: [String: String] = [
        "shop.payment": "Which orders are still waiting for payment?",
        "shop.fulfil": "Which paid orders do I need to send?",
        "shop.quotes": "Which open quotes should I chase first?",
        "shop.stock": "Which low-stock products should I reorder?",
        "leads.overdue": "Show my overdue lead follow-ups",
        "leads.today": "Who do I need to follow up with today?",
        "leads.meetings": "What meetings do I have today?",
        "leads.unassigned": "Show the leads with no owner",
        "tasks.overdue": "What tasks are overdue?",
        "tasks.today": "What tasks are due today?",
        "invoices.overdue": "Which invoices are overdue?",
        "fs.visits": "What visits are booked today?",
        "fs.overdue": "Which jobs are overdue?",
        "deals.overdue": "Which deal tasks are overdue?",
        "deals.approvals": "What's waiting for my approval?",
        "timesheets.approve": "Which timesheets need my approval?",
    ]

    // MARK: Actions

    private func submit() {
        guard let decision = CommandRouter.decide(text, places: places) else { return }
        if case .ask(let query) = decision, !canAsk {
            // No agent: the best screen match, if there is one.
            if let first = CommandRouter.search(query, places: places).first { go(.open(first)) }
            return
        }
        go(decision)
    }

    private func go(_ decision: CommandRouter.Decision) {
        focused = false
        text = ""
        switch decision {
        case .open(let place): onOpen(place)
        case .ask(let request): onAsk(request)
        }
    }
}
