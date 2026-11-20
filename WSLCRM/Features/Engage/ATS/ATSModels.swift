import Foundation

// Hiring (applicant tracking + AI first-round interviews): the shapes `lapis/routes/ats.lua` sends,
// read from the raw JSON (`Record`) so a missing or extra field never fails a whole screen.
// Field names are the server's (`queries/AtsQueries.lua`, `queries/AtsInterviewQueries.lua`).

/// The server's RBAC modules for hiring (`routes/ats.lua` header).
enum ATSModule {
    static let jobs = "ats_jobs"
    static let candidates = "ats_candidates"
    static let interviews = "ats_interviews"
    static let kits = "ats_kits"
    static let reports = "ats_reports"
    static let settings = "ats_settings"
}

/// Where a candidate is for one job. Only a person's "Decline" (with a reason) moves anyone to rejected.
enum ATSStage: String, CaseIterable, Identifiable, Sendable {
    case applied, screening, interview, review, offer, hired, rejected, withdrawn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .applied: "Applied"
        case .screening: "Screening"
        case .interview: "AI interview"
        case .review: "Review"
        case .offer: "Offer"
        case .hired: "Hired"
        case .rejected: "Rejected"
        case .withdrawn: "Withdrawn"
        }
    }

    var tone: Tone {
        switch self {
        case .applied, .withdrawn: .neutral
        case .screening: .info
        case .interview: .progress
        case .review: .warning
        case .offer, .hired: .success
        case .rejected: .danger
        }
    }

    var symbol: String {
        switch self {
        case .applied: "tray.and.arrow.down"
        case .screening: "magnifyingglass"
        case .interview: "bubble.left.and.bubble.right"
        case .review: "eye"
        case .offer: "envelope.open"
        case .hired: "checkmark.seal"
        case .rejected: "xmark.octagon"
        case .withdrawn: "arrow.uturn.backward"
        }
    }

    static func of(_ raw: String?) -> ATSStage { ATSStage(rawValue: raw ?? "") ?? .applied }
}

enum ATSJobStatus: String, CaseIterable, Identifiable, Sendable {
    case open, paused, draft, closed
    var id: String { rawValue }
    var label: String { rawValue.capitalizedFirst }
    var tone: Tone {
        switch self {
        case .open: .success
        case .paused: .warning
        case .draft, .closed: .neutral
        }
    }
}

/// A job (`job_out`).
struct ATSJob: Identifiable, Hashable, Sendable {
    let uuid: String
    var title: String
    var department: String?
    var location: String?
    var employmentType: String?
    var description: String?
    var status: ATSJobStatus
    var kitUUID: String?
    var candidates: Int
    var toReview: Int
    var createdAt: String?
    /// The row as sent (for the module kit's edit form).
    let record: Record

    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        title = r.string("title") ?? "Untitled job"
        department = r.string("department")
        location = r.string("location")
        employmentType = r.string("employment_type")
        description = r.string("description")
        status = ATSJobStatus(rawValue: r.string("status") ?? "") ?? .open
        kitUUID = r.string("kit_uuid")
        candidates = r.int("candidates") ?? 0
        toReview = r.int("to_review") ?? 0
        createdAt = r.string("created_at")
        record = r
    }

    /// "Sales · Leeds · Full time".
    var summary: String? {
        let parts = [department, location, employmentType].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One candidate's application to one job (`application_out`).
struct ATSApplication: Identifiable, Hashable, Sendable {
    let uuid: String
    var stage: ATSStage
    var decisionReason: String?
    var decidedBy: String?
    var decidedAt: String?
    var jobUUID: String?
    var jobTitle: String?
    var candidateUUID: String?
    var candidateName: String?
    var candidateEmail: String?
    var interviewUUID: String?
    var interviewState: String?
    var interviewEvaluation: String?
    var interviewReviewed: Bool

    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        stage = ATSStage.of(r.string("stage"))
        decisionReason = r.string("decision_reason")
        decidedBy = r.string("decided_by")
        decidedAt = r.string("decided_at")
        jobUUID = r.string("job.uuid")
        jobTitle = r.string("job.title")
        candidateUUID = r.string("candidate.uuid")
        candidateName = r.string("candidate.name")
        candidateEmail = r.string("candidate.email")
        interviewUUID = r.string("latest_interview.uuid")
        interviewState = r.string("latest_interview.state")
        interviewEvaluation = r.string("latest_interview.evaluation_status")
        interviewReviewed = r.bool("latest_interview.reviewed") ?? false
    }

    /// Invitations make sense until someone is hired or declined.
    var canInvite: Bool { stage != .rejected && stage != .hired }
}

