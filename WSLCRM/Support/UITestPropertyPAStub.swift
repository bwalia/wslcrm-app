#if DEBUG
import Foundation

/// Property PA routes for the UI-test stub server: a **mock** of the API the app asked opsapi
/// for (`docs/property-pa/api-requests/ios-pa-native-client.md`), seeded from How It Works
/// (fake data): Sophie (seller agent) and Ashley (manager); Sarah at 22 Station Road, Michael at
/// 14 Green Lane, Rick at 18 Market Street, and seven more sellers so "I have 30 minutes" has to
/// choose. Model answers are canned; the point is the app's behaviour, not the model's.
struct UITestPropertyPAStub {
    static let sarahCard = "card-sarah"
    static let sarahOpportunity = "opp-sarah"
    static let sarahPerson = "person-sarah"
    static let handoffUuid = "handoff-1"

    var isManager = false
    var writes: [String] = []
    private var doneCards: Set<String> = []
    private var captures: [String: [String: Any]] = [:]
    private var captureReads: [String: Int] = [:]
    private var handoff: [String: Any] = [:]
    private var rules: [String: [String: Any]] = [:]
    private var jobs: [String: Any] = [:]
    private var jobCount = 0

    mutating func reset() {
        writes = []
        doneCards = []
        captures = [:]
        captureReads = [:]
        handoff = Self.seededHandoff
        rules = [:]
        jobs = [:]
        jobCount = 0
    }

