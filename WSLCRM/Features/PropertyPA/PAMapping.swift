import Foundation

/// Turns opsapi's PA wire shapes into the app's screen models. Pure, so it's tested without a
/// server. Nothing here ranks, scores or invents: order and facts come from the server.
enum PAMapping {
    // MARK: Gate and Today

    static func me(from briefing: PAServerBriefing) -> PAMe {
        PAMe(enabled: true, role: briefing.me?.isManager == true ? .manager : .agent, userUuid: nil,
             displayName: briefing.me?.name,
             permissions: briefing.me?.isManager == true ? ["knowledge": ["manage"], "manager_view": ["read"]] : ["knowledge": ["create"]],
             stt: "server", maxAudioSeconds: 300, timezone: nil)
    }

    /// Cards from the briefing, in its order. Without a server score there's no "Why #1?"
    /// (the app never makes one up) and no time packing.
    static func today(from briefing: PAServerBriefing, manager: Bool) -> PAToday {
        var today = PAToday()
        today.generatedAt = briefing.now
        if manager {
            today.cards = briefing.handoffsForMe.enumerated().map { index, handoff in
                PACard(uuid: "handoff-\(handoff.uuid)", rank: index + 1, kind: .handoff,
                       person: handoff.fromName.map { PACard.Person(name: $0) }, opportunityUuid: handoff.opportunityUuid,
                       handoffUuid: handoff.uuid, action: handoff.question,
                       whyNow: handoff.createdAt.map { "Asked \(Formatters.relative($0) ?? "")" })
            }
            today.brief = .init(text: managerBrief(briefing))
        } else {
            today.cards = briefing.opportunities.enumerated().map { index, opportunity in
                card(from: opportunity, rank: index + 1)
            }
            today.brief = .init(text: agentBrief(briefing))
        }
        today.mode = "briefing"
        return today
    }

    static func card(from opportunity: PAServerBriefing.Opportunity, rank: Int) -> PACard {
        let name = opportunity.personName ?? opportunity.title ?? "Opportunity"
        var why: [String] = []
        if let reason = opportunity.nextActionReason { why.append(reason) }
        if let due = opportunity.nextActionAt { why.append("Due \(Formatters.relative(due) ?? "")") }
        if why.isEmpty, let last = opportunity.lastMeaningfulContactAt {
            why.append("Last meaningful contact \(Formatters.relative(last) ?? "")")
        } else if why.isEmpty {
            why.append("No meaningful contact recorded yet")
        }
        return PACard(uuid: opportunity.uuid, rank: rank, kind: opportunity.kind == "buy" ? .opportunity : .call,
                      person: PACard.Person(name: name),
                      property: opportunity.title.flatMap { $0 == name ? nil : PACard.Property(address: $0) },
                      opportunityUuid: opportunity.uuid, action: opportunity.nextAction ?? "Follow up with \(firstName(name))",
                      whyNow: why.joined(separator: " · "),
                      paView: opportunity.temperature.map { "Temperature: \($0)" })
    }

    static func agentBrief(_ briefing: PAServerBriefing) -> String {
        var parts: [String] = []
        let name = briefing.me?.name.map { firstName($0) }
        parts.append(name.map { "Morning, \($0)." } ?? "Morning.")
        let count = briefing.opportunities.count
        parts.append(count == 0 ? "No open opportunities." : "\(count) open \(count == 1 ? "opportunity" : "opportunities"), most urgent first.")
        if !briefing.eventsSoon.isEmpty {
            parts.append("\(briefing.eventsSoon.count) \(briefing.eventsSoon.count == 1 ? "event" : "events") in the next two days.")
        }
        if let waiting = briefing.updatesWaiting?.n, waiting > 0 {
            parts.append("\(waiting) \(waiting == 1 ? "change" : "changes") waiting for you to confirm.")
        }
        return parts.joined(separator: " ")
    }

    static func managerBrief(_ briefing: PAServerBriefing) -> String {
        let n = briefing.handoffsForMe.count
        return n == 0 ? "Nothing needs you right now." : "\(n) \(n == 1 ? "question needs" : "questions need") your decision."
    }

    // MARK: Runs

