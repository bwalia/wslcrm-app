import SwiftUI

/// Employees (`/dashboard/employees`): the staff profiles behind workspace members — job title, code,
/// skills, hourly cost, engineer flag. `/api/v2/employees*` (RBAC `employees.*`; adding a team member
/// with a new login is `users.create`).
struct EmployeesScreen: View {
    @Environment(\.services) private var services

    var body: some View {
        EmployeesList(api: services.workspace())
    }
}

/// The employee profile fields and the request bodies the server expects (`EmployeeQueries.lua`).
enum EmployeeForm {
    struct Detail: Equatable, Identifiable {
        var id = UUID()
        var label = ""
        var value = ""
    }

    struct Draft: Equatable {
        var memberUUID = ""
        var memberName = ""
        var jobTitle = ""
        var code = ""
        var phone = ""
        var email = ""
        var team = ""
        var hourlyCost = ""
        var skills = ""
        var isActive = true
        var isEngineer = false
        var fgas = ""
        var details: [Detail] = []

        init() {}

        init(_ employee: Record) {
            memberUUID = employee.string("user_uuid") ?? ""
            memberName = employee.string("user_name") ?? employee.string("user_email") ?? ""
            jobTitle = employee.string("job_title") ?? ""
            code = employee.string("employee_code") ?? ""
            phone = employee.string("phone") ?? ""
            email = employee.string("email") ?? ""
            team = employee.string("region") ?? ""
            hourlyCost = employee.decimal("hourly_cost_rate").map {
                $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
            } ?? ""
            skills = employee.array("skills").compactMap(\.stringValue).joined(separator: ", ")
            isActive = employee.bool("is_active") ?? true
            isEngineer = employee.bool("is_engineer") ?? false
            fgas = employee.string("fgas_certificate_no") ?? ""
            details = EmployeeForm.details(employee).map { Detail(label: $0.0, value: $0.1) }
        }

        var skillList: [String] {
            skills.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var hourlyCostValue: Double? {
            Double(hourlyCost.replacingOccurrences(of: "£", with: "").replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces))
        }

        func problem() -> String? {
            if !hourlyCost.trimmingCharacters(in: .whitespaces).isEmpty, hourlyCostValue == nil {
                return "The hourly cost must be a number of pounds, like 25 or 32.50."
            }
            return nil
        }

        /// `metadata` with the "Additional information" lines replaced and anything else kept.
        func metadata(keeping existing: [String: JSONValue]) -> JSONValue {
            var fields = existing
            let lines = details.compactMap { line -> JSONValue? in
                guard let label = line.label.trimmedOrNil else { return nil }
                return .object(["label": .string(label), "value": .string(line.value.trimmingCharacters(in: .whitespaces))])
            }
            fields["details"] = .array(lines)
            return .object(fields)
        }

