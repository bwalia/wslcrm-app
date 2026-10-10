import Foundation

/// What someone captured on the doorstep: a seller lead, a property, or both, with photos and a
/// note (typed or dictated). Saved as one queued chain so it survives no signal.
struct PDCaptureDraft: Equatable, Sendable {
    // Seller
    var includeLead = true
    var firstName = ""
    var lastName = ""
    var phone = ""
    var email = ""
    var situation: PDSituation?
    var deadline: Date?
    var vulnerable = false
    var vulnerabilityNote = ""
    /// The note: typed, or the on-device transcript of a voice note (the audio never leaves the phone).
    var notes = ""

    // Property
    var includeProperty = true
    var addressLine1 = ""
    var town = ""
    var postcode = ""
    var latitude: Double?
    var longitude: Double?
    /// Photos, already saved to `PendingUploads` (file names).
    var photoFiles: [String] = []

    var hasLead: Bool { includeLead && !firstName.trimmed.isEmpty }
    var hasProperty: Bool { includeProperty && (!addressLine1.trimmed.isEmpty || latitude != nil) }

    /// Why Save is disabled, in words; nil when it can be saved.
    var problem: String? {
        if !includeLead && !includeProperty { return "Choose a seller, a property or both." }
        if includeLead && firstName.trimmed.isEmpty { return "Add the seller's first name." }
        if includeProperty && addressLine1.trimmed.isEmpty && latitude == nil {
            return "Add the address, or use your location."
        }
        if vulnerable && vulnerabilityNote.trimmed.isEmpty { return "Say briefly why they may be vulnerable." }
        return nil
    }

    /// "Pat Probate · 7 Mill Lane"
    var summary: String {
        [hasLead ? "\(firstName.trimmed) \(lastName.trimmed)".trimmed : nil,
         hasProperty ? (addressLine1.trimmed.isEmpty ? "Property at your location" : addressLine1.trimmed) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// `situation` on a seller lead (`PUT /leads/{uuid}/details`).
enum PDSituation: String, CaseIterable, Identifiable, Sendable {
    case probate, brokenChain = "broken_chain", divorce, relocation, careFees = "care_fees"
    case repossessionRisk = "repossession_risk", tenanted, unmortgageable, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .probate: "Probate"
        case .brokenChain: "Broken chain"
        case .divorce: "Divorce or separation"
        case .relocation: "Relocation"
        case .careFees: "Care fees"
        case .repossessionRisk: "Risk of repossession"
        case .tenanted: "Tenanted"
        case .unmortgageable: "Unmortgageable"
        case .other: "Something else"
        }
    }
}

extension PropertyDealsAPI.Mutations {
    /// Quick capture as one chained write:
    /// 1. `POST /api/v2/crm/leads` (captures `lead`)
    /// 2. `PUT /property-deals/leads/{{lead}}/details` (kind, situation, deadline, vulnerability)
    /// 3. `POST /property-deals/properties` (captures `property`)
    /// 4. `PUT …/leads/{{lead}}/details { property_uuid }` when both were captured
    /// 5. `POST /property-deals/documents` per photo (multipart, `category: photo`)
    /// Every create carries its own `Idempotency-Key`, kept across retries.
    static func capture(_ draft: PDCaptureDraft, context: MutationContext, today: Date = Date(),
                        calendar: Calendar = .current) -> PendingMutation {
        let base = PropertyDealsAPI.base
        var steps: [PendingMutation.Step] = []

        if draft.hasLead {
            var lead: [String: String] = ["first_name": draft.firstName.trimmed, "source": "phone_capture"]
            if !draft.lastName.trimmed.isEmpty { lead["last_name"] = draft.lastName.trimmed }
            if !draft.phone.trimmed.isEmpty { lead["phone"] = draft.phone.trimmed }
            if !draft.email.trimmed.isEmpty { lead["email"] = draft.email.trimmed }
            if !draft.notes.trimmed.isEmpty { lead["notes"] = draft.notes.trimmed }
            steps.append(.init(label: "Seller lead", method: .post, path: "/api/v2/crm/leads", body: json(lead), captures: "lead"))

            var details: [String: Any] = ["lead_kind": "seller"]
            if let situation = draft.situation { details["situation"] = situation.rawValue }
            if let deadline = draft.deadline { details["deadline_date"] = day(deadline, calendar: calendar) }
            if draft.vulnerable {
                details["vulnerability_flag"] = true
                details["vulnerability_note"] = draft.vulnerabilityNote.trimmed
            }
            steps.append(.init(label: "Seller details", method: .put, path: "\(base)/leads/{{lead}}/details", body: json(details)))
        }

        if draft.hasProperty {
            var property: [String: Any] = [:]
            if !draft.addressLine1.trimmed.isEmpty { property["address_line1"] = draft.addressLine1.trimmed }
            if !draft.town.trimmed.isEmpty { property["town"] = draft.town.trimmed }
            if !draft.postcode.trimmed.isEmpty { property["postcode"] = draft.postcode.trimmed.uppercased() }
            if let latitude = draft.latitude, let longitude = draft.longitude {
                property["lat"] = latitude
                property["lng"] = longitude
                if property["address_line1"] == nil { property["address_line1"] = "Captured at \(String(format: "%.5f, %.5f", latitude, longitude))" }
            }
            steps.append(.init(label: "Property", method: .post, path: "\(base)/properties", body: json(property), captures: "property"))
            if draft.hasLead {
                steps.append(.init(label: "Link seller to property", method: .put, path: "\(base)/leads/{{lead}}/details",
                                   body: json(["property_uuid": "{{property}}"])))
            }
            for (index, file) in draft.photoFiles.enumerated() {
                steps.append(.init(label: "Photo \(index + 1) of \(draft.photoFiles.count)", method: .post, path: "\(base)/documents",
                                   upload: .init(fileName: file, fieldName: "file", mimeType: "image/jpeg",
                                                 fields: [["property_uuid", "{{property}}"], ["category", "photo"]])))
            }
        }

        var mutation = PendingMutation(kind: .pdCapture, method: .post, path: "\(base)/capture", body: nil,
                                       namespaceId: context.namespaceId, userId: context.userId,
                                       entityId: "capture-\(UUID().uuidString)", jobId: nil,
                                       summary: "Capture · \(draft.summary)",
                                       hints: ["photos": String(draft.photoFiles.count)])
        mutation.steps = steps
        mutation.results = [:]
        return mutation
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
