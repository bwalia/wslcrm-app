#if DEBUG
import Foundation

/// Property Deals routes for the UI-test stub server, seeded with the SPEC §5 scenario: workspace
/// "Demo Buyers Ltd", a deal at Searches with 9 working days to its target completion, a £500/day
/// late penalty (cap 20 days), an overdue EPC booking task, and the seller's solicitor silent for
/// 50 hours with 2 open enquiries. Shapes follow the plugin's OpenAPI schemas (nulls left out).
///
/// Only the `operator` role has the plugin; every other role gets `404 PLUGIN_DISABLED`, as a
/// workspace without the plugin would.
struct UITestPropertyDealsStub {
    static let dealUuid = "d0000000-0000-4000-8000-000000000001"
    static let amberDealUuid = "d0000000-0000-4000-8000-000000000002"
    static let epcTaskUuid = "t0000000-0000-4000-8000-000000000001"
    static let chaseTaskUuid = "t0000000-0000-4000-8000-000000000002"
    static let searchesTaskUuid = "t0000000-0000-4000-8000-000000000003"
    static let fundsTaskUuid = "t0000000-0000-4000-8000-000000000004"
    static let approvalUuid = "a0000000-0000-4000-8000-000000000001"
    static let checklistItemUuids = ["ci000000-0000-4000-8000-000000000001", "ci000000-0000-4000-8000-000000000002"]
    static let hotLeadUuid = "l0000000-0000-4000-8000-000000000001"
    static let hotCallTaskUuid = "t0000000-0000-4000-8000-000000000009"
    static let renovationJobUuid = "rj000000-0000-4000-8000-000000000001"

    var tasks: [String: [String: Any]] = [:]
    var approval: [String: Any] = [:]
    /// `-UITestApprovalChanges`: someone edits the draft on the web just before this phone approves.
    var approvalChangesBeforeDecide = false
    /// `-UITestApprovalChangesLate`: the edit lands after the app's own check, so only the
    /// server's version guard (409) catches it.
    var approvalChangesAtDecide = false
    var preferences: [String: Any] = [:]
    var checklistDone: [String: Bool] = [:]
    var chases: [[String: Any]] = []
    /// Every write the app sent, for UI tests that assert on what reached the server.
    var writes: [String] = []
    /// The signed-in person is the workspace's Property Deals manager (`-UITestRole pdmanager`):
    /// the team's view of what's due, renovations and a hot lead to call.
    var isManager = false
    /// The request's query string (the router only sees the path).
    var query = ""
    var hotLeadOpen = false
    var replies: [[String: Any]] = []
    var signals: [[String: Any]] = []
    var renovations: [[String: Any]] = []
    private var inboxReads = 0
    private var capturedLeads = 0
    private var capturedProperties = 0

    mutating func reset() {
        tasks = Self.seededTasks()
        approval = Self.seededApproval
        approvalChangesBeforeDecide = ProcessInfo.processInfo.arguments.contains("-UITestApprovalChanges")
        approvalChangesAtDecide = ProcessInfo.processInfo.arguments.contains("-UITestApprovalChangesLate")
        preferences = Self.defaultPreferences
        checklistDone = [Self.checklistItemUuids[0]: true, Self.checklistItemUuids[1]: false]
        chases = []
        writes = []
        inboxReads = 0
        hotLeadOpen = true
        replies = [["uuid": "rp1", "lead_uuid": Self.hotLeadUuid, "channel": "whatsapp", "from_name": "Pat Keen",
                    "received_at": Self.iso(minutes: -6), "body_text": "Yes please, can you come round tomorrow? We'd like to sell quickly.",
                    "reply_temperature": "hot", "reply_score": 88, "reply_reason": "Asks for a visit tomorrow and wants a quick sale",
                    "hot_task_uuid": Self.hotCallTaskUuid, "matched_by": "lead"]]
        signals = [["uuid": "sg1", "lead_uuid": Self.hotLeadUuid, "kind": "charge_registered", "source": "companies_house",
                    "title": "New charge on Keen Lettings Ltd", "summary": "Outstanding charge registered with Nationwide",
                    "occurred_at": Self.iso(minutes: -60 * 24 * 3)]]
        renovations = [Self.renovation]
    }

