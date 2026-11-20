import Foundation

/// The hiring API (`lapis/routes/ats.lua`), on the engage area's JSON client.
struct ATSAPI: Sendable {
    static let base = "/api/v2/ats"
    let client: EngageClient

    init(_ services: Services) { client = services.engage }

    init(client: EngageClient) { self.client = client }

    private func path(_ tail: String) -> String { Self.base + tail }

    // MARK: Overview

    func overview() async throws -> ATSOverview {
        ATSOverview(try await client.get(path("/overview")).engageRecord ?? Record([:]))
    }

    // MARK: Jobs

    func jobs(search: String = "", status: String? = nil, page: Int = 1,
              perPage: Int = Paging.pageSize) async throws -> Page<ATSJob> {
        let json = try await client.get(path("/jobs"), query: ["q": search, "status": status, "page": String(page),
                                                                "per_page": String(perPage)])
        return ResourceService.parsePage(json, listKey: nil, idKeys: ["uuid"], requestedPage: page, perPage: perPage)
            .atsMap(ATSJob.init)
    }

    func job(_ uuid: String) async throws -> ATSJob {
        try ATSJob(Self.record(await client.get(path("/jobs/\(uuid)")), "job"))
    }

    @discardableResult
    func updateJob(_ uuid: String, _ body: JSONValue) async throws -> ATSJob {
        try ATSJob(Self.record(await client.put(path("/jobs/\(uuid)"), body), "job"))
    }

    func deleteJob(_ uuid: String) async throws { try await client.delete(path("/jobs/\(uuid)")) }

    func pipeline(_ uuid: String) async throws -> [ATSPipelineColumn] {
        ATSPipelineColumn.parse(try await client.get(path("/jobs/\(uuid)/pipeline")))
    }

    // MARK: Candidates

    func candidates(search: String = "", page: Int = 1) async throws -> Page<ATSCandidate> {
        let json = try await client.get(path("/candidates"), query: ["q": search, "page": String(page),
                                                                      "per_page": String(Paging.pageSize)])
        return Self.page(json, page: page).atsMap(ATSCandidate.init)
    }

    func candidate(_ uuid: String) async throws -> ATSCandidate {
        try ATSCandidate(Self.record(await client.get(path("/candidates/\(uuid)")), "candidate"))
    }

    @discardableResult
    func createCandidate(name: String, email: String, phone: String, reference: String,
                         jobUUID: String?) async throws -> ATSCandidate {
        try ATSCandidate(Self.record(await client.post(path("/candidates"),
                                                       Self.newCandidateBody(name: name, email: email, phone: phone,
                                                                             reference: reference, jobUUID: jobUUID)),
                                     "candidate"))
    }

    func deleteCandidate(_ uuid: String) async throws { try await client.delete(path("/candidates/\(uuid)")) }

    /// Everything held about the candidate (a subject access request), as the server sends it.
    func exportCandidate(_ uuid: String) async throws -> JSONValue {
        try await client.get(path("/candidates/\(uuid)/export")).payload
    }

    func addNote(candidate uuid: String, body: String, applicationUUID: String? = nil) async throws {
        var payload: [String: JSONValue] = ["body": .string(body)]
        if let applicationUUID { payload["application_uuid"] = .string(applicationUUID) }
        try await client.post(path("/candidates/\(uuid)/notes"), .object(payload))
    }

    // MARK: Applications

    func addApplication(job: String, candidate: String) async throws {
        try await client.post(path("/applications"), .object(["job_uuid": .string(job), "candidate_uuid": .string(candidate)]))
    }

    func move(_ application: String, to stage: ATSStage) async throws {
        try await client.post(path("/applications/\(application)/stage"), .object(["stage": .string(stage.rawValue)]))
    }

    func reject(_ application: String, reason: String) async throws {
        try await client.post(path("/applications/\(application)/reject"), .object(["reason": .string(reason)]))
    }

    // MARK: Kits

    func kits(approvedOnly: Bool = false) async throws -> [ATSKitSummary] {
        try await client.get(path("/kits"), query: ["approved": approvedOnly ? "true" : nil]).engageRecords
            .map(ATSKitSummary.init)
    }

    func kit(_ uuid: String) async throws -> ATSKitSummary {
        try ATSKitSummary(Self.record(await client.get(path("/kits/\(uuid)")), "kit"))
    }

    func createKit(title: String, jobUUID: String?) async throws -> ATSKitSummary {
        var body: [String: JSONValue] = ["title": .string(title)]
        if let jobUUID { body["job_uuid"] = .string(jobUUID) }
        return try ATSKitSummary(Self.record(await client.post(path("/kits"), .object(body)), "kit"))
    }

    /// The AI drafts a kit from a job description (can take a minute; saved unapproved).
    func generateKit(jobDescription: String, jobUUID: String?) async throws -> ATSKitSummary {
        var body: [String: JSONValue] = ["job_description": .string(jobDescription)]
        if let jobUUID { body["job_uuid"] = .string(jobUUID) }
        return try ATSKitSummary(Self.record(await client.post(path("/kits/generate"), .object(body), timeout: 180), "kit"))
    }

    func saveKit(_ uuid: String, _ kit: ATSKit) async throws -> ATSKitSummary {
        try ATSKitSummary(Self.record(await client.put(path("/kits/\(uuid)"), .object(["kit": kit.json])), "kit"))
    }