    mutating func route(method: String, path: String, query: String, json: [String: Any], body: Data, enabled: Bool) -> (Int, Any)? {
        let base = "/api/v2/property-pa"
        guard path.hasPrefix(base) else { return nil }
        guard enabled else { return (404, ["success": false, "error": "The PA is off for this workspace", "code": "PLUGIN_DISABLED"]) }
        let sub = String(path.dropFirst(base.count))
        switch (method, sub) {
        case ("GET", "/me"):
            return ok(["enabled": true, "role": isManager ? "manager" : "agent",
                       "user_uuid": UITestStubServer.userUuid, "display_name": isManager ? "Ashley" : "Sophie",
                       "permissions": ["capture": ["create"], "ask": ["create"], "handoff": ["create"], "knowledge": ["create"],
                                       "manager_view": isManager ? ["read"] : []],
                       "stt": "server", "max_audio_seconds": 300, "timezone": "Europe/London"])
        case ("GET", "/today"):
            return ok(query.contains("role=manager") ? managerToday : agentToday(query: query))
        case ("GET", let p) where p.hasPrefix("/why/"):
            return ok(Self.why)
        case ("POST", let p) where p.hasPrefix("/cards/"):
            let parts = p.split(separator: "/")
            guard parts.count == 3 else { return nil }
            doneCards.insert(String(parts[1]))
            writes.append("POST card \(parts[2]) \(parts[1])")
            return ok(["ok": true])
        case ("POST", let p) where p.hasPrefix("/prepare/"):
            return job(Self.brief(withRule: rules.values.contains { $0["status"] as? String == "approved" }))
        case ("POST", "/ask"):
            let question = (json["question"] as? String ?? "").lowercased()
            writes.append("POST ask")
            if question.contains("ashley") {
                handoff = Self.seededHandoff
                return job(["answer": "I've asked Ashley. The question and the facts are on his Today; his answer will come back here.",
                            "facts": [], "gaps": [],
                            "actions": [["type": "handoff_created", "handoff_uuid": Self.handoffUuid, "label": "Asked Ashley about the £230k offer"]]])
            }
            return job(Self.coaching)
        case ("GET", let p) where p.hasPrefix("/jobs/"):
            let id = String(p.dropFirst("/jobs/".count))
            guard let result = jobs[id] else { return (404, ["success": false, "error": "Not found"]) }
            return ok(["job_uuid": id, "status": "done", "result": result])
        case ("POST", "/capture"):
            let id = "capture-\(captures.count + 1)"
            let isAudio = !body.isEmpty && json.isEmpty
            captures[id] = Self.sarahCapture(id: id, transcript: isAudio ? Self.transcript : (json["text"] as? String ?? Self.transcript))
            captureReads[id] = 0
            writes.append("POST capture \(isAudio ? "audio" : "text")")
            return (202, ["success": true, "data": ["uuid": id, "capture_uuid": id, "status": "queued"]])
        case ("GET", "/captures"):
            return ok(captures.values.filter { $0["status"] as? String != "confirmed" }.map { capture -> [String: Any] in
                var row = capture
                row["status"] = "ready"
                return row
            })
        case ("GET", let p) where p.hasPrefix("/capture/") && !p.hasSuffix("/confirm"):
            let id = String(p.dropFirst("/capture/".count))
            guard var capture = captures[id] else { return (404, ["success": false, "error": "Not found"]) }
            captureReads[id, default: 0] += 1
            if capture["status"] as? String != "confirmed" {
                // The first read finds the PA still working; then it's ready.
                capture["status"] = (captureReads[id] ?? 0) <= 1 ? "extracting" : "ready"
            }
            return ok(capture)
        case ("POST", let p) where p.hasPrefix("/capture/") && p.hasSuffix("/confirm"):
            let id = String(p.dropFirst("/capture/".count).dropLast("/confirm".count))
            guard var capture = captures[id] else { return (404, ["success": false, "error": "Not found"]) }
            let decisions = json["decisions"] as? [[String: Any]] ?? []
            var updates = capture["updates"] as? [[String: Any]] ?? []
            for (index, update) in updates.enumerated() {
                guard let decision = decisions.first(where: { $0["update_uuid"] as? String == update["uuid"] as? String }) else { continue }
                let action = decision["action"] as? String ?? ""
                updates[index]["status"] = ["confirm": "confirmed", "correct": "corrected", "reject": "rejected"][action] ?? "proposed"
                if action == "correct" { updates[index]["new_value"] = decision["value"] }
            }
            capture["updates"] = updates
            capture["status"] = "confirmed"
            capture["summary"] = "Call with Sarah about 22 Station Road. Second valuation £240k; she won't go below £235k; Tom needs to agree. Call her tomorrow at 11:00."
            captures[id] = capture
            doneCards.insert(Self.sarahCard)
            writes.append("POST confirm " + decisions.map { "\($0["update_uuid"] as? String ?? ""):\($0["action"] as? String ?? "")" }.joined(separator: ","))
            return ok(capture)
        case ("POST", "/handoff"):
            handoff = Self.seededHandoff
            handoff["question"] = json["question"] ?? handoff["question"] ?? ""
            if let recommendation = json["recommendation"] { handoff["recommendation"] = recommendation }
            writes.append("POST handoff")
            return (201, ["success": true, "data": handoff])
        case ("GET", "/handoffs/\(Self.handoffUuid)"):
            return ok(handoff)
        case ("POST", "/handoffs/\(Self.handoffUuid)/reply"):
            let decision = json["decision"] as? String ?? "agree"
            handoff["status"] = decision == "agree" ? "agreed" : "replied"
            handoff["reply"] = (json["text"] as? String) ?? "Agreed: go to £230k if she'll complete in 4 weeks."
            handoff["replied_at"] = UITestPropertyDealsStub.iso(minutes: 0)
            writes.append("POST handoff reply \(decision)")
            return ok(handoff)
        case ("POST", "/teach"):
            let id = "rule-\(rules.count + 1)"
            let rule: [String: Any] = ["uuid": id, "rule": "An agent's valuation is not the seller's minimum price; treat it as their anchor.",
                                       "rationale": "Sellers quote the highest valuation they've heard. It sets expectations, not a floor.",
                                       "category": "negotiation", "triggers": ["A seller quotes another agent's valuation", "Discussing price"],
                                       "scope": json["scope"] ?? "personal", "version": 1, "status": "draft"]
            rules[id] = rule
            writes.append("POST teach \(json["scope"] as? String ?? "")")
            return (201, ["success": true, "data": rule])
        case ("POST", let p) where p.hasPrefix("/knowledge/") && p.hasSuffix("/approve"):
            let id = String(p.dropFirst("/knowledge/".count).dropLast("/approve".count))
            guard var rule = rules[id] else { return (404, ["success": false, "error": "Not found"]) }
            rule["status"] = "approved"
            rules[id] = rule
            writes.append("POST approve \(id)")
            return ok(rule)
        default:
            return nil
        }
    }