    /// Handles a Property Deals call, or a kanban call on one of its tasks; nil for anything else.
    mutating func route(method: String, path: String, json: [String: Any], enabled: Bool) -> (Int, Any)? {
        let base = "/api/v2/property-deals"
        // Quick capture's first step is a core CRM lead.
        if method == "POST", path == "/api/v2/crm/leads", enabled {
            capturedLeads += 1
            writes.append("POST /crm/leads \(json["first_name"] as? String ?? "")")
            return (201, ["success": true, "data": ["uuid": "lead-cap-\(capturedLeads)", "first_name": json["first_name"] ?? ""]])
        }
        // Core push registration; recorded so tests can see this phone asked for alerts.
        if path == "/api/v2/device-tokens" {
            writes.append("\(method) /device-tokens")
            return (method == "POST" ? 201 : 200, ["message": "ok", "data": ["token_type": json["token_type"] ?? "apns"]])
        }
        let isPDTask = Self.taskUuids.contains { path.hasPrefix("/api/v2/kanban/tasks/\($0)/") }
        let isPDChecklistItem = Self.checklistItemUuids.contains { path.hasPrefix("/api/v2/kanban/checklist-items/\($0)") }
        guard path.hasPrefix(base) || isPDTask || isPDChecklistItem else { return nil }
        guard enabled else {
            return (404, ["success": false, "error": "Property Deals is turned off for this workspace", "code": "PLUGIN_DISABLED"])
        }
        let sub = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path

        switch (method, sub) {
        case ("GET", "/me"):
            return ok(isManager ? Self.managerMe : Self.me)
        case ("GET", "/hot-leads"):
            return ok(isManager && hotLeadOpen ? [Self.hotLead] : [])
        case ("GET", "/leads/\(Self.hotLeadUuid)"):
            return ok(Self.lead)
        case ("GET", "/leads/\(Self.hotLeadUuid)/replies"):
            return ok(replies)
        case ("GET", "/leads/\(Self.hotLeadUuid)/signals"):
            return ok(signals)
        case ("POST", "/leads/\(Self.hotLeadUuid)/replies"):
            let text = (json["text"] as? String ?? "").lowercased()
            let hot = ["yes", "keen", "asap", "call me", "today"].contains { text.contains($0) }
            let reply: [String: Any] = ["uuid": "rp\(replies.count + 1)", "lead_uuid": Self.hotLeadUuid,
                                        "channel": json["channel"] ?? "other", "body_text": json["text"] ?? "",
                                        "received_at": Self.iso(minutes: 0), "reply_temperature": hot ? "hot" : "warm",
                                        "reply_score": hot ? 82 : 55,
                                        "reply_reason": hot ? "Wants to go ahead now" : "Interested but no timing",
                                        "alerted": hot ? 1 : 0, "scored_by": "rules"]
            replies.insert(reply, at: 0)
            if hot { hotLeadOpen = true }
            writes.append("POST replies \(json["channel"] as? String ?? "")")
            return (201, ["success": true, "data": reply])
        case ("POST", "/leads/\(Self.hotLeadUuid)/signals"):
            let signal: [String: Any] = ["uuid": "sg\(signals.count + 1)", "lead_uuid": Self.hotLeadUuid,
                                         "kind": json["kind"] ?? "note", "source": "manual",
                                         "summary": json["text"] ?? "", "created_at": Self.iso(minutes: 0)]
            signals.insert(signal, at: 0)
            writes.append("POST signals \(json["kind"] as? String ?? "")")
            return (201, ["success": true, "data": signal])
        case ("POST", "/tasks/\(Self.hotCallTaskUuid)/contact-log"):
            writes.append("POST contact-log \(json["channel"] as? String ?? "") \(json["outcome"] as? String ?? "")")
            return (201, ["success": true, "data": ["uuid": "ch-call-1", "channel": json["channel"] ?? "phone",
                                                    "outcome": json["outcome"] ?? ""]])
        case ("PUT", "/tasks/\(Self.hotCallTaskUuid)"):
            hotLeadOpen = false
            writes.append("PUT /tasks/\(Self.hotCallTaskUuid) \(json["pd_status"] as? String ?? "")")
            return ok(["task_uuid": Self.hotCallTaskUuid, "title": "Call Pat Keen now", "pd_status": json["pd_status"] ?? "done"])
        case ("GET", "/due"):
            let mine = query.contains("mine=true")
            return ok(["days": 7, "everyone": isManager && !mine, "items": dueItems(everyone: isManager && !mine)])
        case ("GET", "/renovations"):
            let deal = query.split(separator: "&").first { $0.hasPrefix("deal_uuid=") }.map { String($0.dropFirst("deal_uuid=".count)) }
            return ok(renovations.filter { deal == nil || $0["deal_uuid"] as? String == deal })
        case ("POST", "/renovations"):
            var created = Self.renovation
            created["uuid"] = "rn\(renovations.count + 1)"
            created["deal_uuid"] = json["deal_uuid"] ?? ""
            created["name"] = json["name"] ?? "Renovation"
            created["due_date"] = json["target_end_date"] ?? Self.isoDay(days: 50)
            created["jobs_done"] = 0
            created["jobs_overdue"] = 0
            renovations.append(created)
            writes.append("POST /renovations \(json["deal_uuid"] as? String ?? "")")
            return (201, ["success": true, "data": created])
        case ("GET", "/today"):
            return ok(today)
        case ("GET", let p) where p.hasPrefix("/tasks/") && !p.dropFirst("/tasks/".count).contains("/"):
            let uuid = String(p.dropFirst("/tasks/".count))
            guard let task = tasks[uuid] else { return notFound }
            return ok(task)
        case ("PUT", let p) where p.hasPrefix("/tasks/"):
            let uuid = String(p.dropFirst("/tasks/".count))
            guard var task = tasks[uuid] else { return notFound }
            if json["snoozed_until"] != nil, (json["snooze_reason"] as? String)?.isEmpty ?? true {
                return (422, ["success": false, "error": "Validation failed", "details": ["snooze_reason": "is required when snoozing"]])
            }
            if json["pd_status"] as? String == "done", task["compliance"] as? Bool == true, json["evidence"] == nil {
                return (422, ["success": false, "error": "Validation failed",
                              "details": ["evidence": "a compliance task needs evidence to close"]])
            }
            for key in ["pd_status", "snoozed_until", "snooze_reason", "evidence"] where json[key] != nil {
                task[key] = json[key]
            }
            if json["pd_status"] as? String == "done" { task["completed_at"] = Self.iso(minutes: 0) }
            tasks[uuid] = task
            writes.append("PUT /tasks/\(uuid) \(json["pd_status"] as? String ?? (json["snoozed_until"] != nil ? "snooze" : ""))")
            return ok(task)
        case ("POST", let p) where p.hasPrefix("/tasks/") && p.hasSuffix("/agent-run"):
            // Phase 5 endpoint: not on the server yet, so the stub answers as the real one does today.
            return notFound
        case ("GET", "/approvals/inbox"):
            if approvalChangesBeforeDecide, inboxReads >= 1 {
                // The second read is the app's check just before approving: the draft has moved on.
                approvalChangesBeforeDecide = false
                approval["original_payload"] = approval["payload"]
                approval["payload"] = Self.emailPayload(body: Self.emailBody + "\n\nPS: we can courier the signed forms today.")
                approval["payload_version"] = 2
            }
            inboxReads += 1
            return ok(approval["status"] as? String == "pending" ? [approval] : [], meta: true)
        case ("POST", let p) where p.hasPrefix("/approvals/") && p.hasSuffix("/decide"):
            guard approval["status"] as? String == "pending" else {
                return (409, ["success": false, "error": "Already \(approval["status"] as? String ?? "decided")"])
            }
            if approvalChangesAtDecide {
                approvalChangesAtDecide = false
                approval["original_payload"] = approval["payload"]
                approval["payload"] = Self.emailPayload(body: Self.emailBody + "\n\nPS: please confirm the FENSA date too.")
                approval["payload_version"] = 2
            }
            if let seen = json["payload_version"] as? Int, seen != (approval["payload_version"] as? Int ?? 1) {
                return (409, ["success": false, "error": "The draft has changed since you opened it",
                              "details": ["payload_version": approval["payload_version"] ?? 1]])
            }
            let decision = json["decision"] as? String
            if decision == "reject", (json["note"] as? String)?.isEmpty ?? true {
                return (422, ["success": false, "error": "Validation failed",
                              "details": ["note": "say why it is rejected (the agent can retry with it)"]])
            }
            var entry: [String: Any] = ["user_uuid": UITestStubServer.userUuid, "decision": decision ?? "",
                                        "at": Self.iso(minutes: 0), "edited": json["payload"] != nil,
                                        "payload_version": approval["payload_version"] ?? 1]
            if let note = json["note"] { entry["note"] = note }
            if let edited = json["payload"] {
                approval["original_payload"] = approval["payload"]
                approval["payload"] = edited
                approval["payload_version"] = ((approval["payload_version"] as? Int) ?? 1) + 1
                entry["payload_version"] = approval["payload_version"]
            }
            approval["decisions"] = [entry]
            approval["status"] = decision == "reject" ? "rejected" : "approved"
            approval["decided_at"] = Self.iso(minutes: 0)
            if decision == "approve", approval["action"] as? String == "send_email" {
                // Phase 5: the executor sends it straight away.
                approval["status"] = "executed"
                approval["executed_at"] = Self.iso(minutes: 0)
                approval["execution_result"] = ["chase_uuid": "ch-sent-1",
                                                "sent_to": (approval["payload"] as? [String: Any])?["to"] ?? ""]
            }
            approval.removeValue(forKey: "can_decide")
            writes.append("POST decide \(decision ?? "") \(json["payload"] != nil ? "edited" : "as-is")")
            return ok(approval)
        case ("PUT", let p) where p.hasPrefix("/leads/") && p.hasSuffix("/details"):
            writes.append("PUT \(p) \(json.keys.sorted().joined(separator: ","))")
            return ok(["uuid": String(p.dropFirst("/leads/".count).dropLast("/details".count)), "details": json])
        case ("POST", "/properties"):
            capturedProperties += 1
            writes.append("POST /properties \(json["address_line1"] as? String ?? "")")
            return (201, ["success": true, "data": ["uuid": "prop-cap-\(capturedProperties)"].merging(
                json.compactMapValues { $0 as? String }) { a, _ in a }])
        case ("POST", "/documents"):
            writes.append("POST /documents photo")
            return (201, ["success": true, "data": ["uuid": "doc-cap-\(writes.count)", "filename": "photo.jpg", "category": "photo"]])
        case ("GET", "/notification-preferences"):
            return ok(preferences)
        case ("PUT", "/notification-preferences"):
            for (key, value) in json {
                if value is NSNull { preferences.removeValue(forKey: key); continue }
                if var current = preferences[key] as? [String: Any], let change = value as? [String: Any], key != "quiet_hours" {
                    current.merge(change) { $1 }
                    preferences[key] = current
                } else {
                    preferences[key] = value
                }
            }
            writes.append("PUT /notification-preferences \(json.keys.sorted().joined(separator: ","))")
            return ok(preferences)
        case ("GET", "/documents"):
            return ok([["uuid": "doc00000-0000-4000-8000-000000000001", "filename": "EPC-register-search.pdf",
                        "category": "epc", "mime_type": "application/pdf", "size_bytes": 48_211,
                        "created_at": Self.iso(minutes: -90)]], meta: true)
        case ("GET", let p) where p.hasPrefix("/deals/") && p.hasSuffix("/overview"):
            let uuid = String(p.dropFirst("/deals/".count).dropLast("/overview".count))
            return uuid == Self.dealUuid ? ok(overview) : (uuid == Self.amberDealUuid ? ok(amberOverview) : notFound)
        case ("GET", "/deals"):
            return ok(dealsList, meta: true)
        case ("POST", "/chases"):
            var chase = json
            chase["uuid"] = "ch\(chases.count + 1)"
            chases.append(chase)
            writes.append("POST /chases \(json["channel"] as? String ?? "")")
            return (201, ["success": true, "data": chase])

        // Kanban side of a deal task (checklist, notes come from the shared comments stub).
        case ("GET", let p) where p.hasSuffix("/checklists"):
            guard Self.taskUuid(in: p) == Self.epcTaskUuid else { return ok([]) }
            return ok([["uuid": "cl000000-0000-4000-8000-000000000001", "name": "Before booking",
                        "item_count": 2, "completed_item_count": checklistDone.values.filter { $0 }.count,
                        "items": [
                            ["uuid": Self.checklistItemUuids[0], "content": "Search the EPC register for a valid certificate",
                             "is_completed": checklistDone[Self.checklistItemUuids[0]] ?? false, "position": 0],
                            ["uuid": Self.checklistItemUuids[1], "content": "Confirm access with the seller",
                             "is_completed": checklistDone[Self.checklistItemUuids[1]] ?? false, "position": 1],
                        ]]])
        case ("PUT", let p) where p.hasPrefix("/api/v2/kanban/checklist-items/") && p.hasSuffix("/toggle"):
            let uuid = String(p.dropFirst("/api/v2/kanban/checklist-items/".count).dropLast("/toggle".count))
            checklistDone[uuid] = !(checklistDone[uuid] ?? false)
            writes.append("PUT checklist \(uuid)")
            return ok(["uuid": uuid, "is_completed": checklistDone[uuid] ?? false])
        default:
            return nil
        }
    }

