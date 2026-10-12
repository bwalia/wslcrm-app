#if DEBUG
import Foundation

/// Property PA routes for the UI-test stub server, answering as opsapi's `property_pa` plugin
/// does (Week 1 "Brain", cb2a1de): `/briefing`, `/ask` runs, `/proposed-updates`, `/interactions`,
/// `/opportunities`, `/handoffs`, `/knowledge`, plus core `/api/v2/voice/transcribe`. Seeded from
/// How It Works (fake data): Sophie (seller agent), Ashley (manager), Sarah / 22 Station Road,
/// Michael, Rick and seven more sellers. Model answers are canned.
///
/// Answers as opsapi Week 3 ("Think": rules-engine `/today`, `/today/why`, `/prepare`, `/coach`,
/// `/knowledge/teach`). `-UITestPAWeek1` turns those off (404), as on a server without Week 3.
struct UITestPropertyPAStub {
    static let sarahOpportunity = "opp-sarah"
    static let handoffUuid = "c0000000-0000-4000-8000-000000000001"
    static let ashleyUuid = "user-ashley"

    var isManager = false
    var writes: [String] = []
    private var week3 = true
    private var updates: [[String: Any]] = []
    private var interactions: [String: [String: Any]] = [:]
    private var handoffs: [[String: Any]] = []
    private var knowledge: [String: [String: Any]] = [:]
    private var runs: [String: [String: Any]] = [:]
    private var doneCards: Set<String> = []
    private var captureCount = 0
    private var sheetReads: [String: Int] = [:]

    mutating func reset() {
        week3 = !ProcessInfo.processInfo.arguments.contains("-UITestPAWeek1")
        writes = []
        updates = []
        interactions = [:]
        handoffs = [Self.seededHandoff]
        knowledge = [:]
        runs = [:]
        doneCards = []
        captureCount = 0
        sheetReads = [:]
    }