/// One column of a job's pipeline.
struct ATSPipelineColumn: Identifiable, Hashable, Sendable {
    let stage: ATSStage
    var applications: [ATSApplication]
    var id: String { stage.rawValue }

    /// `GET /jobs/:uuid/pipeline` → every stage in order, empty ones included.
    static func parse(_ json: JSONValue) -> [ATSPipelineColumn] {
        let rows = json.payload.listValue
        var byStage: [ATSStage: [ATSApplication]] = [:]
        for row in rows {
            guard case .object(let o) = row else { continue }
            let column = Record(o)
            guard let stage = ATSStage(rawValue: column.string("stage") ?? "") else { continue }
            byStage[stage] = column.records("applications").map(ATSApplication.init)
        }
        return ATSStage.allCases.map { ATSPipelineColumn(stage: $0, applications: byStage[$0] ?? []) }
    }
}

/// An interview as it appears on a candidate (`Q.candidate` interviews).
struct ATSCandidateInterview: Identifiable, Hashable, Sendable {
    let uuid: String
    var state: String
    var source: String?
    var evaluationStatus: String?
    var reviewed: Bool
    var decision: String?
    var jobTitle: String?
    var endedAt: String?
    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        state = r.string("state") ?? "invited"
        source = r.string("source")
        evaluationStatus = r.string("evaluation_status")
        reviewed = r.bool("reviewed") ?? false
        decision = r.string("decision")
        jobTitle = r.string("job_title")
        endedAt = r.string("ended_at")
    }
}

struct ATSNote: Identifiable, Hashable, Sendable {
    let uuid: String
    var body: String
    var author: String?
    var createdAt: String?
    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        body = r.string("body") ?? ""
        author = r.string("author_name")
        createdAt = r.string("created_at")
    }
}

struct ATSAttachment: Identifiable, Hashable, Sendable {
    let uuid: String
    var name: String
    var contentType: String?
    var size: Int?
    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        name = r.string("name") ?? "File"
        contentType = r.string("content_type")
        size = r.int("size")
    }
}

/// A candidate (`candidate_out`); the detail adds applications, interviews, notes and files.
struct ATSCandidate: Identifiable, Hashable, Sendable {
    let uuid: String
    var name: String
    var email: String?
    var phone: String?
    var reference: String?
    var source: String?
    var tags: [String]
    var createdAt: String?
    /// In the list: how many applications.
    var applicationCount: Int?
    var applications: [ATSApplication]
    var interviews: [ATSCandidateInterview]
    var notes: [ATSNote]
    var attachments: [ATSAttachment]
    let record: Record

    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        name = r.string("name") ?? "Unnamed candidate"
        email = r.string("email")
        phone = r.string("phone")
        reference = r.string("reference")
        source = r.string("source")
        tags = r.array("tags").compactMap(\.stringValue)
        createdAt = r.string("created_at")
        if case .array? = r["applications"] { applicationCount = r.array("applications").count } else {
            applicationCount = r.int("applications")
        }
        applications = r.records("applications").map(ATSApplication.init)
        interviews = r.records("interviews").map(ATSCandidateInterview.init)
        notes = r.records("notes").map(ATSNote.init)
        attachments = r.records("attachments").map(ATSAttachment.init)
        record = r
    }

    var contactLine: String? {
        let parts = [email, phone, reference].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where the candidate came from, in words.
    static func sourceLabel(_ raw: String?) -> String? {
        switch raw {
        case nil: nil
        case "dashboard": "Added by the team"
        case "bulk_invite": "Invited in a batch"
        case "snazzy_file": "Imported from Snazzy Pro"
        case let other?: other.hasPrefix("token") ? "Sent by Snazzy Pro" : Formatters.humanize(other)
        }
    }
}

// MARK: - Interviews

enum ATSInterviewState {
    static let all = ["invited", "in_progress", "paused", "completed", "human_requested", "abandoned", "expired",
                      "withdrawn"]

    static func label(_ raw: String) -> String {
        switch raw {
        case "invited": "Invited"
        case "in_progress": "In progress"
        case "paused": "Paused"
        case "completed": "Completed"
        case "human_requested": "Asked for a person"
        case "abandoned": "Abandoned"
        case "expired": "Expired"
        case "withdrawn": "Withdrawn"
        default: Formatters.humanize(raw)
        }
    }