    // MARK: Responses

    private func ok(_ data: Any, meta: Bool = false) -> (Int, Any) {
        var body: [String: Any] = ["success": true, "data": data]
        if meta, let list = data as? [Any] {
            body["meta"] = ["page": 1, "per_page": 50, "total": list.count, "total_pages": 1]
        }
        return (200, body)
    }

    private var notFound: (Int, Any) { (404, ["success": false, "error": "Not found"]) }

    static var me: [String: Any] {
        [
        "user_uuid": UITestStubServer.userUuid, "namespace_uuid": UITestStubServer.namespaceUuid,
        "is_manager": false, "setup_done": true,
        "permissions": ["deals": ["read", "create", "update"], "properties": ["read", "create"], "tasks": ["read", "create", "update"],
                        "approvals": ["read", "update"], "compliance": ["read"], "ai": ["read", "create"],
                        "suppliers": ["read"], "buyers": ["read"], "settings": ["read"], "reports": ["read"]],
        "settings": ["timezone": "Europe/London", "jurisdiction": "england_wales", "currency": "GBP",
                     "digest_time": "07:30", "due_time": "17:00"],
        ]
    }

    private var openTasks: [[String: Any]] {
        let order = [Self.epcTaskUuid, Self.chaseTaskUuid, Self.searchesTaskUuid, Self.fundsTaskUuid]
        return order.compactMap { tasks[$0] }.filter { task in
            guard let status = task["pd_status"] as? String, status != "done", status != "cancelled" else { return false }
            if let until = (task["snoozed_until"] as? String).flatMap(APIDate.parse), until > Date() { return false }
            return true
        }
    }