    mutating func route(method: String, path: String, query: String, json: [String: Any], body: Data, enabled: Bool) -> (Int, Any)? {
        if path == "/api/v2/voice/transcribe", method == "POST", enabled {
            writes.append("POST transcribe \(body.count) bytes")
            return (200, ["text": Self.transcript])
        }
        let base = "/api/v2/property-pa"
        guard path.hasPrefix(base) else { return nil }
        guard enabled else {
            return (404, ["success": false, "error": "Property PA is turned off for this workspace", "code": "PLUGIN_DISABLED"])
        }
        let sub = String(path.dropFirst(base.count))
        switch (method, sub) {
        case ("GET", "/briefing"):
            return ok(briefing)
        case ("GET", "/manager/today") where week3:
            guard isManager else { return (403, ["success": false, "error": "For managers"]) }
            let open = handoffs.filter { $0["status"] as? String == "open" }.map {
                ["uuid": $0["uuid"] ?? "", "question": $0["question"] ?? "", "from_name": "Sophie Turner",
                 "opportunity_uuid": Self.sarahOpportunity, "pa_recommendation": $0["pa_recommendation"] ?? ""] as [String: Any]
            }
            return ok(["handoffs": open, "unusual_negotiations": [],
                       "relationship_risks": [["uuid": "opp-rick", "title": "Rick Dawson — 18 Market Street",
                                               "text": "Rick Dawson — 18 Market Street: no meaningful contact for 21 days (warm)",
                                               "owner_name": "Sophie Turner", "days": 21]],
                       "overdue_actions": [], "deal_risks": [], "top_opportunities": [],
                       "summary": "\(open.count + 1) need you. Everything else (10) is being handled."])
        case ("GET", "/today") where week3:
            return ok(agentToday(query: query))
        case ("GET", let p) where p.hasPrefix("/today/why/") && week3:
            return ok(Self.why)
        case ("GET", let p) where p.hasPrefix("/prepare/") && week3:
            return ok(prepare)
        case ("GET", let p) where p.hasPrefix("/coach/") && week3:
            writes.append("GET coach")
            return ok(Self.coach)
        case ("POST", "/knowledge/teach") where week3:
            guard let statement = json["statement"] as? String, !statement.isEmpty else {
                return (422, ["success": false, "error": "Validation failed"])
            }
            let id = "k0000000-0000-4000-8000-00000000000\(knowledge.count + 1)"
            knowledge[id] = ["uuid": id, "key": "rule_\(knowledge.count + 1)", "scope": json["scope"] ?? "company", "status": "draft",
                             "current_version": 0, "title": String(statement.prefix(60)), "rule": statement, "triggers": []]
            writes.append("POST knowledge/teach \(json["scope"] as? String ?? "")")
            return (201, ["success": true, "data": ["knowledge_uuid": id, "version": 1, "status": "proposed"]])
        case ("POST", let p) where p.hasPrefix("/cards/"):
            let parts = p.split(separator: "/")
            if parts.count == 3 { doneCards.insert(String(parts[1])) }
            return ok(["ok": true])
        case ("GET", "/managers"):
            return ok([["uuid": Self.ashleyUuid, "name": "Ashley Brooks"]])

        // PA chat: a run that's "running" on the first read and checked on the second.
        case ("POST", "/ask"):
            let mode = json["mode"] as? String ?? "ask"
            let message = json["message"] as? String ?? ""
            let id = "run-\(runs.count + 1)"
            runs[id] = ["uuid": id, "status": "running", "mode": mode, "message": message, "reads": 0]
            writes.append("POST ask \(mode)")
            if mode == "capture" { capture(from: message) }
            return (202, ["success": true, "data": ["uuid": id, "status": "running", "agent_key": "pa_seller_agent"]])
        case ("GET", let p) where p.hasPrefix("/ask/"):
            let id = String(p.dropFirst("/ask/".count))
            guard var run = runs[id] else { return notFound }
            run["reads"] = (run["reads"] as? Int ?? 0) + 1
            runs[id] = run
            if (run["reads"] as? Int ?? 0) < 2 { return ok(["uuid": id, "status": "running"]) }
            return ok(["uuid": id, "status": "succeeded", "model": "private", "prompt_version": "seller-pa@1.1.0",
                       "output": output(mode: run["mode"] as? String ?? "ask", message: run["message"] as? String ?? "")])

        // Week 2 capture: start, the confirm sheet (the PA still working on the first read), decide.
        case ("POST", "/captures/start"):
            guard let text = json["text"] as? String, !text.isEmpty else {
                return (422, ["success": false, "error": "Validation failed", "details": ["text": "is required"]])
            }
            capture(from: text)
            let id = "int-\(captureCount)"
            writes.append("POST captures/start \(json["channel"] as? String ?? "")")
            return (201, ["success": true, "data": ["interaction": interactions[id] ?? [:], "pa": ["run_uuid": "run-cap", "status": "running"]]])
        case ("GET", let p) where p.hasPrefix("/interactions/") && p.hasSuffix("/capture"):
            let id = String(p.dropFirst("/interactions/".count).dropLast("/capture".count))
            guard let interaction = interactions[id] else { return notFound }
            sheetReads[id, default: 0] += 1
            let working = (sheetReads[id] ?? 0) <= 1
            let rows = working ? [] : updates.filter { $0["source_interaction_uuid"] as? String == id }.map(Self.sheetRow)
            return ok(["interaction": interaction, "author": "Sophie", "proposals": rows,
                       "run": ["uuid": "run-cap", "status": working ? "running" : "succeeded"]])
        case ("POST", let p) where p.hasPrefix("/interactions/") && p.hasSuffix("/decide"):
            let id = String(p.dropFirst("/interactions/".count).dropLast("/decide".count))
            let decisions = json["decisions"] as? [[String: Any]] ?? []
            if json["confirm_rest"] as? Bool == true { writes.append("confirm_rest used") }
            for decision in decisions {
                guard let index = updates.firstIndex(where: { $0["uuid"] as? String == decision["uuid"] as? String
                                                              && $0["source_interaction_uuid"] as? String == id }) else {
                    return (422, ["success": false, "error": "Validation failed"])
                }
                let action = decision["action"] as? String ?? ""
                updates[index]["status"] = ["confirm": "confirmed", "correct": "corrected", "reject": "rejected"][action] ?? "proposed"
                if action == "correct" { updates[index]["new_value"] = decision["value"] }
            }
            writes.append("POST decide " + decisions.map { "\($0["uuid"] as? String ?? ""):\($0["action"] as? String ?? "")" }.joined(separator: ","))
            return ok(["results": [], "sheet": [:]])

        // Captures and proposed updates.
        case ("GET", "/proposed-updates"):
            var list = updates
            if let status = param("status", in: query) { list = list.filter { status.split(separator: ",").map(String.init).contains($0["status"] as? String ?? "") } }
            if let capture = param("capture_uuid", in: query) { list = list.filter { $0["capture_uuid"] as? String == capture } }
            return ok(list)
        case ("POST", let p) where p.hasPrefix("/proposed-updates/"):
            let parts = p.split(separator: "/").map(String.init)
            guard parts.count == 3, let index = updates.firstIndex(where: { $0["uuid"] as? String == parts[1] }) else { return notFound }
            guard updates[index]["status"] as? String == "proposed" else { return (409, ["success": false, "error": "Already decided"]) }
            updates[index]["status"] = ["confirm": "confirmed", "correct": "corrected", "reject": "rejected"][parts[2]] ?? "proposed"
            if parts[2] == "correct" { updates[index]["new_value"] = json["value"] }
            writes.append("POST \(parts[2]) \(updates[index]["field"] as? String ?? updates[index]["target_table"] as? String ?? "")")
            return ok(updates[index])
        case ("GET", let p) where p.hasPrefix("/interactions/"):
            guard let interaction = interactions[String(p.dropFirst("/interactions/".count))] else { return notFound }
            return ok(interaction)
        case ("GET", "/opportunities/\(Self.sarahOpportunity)"):
            return ok(["uuid": Self.sarahOpportunity, "title": "22 Station Road", "person_uuid": "person-sarah",
                       "person_name": "Sarah Collins", "property_address": "22 Station Road"])

        // Handoffs.
        case ("POST", "/handoffs"):
            guard json["to_user_uuid"] is String, let question = json["question"] as? String else {
                return (422, ["success": false, "error": "Validation failed", "details": ["to_user_uuid": "is required"]])
            }
            var handoff = Self.seededHandoff
            handoff["uuid"] = "c0000000-0000-4000-8000-00000000000\(handoffs.count + 1)"
            handoff["question"] = question
            handoff["pa_recommendation"] = json["pa_recommendation"] ?? NSNull()
            handoff["from_user_uuid"] = UITestStubServer.userUuid
            handoffs.append(handoff)
            writes.append("POST handoff")
            return (201, ["success": true, "data": handoff])
        case ("GET", "/handoffs"):
            let sent = query.contains("box=sent")
            return ok(handoffs.filter { sent ? ($0["from_user_uuid"] as? String == UITestStubServer.userUuid) : isManager })
        case ("POST", let p) where p.hasPrefix("/handoffs/") && p.hasSuffix("/reply"):
            let id = String(p.dropFirst("/handoffs/".count).dropLast("/reply".count))
            guard let index = handoffs.firstIndex(where: { $0["uuid"] as? String == id }) else { return notFound }
            guard handoffs[index]["status"] as? String == "open" else { return (409, ["success": false, "error": "Already replied"]) }
            guard let reply = json["reply"] as? String, !reply.isEmpty else {
                return (422, ["success": false, "error": "Validation failed", "details": ["reply": "is required"]])
            }
            handoffs[index]["status"] = "replied"
            handoffs[index]["reply"] = reply
            handoffs[index]["replied_at"] = UITestPropertyDealsStub.iso(minutes: 0)
            writes.append("POST handoff reply \(json["decision"] as? String ?? "")")
            return ok(["uuid": id, "status": "replied"])

        // Knowledge.
        case ("POST", "/knowledge"):
            guard let key = json["key"] as? String, let title = json["title"] as? String, let rule = json["rule"] as? String else {
                return (422, ["success": false, "error": "Validation failed"])
            }
            let id = "k0000000-0000-4000-8000-00000000000\(knowledge.count + 1)"
            knowledge[id] = ["uuid": id, "key": key, "scope": json["scope"] ?? "personal", "status": "draft", "current_version": 0,
                             "title": title, "rule": rule, "triggers": []]
            writes.append("POST knowledge \(json["scope"] as? String ?? "")")
            return (201, ["success": true, "data": ["knowledge_uuid": id, "version": 1, "status": "proposed"]])
        case ("POST", let p) where p.hasPrefix("/knowledge/") && p.hasSuffix("/approve"):
            let parts = p.split(separator: "/").map(String.init)
            guard parts.count == 5, var rule = knowledge[parts[1]] else { return notFound }
            if rule["scope"] as? String == "company", !isManager { return (403, ["success": false, "error": "Not a manager"]) }
            rule["status"] = "approved"
            rule["current_version"] = Int(parts[3]) ?? 1
            knowledge[parts[1]] = rule
            writes.append("POST approve \(parts[3])")
            return ok(rule)
        default:
            return nil
        }
    }