    static func tone(_ raw: String) -> Tone {
        switch raw {
        case "completed": .success
        case "human_requested": .warning
        case "in_progress", "paused": .progress
        case "invited": .info
        default: .neutral
        }
    }

    /// The interview has ended: it can be assessed and reviewed.
    static func isFinished(_ raw: String) -> Bool {
        ["completed", "human_requested", "withdrawn", "abandoned", "expired"].contains(raw)
    }

    /// The candidate's link still works.
    static func isLive(_ raw: String) -> Bool { ["invited", "in_progress", "paused"].contains(raw) }
}

enum ATSDecision: String, CaseIterable, Identifiable, Sendable {
    case advance, hold, decline
    var id: String { rawValue }
    var label: String { rawValue.capitalizedFirst }
    var tone: Tone {
        switch self {
        case .advance: .success
        case .hold: .warning
        case .decline: .danger
        }
    }
}

/// How an interview was taken, in words.
enum ATSDelivery {
    static func label(source: String?, delivery: String?) -> String {
        if delivery == "offline" { return "Offline (candidate’s Mac)" }
        return source == "hosted" ? "Online" : "Snazzy Pro"
    }
}

/// An interview row (`LIST_SELECT`).
struct ATSInterviewSummary: Identifiable, Hashable, Sendable {
    let uuid: String
    var state: String
    var source: String?
    var delivery: String?
    var evaluationStatus: String
    var startedAt: String?
    var endedAt: String?
    var resultUploadedAt: String?
    var decision: ATSDecision?
    var reviewed: Bool
    var flagCount: Int
    var candidateUUID: String?
    var candidateName: String
    var jobUUID: String?
    var jobTitle: String
    var applicationUUID: String?

    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        state = r.string("state") ?? "invited"
        source = r.string("source")
        delivery = r.string("delivery")
        evaluationStatus = r.string("evaluation_status") ?? "none"
        startedAt = r.string("started_at")
        endedAt = r.string("ended_at")
        resultUploadedAt = r.string("result_uploaded_at")
        decision = ATSDecision(rawValue: r.string("decision") ?? "")
        reviewed = r.bool("reviewed") ?? false
        flagCount = r.int("flag_count") ?? 0
        candidateUUID = r.string("candidate_uuid")
        candidateName = r.string("candidate_name") ?? "Candidate"
        jobUUID = r.string("job_uuid")
        jobTitle = r.string("job_title") ?? "Job"
        applicationUUID = r.string("application_uuid")
    }

    var waitingForReview: Bool { decision == nil && !reviewed && (state == "completed" || state == "human_requested") }

    var assessmentLabel: String? {
        switch evaluationStatus {
        case "done": "Assessment ready"
        case "running": "Assessment running"
        case "failed": "Assessment failed"
        default: nil
        }
    }
}

struct ATSTurn: Identifiable, Hashable, Sendable {
    let id: String
    var role: String
    var text: String
    var input: String?

    init(_ r: Record) {
        id = r.string("id") ?? r.id
        role = r.string("role") ?? "system"
        text = r.string("text") ?? ""
        input = r.string("input")
    }

    var isCandidate: Bool { role == "candidate" }
}

struct ATSFlag: Hashable, Sendable {
    var kind: String
    var detail: String?
    var turn: String?

    init(_ r: Record) {
        kind = r.string("kind") ?? "other"
        detail = r.string("detail")
        turn = r.string("turn")
    }

    var label: String {
        switch kind {
        case "adjustment": "Adjustment requested"
        case "human_requested": "Asked for a person"
        case "distress": "Seemed distressed"
        case "protected_info_volunteered": "Shared personal information (hidden from the assessment)"
        case "injection_attempt": "Tried to instruct the AI"
        case "technical": "Technical problem"
        case "off_topic": "Off topic"
        case "pasted": "Answer pasted in (information only)"
        case "time_up": "Ran out of time"
        default: "Note"
        }
    }

    /// The words shown: never the detail of personal information the candidate volunteered.
    var text: String {
        if kind != "protected_info_volunteered", let detail { return "\(label): \(detail)" }
        return label
    }
}

struct ATSEligibilityAnswer: Identifiable, Hashable, Sendable {
    let id: String
    var text: String
    var answer: String?
    var meets: Bool?

    init(_ r: Record) {
        id = r.string("id") ?? r.id
        text = r.string("text") ?? ""
        answer = r.string("answer")
        meets = r.bool("meets")
    }
}

struct ATSQuote: Hashable, Sendable {
    var turn: String
    var quote: String
}