    private func summary(_ task: [String: Any]) -> [String: Any] {
        var row = task
        for key in ["description", "evidence", "metadata", "uuid", "comment_count", "attachment_count",
                    "sla_started_at", "sla_warned_at", "sla_breached_at", "created_at", "updated_at"] {
            row.removeValue(forKey: key)
        }
        row["deal_health"] = "red"
        if let due = (task["due_at"] as? String).flatMap(APIDate.parse) { row["overdue"] = due < Date() }
        return row
    }

    private var today: [String: Any] {
        let open = openTasks.map(summary)
        let overdue = open.filter { $0["overdue"] as? Bool == true }.count
        let pending = approval["status"] as? String == "pending"
        return [
            "today": Self.isoDay(days: 0), "generated_at": Self.iso(minutes: 0),
            "counts": ["open": open.count, "overdue": overdue, "due_today": 1, "awaiting_approval": pending ? 1 : 0],
            "tasks": open,
            "red_deals": [Self.redDealCard],
            "money_at_risk": 7000,
            "approvals_waiting": pending ? [Self.approvalCard] : [],
            "approvals_waiting_count": pending ? 1 : 0,
        ]
    }

    static var redDealCard: [String: Any] {
        [
        "uuid": dealUuid, "name": "7 Mill Lane", "stage_key": "searches", "health": "red", "money_at_risk": 7000,
        "target_completion_date": isoDay(days: 13), "predicted_completion_date": isoDay(days: 27),
        "health_reasons": ["1 blocking task(s) overdue", "£7000.00 at risk: 14 day(s) late × £500/day (cap 20 days)"],
        ]
    }