    /// Prepare me: the PA's checked answer, its sources, what it inferred, and what's unknown.
    static func brief(from run: PAServerRun, opportunityUuid: String) throws -> PABrief {
        let output = try shown(run)
        var sections = [PABrief.Section(key: "brief", title: "Brief", facts: [PAFact(text: output.answer ?? "", kind: .stated)])]
        let sources = output.sources.map(sourceFact)
        if !sources.isEmpty { sections.append(.init(key: "sources", title: "Where this comes from", facts: sources)) }
        let inferred = output.inferences.map { PAFact(text: $0, kind: .inferred, confirmed: false) }
        if !inferred.isEmpty { sections.append(.init(key: "inferences", title: "Judgements, not facts", facts: inferred)) }
        return PABrief(opportunityUuid: opportunityUuid, sections: sections, gaps: output.unknowns)
    }

    static func answer(from run: PAServerRun) throws -> PAAnswer {
        let output = try shown(run)
        var facts = output.sources.map(sourceFact)
        facts += output.inferences.map { PAFact(text: $0, kind: .inferred, confirmed: false) }
        let actions: [PAAnswer.Action] = output.actions.compactMap { value in
            guard case .object(let object) = value, case .string(let type)? = object["type"] else { return nil }
            var handoff: String?
            if case .string(let id)? = object["handoff_uuid"] ?? object["uuid"] { handoff = id }
            var label: String?
            if case .string(let text)? = object["label"] ?? object["summary"] { label = text }
            return PAAnswer.Action(type: type == "handoff" ? "handoff_created" : type, handoffUuid: handoff, label: label)
        }
        return PAAnswer(answer: output.answer ?? "", facts: facts, gaps: output.unknowns, actions: actions)
    }

    /// The output if it may be shown; otherwise the server's reason it was withheld.
    static func shown(_ run: PAServerRun) throws -> PAServerRun.Output {
        guard let output = run.output else { throw APIError.pa("The PA didn't answer.") }
        if output.answer == nil || output.grounded == false {
            throw APIError.pa(output.withheld ?? "The PA's answer couldn't be checked, so it isn't shown.")
        }
        return output
    }

    /// A source as a fact row: the quote when there is one (the chip then names the record), else
    /// the record's label (and the chip just its kind, so it isn't said twice).
    static func sourceFact(_ s: PAServerRun.Source) -> PAFact {
        var chip = source(s)
        if s.quote == nil { chip?.label = nil }
        return PAFact(text: s.quote ?? s.label ?? s.title ?? label(forRef: s), kind: .stated, source: chip)
    }

    static func source(_ s: PAServerRun.Source) -> PASource? {
        guard let id = s.id else { return nil }
        let parts = id.split(separator: ":").map(String.init)
        if parts.count >= 2 {
            return PASource(type: appType(forTable: parts[0]), uuid: parts[1], label: s.label ?? s.title)
        }
        return PASource(type: s.type ?? "record", uuid: id, label: s.label ?? s.title)
    }

    static func label(forRef s: PAServerRun.Source) -> String {
        s.type.map { Formatters.humanize($0) } ?? "Record"
    }

    /// OpsAPI tables → the source kinds the app can open.
    static func appType(forTable table: String) -> String {
        switch table {
        case "crm_leads": "lead"
        case "crm_contacts": "contact"
        case "crm_deals", "property_deals_deals": "deal"
        case "kanban_tasks", "property_deals_task_details": "task"
        case "crm_activities": "interaction"
        case "pa_events": "event"
        case "pa_offers": "offer"
        case "pa_opportunities": "opportunity"
        case "pa_knowledge": "knowledge"
        default: table
        }
    }

    // MARK: Captures