/// The AI's evidence for one competency (`evaluation.competencies[]`).
struct ATSCompetencyResult: Hashable, Sendable {
    var id: String
    var evidence: [ATSQuote]
    var level: Int?
    var secondLevel: Int?
    var agreed: Bool
    var reason: String?
    var probeNext: String?

    init(_ r: Record) {
        id = r.string("id") ?? r.id
        evidence = r.records("evidence").map { ATSQuote(turn: $0.string("turn") ?? "", quote: $0.string("quote") ?? "") }
        level = r.int("level")
        secondLevel = r.int("second_level")
        agreed = r.bool("agreed") ?? true
        reason = r.string("reason")
        probeNext = r.string("probe_next")
    }
}

struct ATSEvaluation: Hashable, Sendable {
    var competencies: [ATSCompetencyResult]
    var notesForReviewer: String?
    var model: String?

    init(_ r: Record) {
        competencies = r.records("competencies").map(ATSCompetencyResult.init)
        notesForReviewer = r.string("notes_for_reviewer")
        model = r.string("model")
    }

    func result(for competency: String) -> ATSCompetencyResult? { competencies.first { $0.id == competency } }
}

struct ATSReview: Hashable, Sendable {
    var reviewer: String?
    var decision: ATSDecision?
    var reason: String
    var note: String
    var levels: [String: Int]
    var at: String?
    var via: String?

    init(_ r: Record) {
        reviewer = r.string("reviewer")
        decision = ATSDecision(rawValue: r.string("decision") ?? "")
        reason = r.string("reason") ?? ""
        note = r.string("note") ?? ""
        var levels: [String: Int] = [:]
        if case .object(let o)? = r["levels"] {
            for (key, value) in o { if let n = value.numberValue { levels[key] = Int(n) } }
        }
        self.levels = levels
        at = r.string("at")
        via = r.string("via")
    }
}

/// `GET /interviews/:uuid`: everything a reviewer needs.
struct ATSInterviewDetail: Hashable, Sendable {
    var summary: ATSInterviewSummary
    var kit: ATSKit
    var kitVersion: Int?
    var turns: [ATSTurn]
    var flags: [ATSFlag]
    var eligibility: [ATSEligibilityAnswer]
    var forwardedQuestions: [String]
    var deviceReported: Bool
    var evaluation: ATSEvaluation?
    var review: ATSReview?
    var settings: ATSSettings

    init(_ r: Record) {
        summary = ATSInterviewSummary(r)
        kit = ATSKit(json: r["kit"] ?? .object([:]))
        kitVersion = r.int("kit_version")
        turns = r.records("turns").map(ATSTurn.init)
        flags = r.records("flags").map(ATSFlag.init)
        eligibility = r.records("eligibility").map(ATSEligibilityAnswer.init)
        forwardedQuestions = r.array("forwarded_questions").compactMap(\.stringValue)
        deviceReported = r.bool("device_reported") ?? false
        evaluation = r.object("evaluation").map(ATSEvaluation.init)
        review = r.object("review").map(ATSReview.init)
        settings = ATSSettings(r.object("settings") ?? Record([:]))
    }

    /// Evidence quotes grouped by the turn they came from (to highlight them in the transcript).
    var quotesByTurn: [String: [String]] {
        var out: [String: [String]] = [:]
        for result in evaluation?.competencies ?? [] {
            for quote in result.evidence { out[quote.turn, default: []].append(quote.quote) }
        }
        return out
    }

    var finished: Bool { ATSInterviewState.isFinished(summary.state) }
}

/// The review a person records: their levels, decision and note (`POST /interviews/:uuid/review`).
struct ATSReviewDraft: Hashable, Sendable {
    var levels: [String: Int] = [:]
    var decision: ATSDecision?
    var reason = ""
    var note = ""

    init() {}

    init(_ review: ATSReview?) {
        levels = review?.levels ?? [:]
        decision = review?.decision
        reason = review?.reason ?? ""
        note = review?.note ?? ""
    }

    /// Declining needs a reason (the server refuses otherwise).
    var problem: String? {
        decision == .decline && reason.trimmingCharacters(in: .whitespaces).isEmpty ? "Choose a reason for declining." : nil
    }

    var body: JSONValue {
        var out: [String: JSONValue] = [
            "levels": .object(levels.mapValues { .number(Double($0)) }),
            "reason": .string(reason),
            "note": .string(note),
        ]
        if let decision { out["decision"] = .string(decision.rawValue) }
        return .object(out)
    }
}

// MARK: - Kits