    static var managerMe: [String: Any] {
        var me = Self.me
        me["user_uuid"] = UITestStubServer.userUuid
        me["is_manager"] = true
        let all = ["read", "create", "update", "delete", "manage"]
        me["permissions"] = Dictionary(uniqueKeysWithValues: ["deals", "properties", "tasks", "approvals", "compliance", "ai",
                                                              "suppliers", "buyers", "settings", "reports"].map { ($0, all) })
        return me
    }

    static var hotLead: [String: Any] {
        ["lead_uuid": hotLeadUuid, "first_name": "Pat", "last_name": "Keen", "company_name": "Keen Lettings Ltd",
         "phone": "+44 7700 900123", "email": "pat@keen.example", "lead_kind": "seller", "hot_score": 88,
         "hot_reason": "Asks for a visit tomorrow and wants a quick sale", "last_reply_at": iso(minutes: -6),
         "call_task_uuid": hotCallTaskUuid, "call_due_at": iso(minutes: 9)]
    }

    static var lead: [String: Any] {
        ["uuid": hotLeadUuid, "first_name": "Pat", "last_name": "Keen", "company_name": "Keen Lettings Ltd",
         "phone": "+44 7700 900123", "email": "pat@keen.example", "source": "companies_house", "status": "contacted",
         "details": ["lead_kind": "seller", "situation": "relocation", "temperature": "hot"]]
    }