    // MARK: Helpers

    private func ok(_ data: Any) -> (Int, Any) { (200, ["success": true, "data": data]) }

    /// Model calls answer 202 with a job; the first poll finds it done.
    private mutating func job(_ result: Any) -> (Int, Any) {
        jobCount += 1
        let id = "job-\(jobCount)"
        jobs[id] = result
        return (202, ["success": true, "data": ["job_uuid": id, "status": "queued"]])
    }

    // MARK: Fixtures

    private func agentToday(query: String) -> [String: Any] {
        var cards = Self.sellerCards.filter { !doneCards.contains($0["uuid"] as? String ?? "") }
        if let minutes = query.split(separator: "&").first(where: { $0.hasPrefix("mode=minutes") })
            .flatMap({ Int($0.split(separator: "%3A").last ?? $0.split(separator: ":").last ?? "") }) {
            var used = 0
            cards = cards.filter { card in
                let need = card["estimated_minutes"] as? Int ?? 10
                guard used + need <= minutes else { return false }
                used += need
                return true
            }
        }
        let approvedRule = rules.values.contains { $0["status"] as? String == "approved" }
        var brief = "Morning, Sophie. Sarah is the one today: her second valuation was yesterday and she said she'd decide after it. Michael is waiting for the follow-up you promised, and Rick has gone quiet."
        if approvedRule { brief += " New company rule: an agent's valuation isn't the seller's minimum." }
        return ["generated_at": UITestPropertyDealsStub.iso(minutes: -5), "mode": query.contains("minutes") ? "minutes" : "full",
                "brief": ["text": brief, "sources": [["type": "event", "uuid": "event-valuation", "label": "Second valuation, yesterday"],
                                                     ["type": "lead", "uuid": UITestPropertyDealsStub.hotLeadUuid, "label": "Sarah Collins"]]],
                "cards": cards]
    }

    private var managerToday: [String: Any] {
        var cards: [[String: Any]] = []
        if handoff["status"] as? String == "open" {
            cards.append(["uuid": "card-handoff", "rank": 1, "kind": "handoff",
                          "person": ["uuid": "user-sophie", "name": "Sophie"], "property": ["uuid": "prop-22", "address": "22 Station Road"],
                          "handoff_uuid": Self.handoffUuid, "action": "Sophie asks: offer £230k to Sarah?",
                          "why_now": "Sarah decides after speaking to Tom tomorrow at 11:00."])
        }
        cards.append(["uuid": "card-rick", "rank": cards.count + 1, "kind": "relationship_risk",
                      "person": ["uuid": "person-rick", "name": "Rick Hughes"], "property": ["uuid": "prop-18", "address": "18 Market Street"],
                      "opportunity_uuid": "opp-rick", "action": "Rick has gone quiet for 3 weeks",
                      "why_now": "No meaningful contact since 20 Sep; he was warm before."])
        return ["generated_at": UITestPropertyDealsStub.iso(minutes: -5),
                "brief": ["text": "One decision needs you, and one relationship is at risk. Everything else is being handled.", "sources": []],
                "cards": cards, "handled_count": 14]
    }