    static func captureSummaries(from updates: [PAServerProposedUpdate]) -> [PACapture] {
        var seen: [String: Int] = [:]
        var result: [PACapture] = []
        for update in updates {
            // The confirm sheet is per note (interaction); fall back to the capture id.
            guard let id = update.sourceInteractionUuid ?? update.captureUuid else { continue }
            if seen[id] != nil { continue }
            seen[id] = result.count
            let count = updates.filter { ($0.sourceInteractionUuid ?? $0.captureUuid) == id }.count
            result.append(PACapture(uuid: id, status: .ready, summary: "\(count) \(count == 1 ? "change" : "changes") to confirm",
                                    createdAt: update.createdAt))
        }
        return result.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// The Week 2 sheet: labels, kinds and the judgement wording come from the server.
    static func capture(interactionUuid: String, sheet: PAServerSheet, opportunity: PAServerOpportunity?) -> PACapture {
        let working = sheet.run?.status == "running" && sheet.proposals.isEmpty
        let decided = !sheet.proposals.isEmpty && sheet.proposals.allSatisfy { $0.status != "proposed" }
        var capture = PACapture(uuid: interactionUuid, status: working ? .extracting : (decided ? .confirmed : .ready),
                                transcript: sheet.interaction?.transcript ?? sheet.interaction?.rawText,
                                summary: sheet.interaction?.summary, createdAt: sheet.interaction?.at,
                                error: sheet.run?.status == "failed" ? (sheet.run?.error ?? "The PA couldn't read this note.") : nil)
        if let opportunity {
            capture.resolved = .init(person: opportunity.personName.map { PACard.Person(uuid: opportunity.personUuid, name: $0) },
                                     property: opportunity.propertyAddress.map { PACard.Property(address: $0) })
        }
        capture.updates = sheet.proposals.filter { $0.targetTable != "next_action" }.map { row in
            PAProposedUpdate(uuid: row.uuid, label: row.label ?? fieldLabel(table: row.targetTable, field: row.field, value: row.newValue),
                             oldValue: row.oldValue, newValue: row.newValue, display: display(row.newValue, field: row.field),
                             kind: row.isInferred == true ? .inferred : (row.kind == "proposed" ? .proposed : .stated),
                             by: row.isInferred == true ? sheet.author : nil, confidence: row.confidence, material: row.material,
                             status: PAProposedUpdate.Status(rawValue: row.status ?? "") ?? .proposed, quote: row.sourceQuote)
        }
        if let next = sheet.proposals.first(where: { $0.targetTable == "next_action" }) {
            var action = nextAction(from: PAServerProposedUpdate(uuid: next.uuid, targetTable: next.targetTable, newValue: next.newValue,
                                                                 material: next.material))
            action.owner = next.owner?.name.map { PACard.Person(uuid: next.owner?.userUuid, name: $0) }
            capture.nextAction = action
        }
        return capture
    }

    static func capture(uuid: String, updates: [PAServerProposedUpdate], interaction: PAServerInteraction?,
                        opportunity: PAServerOpportunity?) -> PACapture {
        let open = updates.allSatisfy { $0.status != "proposed" } ? PACapture.Status.confirmed : .ready
        var capture = PACapture(uuid: uuid, status: open, transcript: interaction?.transcript ?? interaction?.rawText,
                                summary: interaction?.summary, createdAt: interaction?.at)
        if let opportunity {
            capture.resolved = .init(person: opportunity.personName.map { PACard.Person(uuid: opportunity.personUuid, name: $0) },
                                     property: opportunity.propertyAddress.map { PACard.Property(address: $0) })
        }
        capture.updates = updates.filter { $0.targetTable != "next_action" }.map(proposedUpdate)
        if let next = updates.first(where: { $0.targetTable == "next_action" }) {
            capture.nextAction = nextAction(from: next)
        }
        return capture
    }

    static func proposedUpdate(_ u: PAServerProposedUpdate) -> PAProposedUpdate {
        PAProposedUpdate(uuid: u.uuid, label: fieldLabel(table: u.targetTable, field: u.field, value: u.newValue),
                         oldValue: u.oldValue, newValue: u.newValue, display: display(u.newValue, field: u.field),
                         kind: u.isInferred == true ? .inferred : .stated, by: nil, confidence: u.confidence,
                         material: u.material, status: PAProposedUpdate.Status(rawValue: u.status ?? "") ?? .proposed,
                         quote: u.sourceQuote)
    }

    static func nextAction(from u: PAServerProposedUpdate) -> PACapture.NextAction {
        var title = "Next action"
        var due: Date?
        var reason: String?
        if case .object(let o)? = u.newValue {
            if case .string(let t)? = o["title"] { title = t }
            if case .string(let d)? = o["due_at"] { due = APIDate.parse(d) }
            if case .string(let r)? = o["reason"] { reason = r }
        }
        return PACapture.NextAction(uuid: u.uuid, title: title, dueAt: due, owner: nil, reason: reason, material: u.material)
    }

    static let fieldLabels: [String: String] = [
        "expectation_price": "Seller's stated figure", "offer_amount": "Offer", "decision_makers": "Decision makers",
        "next_action_at": "Next action time", "motivation": "Motivation", "temperature": "Temperature",
        "our_position": "Our position (judgement)", "primary_concern": "Primary concern", "status": "Status",
        "last_meaningful_contact_at": "Last meaningful contact",
    ]

    static func fieldLabel(table: String?, field: String?, value: JSONValue?) -> String {
        if let field { return fieldLabels[field] ?? Formatters.humanize(field) }
        switch table {
        case "pa_events":
            if case .object(let o)? = value, case .string(let kind)? = o["kind"] { return "Event: \(Formatters.humanize(kind))" }
            return "Event"
        case "pa_offers": return "Offer"
        default: return Formatters.humanize(table ?? "Change")
        }
    }

    /// Money for price and amount fields, names for decision makers, readable records for creates.
    static func display(_ value: JSONValue?, field: String?) -> String? {
        guard let value else { return nil }
        let money = field.map { $0.contains("price") || $0.contains("amount") } ?? false
        switch value {
        case .number(let n) where money:
            return Formatters.money(Decimal(n), currency: "GBP")
        case .array(let items):
            let names: [String] = items.compactMap {
                guard case .object(let o) = $0, case .string(let name)? = o["name"] else { return $0.displayString }
                if case .string(let role)? = o["role"] { return "\(name) (\(role))" }
                return name
            }
            return names.joined(separator: " + ")
        case .object(let o):
            var parts: [String] = []
            for key in ["title", "kind", "amount", "at", "conditions"] {
                guard let v = o[key] else { continue }
                if key == "amount", case .number(let n) = v {
                    parts.append(Formatters.money(Decimal(n), currency: "GBP") ?? v.displayString)
                } else {
                    parts.append(v.displayString)
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nil
        }
    }

    // MARK: Handoffs and knowledge

    static func handoff(_ h: PAServerHandoff, fromName: String?) -> PAHandoff {
        PAHandoff(uuid: h.uuid, from: fromName.map { PACard.Person(uuid: h.fromUserUuid, name: $0) },
                  to: nil, opportunityUuid: h.opportunityUuid, dealUuid: h.dealUuid, title: nil, question: h.question,
                  recommendation: h.paRecommendation, contextFacts: [],
                  status: PAHandoff.Status(rawValue: h.status == "replied" ? "replied" : (h.status ?? "open")) ?? .open,
                  reply: h.reply, repliedAt: h.repliedAt)
    }

    /// Members with a manager or owner role, from `/namespace/members` (shape varies: be lenient).
    static func managers(fromMembers members: [JSONValue]) -> [PAManager] {
        members.compactMap { member in
            guard case .object(let m) = member else { return nil }
            let user: [String: JSONValue] = { if case .object(let u)? = m["user"] { return u }; return m }()
            func s(_ k: String, _ o: [String: JSONValue]) -> String? { if case .string(let v)? = o[k] { return v }; return nil }
            guard let uuid = s("user_uuid", m) ?? s("uuid", user) else { return nil }
            var roleNames: [String] = []
            if case .array(let roles)? = m["roles"] {
                for role in roles {
                    if case .object(let r) = role, let name = s("role_name", r) ?? s("name", r) { roleNames.append(name) }
                    if case .string(let name) = role { roleNames.append(name) }
                }
            }
            let isOwner: Bool = { if case .bool(let b)? = m["is_owner"] { return b }; return false }()
            guard isOwner || roleNames.contains(where: { ["pd_manager", "manager", "owner", "admin"].contains($0) }) else { return nil }
            let name = [s("first_name", user), s("last_name", user)].compactMap { $0 }.joined(separator: " ")
            return PAManager(uuid: uuid, name: name.isEmpty ? (s("email", user) ?? "Manager") : name)
        }
    }

    /// A rule as the person wrote it: the first sentence is the title, the key a slug of it.
    static func knowledgeBody(text: String, scope: String) -> PAServerKnowledgeBody {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = trimmed.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? trimmed
        let title = String(firstSentence.prefix(120)).trimmingCharacters(in: .whitespaces)
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        var key = String(slug).split(separator: "_").prefix(6).joined(separator: "_")
        if key.isEmpty { key = "rule" }
        return PAServerKnowledgeBody(key: String(key.prefix(60)), scope: scope, domain: "seller", title: title, rule: trimmed,
                                     rationale: nil, triggers: nil)
    }

    static func firstName(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }
}

// MARK: - Week 3

extension PAMapping {
    /// A `table:uuid[:field]` ref as a source chip.
    static func source(ref: String?, label: String? = nil) -> PASource? {
        guard let ref else { return nil }
        return source(PAServerRun.Source(type: nil, id: ref, label: label))
    }

    static func fact(_ f: PAServerFact, by author: String? = nil) -> PAFact {
        let inferred = f.isInferred == true || f.label == "inference" || (f.label?.contains("judgement") ?? false)
        return PAFact(text: f.text, kind: inferred ? .inferred : .stated, confirmed: inferred ? false : nil,
                      by: inferred ? author : nil, source: source(ref: f.ref))
    }

    static func card(from c: PAServerToday.Card) -> PACard {
        let name = c.personName ?? c.title ?? "Opportunity"
        return PACard(uuid: c.opportunityUuid, rank: c.rank, kind: c.kind == "buy" ? .opportunity : .call,
                      person: PACard.Person(uuid: c.personUuid, name: name),
                      property: (c.propertyAddress ?? c.title).flatMap { $0 == name ? nil : PACard.Property(address: $0) },
                      opportunityUuid: c.opportunityUuid, action: c.action ?? "Follow up with \(firstName(name))",
                      whyNow: c.whyNow ?? c.signals.first?.text, objective: c.objective,
                      estimatedMinutes: c.minutes, score: c.score)
    }

    /// The ranked day; with a time budget, only the cards that fit (and how many wait).
    static func today(from server: PAServerToday, budgeted: Bool) -> PAToday {
        var today = PAToday()
        let cards = budgeted ? (server.budget?.fits ?? server.cards) : server.cards
        today.cards = cards.map(card(from:))
        today.mode = budgeted ? "minutes" : "full"
        let waits = server.budget?.waits.count ?? 0
        if budgeted, let budget = server.budget {
            today.brief = .init(text: "\(today.cards.count) \(today.cards.count == 1 ? "thing fits" : "things fit") in \(budget.minutes ?? 0) minutes"
                                + (waits > 0 ? "; \(waits) can wait." : "."))
        }
        return today
    }

    static func why(from server: PAServerWhy, cardUuid: String) -> PAWhy {
        PAWhy(cardUuid: cardUuid, score: server.score,
              signals: server.signals.map {
                  PAWhy.Signal(key: $0.key, label: $0.text ?? Formatters.humanize($0.key), weight: $0.weight, points: $0.weight,
                               source: source(ref: $0.ref))
              },
              explanation: server.explanation)
    }

    static func brief(from p: PAServerPrepare) -> PABrief {
        var sections: [PABrief.Section] = []
        func add(_ key: String, _ title: String, _ facts: [PAFact]) {
            if !facts.isEmpty { sections.append(.init(key: key, title: title, facts: facts)) }
        }
        add("snapshot", "Snapshot", p.snapshot.map { fact($0) })
        if let last = p.lastInteraction { add("last", "Last meaningful conversation", [fact(last)]) }
        add("position", "Price and offers", p.price.map { fact($0) })
        add("decision_makers", "Decision makers", p.decisionMakers.map { fact($0) })
        add("promises", "Promises", p.promises.map { fact($0) })
        add("objections", "Likely objections", p.objections.map { fact($0) })
        add("questions", "Questions to establish", p.questions.compactMap { $0.question.map { PAFact(text: $0, kind: .proposed) } })
        add("playbook", "Playbook", p.playbook.map {
            PAFact(text: [$0.title, $0.rule].compactMap { $0 }.joined(separator: ": "), kind: .stated,
                   source: source(ref: $0.ref, label: "Rule"))
        })
        let objective = [p.recommendedAction, p.objective].compactMap { $0 }.joined(separator: ". ")
        return PABrief(opportunityUuid: p.opportunityUuid, sections: sections,
                       gaps: p.unknowns.map { fieldLabels[$0] ?? Formatters.humanize($0) },
                       objective: objective.isEmpty ? nil : objective)
    }

    /// Coaching: questions first, what's known (cited) and what's assumed, never a figure.
    static func answer(fromCoach c: PAServerCoach) -> PAAnswer {
        var text = "Before any figure, find out:\n" + c.questions.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        if let next = c.nextStep { text += "\n\n\(next)" }
        let facts = c.known.map { fact($0) } + c.assumed.map { fact($0) }
        return PAAnswer(answer: text, facts: facts, gaps: [], actions: [])
    }
}