/// A kit in a list (`kit_out`), with the full kit and its checks when opened.
struct ATSKitSummary: Identifiable, Hashable, Sendable {
    let uuid: String
    var title: String
    var version: Int
    var approvedAt: String?
    var approvedBy: String?
    var source: String?
    var jobUUID: String?
    var competencies: Int
    var questions: Int
    var updatedAt: String?
    var kit: ATSKit?
    var issues: [ATSKitIssue]

    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        title = r.string("title") ?? "Untitled role"
        version = r.int("version") ?? 0
        approvedAt = r.string("approved_at")
        approvedBy = r.string("approved_by")
        source = r.string("source")
        jobUUID = r.string("job_uuid")
        competencies = r.int("competencies") ?? 0
        questions = r.int("questions") ?? 0
        updatedAt = r.string("updated_at")
        kit = r["kit"].map { ATSKit(json: $0) }
        issues = r.records("issues").map(ATSKitIssue.init)
    }

    var isApproved: Bool { approvedAt != nil }

    var sourceLabel: String {
        switch source {
        case "snazzy_desktop": "from Snazzy Pro"
        case "generated": "drafted by AI"
        case "dashboard", nil: "made by the team"
        case let other?: Formatters.humanize(other).lowercased()
        }
    }
}

struct ATSKitIssue: Hashable, Sendable, Identifiable {
    var severity: String
    var message: String
    var subject: String?
    var id: String { "\(severity)|\(subject ?? "")|\(message)" }

    init(severity: String, message: String, subject: String? = nil) {
        self.severity = severity
        self.message = message
        self.subject = subject
    }

    init(_ r: Record) {
        severity = r.string("severity") ?? "warning"
        message = r.string("message") ?? ""
        subject = r.string("subject")
    }

    var isError: Bool { severity == "error" }

    static func parse(_ json: JSONValue) -> [ATSKitIssue] {
        json.payload.listValue.compactMap { value in
            if case .object(let o) = value { return ATSKitIssue(Record(o)) }
            return nil
        }
    }
}

struct ATSCompetency: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String
    var weight: Int
    var source: String
    var anchor1: String
    var anchor3: String
    var anchor5: String
}

struct ATSEligibilityQuestion: Hashable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case yesNo = "yes_no", choice, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .yesNo: "Yes / No"
            case .choice: "Choice"
            case .text: "Free text"
            }
        }
    }

    var id: String
    var text: String
    var kind: Kind
    var options: [String]
    var accepted: [String]
}

struct ATSCoreQuestion: Hashable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case behavioural, situational
        var id: String { rawValue }
        var label: String {
            switch self {
            case .behavioural: "Behavioural (a time when…)"
            case .situational: "Situational (what would you do…)"
            }
        }
    }

    var id: String
    var text: String
    var competency: String
    var kind: Kind
}

struct ATSKitSettings: Hashable, Sendable {
    var interviewerName = "Snazzy Interviewer"
    var minutes = 25
    var maxFollowUps = 2
    var secondsPerAnswer = 0
    var allowVoice = true
    var allowPause = true
    var allowedAdjustments: [String] = ATSKit.defaultAdjustments
    var nextSteps = "The hiring team reviews every interview and will contact you within 5 working days."
    var ratingsEnabled = true
    var writtenCommunication = false
    var retentionDays = 180
}

/// The interview kit itself (the "RoleKit" JSON, `lib/ats/kit.lua` `normalise`). Edited here and sent
/// back whole as `{kit: …}`; keys this build doesn't know are kept as they came.
struct ATSKit: Hashable, Sendable {
    static let defaultAdjustments = ["extra time", "a pause", "questions repeated or rephrased", "text instead of voice",
                                     "voice instead of text", "large text or high contrast"]

    var title: String
    var organisation: String
    var summary: String
    var language: String
    var jobDescription: String
    var companyFacts: String
    var warnings: [String]
    var competencies: [ATSCompetency]
    var eligibility: [ATSEligibilityQuestion]
    var questions: [ATSCoreQuestion]
    var settings: ATSKitSettings
    /// The JSON as it came (id, format, version, approval and anything newer).
    private var original: [String: JSONValue]