    static var renovation: [String: Any] {
        ["uuid": "rn1", "project_uuid": UITestStubServer.projectUuid, "board_uuid": "b1", "deal_uuid": amberDealUuid,
         "deal_name": "22 Station Road", "name": "Renovation — 22 Station Road", "status": "active",
         "budget": 18000, "budget_spent": 4200, "budget_currency": "GBP", "start_date": isoDay(days: -10),
         "due_date": isoDay(days: 40), "jobs_total": 19, "jobs_done": 4, "jobs_overdue": 1]
    }

    func dueItems(everyone: Bool) -> [[String: Any]] {
        var items: [[String: Any]] = [
            ["kind": "deal_task", "uuid": Self.epcTaskUuid, "title": "Book an EPC assessor", "due_at": Self.iso(minutes: -60),
             "overdue": true, "status": "todo", "deal_uuid": Self.dealUuid, "deal_name": "7 Mill Lane", "assignee": "Sam Okafor"],
            ["kind": "renovation_job", "uuid": Self.renovationJobUuid, "title": "Strip out the kitchen",
             "due_at": Self.iso(minutes: 60 * 26), "overdue": false, "status": "open", "deal_uuid": Self.amberDealUuid,
             "deal_name": "22 Station Road", "project_uuid": UITestStubServer.projectUuid,
             "project_name": "Renovation — 22 Station Road", "column_name": "Strip out", "assignee": "Sam Builder"],
        ]
        if everyone {
            items.append(["kind": "deal_task", "uuid": Self.fundsTaskUuid, "title": "Confirm the buyer's proof of funds",
                          "due_at": Self.iso(minutes: 60 * 24 * 4), "overdue": false, "status": "todo",
                          "deal_uuid": Self.dealUuid, "deal_name": "7 Mill Lane", "assignee": "Priya Shah"])
        }
        return items
    }

    static var approvalCard: [String: Any] {
        [
        "uuid": approvalUuid, "title": "Chase seller's solicitor", "subject_type": "chase", "action": "send_email",
        "rule": "any_operator", "deal_uuid": dealUuid, "deal_name": "7 Mill Lane", "task_uuid": chaseTaskUuid,
        "created_at": iso(minutes: -20), "requested_by_agent": "legal_chaser", "agent_key": "legal_chaser",
        "provider": "local", "model": "llama3.1:8b", "cost_usd": 0, "from_jobshout": false, "approvals_so_far": 0,
        ]
    }

    static var defaultPreferences: [String: Any] {
        Dictionary(uniqueKeysWithValues: ["sla_warning", "overdue", "escalated", "approval_requested", "digest",
                                          "compliance_expiring", "agent_update", "hot_lead"].map { ($0, ["push": true, "email": $0 == "digest"]) })
    }

    static let emailBody = """
        Dear Harrow & Co,

        We're still waiting on replies to two enquiries for 7 Mill Lane: the missing FENSA certificate for \
        the rear windows, and boundary responsibility on the east side. Our last email was two days ago.

        Exchange is planned in 9 working days. Could you reply by 3pm tomorrow?

        Kind regards,
        Sam Okafor
        """

    static func emailPayload(body: String) -> [String: Any] {
        ["to": "conveyancing@harrow-co.example", "subject": "7 Mill Lane: 2 enquiries still open",
         "body": body]
    }

    static var seededApproval: [String: Any] {
        var full = approvalCard
        full.removeValue(forKey: "approvals_so_far")
        full["status"] = "pending"
        full["task_title"] = "Chase seller's solicitor on 2 open enquiries"
        full["payload"] = emailPayload(body: emailBody)
        full["payload_version"] = 1
        full["payload_sha256"] = "9b2f0c1d7c1e4b8a"
        full["agent_run_uuid"] = "r0000000-0000-4000-8000-000000000001"
        full["tokens_in"] = 1840
        full["tokens_out"] = 212
        full["can_decide"] = true
        full["decisions"] = []
        full["run_sources"] = [
            ["kind": "chase", "title": "Last chase: email to Harrow & Co, 50 hours ago"],
            ["kind": "enquiry", "title": "Open enquiry: missing FENSA certificate"],
            ["kind": "enquiry", "title": "Open enquiry: boundary responsibility (east side)"],
            ["kind": "template", "title": "Chase template: seller's solicitor, 2nd reminder"],
        ]
        return full
    }

    private var dealsList: [[String: Any]] {
        [Self.deal, [
            "uuid": Self.amberDealUuid, "crm_deal_uuid": "crm-2", "name": "22 Station Road", "deal_type": "buy",
            "status": "active", "stage_key": "survey", "health": "amber", "currency": "GBP", "money_at_risk": 0,
            "target_completion_date": Self.isoDay(days: 30), "postcode": "YO24 1AB", "owner_user_uuid": UITestStubServer.userUuid,
            "health_reasons": ["Valuer hasn't confirmed a date"],
        ]]
    }