    // MARK: Helpers

    private func ok(_ data: Any) -> (Int, Any) { (200, ["success": true, "data": data]) }
    private var notFound: (Int, Any) { (404, ["success": false, "error": "Not found"]) }

    private func param(_ name: String, in query: String) -> String? {
        query.split(separator: "&").first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)).removingPercentEncoding ?? String($0.dropFirst(name.count + 1)) }
    }

    private var approvedRule: Bool { knowledge.values.contains { $0["status"] as? String == "approved" } }

    /// What the Seller PA does with a capture run: log the interaction and propose changes.
    private mutating func capture(from message: String) {
        captureCount += 1
        let capture = "cap-\(captureCount)"
        let interaction = "int-\(captureCount)"
        interactions[interaction] = ["uuid": interaction, "channel": "voice", "transcript": message, "raw_text": message,
                                     "at": UITestPropertyDealsStub.iso(minutes: 0), "person_uuid": "person-sarah",
                                     "opportunity_uuid": Self.sarahOpportunity]
        func update(_ n: Int, field: String?, table: String, value: Any, inferred: Bool, material: Bool, quote: String?, confidence: Double) -> [String: Any] {
            var row: [String: Any] = ["uuid": "pu-\(captureCount)-\(n)", "capture_uuid": capture, "target_table": table,
                                      "new_value": value, "confidence": confidence, "is_inferred": inferred, "material": material,
                                      "source_interaction_uuid": interaction, "status": "proposed",
                                      "created_at": UITestPropertyDealsStub.iso(minutes: 0), "model": "private", "prompt_version": "seller-pa@1.1.0"]
            if let field { row["field"] = field; row["target_uuid"] = Self.sarahOpportunity }
            if let quote { row["source_quote"] = quote }
            return row
        }
        updates += [
            update(1, field: nil, table: "pa_events", value: ["kind": "valuation", "title": "Second agent valued it at £240,000", "amount": 240000],
                   inferred: false, material: false, quote: "Second agent valued it at 240k", confidence: 0.95),
            update(2, field: "expectation_price", table: "pa_opportunities", value: 235000, inferred: false, material: true,
                   quote: "She won't go below 235", confidence: 0.93),
            update(3, field: "decision_makers", table: "pa_opportunities", value: [["name": "Sarah", "role": "seller"], ["name": "Tom", "role": "husband"]],
                   inferred: false, material: true, quote: "Her husband Tom needs to agree", confidence: 0.9),
            update(4, field: "our_position", table: "pa_opportunities", value: "£225,000 might work with a 4-week completion (Sophie's judgement)",
                   inferred: true, material: true, quote: nil, confidence: 0.6),
            update(5, field: nil, table: "next_action", value: ["title": "Call Sarah", "due_at": UITestPropertyPAStubFixtures.tomorrowAt11,
                                                                 "reason": "She'll decide after speaking to Tom"],
                   inferred: false, material: true, quote: "Call her tomorrow at 11", confidence: 0.92),
        ]
    }

    private func output(mode: String, message: String) -> [String: Any] {
        let base: [String: Any] = ["grounded": true, "contract_ok": true, "mode": mode, "unknowns": [], "inferences": [],
                                   "actions": [], "needs_human": false, "sources": []]
        var out = base
        switch mode {
        case "prepare":
            var answer = "Sarah said she'd decide after her second valuation, which was yesterday: £240,000. Lead with a quick, certain completion rather than price, and find out what Tom thinks."
            if approvedRule { answer += " Company rule: an agent's valuation is not her minimum; treat £240,000 as her anchor." }
            out["answer"] = answer
            out["sources"] = [["type": "event", "id": "pa_events:ev-valuation", "label": "Valuation, 12 Oct"],
                              ["type": "interaction", "id": "crm_activities:int-0", "label": "Call, 6 Oct"],
                              ["type": "deal", "id": "property_deals_deals:\(UITestPropertyDealsStub.amberDealUuid)", "label": "Deal, 22 Station Road"]]
            out["unknowns"] = ["Tom's view on price", "The second agent's fee and terms"]
            out["inferences"] = ["£225,000 might work with a 4-week completion (Sophie's judgement)"]
        case "capture":
            out["answer"] = "I've put 5 changes up for you to confirm."
        default:
            if message.lowercased().contains("would you do") || message.contains("235") {
                out["answer"] = "Don't raise the offer yet. Her £235,000 is anchored on the £240,000 valuation, and Tom hasn't been asked. Ask what matters more to them, price or a 4-week completion, before talking money."
                out["sources"] = [["type": "interaction", "id": "crm_activities:int-0", "label": "Your note, today"]]
                out["inferences"] = ["£225,000 might work with a 4-week completion (Sophie's judgement)"]
                out["unknowns"] = ["Tom's view on price"]
            } else if message.lowercased().contains("make it up") {
                return ["grounded": false, "contract_ok": true, "mode": mode,
                        "withheld": "The PA's answer cited something that isn't on record, so it isn't shown."]
            } else {
                out["answer"] = "Sarah is the one to call first: her second valuation was yesterday."
                out["sources"] = [["type": "event", "id": "pa_events:ev-valuation", "label": "Valuation, 12 Oct"]]
            }
        }
        return out
    }

    private var briefing: [String: Any] {
        let confirmedNext = updates.contains { $0["target_table"] as? String == "next_action" && $0["status"] as? String == "confirmed" }
        var opportunities = UITestPropertyPAStubFixtures.opportunities
        if confirmedNext {
            opportunities[0]["next_action"] = "Call Sarah"
            opportunities[0]["next_action_at"] = UITestPropertyPAStubFixtures.tomorrowAt11
            opportunities[0]["next_action_reason"] = "She'll decide after speaking to Tom"
        }
        return ["me": ["name": isManager ? "Ashley Brooks" : "Sophie Turner", "is_manager": isManager],
                "now": UITestPropertyDealsStub.iso(minutes: 0),
                "opportunities": opportunities,
                "events_soon": [["uuid": "ev-valuation", "kind": "valuation", "at": UITestPropertyDealsStub.iso(minutes: -60 * 20),
                                 "title": "Second valuation", "opportunity_uuid": Self.sarahOpportunity]],
                "updates_waiting": ["n": updates.filter { $0["status"] as? String == "proposed" }.count, "material": 0],
                "handoffs_for_me": isManager ? handoffs.filter { $0["status"] as? String == "open" }.map {
                    ["uuid": $0["uuid"] ?? "", "question": $0["question"] ?? "", "opportunity_uuid": Self.sarahOpportunity,
                     "created_at": UITestPropertyDealsStub.iso(minutes: -30), "from_name": "Sophie Turner"]
                } : []]
    }

    /// Week 3 Today: cards ranked by the rules engine; `?minutes=` packs a time budget.
    private func agentToday(query: String) -> [String: Any] {
        var cards = UITestPropertyPAStubFixtures.rankedCards.filter { !doneCards.contains($0["opportunity_uuid"] as? String ?? "") }
        // A confirmed next action becomes the top signal on Sarah's card.
        if updates.contains(where: { $0["target_table"] as? String == "next_action" && $0["status"] as? String == "confirmed" }),
           let index = cards.firstIndex(where: { $0["opportunity_uuid"] as? String == Self.sarahOpportunity }) {
            cards[index]["why_now"] = "Next action due: She'll decide after speaking to Tom"
        }
        var out: [String: Any] = ["cards": cards, "weights": ["event_just_happened": 30, "promised_decision": 25]]
        if let raw = param("minutes", in: query), let minutes = Int(raw) {
            var used = 0
            var fits: [[String: Any]] = []
            var waits: [[String: Any]] = []
            for card in cards {
                let need = card["minutes"] as? Int ?? 10
                if used + need <= minutes { used += need; fits.append(card) }
                else { waits.append(["opportunity_uuid": card["opportunity_uuid"] ?? "", "title": card["title"] ?? "", "minutes": need]) }
            }
            out["budget"] = ["minutes": minutes, "used": used, "fits": fits, "waits": waits]
        }
        return out
    }

    private var prepare: [String: Any] {
        var playbook: [[String: Any]] = [["key": "seller_competing_valuation", "title": "A competing valuation",
                                          "rule": "Ask what the other agent based it on before talking price.", "ref": "pa_knowledge:k-seed-1"]]
        if approvedRule {
            playbook.insert(["key": "valuation_is_anchor", "title": "Company rule: an agent's valuation is not the seller's minimum",
                             "rule": "Treat it as their anchor.", "ref": "pa_knowledge:k-1"], at: 0)
        }
        return ["opportunity_uuid": Self.sarahOpportunity, "title": "22 Station Road", "person_name": "Sarah Collins",
                "snapshot": [["text": "22 Station Road, YO24 1AB", "ref": "pa_opportunities:\(Self.sarahOpportunity)"],
                             ["text": "Warm, leaning hot", "ref": "pa_opportunities:\(Self.sarahOpportunity):temperature", "label": "stated"]],
                "last_interaction": ["text": "Said she'd decide after the second valuation", "ref": "crm_activities:int-0"],
                "price": [["text": "Second valuation (£240,000)", "ref": "pa_events:ev-valuation", "label": "stated"]],
                "decision_makers": [["text": "Sarah", "ref": "pa_opportunities:\(Self.sarahOpportunity):decision_makers"]],
                "promises": [["text": "Decide after the second valuation", "ref": "pa_events:ev-promise", "label": "stated"]],
                "objections": [["text": "Another agent's valuation may anchor Sarah's expectations", "ref": "pa_events:ev-valuation", "label": "inference"]],
                "unknowns": ["motivation", "timescale"],
                "questions": [["field": "motivation", "question": "Why is Sarah selling, and why now?"],
                              ["field": "timescale", "question": "Is there a date Sarah needs to be out by?"]],
                "playbook": playbook, "objective": "Find out whether Tom agrees", "recommended_action": "Call Sarah"]
    }

    /// A proposal as the Week 2 sheet shows it: the server's label and kind.
    static func sheetRow(_ update: [String: Any]) -> [String: Any] {
        var row = update
        let labels = ["expectation_price": "Seller's stated minimum", "our_position": "Price that might work",
                      "decision_makers": "Decision makers"]
        if let field = update["field"] as? String { row["label"] = labels[field] ?? field }
        else if update["target_table"] as? String == "pa_events" { row["label"] = "Event" }
        else if update["target_table"] as? String == "next_action" {
            row["label"] = "Next action"
            row["owner"] = ["user_uuid": UITestStubServer.userUuid, "name": "Sophie"]
        }
        let inferred = update["is_inferred"] as? Bool == true
        row["kind"] = inferred ? "inferred" : (update["field"] == nil ? "proposed" : "stated")
        row["kind_label"] = inferred ? "SOPHIE'S JUDGEMENT, UNCONFIRMED" : "Stated"
        return row
    }

    static var coach: [String: Any] {
        ["known": [["text": "She won't go below £235,000", "ref": "pa_opportunities:opp-sarah:expectation_price", "label": "stated"]],
         "assumed": [["text": "£225,000 might work with a 4-week completion", "ref": "pa_opportunities:opp-sarah:our_position",
                      "is_inferred": true, "label": "judgement, unconfirmed"]],
         "questions": ["What matters more to Sarah: the price, or a quick and certain completion?",
                       "Has everyone who must agree seen the figures? What do they think?"],
         "next_step": "Ask these before discussing any figure. Changing the offer is a decision for someone with authority: hand it off with the answers.",
         "never": "The PA does not suggest a higher offer or a price cut."]
    }

    static var why: [String: Any] {
        ["rank": 1, "of": 10, "score": 87,
         "signals": [["key": "event_just_happened", "weight": 30, "text": "Second valuation yesterday", "ref": "pa_events:ev-valuation"],
                     ["key": "promised_decision", "weight": 25, "text": "She said she'd decide after the second valuation", "ref": "pa_events:ev-promise"],
                     ["key": "temperature", "weight": 16, "text": "Warm, leaning hot"]],
         "explanation": "Ranked by points from named signals (weights above), highest first. The order is decided by these rules, not by the AI."]
    }

    static let transcript = "Spoke to Sarah. Second agent valued it at 240k. She won't go below 235. Her husband Tom needs to agree. I reckon 225 might work if we can complete in four weeks. Call her tomorrow at 11."

    static var seededHandoff: [String: Any] {
        ["uuid": handoffUuid, "from_user_uuid": "user-sophie", "to_user_uuid": ashleyUuid, "opportunity_uuid": sarahOpportunity,
         "deal_uuid": UITestPropertyDealsStub.amberDealUuid, "question": "Can we offer Sarah £230k if she completes in 4 weeks?",
         "pa_recommendation": "Hold at £225k until Tom's view is known; go to £230k only for a 4-week completion.",
         "status": "open", "created_at": UITestPropertyDealsStub.iso(minutes: -30)]
    }
}

