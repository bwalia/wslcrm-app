import Foundation

/// The records kept under one patient or one hospital. Each is described for its parent (the
/// server's paths carry the parent's uuid) and opened through `HealthScope`.
///
/// Lists answer `{data: [...], total}` and page with `page` + `perPage`; one record is `{data: {...}}`.
/// Values the server keeps as JSON lists (goals, scope, side effects…) are edited as comma-separated
/// tags and sent as arrays, which the server stores as JSON.
extension HealthCatalog {
    private static func patientPath(_ patient: String, _ resource: String) -> String {
        "/api/v2/patients/\(patient)/\(resource)"
    }

    private static func choices(_ values: [String]) -> [Choice] { values.map { Choice($0) } }

    static let shifts = [Choice("morning", "Morning"), Choice("afternoon", "Afternoon"), Choice("night", "Night")]

    // MARK: Care plans

    static let carePlanTypes = [Choice("general", "General"), Choice("medication", "Medicines"),
                                Choice("rehabilitation", "Rehabilitation"), Choice("dementia", "Dementia"),
                                Choice("palliative", "Palliative (end of life)"), Choice("nutrition", "Food and drink")]
    static let priorities = [Choice("low", "Low"), Choice("normal", "Normal"), Choice("high", "High"), Choice("urgent", "Urgent")]
    static let carePlanStatus = StatusStyle(tones: ["draft": .neutral, "active": .success, "completed": .info,
                                                    "cancelled": .danger],
                                            labels: ["active": "In use", "completed": "Finished"])
    static let carePlanStatuses = [Choice("draft", "Draft"), Choice("active", "In use"), Choice("completed", "Finished"),
                                   Choice("cancelled", "Cancelled")]