    static var sellerCards: [[String: Any]] {
        var cards: [[String: Any]] = [
            ["uuid": sarahCard, "rank": 1, "kind": "call",
             "person": ["uuid": sarahPerson, "name": "Sarah Collins", "phone": "+44 7700 900111"],
             "property": ["uuid": "prop-22", "address": "22 Station Road"], "opportunity_uuid": sarahOpportunity,
             "action": "Call Sarah", "why_now": "Her second valuation was yesterday and she said she'd decide after it.",
             "objective": "Find out what the other agent said, and whether Tom agrees.",
             "pa_view": "Lead with a quick, certain completion rather than price.", "estimated_minutes": 15, "score": 87],
            ["uuid": "card-michael", "rank": 2, "kind": "call",
             "person": ["uuid": "person-michael", "name": "Michael Grant", "phone": "+44 7700 900222"],
             "property": ["uuid": "prop-14", "address": "14 Green Lane"], "opportunity_uuid": "opp-michael",
             "action": "Call Michael back", "why_now": "You promised him a follow-up this week.",
             "objective": "Keep the promise and agree a viewing date.", "estimated_minutes": 10, "score": 72],
            ["uuid": "card-rick-agent", "rank": 3, "kind": "message",
             "person": ["uuid": "person-rick", "name": "Rick Hughes", "phone": "+44 7700 900333"],
             "property": ["uuid": "prop-18", "address": "18 Market Street"], "opportunity_uuid": "opp-rick",
             "action": "Check in with Rick", "why_now": "Quiet for 3 weeks; he was warm before.",
             "objective": "Find out if anything changed.", "estimated_minutes": 5, "score": 58],
        ]
        let others = ["Priya Nair · 3 Brick Row", "Tom Ellis · 9 Abbey Close", "Hannah Webb · 51 Mill Road",
                      "Owen Price · 2 Fern Court", "Grace Lee · 77 Bridge Street", "Dan Hart · 6 Orchard Way", "Lucy Moss · 40 High Street"]
        for (index, entry) in others.enumerated() {
            let parts = entry.components(separatedBy: " · ")
            cards.append(["uuid": "card-\(index + 4)", "rank": index + 4, "kind": "call",
                          "person": ["uuid": "person-\(index + 4)", "name": parts[0], "phone": "+44 7700 90040\(index)"],
                          "property": ["uuid": "prop-\(index + 4)", "address": parts[1]], "opportunity_uuid": "opp-\(index + 4)",
                          "action": "Follow up with \(parts[0].split(separator: " ").first ?? "")",
                          "why_now": "\(14 + index * 3) days since a meaningful conversation.", "estimated_minutes": 10,
                          "score": 50 - Double(index * 4)])
        }
        return cards
    }

    static var why: [String: Any] {
        ["card_uuid": sarahCard, "score": 87,
         "signals": [
            ["key": "event_just_happened", "label": "Second valuation yesterday", "value": 1, "weight": 30, "points": 30,
             "source": ["type": "event", "uuid": "event-valuation", "label": "Valuation, 12 Oct"]],
            ["key": "promised_decision", "label": "She said she'd decide after the second valuation", "value": 1, "weight": 25, "points": 25,
             "source": ["type": "interaction", "uuid": "int-1", "label": "Call, 6 Oct"]],
            ["key": "temperature", "label": "Warm, leaning hot", "value": 0.8, "weight": 20, "points": 16],
            ["key": "days_since_contact", "label": "6 days since a meaningful conversation", "value": 6, "weight": 2, "points": 12],
            ["key": "lead_source", "label": "Direct enquiry", "value": 1, "weight": 4, "points": 4],
         ],
         "explanation": "Something just happened that she said she'd decide on, and it's been nearly a week."]
    }

    static func brief(withRule: Bool) -> [String: Any] {
        var facts: [[String: Any]] = [
            ["text": "Second agent valued 22 Station Road at £240,000 yesterday", "kind": "stated", "confidence": 0.9,
             "source": ["type": "event", "uuid": "event-valuation", "label": "Valuation, 12 Oct"]],
            ["text": "She said she'd decide after the second valuation", "kind": "stated",
             "source": ["type": "interaction", "uuid": "int-1", "label": "Call, 6 Oct"]],
        ]
        if withRule {
            facts.append(["text": "Company rule: an agent's valuation isn't her minimum price; treat £240k as her anchor", "kind": "stated",
                          "source": ["type": "knowledge", "uuid": "rule-1", "label": "Rule v1, Ashley"]])
        }
        return ["opportunity_uuid": sarahOpportunity, "objective": "Find out whether Tom agrees, and whether speed matters more than price.",
                "sections": [
                    ["key": "snapshot", "title": "Snapshot", "facts": facts],
                    ["key": "position", "title": "Price and offer", "facts": [
                        ["text": "Our offer so far: £220,000", "kind": "stated",
                         "source": ["type": "deal", "uuid": UITestPropertyDealsStub.amberDealUuid, "label": "Deal, 22 Station Road"]]]],
                    ["key": "questions", "title": "Questions to establish", "facts": [
                        ["text": "What does Tom think?", "kind": "proposed"],
                        ["text": "What matters more: the price or completing in 4 weeks?", "kind": "proposed"]]],
                ],
                "gaps": ["We don't know Tom's view yet.", "We don't know the second agent's fee or terms."]]
    }