    static var deal: [String: Any] {
        [
        "uuid": dealUuid, "crm_deal_uuid": "crm-1", "name": "7 Mill Lane", "deal_type": "buy", "status": "active",
        "stage_key": "searches", "template_key": "uk_guaranteed_sale", "health": "red",
        "health_reasons": ["1 blocking task(s) overdue", "£7000.00 at risk: 14 day(s) late × £500/day (cap 20 days)"],
        "money_at_risk": 7000, "currency": "GBP", "agreed_price": 182_500, "offer_amount": 182_500,
        "target_exchange_date": isoDay(days: 6), "target_completion_date": isoDay(days: 13),
        "predicted_completion_date": isoDay(days: 27), "late_penalty_per_day": 500, "late_penalty_cap_days": 20,
        "owner_user_uuid": UITestStubServer.userUuid, "address_line1": "7 Mill Lane", "postcode": "YO1 7AA", "town": "York",
        ]
    }

    private var overview: [String: Any] {
        let open = openTasks.map(summary)
        return [
            "deal": Self.deal,
            "property": ["uuid": "p1", "address_line1": "7 Mill Lane", "postcode": "YO1 7AA", "tenure": "freehold"],
            "stage": [
                "current": "searches", "next": "enquiries",
                "next_gate": ["stage": "exchange", "ok": false,
                              "missing": [["type": "compliance", "key": "aml_cdd_buyer",
                                           "message": "Buyer AML customer due diligence isn't passed"]]],
                "stages": [["key": "new_lead", "name": "New lead", "state": "done"],
                           ["key": "offer_sent", "name": "Offer", "state": "done"],
                           ["key": "accepted", "name": "Accepted", "state": "done"],
                           ["key": "searches", "name": "Searches", "state": "current"],
                           ["key": "lease_pack", "name": "Lease pack", "state": "skipped"],
                           ["key": "enquiries", "name": "Enquiries", "state": "upcoming"],
                           ["key": "exchange", "name": "Exchange", "state": "upcoming", "has_gate": true],
                           ["key": "completion", "name": "Completion", "state": "upcoming", "has_gate": true]],
            ],
            "health": ["health": "red", "reasons": Self.deal["health_reasons"]!, "money_at_risk": 7000,
                       "working_days_left": 9, "target_completion_date": Self.isoDay(days: 13),
                       "predicted_completion_date": Self.isoDay(days: 27), "late_penalty_per_day": 500,
                       "late_penalty_cap_days": 20],
            "parties": [["uuid": "pa1", "role": "seller", "is_primary": true, "name": "Pat Probate",
                         "phone": "07700 900123", "email": "pat.probate@example.com"],
                        ["uuid": "pa2", "role": "seller_solicitor", "name": "Harrow & Co Solicitors",
                         "phone": "01904 000111", "email": "conveyancing@harrow-co.example"]],
            "tasks": ["counts": ["total": 9, "done": 9 - open.count, "overdue": open.filter { $0["overdue"] as? Bool == true }.count],
                      "open": open],
            "enquiries": [["uuid": "e1", "title": "Missing FENSA certificate for rear windows", "owner_party": "seller_solicitor",
                           "status": "open", "blocking": true, "raised_at": Self.iso(minutes: -50 * 60)],
                          ["uuid": "e2", "title": "Boundary responsibility on the east side", "owner_party": "seller_solicitor",
                           "status": "open", "blocking": false, "raised_at": Self.iso(minutes: -50 * 60)]],
            "recent_chases": chases.reversed().map { ["uuid": $0["uuid"] ?? "", "channel": $0["channel"] ?? "",
                                                      "to_name": $0["to_name"] ?? "", "subject": $0["subject"] ?? "",
                                                      "sent_at": Self.iso(minutes: 0)] }
                + [["uuid": "ch0", "to_party": "seller_solicitor", "to_name": "Harrow & Co Solicitors", "channel": "email",
                    "subject": "Enquiries", "status": "sent", "sent_at": Self.iso(minutes: -50 * 60)]],
            "compliance": [["key": "aml_cdd_seller", "name": "AML customer due diligence — seller", "applies": true, "status": "passed"],
                           ["key": "aml_cdd_buyer", "name": "AML customer due diligence — buyer", "applies": true, "status": "in_progress"],
                           ["key": "sanctions_pep", "name": "Sanctions and PEP screening", "applies": true, "status": "passed"]],
            "documents": [["category": "title", "count": 1], ["category": "searches", "count": 0]],
            "approvals_waiting": [Self.approvalCard],
            "top_matches": [],
        ]
    }