    init(json: JSONValue) {
        let r = Record(json.objectValue ?? [:])
        original = json.objectValue ?? [:]
        title = r.string("title") ?? "Untitled role"
        organisation = r.string("organisation") ?? ""
        summary = r.string("summary") ?? ""
        language = r.string("language") ?? "en-GB"
        jobDescription = r.string("job_description") ?? ""
        if case .array(let lines)? = r["company_facts"] {
            companyFacts = lines.compactMap(\.stringValue).joined(separator: "\n")
        } else {
            companyFacts = r.string("company_facts") ?? ""
        }
        warnings = r.array("warnings").compactMap(\.stringValue)
        competencies = r.records("competencies").map { c in
            ATSCompetency(id: c.string("id") ?? "", name: c.string("name") ?? "", description: c.string("description") ?? "",
                          weight: c.int("weight") ?? 0, source: c.string("source") ?? "",
                          anchor1: c.string("anchors.1") ?? "", anchor3: c.string("anchors.3") ?? "",
                          anchor5: c.string("anchors.5") ?? "")
        }
        eligibility = r.records("eligibility").map { e in
            ATSEligibilityQuestion(id: e.string("id") ?? "", text: e.string("text") ?? "",
                                   kind: ATSEligibilityQuestion.Kind(rawValue: e.string("kind") ?? "") ?? .text,
                                   options: e.array("options").compactMap(\.stringValue),
                                   accepted: e.array("accepted").compactMap(\.stringValue))
        }
        questions = r.records("questions").map { q in
            ATSCoreQuestion(id: q.string("id") ?? "", text: q.string("text") ?? "", competency: q.string("competency") ?? "",
                            kind: ATSCoreQuestion.Kind(rawValue: q.string("kind") ?? "") ?? .behavioural)
        }
        var s = ATSKitSettings()
        if let settings = r.object("settings") {
            s.interviewerName = settings.string("interviewer_name") ?? s.interviewerName
            s.minutes = settings.int("minutes") ?? s.minutes
            s.maxFollowUps = settings.int("max_follow_ups") ?? s.maxFollowUps
            s.secondsPerAnswer = settings.int("seconds_per_answer") ?? s.secondsPerAnswer
            s.allowVoice = settings.bool("allow_voice") ?? s.allowVoice
            s.allowPause = settings.bool("allow_pause") ?? s.allowPause
            if settings["allowed_adjustments"] != nil {
                s.allowedAdjustments = settings.array("allowed_adjustments").compactMap(\.stringValue)
            }
            s.nextSteps = settings.string("next_steps") ?? s.nextSteps
            s.ratingsEnabled = settings.bool("ratings_enabled") ?? s.ratingsEnabled
            s.writtenCommunication = settings.bool("written_communication") ?? s.writtenCommunication
            s.retentionDays = settings.int("retention_days") ?? s.retentionDays
        }
        settings = s
    }

    /// The kit as the server reads it (`Kit.normalise`).
    var json: JSONValue {
        var out = original
        out["title"] = .string(title)
        out["organisation"] = .string(organisation)
        out["summary"] = .string(summary)
        out["language"] = .string(language)
        out["job_description"] = .string(jobDescription)
        out["company_facts"] = .string(companyFacts)
        out["warnings"] = .array(warnings.map { JSONValue.string($0) })
        out["competencies"] = .array(competencies.map { c in
            .object(["id": .string(c.id), "name": .string(c.name), "description": .string(c.description),
                     "weight": .number(Double(c.weight)), "source": .string(c.source),
                     "anchors": .object(["1": .string(c.anchor1), "3": .string(c.anchor3), "5": .string(c.anchor5)])])
        })
        out["eligibility"] = .array(eligibility.map { e in
            .object(["id": .string(e.id), "text": .string(e.text), "kind": .string(e.kind.rawValue),
                     "options": .array(e.options.map { JSONValue.string($0) }),
                     "accepted": .array(e.accepted.map { JSONValue.string($0) })])
        })
        out["questions"] = .array(questions.map { q in
            .object(["id": .string(q.id), "text": .string(q.text), "competency": .string(q.competency),
                     "kind": .string(q.kind.rawValue)])
        })
        var settingsObject = original["settings"]?.objectValue ?? [:]
        settingsObject["interviewer_name"] = .string(settings.interviewerName)
        settingsObject["minutes"] = .number(Double(settings.minutes))
        settingsObject["max_follow_ups"] = .number(Double(settings.maxFollowUps))
        settingsObject["seconds_per_answer"] = .number(Double(settings.secondsPerAnswer))
        settingsObject["allow_voice"] = .bool(settings.allowVoice)
        settingsObject["allow_pause"] = .bool(settings.allowPause)
        settingsObject["allowed_adjustments"] = .array(settings.allowedAdjustments.map { JSONValue.string($0) })
        settingsObject["next_steps"] = .string(settings.nextSteps)
        settingsObject["ratings_enabled"] = .bool(settings.ratingsEnabled)
        settingsObject["written_communication"] = .bool(settings.writtenCommunication)
        settingsObject["retention_days"] = .number(Double(settings.retentionDays))
        out["settings"] = .object(settingsObject)
        return .object(out)
    }