    static func carePlans(patient: String) -> ResourceDescriptor {
        ResourceDescriptor(
            id: "health.care_plans@\(patient)", title: "Care plans", noun: "care plan", systemImage: "list.clipboard",
            api: .crud(patientPath(patient, "care-plans"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["title"],
                           subtitle: [FieldSpec("plan_type", "Type", .choice(carePlanTypes)),
                                      FieldSpec("priority", "Priority", .choice(priorities)),
                                      FieldSpec("review_date", "Review", .date)],
                           badge: FieldSpec("status", "Status", .status(carePlanStatus)),
                           filters: [FilterSpec("status", "Status", carePlanStatuses),
                                     FilterSpec("plan_type", "Type", carePlanTypes)],
                           emptyTitle: "No care plans yet",
                           emptyDescription: "A care plan sets out what someone needs and how you’ll help: goals, support, risks and when to review it."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("plan_type", "Type", .choice(carePlanTypes)), FieldSpec("priority", "Priority", .choice(priorities)),
                    FieldSpec("status", "Status", .status(carePlanStatus)), FieldSpec("start_date", "Starts", .date),
                    FieldSpec("end_date", "Ends", .date), FieldSpec("review_date", "Review by", .date),
                ]),
                SectionSpec("The plan", [
                    FieldSpec("description", "What it covers", .multiline), FieldSpec("goals", "Goals", .tags),
                    FieldSpec("interventions", "How we’ll help", .tags), FieldSpec("mobility_aids", "Mobility aids", .tags),
                ]),
                SectionSpec("Needs and risks", [
                    FieldSpec("risk_assessments", "Risks", .json), FieldSpec("dietary_requirements", "Food and drink", .json),
                    FieldSpec("communication_needs", "Communication", .json), FieldSpec("daily_routines", "Daily routine", .json),
                    FieldSpec("medication_schedule", "Medicine times", .json),
                ]),
                SectionSpec("Record", [
                    FieldSpec("notes", "Notes", .multiline), FieldSpec("created_by_name", "Written by"),
                    FieldSpec("approved_by", "Approved by"), FieldSpec("created_at", "Added", .dateTime),
                    FieldSpec("updated_at", "Last changed", .dateTime),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("title", "Title", required: true, placeholder: "e.g. Staying safe on the stairs"),
                    FieldSpec("plan_type", "Type", .choice(carePlanTypes), required: true, defaultValue: .string("general")),
                    FieldSpec("priority", "Priority", .choice(priorities), required: true, defaultValue: .string("normal")),
                    FieldSpec("status", "Status", .choice(carePlanStatuses), required: true, defaultValue: .string("active")),
                ]),
                SectionSpec("Dates", [
                    FieldSpec("start_date", "Starts", .date, required: true), FieldSpec("end_date", "Ends", .date),
                    FieldSpec("review_date", "Review by", .date, help: "Plans past this date show on the care home dashboard."),
                ]),
                SectionSpec("The plan", [
                    FieldSpec("description", "What it covers", .multiline),
                    FieldSpec("goals", "Goals", .tags, help: "Separate them with commas."),
                    FieldSpec("interventions", "How we’ll help", .tags, help: "Separate them with commas."),
                    FieldSpec("mobility_aids", "Mobility aids", .tags, help: "Separate them with commas."),
                ]),
                SectionSpec(nil, [FieldSpec("approved_by", "Approved by"), FieldSpec("notes", "Notes", .multiline)]),
            ], sendOnlyChanges: true),
            summary: "What this person needs and how you’ll help them.")
    }

    // MARK: Medications

    static let medicationStatus = StatusStyle(tones: ["active": .success, "paused": .warning, "discontinued": .neutral,
                                                      "completed": .info],
                                              labels: ["active": "Taking", "discontinued": "Stopped",
                                                       "completed": "Course finished"])
    static let medicationStatuses = [Choice("active", "Taking"), Choice("paused", "Paused"),
                                     Choice("discontinued", "Stopped"), Choice("completed", "Course finished")]

    static func medications(patient: String) -> ResourceDescriptor {
        ResourceDescriptor(
            id: "health.medications@\(patient)", title: "Medications", noun: "medicine", systemImage: "pills",
            api: .crud(patientPath(patient, "medications"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["name"],
                           subtitle: [FieldSpec("dosage", "Dose"), FieldSpec("unit", "Unit"), FieldSpec("frequency", "How often"),
                                      FieldSpec("route", "How it’s taken")],
                           badge: FieldSpec("status", "Status", .status(medicationStatus)),
                           filters: [FilterSpec("status", "Status", medicationStatuses)],
                           emptyTitle: "No medicines prescribed",
                           emptyDescription: "Add each medicine with its dose and how often, so everyone gives it the same way."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("generic_name", "Also called"), FieldSpec("dosage", "Dose"), FieldSpec("unit", "Unit"),
                    FieldSpec("frequency", "How often"), FieldSpec("route", "How it’s taken"),
                    FieldSpec("schedule_times", "Times", .tags), FieldSpec("is_prn", "Only when needed (PRN)", .bool),
                    FieldSpec("max_daily_doses", "Most doses a day", .integer),
                    FieldSpec("status", "Status", .status(medicationStatus)),
                ]),
                SectionSpec("Instructions", [
                    FieldSpec("instructions", "How to give it", .multiline), FieldSpec("purpose", "What it’s for"),
                    FieldSpec("side_effects", "Side effects", .tags), FieldSpec("interactions", "Don’t mix with", .tags),
                    FieldSpec("allergies_check", "Allergies checked", .bool),
                ]),
                SectionSpec("Prescription", [
                    FieldSpec("prescriber", "Prescribed by"), FieldSpec("pharmacy", "Pharmacy"),
                    FieldSpec("start_date", "Started", .date), FieldSpec("end_date", "Ends", .date),
                    FieldSpec("discontinued_reason", "Why it was stopped", .multiline), FieldSpec("notes", "Notes", .multiline),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("name", "Medicine", required: true), FieldSpec("generic_name", "Also called"),
                    FieldSpec("dosage", "Dose", required: true, placeholder: "e.g. 500"),
                    FieldSpec("unit", "Unit", placeholder: "e.g. mg, ml, tablet"),
                    FieldSpec("frequency", "How often", required: true, placeholder: "e.g. twice a day"),
                    FieldSpec("route", "How it’s taken", placeholder: "e.g. by mouth"),
                    FieldSpec("schedule_times", "Times", .tags, help: "For example 08:00, 20:00."),
                    FieldSpec("is_prn", "Only when needed (PRN)", .bool),
                    FieldSpec("max_daily_doses", "Most doses a day", .integer),
                    FieldSpec("status", "Status", .choice(medicationStatuses), required: true, defaultValue: .string("active")),
                ]),
                SectionSpec("Instructions", [
                    FieldSpec("instructions", "How to give it", .multiline), FieldSpec("purpose", "What it’s for"),
                    FieldSpec("side_effects", "Side effects", .tags, help: "Separate them with commas."),
                    FieldSpec("interactions", "Don’t mix with", .tags, help: "Separate them with commas."),
                    FieldSpec("allergies_check", "Allergies checked", .bool),
                ]),
                SectionSpec("Prescription", [
                    FieldSpec("prescriber", "Prescribed by"), FieldSpec("pharmacy", "Pharmacy"),
                    FieldSpec("start_date", "Started", .date, required: true), FieldSpec("end_date", "Ends", .date),
                    FieldSpec("discontinued_reason", "Why it was stopped", .multiline), FieldSpec("notes", "Notes", .multiline),
                ]),
            ], sendOnlyChanges: true),
            summary: "Medicines prescribed for this person.")
    }

    // MARK: Daily logs

    static let intake = choices(["all", "most", "half", "little", "none"])
    static let moods = choices(["happy", "calm", "anxious", "agitated", "confused", "distressed"])

    static func dailyLogs(patient: String) -> ResourceDescriptor {
        let sleep = choices(["good", "fair", "poor", "disturbed"])
        let mobility = choices(["independent", "assisted", "wheelchair", "bedbound"])
        let wellbeing = choices(["excellent", "good", "fair", "poor", "declining"])
        return ResourceDescriptor(
            id: "health.daily_logs@\(patient)", title: "Daily logs", noun: "daily log", systemImage: "sun.max",
            api: .crud(patientPath(patient, "daily-logs"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["log_date"],
                           subtitle: [FieldSpec("shift", "Shift", .choice(shifts)), FieldSpec("overall_mood", "Mood", .choice(moods)),
                                      FieldSpec("pain_level", "Pain (0–10)", .integer), FieldSpec("concerns", "Concerns")],
                           badge: FieldSpec("general_wellbeing", "Wellbeing", .choice(wellbeing)),
                           filters: [FilterSpec("shift", "Shift", shifts)],
                           emptyTitle: "No daily logs yet",
                           emptyDescription: "One log per shift: sleep, food and drink, mood, activity and anything that worried you."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("log_date", "Day", .date), FieldSpec("shift", "Shift", .choice(shifts)),
                    FieldSpec("recorded_by_name", "Recorded by"), FieldSpec("general_wellbeing", "Wellbeing", .choice(wellbeing)),
                    FieldSpec("pain_level", "Pain (0–10)", .integer), FieldSpec("weight", "Weight (kg)", .decimal(places: 1)),
                ]),
                SectionSpec("Sleep", [
                    FieldSpec("sleep_quality", "Sleep", .choice(sleep)), FieldSpec("sleep_hours", "Hours slept", .decimal(places: 1)),
                    FieldSpec("sleep_notes", "Notes", .multiline),
                ]),
                SectionSpec("Food and drink", [
                    FieldSpec("breakfast_intake", "Breakfast", .choice(intake)), FieldSpec("lunch_intake", "Lunch", .choice(intake)),
                    FieldSpec("dinner_intake", "Dinner", .choice(intake)), FieldSpec("snack_intake", "Snacks", .choice(intake)),
                    FieldSpec("fluid_intake_ml", "Drinks (ml)", .integer), FieldSpec("nutrition_notes", "Notes", .multiline),
                ]),
                SectionSpec("Medicines", [
                    FieldSpec("medications_given", "Given", .tags), FieldSpec("medications_refused", "Refused", .tags),
                    FieldSpec("medication_notes", "Notes", .multiline),
                ]),
                SectionSpec("Activity and mood", [
                    FieldSpec("mobility_level", "Mobility", .choice(mobility)), FieldSpec("activities", "Activities", .tags),
                    FieldSpec("exercise_completed", "Did their exercises", .bool),
                    FieldSpec("activity_notes", "Activity notes", .multiline),
                    FieldSpec("overall_mood", "Mood", .choice(moods)), FieldSpec("mood_changes", "Mood changes", .tags),
                    FieldSpec("behavioural_incidents", "Behaviour", .tags), FieldSpec("social_interactions", "Visitors and company", .json),
                ]),
                SectionSpec("Personal care", [
                    FieldSpec("personal_care_completed", "Personal care done", .json),
                    FieldSpec("continence_notes", "Continence", .multiline),
                ]),
                SectionSpec("Family", [
                    FieldSpec("family_visit", "Family visited", .bool), FieldSpec("family_visit_notes", "Visit notes", .multiline),
                    FieldSpec("family_notified", "Family told about today", .bool),
                ]),
                SectionSpec("Concerns", [FieldSpec("concerns", "Anything that worried you", .multiline)]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("log_date", "Day", .date, required: true),
                    FieldSpec("shift", "Shift", .choice(shifts)),
                    FieldSpec("general_wellbeing", "Wellbeing", .choice(wellbeing)),
                    FieldSpec("pain_level", "Pain (0–10)", .integer), FieldSpec("weight", "Weight (kg)", .decimal(places: 1)),
                ]),
                SectionSpec("Sleep", [
                    FieldSpec("sleep_quality", "Sleep", .choice(sleep)), FieldSpec("sleep_hours", "Hours slept", .decimal(places: 1)),
                    FieldSpec("sleep_notes", "Notes", .multiline),
                ]),
                SectionSpec("Food and drink", [
                    FieldSpec("breakfast_intake", "Breakfast", .choice(intake)), FieldSpec("lunch_intake", "Lunch", .choice(intake)),
                    FieldSpec("dinner_intake", "Dinner", .choice(intake)), FieldSpec("snack_intake", "Snacks", .choice(intake)),
                    FieldSpec("fluid_intake_ml", "Drinks (ml)", .integer), FieldSpec("nutrition_notes", "Notes", .multiline),
                ]),
                SectionSpec("Medicines", [
                    FieldSpec("medications_given", "Given", .tags, help: "Separate them with commas."),
                    FieldSpec("medications_refused", "Refused", .tags, help: "Separate them with commas."),
                    FieldSpec("medication_notes", "Notes", .multiline),
                ]),
                SectionSpec("Activity and mood", [
                    FieldSpec("mobility_level", "Mobility", .choice(mobility)),
                    FieldSpec("activities", "Activities", .tags, help: "Separate them with commas."),
                    FieldSpec("exercise_completed", "Did their exercises", .bool),
                    FieldSpec("activity_notes", "Activity notes", .multiline),
                    FieldSpec("overall_mood", "Mood", .choice(moods)),
                    FieldSpec("mood_changes", "Mood changes", .tags, help: "Separate them with commas."),
                    FieldSpec("behavioural_incidents", "Behaviour", .tags, help: "Separate them with commas."),
                ]),
                SectionSpec("Personal care", [FieldSpec("continence_notes", "Continence", .multiline)]),
                SectionSpec("Family", [
                    FieldSpec("family_visit", "Family visited", .bool), FieldSpec("family_visit_notes", "Visit notes", .multiline),
                    FieldSpec("family_notified", "Family told about today", .bool),
                ]),
                SectionSpec("Concerns", [FieldSpec("concerns", "Anything that worried you", .multiline)]),
            ], sendOnlyChanges: true),
            summary: "A note for each shift: sleep, food, mood, activity and concerns.")
    }

    // MARK: Care logs (care notes and incidents)

    static let careLogTypes = [Choice("feeding", "Food and drink"), Choice("medication", "Medicine given"),
                               Choice("personal_care", "Personal care"), Choice("observation", "Observation"),
                               Choice("incident", "Incident"), Choice("handover", "Handover")]
    static let careLogStatus = StatusStyle(tones: ["draft": .neutral, "completed": .success, "reviewed": .info,
                                                   "flagged": .warning],
                                           labels: ["completed": "Done", "flagged": "Needs a look"])

    static func careLogs(patient: String) -> ResourceDescriptor {
        let statuses = [Choice("draft", "Draft"), Choice("completed", "Done"), Choice("reviewed", "Reviewed"),
                        Choice("flagged", "Needs a look")]
        let meals = choices(["breakfast", "lunch", "dinner", "snack", "fluids"])
        let careTypes = [Choice("bathing"), Choice("dressing"), Choice("toileting"), Choice("oral_care", "Teeth and mouth")]
        let assistance = choices(["independent", "minimal", "moderate", "full"])
        let incidents = [Choice("fall"), Choice("injury"), Choice("wandering"), Choice("aggression"),
                         Choice("medical_emergency", "Medical emergency")]
        let severities = choices(["minor", "moderate", "severe"])
        return ResourceDescriptor(
            id: "health.care_logs@\(patient)", title: "Care notes", noun: "care note", systemImage: "note.text",
            api: .crud(patientPath(patient, "care-logs"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["summary"],
                           subtitle: [FieldSpec("log_type", "Kind", .choice(careLogTypes)), FieldSpec("log_date", "Day", .date),
                                      FieldSpec("shift", "Shift", .choice(shifts))],
                           badge: FieldSpec("status", "Status", .status(careLogStatus)),
                           filters: [FilterSpec("log_type", "Kind", careLogTypes), FilterSpec("shift", "Shift", shifts)],
                           emptyTitle: "No care notes yet",
                           emptyDescription: "Note care as you give it: meals, medicines, personal care, what you noticed, incidents and handovers."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("log_type", "Kind", .choice(careLogTypes)), FieldSpec("log_date", "Day", .date),
                    FieldSpec("log_time", "Time", .dateTime), FieldSpec("shift", "Shift", .choice(shifts)),
                    FieldSpec("status", "Status", .status(careLogStatus)),
                ]),
                SectionSpec("What happened", [
                    FieldSpec("summary", "Summary", .multiline), FieldSpec("details", "More detail", .json),
                ]),
                SectionSpec("Medicine", [
                    FieldSpec("medication_name", "Medicine"), FieldSpec("medication_dose", "Dose"),
                    FieldSpec("medication_administered", "Given", .bool),
                    FieldSpec("medication_refused_reason", "Why it wasn’t taken", .multiline),
                ]),
                SectionSpec("Food and drink", [
                    FieldSpec("meal_type", "Meal", .choice(meals)), FieldSpec("intake_amount", "How much", .choice(intake)),
                    FieldSpec("fluid_intake_ml", "Drinks (ml)", .integer),
                ]),
                SectionSpec("Mood and personal care", [
                    FieldSpec("mood", "Mood", .choice(moods)), FieldSpec("behaviour_notes", "Behaviour", .multiline),
                    FieldSpec("personal_care_type", "Personal care", .choice(careTypes)),
                    FieldSpec("assistance_level", "Help needed", .choice(assistance)),
                ]),
                SectionSpec("Incident", [
                    FieldSpec("incident_type", "Incident", .choice(incidents)),
                    FieldSpec("incident_severity", "How serious", .choice(severities)),
                    FieldSpec("action_taken", "What we did", .multiline),
                    FieldSpec("follow_up_required", "Needs follow-up", .bool),
                    FieldSpec("follow_up_notes", "Follow-up", .multiline),
                ]),
                SectionSpec("Review", [
                    FieldSpec("recorded_by_name", "Written by"),
                    FieldSpec("reviewed_by", "Reviewed by"), FieldSpec("reviewed_at", "Reviewed", .dateTime),
                    FieldSpec("created_at", "Written", .dateTime),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("log_type", "Kind", .choice(careLogTypes), required: true, defaultValue: .string("observation")),
                    FieldSpec("summary", "What happened", .multiline, required: true),
                    FieldSpec("log_date", "Day", .date, required: true), FieldSpec("log_time", "Time", .dateTime),
                    FieldSpec("shift", "Shift", .choice(shifts)),
                    FieldSpec("status", "Status", .choice(statuses), required: true, defaultValue: .string("completed")),
                ]),
                SectionSpec("Medicine (if given)", [
                    FieldSpec("medication_name", "Medicine"), FieldSpec("medication_dose", "Dose"),
                    FieldSpec("medication_administered", "Given", .bool),
                    FieldSpec("medication_refused_reason", "Why it wasn’t taken", .multiline),
                ]),
                SectionSpec("Food and drink (if a meal)", [
                    FieldSpec("meal_type", "Meal", .choice(meals)), FieldSpec("intake_amount", "How much", .choice(intake)),
                    FieldSpec("fluid_intake_ml", "Drinks (ml)", .integer),
                ]),
                SectionSpec("Mood and personal care", [
                    FieldSpec("mood", "Mood", .choice(moods)), FieldSpec("behaviour_notes", "Behaviour", .multiline),
                    FieldSpec("personal_care_type", "Personal care", .choice(careTypes)),
                    FieldSpec("assistance_level", "Help needed", .choice(assistance)),
                ]),
                SectionSpec("Incident (if there was one)", [
                    FieldSpec("incident_type", "Incident", .choice(incidents)),
                    FieldSpec("incident_severity", "How serious", .choice(severities)),
                    FieldSpec("action_taken", "What we did", .multiline),
                    FieldSpec("follow_up_required", "Needs follow-up", .bool),
                    FieldSpec("follow_up_notes", "Follow-up", .multiline),
                ]),
                SectionSpec("Review", [FieldSpec("reviewed_by", "Reviewed by")]),
            ], sendOnlyChanges: true),
            summary: "Care given and things noticed, as they happen.")
    }

    // MARK: Family and contacts

    static let relationships = choices(["spouse", "daughter", "son", "sibling", "parent", "guardian", "other"])

    static func familyMembers(patient: String) -> ResourceDescriptor {
        let contact = [Choice("phone", "Phone"), Choice("email", "Email"), Choice("sms", "Text message")]
        let statuses = [Choice("active", "Active"), Choice("inactive", "Not in use"), Choice("removed", "Removed")]
        return ResourceDescriptor(
            id: "health.family@\(patient)", title: "Family and contacts", noun: "family member", systemImage: "person.3",
            api: .crud(patientPath(patient, "family-members"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["first_name"],
                           subtitle: [FieldSpec("last_name", "Last name"), FieldSpec("relationship", "Relationship", .choice(relationships)),
                                      FieldSpec("phone", "Phone")],
                           badge: FieldSpec("status", "Status", .status(.standard)),
                           filters: [FilterSpec("status", "Status", statuses)],
                           emptyTitle: "No family members yet",
                           emptyDescription: "Add next of kin, emergency contacts and anyone with power of attorney."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("first_name", "First name"), FieldSpec("last_name", "Last name"),
                    FieldSpec("relationship", "Relationship", .choice(relationships)),
                    FieldSpec("status", "Status", .status(.standard)),
                ]),
                SectionSpec("Their role", [
                    FieldSpec("is_next_of_kin", "Next of kin", .bool), FieldSpec("is_emergency_contact", "Emergency contact", .bool),
                    FieldSpec("is_power_of_attorney", "Power of attorney", .bool),
                    FieldSpec("can_make_decisions", "Can make decisions", .bool), FieldSpec("decision_scope", "Decisions about", .json),
                ]),
                SectionSpec("Contact", [
                    FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email),
                    FieldSpec("address", "Address", .multiline),
                    FieldSpec("preferred_contact_method", "Best way to reach them", .choice(contact)),
                    FieldSpec("preferred_language", "Language"),
                ]),
                SectionSpec("Checks", [
                    FieldSpec("verified", "Identity checked", .bool), FieldSpec("verified_by", "Checked by"),
                    FieldSpec("verified_at", "Checked", .dateTime), FieldSpec("notes", "Notes", .multiline),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("first_name", "First name", required: true), FieldSpec("last_name", "Last name", required: true),
                    FieldSpec("relationship", "Relationship", .choice(relationships), required: true),
                    FieldSpec("status", "Status", .choice(statuses), required: true, defaultValue: .string("active")),
                ]),
                SectionSpec("Their role", [
                    FieldSpec("is_next_of_kin", "Next of kin", .bool), FieldSpec("is_emergency_contact", "Emergency contact", .bool),
                    FieldSpec("is_power_of_attorney", "Power of attorney", .bool),
                    FieldSpec("can_make_decisions", "Can make decisions", .bool),
                ]),
                SectionSpec("Contact", [
                    FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email),
                    FieldSpec("address", "Address", .multiline),
                    FieldSpec("preferred_contact_method", "Best way to reach them", .choice(contact)),
                    FieldSpec("preferred_language", "Language"),
                ]),
                SectionSpec("Checks", [
                    FieldSpec("verified", "Identity checked", .bool), FieldSpec("verified_by", "Checked by"),
                    FieldSpec("notes", "Notes", .multiline),
                ]),
            ], sendOnlyChanges: true),
            summary: "Next of kin, emergency contacts and people with power of attorney.")
    }

    // MARK: Shared access (patient-controlled data sharing)

    static let accessRoles = [Choice("family_member", "Family member"), Choice("caregiver", "Carer"), Choice("doctor", "Doctor"),
                              Choice("specialist", "Specialist"), Choice("social_worker", "Social worker")]
    static let accessLevels = [Choice("read", "Can see"), Choice("read_write", "Can see and change"),
                               Choice("emergency_only", "Emergencies only")]
    static let accessStatus = StatusStyle(tones: ["pending": .warning, "active": .success, "expired": .neutral,
                                                  "revoked": .danger, "suspended": .warning],
                                          labels: ["revoked": "Taken away", "pending": "Waiting"])

    static func accessControls(patient: String) -> ResourceDescriptor {
        let statuses = [Choice("pending", "Waiting"), Choice("active", "Active"), Choice("expired", "Expired"),
                        Choice("revoked", "Taken away"), Choice("suspended", "Suspended")]
        return ResourceDescriptor(
            id: "health.access@\(patient)", title: "Shared access", noun: "access grant", systemImage: "lock.shield",
            api: .crud(patientPath(patient, "access-controls"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["granted_to"],
                           subtitle: [FieldSpec("role", "Role", .choice(accessRoles)),
                                      FieldSpec("access_level", "Access", .choice(accessLevels)),
                                      FieldSpec("expires_at", "Until", .date)],
                           badge: FieldSpec("status", "Status", .status(accessStatus)),
                           filters: [FilterSpec("status", "Status", statuses), FilterSpec("role", "Role", accessRoles)],
                           emptyTitle: "Nothing shared",
                           emptyDescription: "The patient hasn’t shared their records with anyone. Add someone to let them see what you choose."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("granted_to", "Shared with", .email), FieldSpec("role", "Role", .choice(accessRoles)),
                    FieldSpec("relationship", "Relationship"), FieldSpec("access_level", "Access", .choice(accessLevels)),
                    FieldSpec("scope", "What they can see", .tags), FieldSpec("status", "Status", .status(accessStatus)),
                ]),
                SectionSpec("Consent and safety", [
                    FieldSpec("consent_given", "Patient agreed", .bool), FieldSpec("consent_date", "Agreed on", .date),
                    FieldSpec("requires_2fa", "Needs a sign-in code", .bool), FieldSpec("expires_at", "Ends", .dateTime),
                ]),
                SectionSpec("History", [
                    FieldSpec("granted_by", "Shared by"), FieldSpec("created_at", "Shared", .dateTime),
                    FieldSpec("access_count", "Times opened", .integer), FieldSpec("last_accessed_at", "Last opened", .dateTime),
                    FieldSpec("revoked_at", "Taken away", .dateTime), FieldSpec("revoked_reason", "Why", .multiline),
                    FieldSpec("notes", "Notes", .multiline),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("granted_to", "Their email", .email, required: true),
                    FieldSpec("role", "Role", .choice(accessRoles), required: true, defaultValue: .string("family_member")),
                    FieldSpec("relationship", "Relationship", placeholder: "e.g. daughter, GP"),
                    FieldSpec("access_level", "Access", .choice(accessLevels), required: true, defaultValue: .string("read")),
                    FieldSpec("scope", "What they can see", .tags,
                              help: "For example medications, appointments, care_plans — or all. Separate them with commas."),
                ]),
                SectionSpec("Consent and safety", [
                    FieldSpec("consent_given", "The patient agreed to this", .bool),
                    FieldSpec("consent_date", "Agreed on", .date),
                    FieldSpec("requires_2fa", "Ask them for a sign-in code", .bool),
                    FieldSpec("expires_at", "Ends", .dateTime, help: "Leave empty to share until you take it away."),
                ]),
                SectionSpec(nil, [FieldSpec("notes", "Notes", .multiline)]),
            ], sendOnlyChanges: true),
            actions: [
                ActionSpec("revoke", "Take access away", systemImage: "hand.raised", path: "\(patientPath(patient, "access-controls"))/{uuid}/revoke",
                           confirm: "They won’t be able to see this person’s records any more.", destructive: true,
                           module: module, action: .create, visibleWhen: .field("status", in: ["active", "pending", "suspended"]),
                           inputs: [FieldSpec("reason", "Why (optional)", .multiline)], done: "Access taken away."),
            ],
            summary: "Who the patient has let see their records.")
    }

    // MARK: Alerts

    static let alertTypes = [Choice("medication_reminder", "Medicine reminder"), Choice("emergency", "Emergency"),
                             Choice("fall", "Fall"), Choice("wandering", "Wandering"), Choice("missed_care", "Missed care"),
                             Choice("vital_sign", "Vital signs"), Choice("appointment", "Appointment"),
                             Choice("family_notification", "Tell the family")]
    static let severities = [Choice("info", "For information"), Choice("warning", "Warning"), Choice("critical", "Critical"),
                             Choice("emergency", "Emergency")]
    static let severityStyle = StatusStyle(tones: ["info": .info, "warning": .warning, "critical": .danger, "emergency": .danger],
                                           symbols: ["critical": "exclamationmark.octagon.fill", "emergency": "light.beacon.max"],
                                           labels: ["info": "For information"])
    static let alertStatus = StatusStyle(tones: ["active": .warning, "acknowledged": .info, "resolved": .success,
                                                 "dismissed": .neutral, "escalated": .danger],
                                         labels: ["active": "Open", "acknowledged": "Seen"])
    static let alertStatuses = [Choice("active", "Open"), Choice("acknowledged", "Seen"), Choice("resolved", "Resolved"),
                                Choice("dismissed", "Dismissed"), Choice("escalated", "Escalated")]

    static func alerts(patient: String) -> ResourceDescriptor {
        let base = patientPath(patient, "alerts")
        return ResourceDescriptor(
            id: "health.alerts@\(patient)", title: "Alerts", noun: "alert", systemImage: "bell.badge",
            api: .crud(base, paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["title"],
                           subtitle: [FieldSpec("severity", "Severity", .status(severityStyle)),
                                      FieldSpec("alert_type", "Kind", .choice(alertTypes)),
                                      FieldSpec("created_at", "Raised", .dateTime)],
                           badge: FieldSpec("status", "Status", .status(alertStatus)),
                           filters: [FilterSpec("status", "Status", alertStatuses), FilterSpec("severity", "Severity", severities),
                                     FilterSpec("alert_type", "Kind", alertTypes)],
                           emptyTitle: "No alerts",
                           emptyDescription: "Raise an alert when something needs the team’s attention: a fall, a missed medicine, a worry."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("severity", "Severity", .status(severityStyle)), FieldSpec("alert_type", "Kind", .choice(alertTypes)),
                    FieldSpec("status", "Status", .status(alertStatus)), FieldSpec("message", "What’s wrong", .multiline),
                    FieldSpec("assigned_to", "Who’s dealing with it"), FieldSpec("created_at", "Raised", .dateTime),
                ]),
                SectionSpec("Follow-up", [
                    FieldSpec("acknowledged_by_name", "Seen by"), FieldSpec("acknowledged_at", "Seen", .dateTime),
                    FieldSpec("resolved_by_name", "Resolved by"), FieldSpec("resolved_at", "Resolved", .dateTime),
                    FieldSpec("resolution_notes", "How it was resolved", .multiline),
                    FieldSpec("escalation_level", "Escalation level", .integer), FieldSpec("escalated_to", "Escalated to"),
                ]),
                SectionSpec("Family", [
                    FieldSpec("notify_family", "Tell the family", .bool), FieldSpec("family_notified_at", "Family told", .dateTime),
                ]),
                SectionSpec("More", [FieldSpec("details", "Details", .json), FieldSpec("triggered_by_name", "Raised by")]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("title", "Title", required: true, placeholder: "e.g. Fall in the lounge"),
                    FieldSpec("message", "What’s wrong", .multiline, required: true),
                    FieldSpec("alert_type", "Kind", .choice(alertTypes), required: true, defaultValue: .string("emergency")),
                    FieldSpec("severity", "Severity", .choice(severities), required: true, defaultValue: .string("warning")),
                    FieldSpec("assigned_to", "Who’s dealing with it"),
                    FieldSpec("notify_family", "Tell the family", .bool),
                ]),
            ], sendOnlyChanges: true),
            actions: [
                ActionSpec("acknowledge", "I’ve seen this", systemImage: "eye", path: "\(base)/{uuid}/acknowledge",
                           module: module, action: .create, visibleWhen: .field("status", in: ["active", "escalated"]),
                           done: "Marked as seen."),
                ActionSpec("resolve", "Resolve", systemImage: "checkmark.circle", path: "\(base)/{uuid}/resolve",
                           module: module, action: .create,
                           visibleWhen: .field("status", in: ["active", "acknowledged", "escalated"]),
                           inputs: [FieldSpec("resolution_notes", "What was done (optional)", .multiline)],
                           done: "Alert resolved."),
            ],
            summary: "Things that need the team’s attention.")
    }

    // MARK: Dementia assessments

    static let riskLevels = [Choice("none", "None"), Choice("low", "Low"), Choice("moderate", "Moderate"), Choice("high", "High")]
    static let assessmentTypes = [Choice("mmse", "MMSE"), Choice("moca", "MoCA"), Choice("adl", "Daily living (ADL)"),
                                  Choice("behavioural", "Behaviour"), Choice("cognitive", "Thinking and memory"),
                                  Choice("capacity", "Mental capacity")]

    static func dementiaAssessments(patient: String) -> ResourceDescriptor {
        let severity = choices(["mild", "moderate", "severe"])
        let communication = [Choice("verbal", "Speaks"), Choice("limited_verbal", "A few words"),
                             Choice("non_verbal", "Doesn’t speak"), Choice("gestures", "Uses gestures")]
        let statuses = [Choice("scheduled", "Booked"), Choice("in_progress", "In progress"), Choice("completed", "Done"),
                        Choice("cancelled", "Cancelled")]
        return ResourceDescriptor(
            id: "health.dementia@\(patient)", title: "Dementia assessments", noun: "assessment", systemImage: "brain.head.profile",
            api: .crud(patientPath(patient, "dementia-assessments"), paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["assessment_date"],
                           subtitle: [FieldSpec("assessment_type", "Type", .choice(assessmentTypes)),
                                      FieldSpec("score", "Score", .integer), FieldSpec("severity_level", "Stage", .choice(severity)),
                                      FieldSpec("wandering_risk", "Wandering risk", .choice(riskLevels))],
                           badge: FieldSpec("status", "Status", .status(.standard)),
                           filters: [FilterSpec("assessment_type", "Type", assessmentTypes),
                                     FilterSpec("severity_level", "Stage", severity)],
                           emptyTitle: "No assessments yet",
                           emptyDescription: "Record memory and thinking assessments, risks, and what helps this person feel calm."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("assessment_type", "Type", .choice(assessmentTypes)), FieldSpec("assessment_date", "Day", .date),
                    FieldSpec("assessor", "Assessed by"), FieldSpec("score", "Score", .integer),
                    FieldSpec("max_score", "Out of", .integer), FieldSpec("severity_level", "Stage", .choice(severity)),
                    FieldSpec("status", "Status", .status(.standard)),
                    FieldSpec("next_assessment_date", "Next assessment", .date),
                ]),
                SectionSpec("Risks", [
                    FieldSpec("wandering_risk", "Wandering", .choice(riskLevels)), FieldSpec("fall_risk", "Falls", .choice(riskLevels)),
                    FieldSpec("communication_ability", "Communication", .choice(communication)),
                ]),
                SectionSpec("What helps", [
                    FieldSpec("recommendations", "Recommendations", .tags), FieldSpec("calming_strategies", "What calms them", .tags),
                    FieldSpec("triggers_to_avoid", "Things to avoid", .tags), FieldSpec("memory_prompts", "Memory prompts", .json),
                    FieldSpec("routine_preferences", "Routines they like", .json),
                ]),
                SectionSpec("Assessment detail", [
                    FieldSpec("cognitive_domains", "Thinking and memory", .json),
                    FieldSpec("behavioural_symptoms", "Behaviour", .json),
                    FieldSpec("functional_abilities", "Everyday abilities", .json),
                    FieldSpec("recognition_ability", "Recognises", .json), FieldSpec("sleep_pattern", "Sleep", .json),
                    FieldSpec("notes", "Notes", .multiline),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("assessment_type", "Type", .choice(assessmentTypes), required: true),
                    FieldSpec("assessment_date", "Day", .date, required: true),
                    FieldSpec("assessor", "Assessed by", required: true),
                    FieldSpec("score", "Score", .integer), FieldSpec("max_score", "Out of", .integer),
                    FieldSpec("severity_level", "Stage", .choice(severity)),
                    FieldSpec("status", "Status", .choice(statuses), required: true, defaultValue: .string("completed")),
                    FieldSpec("next_assessment_date", "Next assessment", .date,
                              help: "Assessments past this date show on the care home dashboard."),
                ]),
                SectionSpec("Risks", [
                    FieldSpec("wandering_risk", "Wandering", .choice(riskLevels)), FieldSpec("fall_risk", "Falls", .choice(riskLevels)),
                    FieldSpec("communication_ability", "Communication", .choice(communication)),
                ]),
                SectionSpec("What helps", [
                    FieldSpec("recommendations", "Recommendations", .tags, help: "Separate them with commas."),
                    FieldSpec("calming_strategies", "What calms them", .tags, help: "Separate them with commas."),
                    FieldSpec("triggers_to_avoid", "Things to avoid", .tags, help: "Separate them with commas."),
                ]),
                SectionSpec(nil, [FieldSpec("notes", "Notes", .multiline)]),
            ], sendOnlyChanges: true),
            summary: "Memory and thinking assessments, risks and what helps.")
    }

    // MARK: Activity log (read only)

    static func auditLogs(patient: String) -> ResourceDescriptor {
        let actions = choices(["view", "create", "update", "delete", "export", "share", "access_granted", "access_revoked",
                               "login", "consent"])
        let resources = [Choice("patient"), Choice("care_plan", "Care plan"), Choice("medication", "Medicine"),
                         Choice("document"), Choice("access_control", "Shared access")]
        return ResourceDescriptor(
            id: "health.audit@\(patient)", title: "Activity log", noun: "entry", systemImage: "clock.arrow.circlepath",
            api: ResourceAPISpec(list: patientPath(patient, "audit-logs"), item: "\(patientPath(patient, "audit-logs"))/{uuid}",
                                 paging: .pageAndCamelPerPage, searchParam: nil, idKeys: ["uuid", "id"]),
            permissions: permissions,
            list: ListSpec(title: ["action"],
                           subtitle: [FieldSpec("resource_type", "About"), FieldSpec("created_at", "When", .dateTime),
                                      FieldSpec("access_context", "How")],
                           badge: FieldSpec("status", "Result", .status(StatusStyle(tones: ["success": .success, "failure": .danger,
                                                                                         "denied": .danger]))),
                           filters: [FilterSpec("action", "What", actions), FilterSpec("resource_type", "About", resources)],
                           emptyTitle: "Nothing recorded yet",
                           emptyDescription: "Who looked at or changed this person’s records, and when."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("action", "What"), FieldSpec("resource_type", "About"), FieldSpec("created_at", "When", .dateTime),
                    FieldSpec("status", "Result", .status(.standard)), FieldSpec("failure_reason", "Why it failed", .multiline),
                ]),
                SectionSpec("How", [
                    FieldSpec("access_context", "Access"), FieldSpec("ip_address", "Internet address"),
                    FieldSpec("user_agent", "App or browser", .multiline), FieldSpec("changes", "Changes", .json),
                    FieldSpec("data_categories_accessed", "Information seen", .tags),
                ]),
            ],
            summary: "Who looked at or changed this person’s records.")
    }

    // MARK: Hospital departments and wards

    static func departments(hospital: String) -> ResourceDescriptor {
        let statuses = [Choice("active", "Open"), Choice("inactive", "Not in use"), Choice("closed", "Closed")]
        return ResourceDescriptor(
            id: "health.departments@\(hospital)", title: "Departments", noun: "department", systemImage: "square.grid.2x2",
            api: .crud("/api/v2/hospitals/\(hospital)/departments", paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["name"],
                           subtitle: [FieldSpec("code", "Code"), FieldSpec("floor", "Floor"),
                                      FieldSpec("head_of_department", "Head")],
                           badge: FieldSpec("status", "Status", .status(.standard)),
                           trailing: FieldSpec("capacity", "Beds", .integer),
                           emptyTitle: "No departments yet",
                           emptyDescription: "Departments group the wards and teams in this place."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("code", "Code"), FieldSpec("head_of_department", "Head of department"),
                    FieldSpec("floor", "Floor"), FieldSpec("capacity", "Beds", .integer),
                    FieldSpec("status", "Status", .status(.standard)), FieldSpec("description", "About", .multiline),
                ]),
                SectionSpec("Contact", [FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email)]),
                SectionSpec("More", [FieldSpec("specialties", "Specialties", .tags), FieldSpec("operating_hours", "Opening hours", .json)]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("name", "Name", required: true), FieldSpec("code", "Code"),
                    FieldSpec("head_of_department", "Head of department"), FieldSpec("floor", "Floor"),
                    FieldSpec("capacity", "Beds", .integer),
                    FieldSpec("status", "Status", .choice(statuses), required: true, defaultValue: .string("active")),
                    FieldSpec("description", "About", .multiline),
                ]),
                SectionSpec("Contact", [FieldSpec("phone", "Phone", .phone), FieldSpec("email", "Email", .email)]),
            ], sendOnlyChanges: true),
            summary: "The departments in this hospital or care home.")
    }

    static let wardTypes = [Choice("general", "General"), Choice("icu", "Intensive care"), Choice("maternity", "Maternity"),
                            Choice("dementia", "Dementia"), Choice("palliative", "Palliative (end of life)")]

    static func wards(hospital: String) -> ResourceDescriptor {
        let statuses = [Choice("active", "Open"), Choice("closed", "Closed"), Choice("maintenance", "Being repaired")]
        let style = StatusStyle(tones: ["active": .success, "closed": .neutral, "maintenance": .warning],
                                labels: ["active": "Open", "maintenance": "Being repaired"])
        let department = ReferenceSpec(list: "/api/v2/hospitals/\(hospital)/departments", valueKey: "id", titleKeys: ["name"],
                                       subtitleKeys: ["code"], searchParam: nil, paging: .pageAndCamelPerPage)
        return ResourceDescriptor(
            id: "health.wards@\(hospital)", title: "Wards", noun: "ward", systemImage: "bed.double",
            api: .crud("/api/v2/hospitals/\(hospital)/wards", paging: .pageAndCamelPerPage, searchParam: nil),
            permissions: permissions,
            list: ListSpec(title: ["name"],
                           subtitle: [FieldSpec("ward_type", "Type", .choice(wardTypes)), FieldSpec("floor", "Floor"),
                                      FieldSpec("current_occupancy", "Beds in use", .integer)],
                           badge: FieldSpec("status", "Status", .status(style)),
                           trailing: FieldSpec("capacity", "Beds", .integer),
                           emptyTitle: "No wards yet",
                           emptyDescription: "Add the wards or units, with their beds and who to call."),
            detail: [
                SectionSpec(nil, [
                    FieldSpec("code", "Code"), FieldSpec("ward_type", "Type", .choice(wardTypes)), FieldSpec("floor", "Floor"),
                    FieldSpec("capacity", "Beds", .integer), FieldSpec("current_occupancy", "Beds in use", .integer),
                    FieldSpec("status", "Status", .status(style)),
                    FieldSpec("nurse_station_phone", "Nurses’ station", .phone),
                ]),
                SectionSpec("Visiting", [
                    FieldSpec("visiting_hours", "Visiting hours", .json), FieldSpec("restrictions", "Restrictions", .tags),
                ]),
            ],
            form: FormSpec([
                SectionSpec(nil, [
                    FieldSpec("name", "Name", required: true), FieldSpec("code", "Code"),
                    FieldSpec("ward_type", "Type", .choice(wardTypes)), FieldSpec("floor", "Floor"),
                    FieldSpec("department_id", "Department", .reference(department),
                              help: "Leave empty if it isn’t part of a department."),
                    FieldSpec("capacity", "Beds", .integer), FieldSpec("current_occupancy", "Beds in use", .integer),
                    FieldSpec("nurse_station_phone", "Nurses’ station", .phone),
                    FieldSpec("status", "Status", .choice(statuses), required: true, defaultValue: .string("active")),
                ]),
            ], sendOnlyChanges: true),
            summary: "The wards or units in this hospital or care home.")
    }
}
