#if DEBUG
import Foundation

/// Purchase-order routes for the UI-test stub server (opsapi #710 shapes): one PO sent to a
/// kitchen supplier for the 22 Station Road renovation, and one draft. The status rules match the
/// server's (`PurchaseOrderQueries` TRANSITIONS), including 409 for a wrong move.
struct UITestPurchaseOrdersStub {
    static let sentUuid = "po000000-0000-4000-8000-000000000001"
    static let draftUuid = "po000000-0000-4000-8000-000000000002"

    var orders: [String: [String: Any]] = [:]
    var writes: [String] = []
    /// The request's query string (the router only sees the path).
    var query = ""
    private var created = 0

    mutating func reset() {
        orders = [Self.sentUuid: Self.seededSent, Self.draftUuid: Self.seededDraft]
        writes = []
        created = 0
    }

    private static let transitions: [String: Set<String>] = [
        "draft": ["sent", "cancelled"],
        "sent": ["acknowledged", "partially_received", "received", "cancelled"],
        "acknowledged": ["partially_received", "received", "cancelled"],
        "partially_received": ["partially_received", "received", "billed"],
        "received": ["billed"],
    ]

    mutating func route(method: String, path: String, json: [String: Any]) -> (Int, Any)? {
        let base = "/api/v2/purchase-orders"
        guard path.hasPrefix(base) else { return nil }
        let sub = String(path.dropFirst(base.count))
        switch (method, sub) {
        case ("GET", ""):
            let status = param("status")
            let project = param("project_uuid")
            let list = orders.values
                .filter { status == nil || $0["status"] as? String == status }
                .filter { project == nil || $0["project_uuid"] as? String == project }
                .sorted { ($0["po_number"] as? String ?? "") > ($1["po_number"] as? String ?? "") }
                .map { row -> [String: Any] in
                    var row = row
                    row["item_count"] = (row["items"] as? [Any])?.count ?? 0
                    row.removeValue(forKey: "items")
                    return row
                }
            return (200, ["success": true, "data": list, "meta": ["total": list.count, "page": 1, "perPage": 25, "totalPages": 1]])
        case ("GET", "/stats"):
            let open = orders.values.filter { ["sent", "acknowledged", "partially_received"].contains($0["status"] as? String ?? "") }
            let toBill = orders.values.filter { $0["status"] as? String == "received" }
            return ok(["open_count": open.count, "open_value": open.reduce(0) { $0 + total($1) },
                       "overdue_count": 0, "to_bill_count": toBill.count, "to_bill_value": toBill.reduce(0) { $0 + total($1) },
                       "draft_count": orders.values.filter { $0["status"] as? String == "draft" }.count])
        case ("POST", ""):
            created += 1
            let uuid = "po-new-\(created)"
            let number = String(format: "PO-%06d", 2 + created)
            var po: [String: Any] = ["uuid": uuid, "id": uuid, "po_number": number, "status": "draft", "currency": json["currency"] ?? "GBP",
                                     "issue_date": UITestPropertyDealsStub.isoDay(days: 0)]
            for key in ["supplier_name", "supplier_email", "reference", "expected_date", "delivery_address", "project_uuid"] {
                if let value = json[key] { po[key] = value }
            }
            po["items"] = ((json["items"] as? [[String: Any]]) ?? []).enumerated().map { index, line in
                Self.line("\(uuid)-l\(index)", line["description"] as? String ?? "", quantity: Self.number(line["quantity"]),
                          price: Self.number(line["unit_price"]), tax: Self.number(line["tax_rate"]), received: 0, order: index)
            }
            Self.recalc(&po)
            orders[uuid] = po
            writes.append("POST /purchase-orders \(json["supplier_name"] as? String ?? "")")
            return (201, ["success": true, "data": po])
        case ("POST", let p) where p.hasSuffix("/receive"):
            let uuid = Self.uuid(p, "/receive")
            guard var po = orders[uuid] else { return notFound }
            guard ["sent", "acknowledged", "partially_received"].contains(po["status"] as? String ?? "") else {
                return conflict("Cannot receive goods on a \(po["status"] as? String ?? "") purchase order")
            }
            var items = po["items"] as? [[String: Any]] ?? []
            for change in json["items"] as? [[String: Any]] ?? [] {
                guard let index = items.firstIndex(where: { $0["uuid"] as? String == change["item_uuid"] as? String }) else {
                    return (404, ["success": false, "error": "Line is not on this purchase order"])
                }
                let qty = Self.number(change["received_quantity"])
                if qty > Self.number(items[index]["quantity"]) {
                    return (400, ["success": false, "error": "Line \(index + 1): received \(qty) is more than ordered"])
                }
                items[index]["received_quantity"] = qty
            }
            let all = items.allSatisfy { Self.number($0["received_quantity"]) >= Self.number($0["quantity"]) }
            let any = items.contains { Self.number($0["received_quantity"]) > 0 }
            guard any else { return (400, ["success": false, "error": "Nothing has been received - enter at least one quantity"]) }
            po["items"] = items
            po["status"] = all ? "received" : "partially_received"
            orders[uuid] = po
            writes.append("POST receive \(po["status"] as? String ?? "")")
            return ok(po)
        case ("POST", let p) where p.hasSuffix("/email"):
            let uuid = Self.uuid(p, "/email")
            guard var po = orders[uuid] else { return notFound }
            if po["status"] as? String == "draft" { po["status"] = "sent"; orders[uuid] = po }
            let to = (json["to"] as? String) ?? (po["supplier_email"] as? String ?? "")
            writes.append("POST email \(to)")
            return ok(["message": "Purchase order emailed to \(to)", "to": to, "status": po["status"] ?? "sent"])
        case ("POST", let p) where ["/send", "/acknowledge", "/convert-to-bill", "/cancel"].contains(where: p.hasSuffix):
            let action = String(p[p.lastIndex(of: "/")!...])
            let uuid = Self.uuid(p, action)
            guard var po = orders[uuid] else { return notFound }
            let target = ["/send": "sent", "/acknowledge": "acknowledged", "/convert-to-bill": "billed", "/cancel": "cancelled"][action]!
            let from = po["status"] as? String ?? ""
            guard Self.transitions[from]?.contains(target) ?? false else {
                return conflict("Cannot change a \(from) purchase order to \(target)")
            }
            po["status"] = target
            orders[uuid] = po
            writes.append("POST \(action.dropFirst()) \(po["po_number"] as? String ?? "")")
            return ok(po)
        case ("POST", let p) where p.hasSuffix("/items"):
            let uuid = Self.uuid(p, "/items")
            guard var po = orders[uuid] else { return notFound }
            guard po["status"] as? String == "draft" else { return conflict("Lines can only change on a draft") }
            var items = po["items"] as? [[String: Any]] ?? []
            items.append(Self.line("\(uuid)-l\(items.count)", json["description"] as? String ?? "", quantity: Self.number(json["quantity"]),
                                   price: Self.number(json["unit_price"]), tax: Self.number(json["tax_rate"]), received: 0, order: items.count))
            po["items"] = items
            Self.recalc(&po)
            orders[uuid] = po
            writes.append("POST line \(json["description"] as? String ?? "")")
            return (201, ["success": true, "data": items.last ?? [:]])
        case ("GET", let p):
            guard let po = orders[String(p.dropFirst())] else { return notFound }
            return ok(po)
        case ("DELETE", let p):
            let uuid = String(p.dropFirst())
            guard orders[uuid]?["status"] as? String == "draft" else { return conflict("Only drafts can be deleted") }
            orders.removeValue(forKey: uuid)
            writes.append("DELETE \(uuid)")
            return ok(["message": "Purchase order deleted"])
        default:
            return nil
        }
    }

