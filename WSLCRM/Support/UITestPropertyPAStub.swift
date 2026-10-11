#if DEBUG
import Foundation

/// Property PA routes for the UI-test stub server, answering as opsapi's `property_pa` plugin
/// does (Week 1 "Brain", cb2a1de): `/briefing`, `/ask` runs, `/proposed-updates`, `/interactions`,
/// `/opportunities`, `/handoffs`, `/knowledge`, plus core `/api/v2/voice/transcribe`. Seeded from
/// How It Works (fake data): Sophie (seller agent), Ashley (manager), Sarah / 22 Station Road,
/// Michael, Rick and seven more sellers. Model answers are canned.
///
/// `-UITestPATodayCards` also serves the routes opsapi hasn't built yet (`/today` ranked cards and
/// `/why`, Week 3) in the shape the app asked for; without it they're 404 as on the real server.
struct UITestPropertyPAStub {
    static let sarahOpportunity = "opp-sarah"
    static let handoffUuid = "c0000000-0000-4000-8000-000000000001"
    static let ashleyUuid = "user-ashley"

    var isManager = false
    var writes: [String] = []
    private var todayCards = false
    private var updates: [[String: Any]] = []
    private var interactions: [String: [String: Any]] = [:]
    private var handoffs: [[String: Any]] = []
    private var knowledge: [String: [String: Any]] = [:]
    private var runs: [String: [String: Any]] = [:]
    private var doneCards: Set<String> = []
    private var captureCount = 0

    mutating func reset() {
        todayCards = ProcessInfo.processInfo.arguments.contains("-UITestPATodayCards")
        writes = []
        updates = []
        interactions = [:]
        handoffs = [Self.seededHandoff]
        knowledge = [:]
        runs = [:]
        doneCards = []
        captureCount = 0
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
        case ("GET", "/today") where todayCards:
            return ok(isManager ? managerToday : agentToday(query: query))
        case ("GET", let p) where p.hasPrefix("/why/") && todayCards:
            return ok(Self.why)
        case ("POST", let p) where p.hasPrefix("/cards/") && todayCards:
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

    private func agentToday(query: String) -> [String: Any] {
        var cards = UITestPropertyPAStubFixtures.cards.filter { !doneCards.contains($0["uuid"] as? String ?? "") }
        if let raw = param("mode", in: query), raw.hasPrefix("minutes:"), let minutes = Int(raw.dropFirst("minutes:".count)) {
            var used = 0
            cards = cards.filter { card in
                let need = card["estimated_minutes"] as? Int ?? 10
                guard used + need <= minutes else { return false }
                used += need
                return true
            }
        }
        return ["generated_at": UITestPropertyDealsStub.iso(minutes: -5),
                "brief": ["text": "Morning, Sophie. Sarah is the one today: her second valuation was yesterday and she said she'd decide after it.",
                          "sources": [["type": "event", "uuid": "ev-valuation", "label": "Second valuation, yesterday"]]],
                "cards": cards]
    }

    private var managerToday: [String: Any] {
        ["brief": ["text": "One decision needs you. Everything else is being handled."],
         "cards": [["uuid": "card-handoff", "rank": 1, "kind": "handoff", "person": ["name": "Sophie Turner"],
                    "handoff_uuid": Self.handoffUuid, "action": "Sophie asks: offer £230k to Sarah?"]],
         "handled_count": 14]
    }

    static var why: [String: Any] {
        ["card_uuid": "opp-sarah", "score": 87,
         "signals": [["key": "event_just_happened", "label": "Second valuation yesterday", "weight": 30, "points": 30],
                     ["key": "promised_decision", "label": "She said she'd decide after the second valuation", "weight": 25, "points": 25],
                     ["key": "temperature", "label": "Warm, leaning hot", "weight": 20, "points": 16]]]
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

    /// Week 3 `/today` cards (behind `-UITestPATodayCards`).
    static var cards: [[String: Any]] {
        var cards: [[String: Any]] = [
            ["uuid": "card-sarah", "rank": 1, "kind": "call", "person": ["name": "Sarah Collins", "phone": "+44 7700 900111"],
             "property": ["address": "22 Station Road"], "opportunity_uuid": UITestPropertyPAStub.sarahOpportunity, "action": "Call Sarah",
             "why_now": "Her second valuation was yesterday and she said she'd decide after it.",
             "objective": "Find out what the other agent said, and whether Tom agrees.", "estimated_minutes": 15, "score": 87],
            ["uuid": "card-michael", "rank": 2, "kind": "call", "person": ["name": "Michael Grant"], "property": ["address": "14 Green Lane"],
             "opportunity_uuid": "opp-michael", "action": "Call Michael back", "why_now": "You promised a follow-up this week.",
             "estimated_minutes": 10, "score": 72],
            ["uuid": "card-rick", "rank": 3, "kind": "message", "person": ["name": "Rick Hughes"], "property": ["address": "18 Market Street"],
             "opportunity_uuid": "opp-rick", "action": "Check in with Rick", "why_now": "Quiet for 3 weeks.", "estimated_minutes": 5, "score": 58],
        ]
        for index in 4...10 {
            cards.append(["uuid": "card-\(index)", "rank": index, "kind": "call", "person": ["name": "Seller \(index)"],
                          "opportunity_uuid": "opp-\(index)", "action": "Follow up", "estimated_minutes": 10, "score": 50 - Double(index)])
        }
        return cards
    }
}
#endif