    private var amberOverview: [String: Any] {
        ["deal": dealsList[1],
         "stage": ["current": "survey", "next": "enquiries", "stages": []],
         "health": ["health": "amber", "reasons": ["Valuer hasn't confirmed a date"], "money_at_risk": 0, "working_days_left": 22],
         "tasks": ["counts": ["total": 6, "done": 3, "overdue": 0], "open": []]]
    }

    // MARK: Seed

    static let taskUuids = [epcTaskUuid, chaseTaskUuid, searchesTaskUuid, fundsTaskUuid]

    static func seededTasks() -> [String: [String: Any]] {
        func task(_ uuid: String, _ title: String, status: String, stage: String, dueMinutes: Int, sla: Int, score: Double,
                  why: [(String, Double, String)], extra: [String: Any] = [:]) -> [String: Any] {
            var row: [String: Any] = [
                "uuid": "det-\(uuid.suffix(4))", "task_uuid": uuid, "title": title, "pd_status": status,
                "deal_uuid": dealUuid, "deal_name": "7 Mill Lane", "stage_key": stage, "template_key": stage + "_task",
                "owner_user_uuid": UITestStubServer.userUuid, "due_at": iso(minutes: dueMinutes), "sla_minutes": sla,
                "urgency_score": score, "escalation_level": 0, "blocking": false, "compliance": false,
                "agent_eligible": false, "approval_rule": "none", "comment_count": 0, "attachment_count": 0,
                "urgency_why": why.map { ["factor": $0.0, "value": $0.1 / 35, "points": $0.1, "why": $0.2] },
            ]
            for (key, value) in extra { row[key] = value }
            return row
        }
        // "Due today" has to stay today in the workspace's zone whatever time the tests run:
        // three hours ahead, but never past 23:50 London time.
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let endOfDay = london.date(bySettingHour: 23, minute: 50, second: 0, of: Date()) ?? Date()
        let laterToday = max(1, min(180, Int(endOfDay.timeIntervalSinceNow / 60)))
        return [
            epcTaskUuid: task(epcTaskUuid, "Book an EPC assessor", status: "todo", stage: "epc", dueMinutes: -20, sla: 60, score: 81.4,
                              why: [("time", 35, "Overdue (133% of its time used)"), ("completion", 11, "9 working day(s) to target completion"),
                                    ("money", 10, "£7000 at risk on the deal"), ("blocking", 15, "On the path to completion")],
                              extra: ["blocking": true, "escalation_level": 2, "agent_eligible": true, "agent_key": "booking_agent",
                                      "sla_breached_at": iso(minutes: -20),
                                      "description": "No valid EPC on the public register. Book an accredited assessor within the hour; the buyer's lender needs it before exchange."]),
            chaseTaskUuid: task(chaseTaskUuid, "Chase seller's solicitor on 2 open enquiries", status: "todo", stage: "enquiries",
                                dueMinutes: laterToday, sla: 1440, score: 55.2,
                                why: [("silence", 20, "No reply from the seller's solicitor for 50 hours"),
                                      ("blockers", 10, "2 open enquiries"), ("money", 10, "£7000 at risk on the deal")],
                                extra: ["agent_eligible": true, "agent_key": "legal_chaser", "blocking": true]),
            searchesTaskUuid: task(searchesTaskUuid, "Local authority searches back from the council", status: "waiting_third_party",
                                   stage: "searches", dueMinutes: 3 * 1440, sla: 10 * 1440, score: 32,
                                   why: [("completion", 11, "9 working day(s) to target completion"), ("blocking", 15, "On the path to completion")],
                                   extra: ["blocking": true]),
            fundsTaskUuid: task(fundsTaskUuid, "Buyer AML: verify source of funds", status: "todo", stage: "funds",
                                dueMinutes: 2 * 1440, sla: 2 * 1440, score: 41,
                                why: [("blocking", 15, "Exchange can't happen until it's done"), ("completion", 11, "9 working day(s) to target completion")],
                                extra: ["compliance": true, "blocking": true]),
        ]
    }

    static func iso(minutes: Int) -> String {
        APIDate.string(from: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    static func isoDay(days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return date.formatted(.iso8601.year().month().day())
    }

    static func taskUuid(in path: String) -> String {
        taskUuids.first { path.contains($0) } ?? ""
    }
}
#endif