    // MARK: Helpers

    private func ok(_ data: Any) -> (Int, Any) { (200, ["success": true, "data": data]) }
    private var notFound: (Int, Any) { (404, ["success": false, "error": "Purchase order not found"]) }
    private func conflict(_ message: String) -> (Int, Any) { (409, ["success": false, "error": message]) }

    private func param(_ name: String) -> String? {
        query.split(separator: "&").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private func total(_ po: [String: Any]) -> Double { Self.number(po["total"]) }

    private static func uuid(_ path: String, _ suffix: String) -> String {
        String(path.dropFirst().dropLast(suffix.count))
    }

    static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    static func line(_ uuid: String, _ description: String, quantity: Double, price: Double, tax: Double, received: Double,
                     order: Int) -> [String: Any] {
        let net = quantity * price
        let vat = (net * tax / 100 * 100).rounded() / 100
        return ["uuid": uuid, "id": uuid, "description": description, "quantity": quantity, "unit_price": price,
                "tax_rate": tax, "tax_amount": vat, "line_total": net + vat, "received_quantity": received, "sort_order": order]
    }

    static func recalc(_ po: inout [String: Any]) {
        let items = po["items"] as? [[String: Any]] ?? []
        let tax = items.reduce(0) { $0 + number($1["tax_amount"]) }
        let total = items.reduce(0) { $0 + number($1["line_total"]) }
        po["subtotal"] = total - tax
        po["tax_total"] = tax
        po["total"] = total
    }

    static var seededSent: [String: Any] {
        var po: [String: Any] = [
            "uuid": sentUuid, "id": sentUuid, "po_number": "PO-000001", "status": "sent",
            "supplier_name": "York Kitchens Ltd", "supplier_email": "orders@yorkkitchens.example",
            "reference": "22 Station Road kitchen", "issue_date": UITestPropertyDealsStub.isoDay(days: -3),
            "expected_date": UITestPropertyDealsStub.isoDay(days: 4), "delivery_address": "22 Station Road, York",
            "currency": "GBP", "project_uuid": UITestStubServer.projectUuid,
            "project": ["uuid": UITestStubServer.projectUuid, "name": "Renovation — 22 Station Road", "status": "active"],
            "items": [line("pol-1", "Kitchen units (shaker, sage)", quantity: 1, price: 3200, tax: 20, received: 0, order: 0),
                      line("pol-2", "Oak worktop, 3m", quantity: 3, price: 180, tax: 20, received: 0, order: 1)],
        ]
        recalc(&po)
        return po
    }

    static var seededDraft: [String: Any] {
        var po: [String: Any] = [
            "uuid": draftUuid, "id": draftUuid, "po_number": "PO-000002", "status": "draft",
            "supplier_name": "Minster Plumbing Supplies", "currency": "GBP",
            "issue_date": UITestPropertyDealsStub.isoDay(days: 0),
            "items": [line("pol-3", "Combi boiler", quantity: 1, price: 1450, tax: 20, received: 0, order: 0)],
        ]
        recalc(&po)
        return po
    }
}
#endif