    static var coaching: [String: Any] {
        ["answer": "Don't raise the offer yet. Her £235k is anchored on the £240k valuation, and Tom hasn't been asked. Ask what matters more to them, price or a 4-week completion, before talking money.",
         "facts": [
            ["text": "She won't go below £235,000", "kind": "stated", "source": ["type": "interaction", "uuid": "int-2", "label": "Your note, today"]],
            ["text": "£225,000 might work with a 4-week completion", "kind": "inferred", "confirmed": false, "by": "Sophie",
             "source": ["type": "interaction", "uuid": "int-2", "label": "Your note, today"]]],
         "gaps": ["Tom's view on price."], "actions": []]
    }

    static let transcript = "Spoke to Sarah. Second agent valued it at 240k. She won't go below 235. Her husband Tom needs to agree. I reckon 225 might work if we can complete in four weeks. Call her tomorrow at 11."

    static func sarahCapture(id: String, transcript: String) -> [String: Any] {
        ["uuid": id, "status": "extracting", "transcript": transcript, "created_at": UITestPropertyDealsStub.iso(minutes: 0),
         "resolved": ["person": ["uuid": sarahPerson, "name": "Sarah Collins"], "property": ["uuid": "prop-22", "address": "22 Station Road"]],
         "updates": [
            ["uuid": "u1", "label": "Second valuation (other agent)", "new_value": 240000, "display": "£240,000", "kind": "stated", "confidence": 0.95, "material": true, "status": "proposed"],
            ["uuid": "u2", "label": "Seller's stated minimum", "new_value": 235000, "display": "£235,000", "kind": "stated", "confidence": 0.93, "material": true, "status": "proposed"],
            ["uuid": "u3", "label": "Decision makers", "new_value": "Sarah + Tom (husband)", "kind": "stated", "confidence": 0.9, "material": true, "status": "proposed"],
            ["uuid": "u4", "label": "Price that might work", "new_value": 225000, "display": "£225,000", "kind": "inferred", "by": "Sophie", "confidence": 0.6, "material": true, "status": "proposed"],
            ["uuid": "u5", "label": "Timescale lever", "new_value": "Completion in 4 weeks", "kind": "inferred", "by": "Sophie", "confidence": 0.7, "material": false, "status": "proposed"],
         ],
         "next_action": ["uuid": "u6", "title": "Call Sarah", "due_at": tomorrowAt11, "owner": ["uuid": UITestStubServer.userUuid, "name": "Sophie"],
                         "reason": "She'll decide after speaking to Tom", "material": true]]
    }

    static var tomorrowAt11: String {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let tomorrow = london.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return APIDate.string(from: london.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
    }

    static var seededHandoff: [String: Any] {
        ["uuid": handoffUuid, "from": ["uuid": "user-sophie", "name": "Sophie"], "to": ["uuid": "user-ashley", "name": "Ashley"],
         "opportunity_uuid": sarahOpportunity, "deal_uuid": UITestPropertyDealsStub.amberDealUuid,
         "question": "Can we offer Sarah £230k if she completes in 4 weeks?",
         "recommendation": "Hold at £225k until Tom's view is known; go to £230k only for a 4-week completion.",
         "context_facts": [
            ["text": "She won't go below £235,000", "kind": "stated", "source": ["type": "interaction", "uuid": "int-2", "label": "Sophie's note"]],
            ["text": "£225,000 might work with a 4-week completion", "kind": "inferred", "confirmed": false, "by": "Sophie",
             "source": ["type": "interaction", "uuid": "int-2", "label": "Sophie's note"]]],
         "status": "open"]
    }
}
#endif