        /// `POST /api/v2/employees` (new) or `PUT /api/v2/employees/:uuid` (edit; "" clears a text field).
        func body(isNew: Bool, fieldService: Bool, existingMetadata: [String: JSONValue] = [:]) -> JSONValue {
            var body: [String: JSONValue] = [:]
            func text(_ key: String, _ value: String) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if isNew { if !trimmed.isEmpty { body[key] = .string(trimmed) } } else { body[key] = .string(trimmed) }
            }
            if isNew { body["user_uuid"] = .string(memberUUID) }
            text("job_title", jobTitle)
            text("employee_code", code)
            text("phone", phone)
            text("email", email)
            text("region", team)
            if fieldService { text("fgas_certificate_no", fgas) }
            if let cost = hourlyCostValue { body["hourly_cost_rate"] = .number(cost) }
            else if !isNew { body["hourly_cost_rate"] = .string("") }  // "" clears it
            body["skills"] = .array(skillList.map(JSONValue.string))
            body["is_active"] = .bool(isActive)
            body["is_engineer"] = .bool(fieldService ? isEngineer : false)
            if isNew {
                if details.contains(where: { $0.label.trimmedOrNil != nil }) {
                    body["metadata"] = metadata(keeping: [:])
                }
            } else {
                body["metadata"] = metadata(keeping: existingMetadata)
            }
            if !fieldService, !isNew { body.removeValue(forKey: "is_engineer") }
            return .object(body)
        }
    }

    /// The "Additional information" lines (`metadata.details: [{label, value}]`).
    static func details(_ employee: Record) -> [(String, String)] {
        employee.records("metadata.details").compactMap { line in
            guard let label = line.string("label") else { return nil }
            return (label, line.string("value") ?? "")
        }
    }

    /// The one-step "add team member" body (`POST /api/v2/employees/team-members`).
    struct TeamMember: Equatable {
        var firstName = ""
        var lastName = ""
        var email = ""
        var phone = ""
        var jobTitle = ""
        var role = ""
        var isEngineer = false
        var skills = ""
        var fgas = ""
        var hourlyCost = ""

        func problem() -> String? {
            if firstName.trimmedOrNil == nil { return "Add their first name." }
            if AdminUserRules.emailProblem(email) != nil { return "Add the email they’ll sign in with." }
            if role.isEmpty { return "Pick a role." }
            if !hourlyCost.trimmingCharacters(in: .whitespaces).isEmpty, Double(hourlyCost) == nil {
                return "The hourly cost must be a number of pounds."
            }
            return nil
        }

        func body(fieldService: Bool) -> JSONValue {
            var body: [String: JSONValue] = [
                "first_name": .string(firstName.trimmingCharacters(in: .whitespaces)),
                "email": .string(email.trimmingCharacters(in: .whitespaces)),
                "role_name": .string(role),
            ]
            if let last = lastName.trimmedOrNil { body["last_name"] = .string(last) }
            if let phone = phone.trimmedOrNil { body["phone"] = .string(phone) }
            if let title = jobTitle.trimmedOrNil { body["job_title"] = .string(title) }
            if fieldService {
                body["is_engineer"] = .bool(isEngineer)
                if isEngineer {
                    let list = skills.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if !list.isEmpty { body["skills"] = .array(list.map(JSONValue.string)) }
                    if let certificate = fgas.trimmedOrNil { body["fgas_certificate_no"] = .string(certificate) }
                    if let cost = Double(hourlyCost) { body["hourly_cost_rate"] = .number(cost) }
                }
            }
            return .object(body)
        }
    }
}

extension PermissionSet {
    /// Field service is in this person's menu (jobs or visits), which brings engineers and F-Gas.
    var employeeFieldService: Bool {
        !menuKeys.isDisjoint(with: ["field_service_jobs", "field_service_visits"])
    }
}

@MainActor
@Observable
private final class EmployeeFilters {
    var engineers = ""
    var active = ""
}

private struct EmployeesList: View {
    let api: WorkspaceAPI
    @Environment(SessionStore.self) private var session
    @State private var filters: EmployeeFilters
    @State private var model: PagedListModel<Record>
    @State private var adding = false
    @State private var addingTeamMember = false
    @State private var feedback: Feedback = .none

    init(api: WorkspaceAPI) {
        self.api = api
        let filters = EmployeeFilters()
        _filters = State(initialValue: filters)
        _model = State(initialValue: PagedListModel { search, page in
            let json = try await api.get("/api/v2/employees", query: [
                "page": String(page), "per_page": "20", "search": search,
                "is_engineer": filters.engineers, "is_active": filters.active,
            ])
            return WorkspaceAPI.page(json, page: page, perPage: 20)
        })
    }

    var body: some View {
        let permissions = session.permissions
        let canAddProfile = permissions.can(.create, moduleName: "employees")
        let canAddLogin = permissions.can(.create, moduleName: "users")
        PagedList(model: model, searchPrompt: "Search name, email, job title, code…", emptyTitle: "No employees yet",
                  emptySystemImage: "person.text.rectangle",
                  emptyDescription: "An employee profile adds a job title, code, skills and hourly cost to someone "
                      + "who signs in to this workspace.",
                  emptyActionTitle: canAddProfile ? "Add an employee profile" : "Add a team member",
                  emptyAction: canAddProfile ? { adding = true } : canAddLogin ? { addingTeamMember = true } : nil) { employee in
            NavigationLink {
                EmployeeDetail(api: api, employee: employee) { message in
                    feedback = .done(message)
                    Task { await model.load() }
                }
            } label: {
                EmployeeRow(employee: employee)
            }
            .accessibilityIdentifier("employees.row.\(employee.id)")
        }
        .safeAreaInset(edge: .top, spacing: 0) { FeedbackBar(feedback: feedback) }
        .navigationTitle("Employees")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if permissions.employeeFieldService {
                        Picker("Role", selection: Binding(get: { filters.engineers }, set: { filters.engineers = $0; reload() })) {
                            Text("Everyone").tag("")
                            Text("Engineers only").tag("true")
                        }
                    }
                    Picker("Status", selection: Binding(get: { filters.active }, set: { filters.active = $0; reload() })) {
                        Text("Active and inactive").tag("")
                        Text("Active only").tag("true")
                        Text("Inactive only").tag("false")
                    }
                } label: {
                    Label("Filter", systemImage: filters.engineers.isEmpty && filters.active.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("employees.filter")
            }
            let canAddLogin = permissions.can(.create, moduleName: "users")
            let canAddProfile = permissions.can(.create, moduleName: "employees")
            if canAddLogin || canAddProfile {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if canAddLogin {
                            Button { addingTeamMember = true } label: {
                                Label("Add a team member (new sign-in)", systemImage: "person.badge.plus")
                            }
                            .accessibilityIdentifier("employees.addTeamMember")
                        }
                        if canAddProfile {
                            Button { adding = true } label: {
                                Label("Add an employee profile for a member", systemImage: "person.text.rectangle")
                            }
                            .accessibilityIdentifier("employees.add")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("employees.addMenu")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                EmployeeEditForm(api: api, existing: nil) {
                    feedback = .done("Employee profile added.")
                    reload()
                }
            }
        }
        .sheet(isPresented: $addingTeamMember) {
            NavigationStack {
                EmployeeTeamMemberForm(api: api) { result in
                    feedback = .done("\(result.string("name") ?? "They") can now sign in as \(result.string("email") ?? "").")
                    reload()
                }
            }
        }
    }

