import SwiftUI

/// Hiring (applicant tracking) — jobs, candidates, interviews and kits.
///
/// The hub and the pipeline, interview review, kit editor, fairness report and settings are hand-built
/// (`Features/Engage/ATS`); job and candidate forms are described here and drawn by the module kit.
extension ModuleGroup {
    static let engageATS = ModuleGroup(
        id: "engage.ats",
        descriptors: [ModuleCatalog.atsJobs, ModuleCatalog.atsCandidates],
        screens: ["ats": ATSScreen.home],
        screen: { id in ATSScreen.view(for: id) })
}

extension ModuleCatalog {
    static let atsBase = "/api/v2/ats"

    static let atsEmploymentTypes = [
        Choice("Full time"), Choice("Part time"), Choice("Contract"), Choice("Temporary"),
    ]

    static let atsJobStatus = StatusStyle(tones: ["open": .success, "paused": .warning, "draft": .neutral,
                                                  "closed": .neutral])

    /// Jobs (`/api/v2/ats/jobs`, RBAC `ats_jobs`). Listed and opened by the hand-built pipeline screens;
    /// this description draws the new-job and edit-job forms.
    static let atsJobs = ResourceDescriptor(
        id: "ats.jobs", title: "Jobs", noun: "job", systemImage: "briefcase",
        api: ResourceAPISpec(list: "\(atsBase)/jobs", item: "\(atsBase)/jobs/{uuid}", create: "\(atsBase)/jobs",
                             update: "\(atsBase)/jobs/{uuid}", delete: "\(atsBase)/jobs/{uuid}", searchParam: "q",
                             idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: ATSModule.jobs),
        list: ListSpec(title: ["title"],
                       subtitle: [FieldSpec("department", "Department"), FieldSpec("location", "Location"),
                                  FieldSpec("employment_type", "Type")],
                       badge: FieldSpec("status", "Status", .status(atsJobStatus)),
                       trailing: FieldSpec("candidates", "Candidates", .integer),
                       filters: [FilterSpec("status", "Status", ATSJobStatus.allCases.map { Choice($0.rawValue, $0.label) })],
                       emptyTitle: "No jobs yet", emptyDescription: "Create one to start hiring.",
                       searchPrompt: "Search jobs"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("department", "Department"), FieldSpec("location", "Location"),
                FieldSpec("employment_type", "Type"), FieldSpec("status", "Status", .status(atsJobStatus)),
                FieldSpec("candidates", "Candidates", .integer), FieldSpec("to_review", "Interviews to review", .integer),
            ]),
            SectionSpec("Description", [FieldSpec("description", "Job description", .multiline)]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("title", "Job title", required: true, placeholder: "e.g. Customer adviser"),
                FieldSpec("department", "Department"),
                FieldSpec("location", "Location"),
                FieldSpec("employment_type", "Type", .choice(atsEmploymentTypes)),
                FieldSpec("status", "Status", .choice(ATSJobStatus.allCases.map { Choice($0.rawValue, $0.label) }),
                          required: true, help: "Open: taking candidates. Paused or closed: kept, but not hiring now.",
                          defaultValue: .string("open")),
            ]),
            SectionSpec("Description", [
                FieldSpec("description", "Job description", .multiline,
                          help: "Used to draft the interview kit. Paste the full advert."),
            ]),
        ], sendOnlyChanges: true),
        summary: "Open roles and their hiring pipelines.")

    /// Candidates (`/api/v2/ats/candidates`, RBAC `ats_candidates`): the add and edit forms.
    static let atsCandidates = ResourceDescriptor(
        id: "ats.candidates", title: "Candidates", noun: "candidate", systemImage: "person.2",
        api: ResourceAPISpec(list: "\(atsBase)/candidates", item: "\(atsBase)/candidates/{uuid}",
                             create: "\(atsBase)/candidates", update: "\(atsBase)/candidates/{uuid}",
                             delete: "\(atsBase)/candidates/{uuid}", searchParam: "q", idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: ATSModule.candidates),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("email", "Email", .email), FieldSpec("source", "Source")],
                       trailing: FieldSpec("applications", "Applications", .integer),
                       emptyTitle: "No candidates found", searchPrompt: "Name, email or reference"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("email", "Email", .email), FieldSpec("phone", "Phone", .phone),
                FieldSpec("reference", "Your reference"), FieldSpec("source", "Source"), FieldSpec("tags", "Tags", .tags),
                FieldSpec("created_at", "Added", .dateTime),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true),
                FieldSpec("email", "Email", .email),
                FieldSpec("phone", "Phone", .phone),
                FieldSpec("reference", "Your reference", help: "For example an ID from another system."),
            ]),
            SectionSpec("Organise", [
                FieldSpec("tags", "Tags", .tags, help: "Separate tags with commas."),
            ]),
        ], sendOnlyChanges: true),
        summary: "Everyone who has applied, across all jobs.")

    /// "Add a candidate": the candidate form, with the job they applied for when added from a pipeline.
    static func atsAddCandidate(jobUUID: String?) -> ResourceDescriptor {
        var descriptor = atsCandidates
        let job = FieldSpec("job_uuid", "Applying for",
                            .reference(ReferenceSpec(list: "\(atsBase)/jobs", titleKeys: ["title"],
                                                     subtitleKeys: ["department", "location"], searchParam: "q",
                                                     paging: .pageAndPerPage)),
                            help: "Optional: the job they go into the pipeline for.")
        var sections = [SectionSpec(nil, [
            FieldSpec("name", "Name", required: true),
            FieldSpec("email", "Email", .email),
            FieldSpec("phone", "Phone", .phone),
            FieldSpec("reference", "Your reference", help: "For example an ID from another system."),
        ])]
        var constants: [String: JSONValue] = [:]
        if let jobUUID { constants["job_uuid"] = .string(jobUUID) } else { sections.append(SectionSpec(nil, [job])) }
        descriptor.form = FormSpec(sections, constants: constants)
        return descriptor
    }
}