    /// Every id in use (competencies, questions, eligibility), so a new one never repeats.
    var usedIDs: [String] { competencies.map(\.id) + questions.map(\.id) + eligibility.map(\.id) }

    /// `c1`, `c2`… the first free id with this prefix (as the web editor does).
    static func nextID(_ prefix: String, used: [String]) -> String {
        var index = 1
        while used.contains("\(prefix)\(index)") { index += 1 }
        return "\(prefix)\(index)"
    }

    var totalWeight: Int { competencies.reduce(0) { $0 + $1.weight } }

    func competencyName(_ id: String) -> String {
        let name = competencies.first { $0.id == id }?.name ?? ""
        return name.isEmpty ? id : name
    }

    mutating func addCompetency() {
        competencies.append(ATSCompetency(id: Self.nextID("c", used: usedIDs), name: "", description: "", weight: 0,
                                          source: "", anchor1: "", anchor3: "", anchor5: ""))
    }

    mutating func addQuestion() {
        questions.append(ATSCoreQuestion(id: Self.nextID("q", used: usedIDs), text: "",
                                         competency: competencies.first?.id ?? "", kind: .behavioural))
    }

    mutating func addEligibility() {
        eligibility.append(ATSEligibilityQuestion(id: Self.nextID("e", used: usedIDs), text: "", kind: .yesNo,
                                                  options: [], accepted: ["Yes"]))
    }

    /// "a, b ,, c" → ["a", "b", "c"] (the web's comma-separated lists).
    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Settings, activation, tokens

struct ATSActivation: Hashable, Sendable {
    var active: Bool
    var status: String
    var source: String?
    var activatedAt: String?
    var expiresAt: String?
    var paymentFailedAt: String?
    var checkoutAvailable: Bool

    init(_ r: Record) {
        active = r.bool("active") ?? false
        status = r.string("status") ?? "inactive"
        source = r.string("source")
        activatedAt = r.string("activated_at")
        expiresAt = r.string("expires_at")
        paymentFailedAt = r.string("payment_failed_at")
        checkoutAvailable = r.bool("checkout_available") ?? false
    }
}

struct ATSSettings: Hashable, Sendable {
    var retentionDays: Int
    var ratingsEnabled: Bool
    var declineReasons: [String]
    var legalNotice: String
    var activation: ATSActivation?

    init(_ r: Record) {
        retentionDays = r.int("retention_days") ?? 180
        ratingsEnabled = r.bool("ratings_enabled") ?? true
        declineReasons = r.array("decline_reasons").compactMap(\.stringValue)
        legalNotice = r.string("legal_notice") ?? ""
        activation = r.object("activation").map(ATSActivation.init)
    }

    /// `PUT /settings` body; decline reasons typed one per line.
    static func body(retentionDays: Int, ratingsEnabled: Bool, reasonsText: String, legalNotice: String) -> JSONValue {
        let reasons = reasonsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return .object([
            "retention_days": .number(Double(retentionDays)), "ratings_enabled": .bool(ratingsEnabled),
            "decline_reasons": .array(reasons.map { JSONValue.string($0) }), "legal_notice": .string(legalNotice),
        ])
    }

    /// The server's own checks, said before saving.
    static func problem(retentionDays: Int?, reasonsText: String) -> String? {
        guard let days = retentionDays, (1...3650).contains(days) else {
            return "Keep interviews for between 1 and 3,650 days."
        }
        let reasons = reasonsText.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return reasons.isEmpty ? "Keep at least one decline reason." : nil
    }
}

struct ATSToken: Identifiable, Hashable, Sendable {
    let uuid: String
    var name: String
    var prefix: String?
    var createdAt: String?
    var lastUsedAt: String?
    var revokedAt: String?
    /// Only in the answer to "Create token": shown once.
    var token: String?
    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        name = r.string("name") ?? "Token"
        prefix = r.string("token_prefix")
        createdAt = r.string("created_at")
        lastUsedAt = r.string("last_used_at")
        revokedAt = r.string("revoked_at")
        token = r.string("token")
    }
}

// MARK: - Overview, fairness, audit

struct ATSOverview: Hashable, Sendable {
    var openJobs: Int
    var candidates: Int
    var toReview: Int
    var inProgress: Int
    var stages: [ATSStage: Int]
    var activation: ATSActivation?

