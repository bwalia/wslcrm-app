import Foundation

/// Opens the records kept under one patient or hospital with the module kit's own screens.
///
/// Their server paths carry the parent's uuid, so each parent gets its own descriptor
/// (`health.care_plans@<patient uuid>`), registered at run time (`RuntimeDescriptors`) the moment a
/// link to it is drawn; the kit's list and record screens then find it by id like any other.
enum HealthScope {
    /// Everything kept under a patient, in the order the patient screen lists it.
    static func patientRecords(_ patient: String) -> [ResourceDescriptor] {
        [
            HealthCatalog.alerts(patient: patient), HealthCatalog.carePlans(patient: patient),
            HealthCatalog.medications(patient: patient), HealthCatalog.dailyLogs(patient: patient),
            HealthCatalog.careLogs(patient: patient), HealthCatalog.dementiaAssessments(patient: patient),
            HealthCatalog.familyMembers(patient: patient), HealthCatalog.accessControls(patient: patient),
            HealthCatalog.auditLogs(patient: patient),
        ]
    }

    /// Registers the descriptor (idempotent) and returns it.
    @discardableResult
    static func register(_ descriptor: ResourceDescriptor) -> ResourceDescriptor {
        RuntimeDescriptors.register(descriptor)
        return descriptor
    }

    /// A link value for the kit's list of these records (`query` narrows it: `status=active`).
    static func list(_ descriptor: ResourceDescriptor, query: [String: String] = [:], title: String? = nil) -> ResourceListRoute {
        register(descriptor)
        return ResourceListRoute(descriptor.id, query: query, title: title)
    }

    /// A link value for one of these records.
    static func record(_ descriptor: ResourceDescriptor, _ record: Record) -> ResourceRoute {
        register(descriptor)
        return ResourceRoute(descriptorID: descriptor.id, recordID: record.id, seed: record)
    }
}

/// The few reads the hand-built health screens need beyond a descriptor's list and record.
struct HealthAPI: Sendable {
    let client: APIClient

    /// One object (`{data: {...}}`), e.g. a hospital's figures.
    func object(_ path: String) async throws -> Record? {
        let (data, _) = try await client.sendRaw(.get(path))
        return ResourceService.parseRecord(try ResourceService.decode(data), itemKey: nil, idKeys: ["uuid", "id"])
    }

    /// Every row of a list that isn't paged (`{data: [...]}`; lua-cjson's `{}` is an empty list).
    func rows(_ path: String, query: [String: String] = [:]) async throws -> [Record] {
        var items = QueryBuilder()
        for (key, value) in query.sorted(by: { $0.key < $1.key }) { items.add(key, value) }
        let (data, _) = try await client.sendRaw(.get(path, query: items.items))
        return ResourceService.parsePage(try ResourceService.decode(data), listKey: nil, idKeys: ["uuid", "id"],
                                         requestedPage: 1, perPage: 0).items
    }

    /// Patients by their number in the database (`patient_id` on care records is that number, not the
    /// uuid the patient screen needs). Reads up to 1,000 patients, optionally of one hospital.
    func patientsByNumber(hospital: String? = nil) async throws -> [String: Record] {
        var table: [String: Record] = [:]
        for page in 1...10 {
            var query = ["page": String(page), "perPage": "100"]
            if let hospital { query["hospital_id"] = hospital }
            let batch = try await rows("/api/v2/patients", query: query)
            for row in batch { if let number = row.string("id") { table[number] = row } }
            if batch.count < 100 { break }
        }
        return table
    }
}

/// How a patient is named and described across the health screens.
enum PatientText {
    static func name(_ record: Record) -> String {
        let name = [record.string("first_name"), record.string("last_name")].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (record.string("patient_id").map { "Patient \($0)" } ?? "Patient") : name
    }

    static func initials(_ record: Record) -> String {
        let letters = [record.string("first_name"), record.string("last_name")].compactMap { $0?.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Whole years since `date_of_birth`, on `today`.
    static func age(_ record: Record, today: Date = Date()) -> Int? {
        guard let raw = record.string("date_of_birth"), let day = CalendarDay(string: raw) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = now.year, let month = now.month, let dayOfMonth = now.day else { return nil }
        var age = year - day.year
        if month < day.month || (month == day.month && dayOfMonth < day.day) { age -= 1 }
        return age >= 0 ? age : nil
    }

    /// "ID 1042 · 82 · Female · Room 12 / B".
    static func summary(_ record: Record) -> String {
        var parts: [String] = []
        if let number = record.string("patient_id") { parts.append("ID \(number)") }
        if let age = age(record) { parts.append("\(age) years old") }
        if let gender = record.string("gender") { parts.append(Formatters.humanize(gender)) }
        if let room = record.string("room_number") {
            parts.append("Room \(room)" + (record.string("bed_number").map { " / \($0)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}