    private func reload() { Task { await model.load() } }
}

private struct EmployeeRow: View {
    let employee: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(employee.string("user_name") ?? employee.string("user_email") ?? "Employee").font(.wsHeadline)
            Text([employee.string("job_title"), employee.string("employee_code"), employee.string("user_email")]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            HStack(spacing: 6) {
                if employee.bool("is_engineer") == true {
                    StatusBadge(text: "Engineer", systemImage: "wrench.and.screwdriver", tone: .info)
                }
                StatusBadge(text: employee.bool("is_active") == false ? "Inactive" : "Active",
                            systemImage: employee.bool("is_active") == false ? "pause.circle" : "checkmark.circle",
                            tone: employee.bool("is_active") == false ? .neutral : .success)
            }
            let skills = employee.array("skills").compactMap(\.stringValue)
            if !skills.isEmpty {
                Text(skills.prefix(3).joined(separator: ", ") + (skills.count > 3 ? " +\(skills.count - 3)" : ""))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EmployeeDetail: View {
    let api: WorkspaceAPI
    let employee: Record
    let changed: (String) -> Void
    @Environment(SessionStore.self) private var session
    @State private var current: Record?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var editing = false

    private var shown: Record { current ?? employee }

    var body: some View {
        let fieldService = session.permissions.employeeFieldService
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.string("user_name") ?? shown.string("user_email") ?? "Employee").font(.wsTitle3.bold())
                    if let title = shown.string("job_title") { Text(title).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                    HStack(spacing: 6) {
                        if shown.bool("is_engineer") == true {
                            StatusBadge(text: "Field engineer", systemImage: "wrench.and.screwdriver", tone: .info)
                        }
                        StatusBadge(text: shown.bool("is_active") == false ? "Not available for new work" : "Available for new work",
                                    systemImage: shown.bool("is_active") == false ? "pause.circle" : "checkmark.circle",
                                    tone: shown.bool("is_active") == false ? .neutral : .success)
                    }
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            Section("Sign-in") {
                DetailRow(label: "Signs in as", value: shown.string("user_email"))
            }
            Section("Work") {
                DetailRow(label: "Employee code", value: shown.string("employee_code"))
                DetailRow(label: "Team", value: shown.string("region"))
                DetailRow(label: "Hourly cost", value: shown.decimal("hourly_cost_rate").flatMap { Formatters.money($0, currency: "GBP") })
                let skills = shown.array("skills").compactMap(\.stringValue)
                if !skills.isEmpty { DetailRow(label: "Skills", value: skills.joined(separator: ", ")) }
                if fieldService { DetailRow(label: "F-Gas certificate", value: shown.string("fgas_certificate_no")) }
            }
            Section("Contact") {
                if let phone = shown.string("phone") { PhoneLinkRow(name: "Phone", phone: phone) }
                if let email = shown.string("email") { EmailLinkRow(email: email) }
                if shown.string("phone") == nil && shown.string("email") == nil {
                    Text("No work phone or email.").foregroundStyle(.secondaryText)
                }
            }
            let details = EmployeeForm.details(shown)
            if !details.isEmpty {
                Section("Additional information") {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                        DetailRow(label: line.0, value: line.1.isEmpty ? "—" : line.1)
                    }
                }
            }
            Section {
                DetailRow(label: "Added", value: Formatters.dateTime(shown.date("created_at")))
                DetailRow(label: "Last changed", value: Formatters.dateTime(shown.date("updated_at")))
            }
            if session.permissions.can(.delete, moduleName: "employees") {
                Section {
                    DeleteButton(title: "Remove employee profile",
                                 message: "Only the profile goes. Their sign-in and workspace membership stay.") {
                        await perform($feedback, done: "Employee profile removed.") {
                            try await api.send(.delete, "/api/v2/employees/\(employee.id)")
                            changed("Employee profile removed. Their sign-in is unchanged.")
                        }
                    }
                }
            }
        }
        .navigationTitle(shown.string("user_name") ?? "Employee")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .toolbar {
            if session.permissions.can(.update, moduleName: "employees") {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("employees.edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                EmployeeEditForm(api: api, existing: shown) {
                    feedback = .done("Employee saved.")
                    changed("Employee saved.")
                    Task { await load() }
                }
            }
        }
    }

    private func load() async {
        do {
            current = WorkspaceAPI.record(try await api.get("/api/v2/employees/\(employee.id)"))
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }
}

private struct EmployeeEditForm: View {
    let api: WorkspaceAPI
    let existing: Record?
    let saved: () -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EmployeeForm.Draft
    @State private var choosingMember = false
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false

    init(api: WorkspaceAPI, existing: Record?, saved: @escaping () -> Void) {
        self.api = api
        self.existing = existing
        self.saved = saved
        _draft = State(initialValue: existing.map(EmployeeForm.Draft.init) ?? EmployeeForm.Draft())
    }

    var body: some View {
        let fieldService = session.permissions.employeeFieldService
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                if existing == nil {
                    Button { choosingMember = true } label: {
                        LabeledContent("Workspace member (needed)") {
                            Text(draft.memberName.isEmpty ? "Choose" : draft.memberName)
                                .foregroundStyle(draft.memberName.isEmpty ? Color.accentColor : .primary)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("employees.form.member")
                } else {
                    LabeledContent("Workspace member", value: draft.memberName)
                }
            } footer: {
                if existing == nil { Text("Someone who already signs in to this workspace. To add someone new, use Add a team member.") }
            }
            Section("Work") {
                TextField("Job title", text: $draft.jobTitle).accessibilityIdentifier("employees.form.job_title")
                TextField("Employee code", text: $draft.code).accessibilityIdentifier("employees.form.code")
                TextField("Team", text: $draft.team).accessibilityIdentifier("employees.form.team")
                LabeledContent("Hourly cost (£)") {
                    TextField("0.00", text: $draft.hourlyCost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("employees.form.hourly_cost")
                }
                TextField("Skills, separated by commas", text: $draft.skills).accessibilityIdentifier("employees.form.skills")
                Toggle("Available for new work", isOn: $draft.isActive).accessibilityIdentifier("employees.form.active")
                if fieldService {
                    Toggle("Field engineer", isOn: $draft.isEngineer).accessibilityIdentifier("employees.form.engineer")
                    TextField("F-Gas certificate number", text: $draft.fgas).accessibilityIdentifier("employees.form.fgas")
                }
            }
            Section("Work contact") {
                TextField("Phone", text: $draft.phone).keyboardType(.phonePad).accessibilityIdentifier("employees.form.phone")
                TextField("Email", text: $draft.email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("employees.form.email")
            }
            Section {
                ForEach($draft.details) { $line in
                    VStack(spacing: 6) {
                        TextField("Label, e.g. Van registration", text: $line.label)
                        TextField("Value", text: $line.value)
                    }
                }
                .onDelete { draft.details.remove(atOffsets: $0) }
                Button { draft.details.append(EmployeeForm.Detail()) } label: {
                    Label("Add a line", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("employees.form.addDetail")
            } header: {
                Text("Additional information")
            } footer: {
                Text("Anything else worth keeping, as label and value. Swipe a line to remove it.")
            }
        }
        .navigationTitle(existing == nil ? "New employee" : "Edit employee")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save(fieldService: fieldService) } }
                    .disabled(working)
                    .accessibilityIdentifier("employees.form.save")
            }
        }
        .sheet(isPresented: $choosingMember) {
            NavigationStack {
                EmployeeMemberPicker(api: api) { member in
                    draft.memberUUID = member.string("uuid") ?? ""
                    draft.memberName = member.string("name") ?? member.string("email") ?? ""
                }
            }
        }
    }

    private func save(fieldService: Bool) async {
        if existing == nil, draft.memberUUID.isEmpty { problem = "Choose the workspace member this profile is for."; return }
        if let issue = draft.problem() { problem = issue; return }
        problem = nil
        working = true
        defer { working = false }
        do {
            if let existing {
                let body = draft.body(isNew: false, fieldService: fieldService, existingMetadata: existing.objectMap("metadata"))
                try await api.send(.put, "/api/v2/employees/\(existing.id)", body: body)
            } else {
                try await api.send(.post, "/api/v2/employees", body: draft.body(isNew: true, fieldService: fieldService))
            }
            saved()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

/// Active members to give a profile (`GET /api/v2/employees/candidates` → `[{uuid, email, name, role}]`).
private struct EmployeeMemberPicker: View {
    let api: WorkspaceAPI
    let choose: (Record) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var members: [Record] = []
    @State private var error: APIError?
    @State private var loaded = false

    var body: some View {
        List {
            if let error { InlineErrorRow(error: error) }
            if loaded && members.isEmpty {
                Text(query.isEmpty ? "No members to choose from." : "Nobody matches.").foregroundStyle(.secondaryText)
            }
            ForEach(members) { member in
                Button {
                    choose(member)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(member.string("name") ?? member.string("email") ?? "Member").foregroundStyle(.primary)
                        Text([member.string("email"), member.string("role")].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("employees.member.\(member.id)")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or email")
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            do {
                members = WorkspaceAPI.records(try await api.get("/api/v2/employees/candidates", query: ["search": query]))
                error = nil
            } catch {
                self.error = error.asAPIError
            }
            loaded = true
        }
        .navigationTitle("Choose a member")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// One step: a new sign-in, workspace membership with a role, and an employee profile.
private struct EmployeeTeamMemberForm: View {
    let api: WorkspaceAPI
    let added: (Record) -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EmployeeForm.TeamMember()
    @State private var roles: [PeopleRoles.Option] = []
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false
    /// The new account, shown with its temporary password once it's made.
    @State private var result: Record?

    var body: some View {
        if let result {
            RevealOnceView(title: "Temporary password", value: result.string("temp_password") ?? "",
                           message: "Give this password to them yourself: it isn’t emailed and won’t be shown again. "
                               + "They should change it after signing in.",
                           details: [("Name", result.string("name") ?? ""), ("Email", result.string("email") ?? ""),
                                     ("Role", result.string("role") ?? "")]) {
                added(result)
                dismiss()
            }
        } else {
            form
        }
    }

    private var form: some View {
        let fieldService = session.permissions.employeeFieldService
        return Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section("Who") {
                TextField("First name (needed)", text: $draft.firstName).accessibilityIdentifier("team.first_name")
                TextField("Last name", text: $draft.lastName).accessibilityIdentifier("team.last_name")
                TextField("Email they’ll sign in with (needed)", text: $draft.email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("team.email")
                TextField("Phone", text: $draft.phone).keyboardType(.phonePad)
                TextField("Job title", text: $draft.jobTitle)
            }
            Section {
                Picker("Role (needed)", selection: $draft.role) {
                    Text("Choose").tag("")
                    ForEach(roles) { Text($0.label).tag($0.name) }
                }
                .accessibilityIdentifier("team.role")
            } footer: {
                Text("What they can do in this workspace. You can only give a role whose permissions you have yourself.")
            }
            if fieldService {
                Section("Field service") {
                    Toggle("Field engineer", isOn: $draft.isEngineer)
                    if draft.isEngineer {
                        TextField("Skills, separated by commas", text: $draft.skills)
                        TextField("F-Gas certificate number", text: $draft.fgas)
                        LabeledContent("Hourly cost (£)") {
                            TextField("0.00", text: $draft.hourlyCost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            Section {
                Text("They get a welcome email with their sign-in email. Their temporary password is shown to you once, here, for you to pass on.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .navigationTitle("Add team member")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .task { roles = (try? await PeopleRoles.load(api)) ?? [] }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save(fieldService: fieldService) } }
                    .disabled(working)
                    .accessibilityIdentifier("team.save")
            }
        }
    }

    private func save(fieldService: Bool) async {
        if let issue = draft.problem() { problem = issue; return }
        problem = nil
        working = true
        defer { working = false }
        do {
            let json = try await api.send(.post, "/api/v2/employees/team-members", body: draft.body(fieldService: fieldService))
            let created = WorkspaceAPI.record(json) ?? Record([:])
            if created.string("temp_password") == nil {
                added(created)
                dismiss()
            } else {
                result = created
            }
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}