    init(_ r: Record) {
        openJobs = r.int("open_jobs") ?? 0
        candidates = r.int("candidates") ?? 0
        toReview = r.int("to_review") ?? 0
        inProgress = r.int("in_progress") ?? 0
        var stages: [ATSStage: Int] = [:]
        for stage in ATSStage.allCases { stages[stage] = r.int("stages.\(stage.rawValue)") ?? 0 }
        self.stages = stages
        activation = r.object("activation").map(ATSActivation.init)
    }
}

struct ATSFairnessRow: Identifiable, Hashable, Sendable {
    var group: String
    var total: Int
    var selected: Int
    var rate: Double
    var impactRatio: Double
    var warning: Bool
    var id: String { group }

    init(_ r: Record) {
        group = r.string("group") ?? "—"
        total = r.int("total") ?? 0
        selected = r.int("selected") ?? 0
        rate = r.double("rate") ?? 0
        impactRatio = r.double("impact_ratio") ?? 1
        warning = r.bool("warning") ?? false
    }
}

struct ATSFairnessQuestion: Identifiable, Hashable, Sendable {
    let id: String
    var label: String
}

struct ATSFairnessReport: Hashable, Sendable {
    var question: String
    var rows: [ATSFairnessRow]
    var suppressed: Int
    var minGroup: Int
    var questions: [ATSFairnessQuestion]

    init(_ r: Record) {
        question = r.string("question") ?? "gender"
        rows = r.records("rows").map(ATSFairnessRow.init)
        suppressed = r.int("suppressed") ?? 0
        minGroup = r.int("min_group") ?? 10
        questions = r.records("questions").map { ATSFairnessQuestion(id: $0.string("id") ?? $0.id, label: $0.string("label") ?? "") }
    }

    /// The same columns as the web's "Export CSV".
    var csv: Data {
        EngageExport.csv([["group", "decided", "advanced", "rate", "impact_ratio"]] + rows.map { row in
            [row.group, String(row.total), String(row.selected), String(format: "%.4f", row.rate),
             String(format: "%.4f", row.impactRatio)]
        })
    }
}

struct ATSAuditEntry: Identifiable, Hashable, Sendable {
    let uuid: String
    var actor: String
    var action: String
    var entity: String?
    var createdAt: String?
    var id: String { uuid }

    init(_ r: Record) {
        uuid = r.string("uuid") ?? r.id
        actor = r.string("actor") ?? "system"
        action = r.string("action") ?? "changed"
        entity = r.string("entity")
        createdAt = r.string("created_at")
    }

    var actionLabel: String { Formatters.humanize(action) }

    /// Who did it, in words: the system, Snazzy Pro, or a person on the team.
    var actorLabel: String {
        if actor == "system" || actor == "engine" { return "Done automatically" }
        if actor.hasPrefix("token:") { return "Snazzy Pro app" }
        return "Someone on the team"
    }
}

/// The answer to "Create link": the private link is shown once.
struct ATSInvitation: Hashable, Sendable {
    var uuid: String
    var url: String
    var appURL: String?
    var expiresAt: String?
    var delivery: String

    init?(_ json: JSONValue) {
        guard let r = json.engageRecord, let url = r.string("url") else { return nil }
        uuid = r.string("uuid") ?? ""
        self.url = url
        appURL = r.string("app_url")
        expiresAt = r.string("expires_at")
        delivery = r.string("delivery") ?? "online"
    }

    /// The email the web drafts for the candidate (opened in Mail; nothing is sent by the app).
    static func emailBody(candidate: String, job: String, link: String, offline: Bool) -> String {
        """
        Hello \(candidate),

        Thank you for applying for \(job). The first step is a short interview you can do \
        \(offline ? "in the Snazzy Pro app on your Mac (it runs on your own computer)" : "online"), at a time that suits you:

        \(link)

        The interviewer is an AI; a person on our team reviews your answers and makes the decision. You can ask for \
        adjustments, or to speak to a person instead, on the first page.

        Kind regards
        """
    }

    static func mailto(email: String, candidate: String, job: String, link: String, offline: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Your interview for \(job)"),
            URLQueryItem(name: "body", value: emailBody(candidate: candidate, job: job, link: link, offline: offline)),
        ]
        return components.url
    }
}

/// The decline reason sent with a note, as the web writes it (`reason: note`).
enum ATSDeclineReason {
    static func text(reason: String, note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? reason : "\(reason): \(trimmed)"
    }
}