    func validate(_ kit: ATSKit) async throws -> [ATSKitIssue] {
        ATSKitIssue.parse(try await client.post(path("/kits/validate"), .object(["kit": kit.json])))
    }

    func approveKit(_ uuid: String) async throws -> ATSKitSummary {
        try ATSKitSummary(Self.record(await client.post(path("/kits/\(uuid)/approve")), "kit"))
    }

    func deleteKit(_ uuid: String) async throws { try await client.delete(path("/kits/\(uuid)")) }

    // MARK: Interviews

    func interviews(state: String?, toReview: Bool, jobUUID: String?, delivery: String?,
                    page: Int) async throws -> Page<ATSInterviewSummary> {
        let json = try await client.get(path("/interviews"), query: [
            "state": state, "to_review": toReview ? "true" : nil, "job_uuid": jobUUID, "delivery": delivery,
            "page": String(page), "per_page": String(Paging.pageSize),
        ])
        return Self.page(json, page: page).atsMap(ATSInterviewSummary.init)
    }

    func interview(_ uuid: String) async throws -> ATSInterviewDetail {
        try ATSInterviewDetail(Self.record(await client.get(path("/interviews/\(uuid)")), "interview"))
    }

    func invite(application: String, kit: String, days: Int, delivery: String) async throws -> ATSInvitation {
        let json = try await client.post(path("/interviews"), Self.inviteBody(application: application, kit: kit,
                                                                              days: days, delivery: delivery))
        guard let invitation = ATSInvitation(json) else {
            throw ResourceService.problem(422, "The invitation was made but no link came back. Try again.")
        }
        return invitation
    }

    /// A `.snazzy_interview` file saved by the Snazzy Pro app: added, or updated if it was imported before.
    func importInterview(content: String) async throws -> (created: Bool, interviewUUID: String?) {
        let r = try await client.post(path("/interviews/import"), .object(["content": .string(content)])).engageRecord
        return (r?.bool("created") ?? true, r?.string("interview_uuid"))
    }

    func evaluate(_ uuid: String) async throws { try await client.post(path("/interviews/\(uuid)/evaluate")) }

    func review(_ uuid: String, _ draft: ATSReviewDraft) async throws -> ATSInterviewDetail {
        try ATSInterviewDetail(Self.record(await client.post(path("/interviews/\(uuid)/review"), draft.body), "interview"))
    }

    func revoke(_ uuid: String) async throws { try await client.post(path("/interviews/\(uuid)/revoke")) }

    func releaseDevice(_ uuid: String) async throws { try await client.post(path("/interviews/\(uuid)/release-device")) }

    // MARK: Reports

    func fairness(question: String, jobUUID: String?) async throws -> ATSFairnessReport {
        ATSFairnessReport(try await client.get(path("/reports/fairness"), query: ["question": question,
                                                                                  "job_uuid": jobUUID]).engageRecord
                          ?? Record([:]))
    }

    func audit(page: Int) async throws -> Page<ATSAuditEntry> {
        let json = try await client.get(path("/audit"), query: ["page": String(page), "per_page": String(Paging.pageSize)])
        return Self.page(json, page: page).atsMap(ATSAuditEntry.init)
    }

    // MARK: Settings

    func settings() async throws -> ATSSettings {
        ATSSettings(try await client.get(path("/settings")).engageRecord ?? Record([:]))
    }

    func saveSettings(_ body: JSONValue) async throws -> ATSSettings {
        ATSSettings(try await client.put(path("/settings"), body).engageRecord ?? Record([:]))
    }

    func tokens() async throws -> [ATSToken] {
        try await client.get(path("/settings/tokens")).engageRecords.map(ATSToken.init)
    }

    func createToken(name: String) async throws -> ATSToken {
        try ATSToken(Self.record(await client.post(path("/settings/tokens"), .object(["name": .string(name)])), "token"))
    }

    func revokeToken(_ uuid: String) async throws { try await client.delete(path("/settings/tokens/\(uuid)")) }

    // MARK: Shapes (static, tested without a server)

    static func record(_ json: JSONValue, _ noun: String) throws -> Record {
        guard let record = json.engageRecord else {
            throw ResourceService.problem(404, "This \(noun) wasn’t found. It may have been deleted.")
        }
        return record
    }

    /// A list with `meta {total, page, per_page, total_pages}`.
    static func page(_ json: JSONValue, page: Int) -> Page<Record> {
        ResourceService.parsePage(json, listKey: nil, idKeys: ["uuid"], requestedPage: page, perPage: Paging.pageSize)
    }

    static func newCandidateBody(name: String, email: String, phone: String, reference: String,
                                 jobUUID: String?) -> JSONValue {
        var body: [String: JSONValue] = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        for (key, value) in [("email", email), ("phone", phone), ("reference", reference)] {
            if let text = value.trimmedOrNil { body[key] = .string(text) }
        }
        if let jobUUID { body["job_uuid"] = .string(jobUUID) }
        return .object(body)
    }

    static func inviteBody(application: String, kit: String, days: Int, delivery: String) -> JSONValue {
        .object(["application_uuid": .string(application), "kit_uuid": .string(kit),
                 "expires_in_days": .number(Double(days)), "delivery": .string(delivery)])
    }
}

extension Page where Item == Record {
    func atsMap<T: Sendable>(_ transform: (Record) -> T) -> Page<T> {
        Page<T>(items: items.map(transform), page: page, perPage: perPage, total: total)
    }
}