/// Fixture rows shared by the stub's routes.
enum UITestPropertyPAStubFixtures {
    static var tomorrowAt11: String {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let tomorrow = london.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return APIDate.string(from: london.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
    }

    /// The briefing's opportunities, in the server's order.
    static var opportunities: [[String: Any]] {
        var rows: [[String: Any]] = [
            ["uuid": UITestPropertyPAStub.sarahOpportunity, "kind": "sell", "title": "22 Station Road", "temperature": "warm",
             "person_name": "Sarah Collins", "next_action": "Call Sarah", "next_action_at": UITestPropertyDealsStub.iso(minutes: 90),
             "next_action_reason": "She said she'd decide after the second valuation (yesterday)",
             "last_meaningful_contact_at": UITestPropertyDealsStub.iso(minutes: -60 * 24 * 6)],
            ["uuid": "opp-michael", "kind": "sell", "title": "14 Green Lane", "temperature": "warm", "person_name": "Michael Grant",
             "next_action": "Call Michael back", "next_action_at": UITestPropertyDealsStub.iso(minutes: 60 * 26),
             "next_action_reason": "You promised a follow-up this week"],
            ["uuid": "opp-rick", "kind": "sell", "title": "18 Market Street", "temperature": "cold", "person_name": "Rick Hughes",
             "last_meaningful_contact_at": UITestPropertyDealsStub.iso(minutes: -60 * 24 * 21)],
        ]
        for (index, entry) in ["Priya Nair · 3 Brick Row", "Tom Ellis · 9 Abbey Close", "Hannah Webb · 51 Mill Road",
                               "Owen Price · 2 Fern Court", "Grace Lee · 77 Bridge Street", "Dan Hart · 6 Orchard Way",
                               "Lucy Moss · 40 High Street"].enumerated() {
            let parts = entry.components(separatedBy: " · ")
            rows.append(["uuid": "opp-\(index + 4)", "kind": "sell", "title": parts[1], "person_name": parts[0],
                         "last_meaningful_contact_at": UITestPropertyDealsStub.iso(minutes: -60 * 24 * (14 + index * 3))])
        }
        return rows
    }

    /// Week 3 `/today` cards, ranked by the rules engine.
    static var rankedCards: [[String: Any]] {
        var cards: [[String: Any]] = [
            ["opportunity_uuid": UITestPropertyPAStub.sarahOpportunity, "rank": 1, "title": "22 Station Road", "kind": "sell",
             "person_name": "Sarah Collins", "person_uuid": "person-sarah", "property_address": "22 Station Road", "score": 87,
             "signals": [["key": "event_just_happened", "weight": 30, "text": "Second valuation yesterday", "ref": "pa_events:ev-valuation"]],
             "action": "Call Sarah", "objective": "Find out whether Tom agrees", "minutes": 15,
             "why_now": "Second valuation yesterday; she said she'd decide after it"],
            ["opportunity_uuid": "opp-michael", "rank": 2, "title": "14 Green Lane", "kind": "sell", "person_name": "Michael Grant",
             "property_address": "14 Green Lane", "score": 72, "signals": [], "action": "Call Michael back", "minutes": 10,
             "why_now": "You promised a follow-up this week"],
            ["opportunity_uuid": "opp-rick", "rank": 3, "title": "18 Market Street", "kind": "sell", "person_name": "Rick Hughes",
             "property_address": "18 Market Street", "score": 58, "signals": [], "action": "Send Rick a short personal follow-up",
             "minutes": 5, "why_now": "21 days since a meaningful conversation"],
        ]
        for index in 4...10 {
            cards.append(["opportunity_uuid": "opp-\(index)", "rank": index, "title": "Seller \(index)", "person_name": "Seller \(index)",
                          "score": 50 - Double(index), "signals": [], "action": "Check in", "minutes": 10, "why_now": "Nothing pressing"])
        }
        return cards
    }
}
#endif
