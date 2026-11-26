import SwiftUI

/// CRM, leads, customers and products, invoices and purchase orders. The menu keys (`crm`, `crm_leads`,
/// `customers`, `products`, `invoices`, `purchase_orders`) open the app's hand-built screens
/// (`NativeModules.screens`); this group adds the described resources those screens link to
/// (activities, partners, tax rates, lead alerts) and the hand-built screens other areas can open by id.
extension ModuleGroup {
    static let crm = ModuleGroup(
        id: "crm",
        descriptors: ModuleCatalog.crmDescriptors,
        screen: { id in
            switch id {
            case "crm.deals": AnyView(CRMDealsListView())
            case "crm.pipelines": AnyView(CRMPipelinesView())
            case "crm.partners": AnyView(PartnersHubView())
            case "crm.activities": AnyView(ResourceListView(ModuleCatalog.crmActivities))
            case "leads.settings": AnyView(LeadSettingsView())
            case "invoices.tax_rates": AnyView(ResourceListView(ModuleCatalog.invoiceTaxRates))
            default: nil
            }
        })
}

extension ModuleCatalog {
    static let crmDescriptors: [ResourceDescriptor] = [
        crmActivities, crmPartners, crmReferrals, invoiceTaxRates, leadAlerts,
    ]

    // MARK: Activities (`/api/v2/crm/activities`, RBAC `crm_activities`)

    static let crmActivitiesBase = "/api/v2/crm/activities"

    static let activityTypes = [
        Choice("call", "Call"), Choice("email", "Email"), Choice("meeting", "Meeting"), Choice("note", "Note"),
        Choice("task", "Task"),
    ]

    /// The server stores `planned` and answers `pending` (CrmQueries.shapeActivity).
    static let activityStatus = StatusStyle(
        tones: ["pending": .warning, "planned": .warning, "completed": .success, "cancelled": .neutral],
        symbols: ["pending": "clock", "planned": "clock"],
        labels: ["pending": "To do", "planned": "To do", "completed": "Done"])

    static let crmActivities = ResourceDescriptor(
        id: "crm.activities", title: "Activities", noun: "activity", systemImage: "calendar.badge.clock",
        api: ResourceAPISpec(list: crmActivitiesBase, item: "\(crmActivitiesBase)/{uuid}", create: crmActivitiesBase,
                             update: "\(crmActivitiesBase)/{uuid}", delete: "\(crmActivitiesBase)/{uuid}",
                             paging: .pageAndPerPage, searchParam: nil),
        permissions: ResourcePermissions(module: "crm_activities"),
        list: ListSpec(title: ["subject"],
                       subtitle: [FieldSpec("type", "Kind", .choice(activityTypes)), FieldSpec("related_name", "For"),
                                  FieldSpec("due_date", "When", .dateTime)],
                       badge: FieldSpec("status", "Status", .status(activityStatus)),
                       filters: [
                           FilterSpec("activity_type", "Kind", activityTypes),
                           FilterSpec("status", "Status", [Choice("planned", "To do"), Choice("completed", "Done"),
                                                           Choice("cancelled", "Cancelled")]),
                       ],
                       emptyTitle: "No activities yet",
                       emptyDescription: "Calls, emails, meetings, notes and tasks for your accounts, contacts and deals "
                           + "show here. Tap + to add one."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("type", "Kind", .choice(activityTypes)), FieldSpec("due_date", "When", .dateTime),
                FieldSpec("duration_minutes", "Minutes", .integer), FieldSpec("completed_at", "Done on", .dateTime),
            ]),
            SectionSpec("For", [
                FieldSpec("account_name", "Account"), FieldSpec("contact_first_name", "Contact"),
                FieldSpec("contact_last_name", "Contact surname"), FieldSpec("deal_name", "Deal"),
            ]),
            SectionSpec("Notes", [FieldSpec("description", "What happened or needs doing", .multiline)]),
            SectionSpec(nil, [FieldSpec("created_at", "Added", .dateTime)]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("type", "Kind", .choice(activityTypes), bodyKey: "activity_type", required: true,
                          defaultValue: .string("call")),
                FieldSpec("subject", "Subject", required: true, placeholder: "e.g. Call about the renewal"),
                FieldSpec("due_date", "When", .dateTime, bodyKey: "activity_date"),
                FieldSpec("duration_minutes", "Minutes", .integer),
            ]),
            SectionSpec("For", [
                FieldSpec("account_id", "Account",
                          .reference(ReferenceSpec(list: "/api/v2/crm/accounts", valueKey: "id", titleKeys: ["name"],
                                                   subtitleKeys: ["industry", "city"], displayKey: "account_name",
                                                   paging: .pageAndPerPage))),
                FieldSpec("contact_id", "Contact",
                          .reference(ReferenceSpec(list: "/api/v2/crm/contacts", valueKey: "id", titleKeys: ["first_name"],
                                                   subtitleKeys: ["last_name", "account_name"],
                                                   displayKey: "contact_first_name", paging: .pageAndPerPage))),
                FieldSpec("deal_id", "Deal",
                          .reference(ReferenceSpec(list: "/api/v2/crm/deals", valueKey: "id", titleKeys: ["name"],
                                                   subtitleKeys: ["account_name", "stage"], displayKey: "deal_name",
                                                   searchParam: nil, paging: .pageAndPerPage))),
            ], footer: "Link it to an account, a contact or a deal so it shows on their page too."),
            SectionSpec("Notes", [FieldSpec("description", "What happened or needs doing", .multiline)]),
        ], sendOnlyChanges: true),
        actions: [
            ActionSpec("complete", "Mark as done", systemImage: "checkmark.circle", method: .put,
                       path: "\(crmActivitiesBase)/{uuid}/complete",
                       visibleWhen: .field("status", in: ["pending", "planned"]), done: "Marked as done."),
            ActionSpec("cancel", "Cancel it", systemImage: "xmark.circle", method: .put,
                       path: "\(crmActivitiesBase)/{uuid}", confirm: "It stays in the history as cancelled.",
                       destructive: true, visibleWhen: .field("status", in: ["pending", "planned"]),
                       body: ["status": .string("cancelled")], done: "Activity cancelled."),
            ActionSpec("reopen", "Set it to do again", systemImage: "arrow.uturn.backward", method: .put,
                       path: "\(crmActivitiesBase)/{uuid}", visibleWhen: .field("status", in: ["completed", "cancelled"]),
                       body: ["status": .string("planned")], done: "Back on the to-do list."),
        ],
        summary: "Calls, emails, meetings, notes and tasks for your accounts, contacts and deals.")

    // MARK: Partners (`/api/v2/crm/partners`, RBAC `crm_accounts`)

    static let commissionKinds = [Choice("percent", "% of the deal"), Choice("fixed", "Fixed fee per deal")]

    static let referralStatus = StatusStyle(
        tones: ["draft": .neutral, "sent": .info, "accepted": .progress, "declined": .neutral, "won": .success,
                "lost": .neutral, "commission_invoiced": .warning, "commission_paid": .success, "cancelled": .neutral],
        labels: ["sent": "Waiting for the partner", "won": "Won — invoice the commission",
                 "commission_invoiced": "Commission invoiced", "commission_paid": "Commission paid"])

    static let crmPartners = ResourceDescriptor(
        id: "crm.partners", title: "Partners", noun: "partner", systemImage: "person.2.badge.gearshape",
        api: ResourceAPISpec(list: "/api/v2/crm/partners", item: "/api/v2/crm/partners/{uuid}",
                             create: "/api/v2/crm/partners", update: "/api/v2/crm/partners/{uuid}",
                             paging: .none, searchParam: "search", listQuery: ["active": "all"]),
        permissions: ResourcePermissions(module: "crm_accounts"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("offering", "Supplies"), FieldSpec("referrals", "Sent", .integer),
                                  FieldSpec("won", "Won", .integer)],
                       badge: FieldSpec("active", "Status", .status(StatusStyle(
                           tones: ["true": .success, "false": .neutral], labels: ["true": "Active", "false": "Off"]))),
                       trailing: FieldSpec("commission_paid", "Received", .money(currencyKey: "currency", minorUnits: false,
                                                                                 currency: Formatters.defaultCurrency)),
                       emptyTitle: "No partners yet",
                       emptyDescription: "Add the companies you pass work to. The AI suggests them on leads that match "
                           + "what they supply, and you earn the commission.",
                       searchPrompt: "Name, what they supply or category"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("offering", "What they supply", .multiline), FieldSpec("categories", "Categories", .tags),
                FieldSpec("regions", "Regions", .tags), FieldSpec("website", "Website", .url),
            ]),
            SectionSpec("Referrals", [
                FieldSpec("referral_email", "Send referrals to", .email),
                FieldSpec("referral_contact_name", "Contact"),
                FieldSpec("commission_type", "Commission", .choice(commissionKinds)),
                FieldSpec("commission_value", "Rate or amount", .decimal(places: 2)),
                FieldSpec("terms", "Agreement notes", .multiline),
            ]),
            SectionSpec("So far", [
                FieldSpec("referrals", "Referrals sent", .integer), FieldSpec("won", "Won", .integer),
                FieldSpec("commission_paid", "Commission received", .money(currencyKey: "currency", minorUnits: false,
                                                                          currency: Formatters.defaultCurrency)),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Company", required: true, placeholder: "e.g. Bosch"),
                FieldSpec("offering", "What they supply", .multiline,
                          help: "The AI suggests partners whose description matches what a lead wants."),
                FieldSpec("categories", "Categories", .tags, placeholder: "laptops, hardware",
                          help: "Separate them with commas."),
                FieldSpec("regions", "Regions", .tags, placeholder: "UK, Ireland"),
                FieldSpec("website", "Website", .url),
            ]),
            SectionSpec("Referrals", [
                FieldSpec("referral_email", "Send referrals to", .email, placeholder: "partners@company.com"),
                FieldSpec("referral_contact_name", "Contact name"),
                FieldSpec("commission_type", "Commission", .choice(commissionKinds), required: true,
                          defaultValue: .string("percent")),
                FieldSpec("commission_value", "Percent or amount", .decimal(places: 2), required: true,
                          defaultValue: .string("5")),
                FieldSpec("terms", "Agreement notes", .multiline),
                FieldSpec("active", "Active (suggested and available for new referrals)", .bool,
                          defaultValue: .bool(true)),
            ]),
        ]),
        related: [RelatedSpec("Referrals", descriptorID: "crm.referrals", embeddedKey: "referral_list")],
        summary: "Companies you pass work to. They fulfil it; you earn the commission.")

    /// Referrals, shown under a partner (the actions live on the lead and on the partners page).
    static let crmReferrals = ResourceDescriptor(
        id: "crm.referrals", title: "Referrals", noun: "referral", systemImage: "arrowshape.turn.up.right",
        api: ResourceAPISpec(list: "/api/v2/crm/referrals", paging: .none, searchParam: nil),
        permissions: ResourcePermissions(module: "crm_deals"),
        list: ListSpec(title: ["deal_name", "partner_name"],
                       subtitle: [FieldSpec("partner_name", "Partner"), FieldSpec("sent_at", "Sent", .date)],
                       badge: FieldSpec("status", "Status", .status(referralStatus)),
                       trailing: FieldSpec("commission_amount", "Commission",
                                           .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                       filters: [FilterSpec("status", "Status", [
                           Choice("sent", "Waiting for the partner"), Choice("accepted", "Accepted"),
                           Choice("won", "Won"), Choice("commission_invoiced", "Commission invoiced"),
                           Choice("commission_paid", "Commission paid"), Choice("declined", "Declined"),
                       ])],
                       emptyTitle: "No referrals yet",
                       emptyDescription: "Use “Pass to a partner” on a lead or a deal."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("partner_name", "Partner"), FieldSpec("deal_value", "Deal value",
                                                                .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                FieldSpec("commission_amount", "Commission", .money(currencyKey: "currency", minorUnits: false,
                                                                    currency: Formatters.defaultCurrency)),
                FieldSpec("invoice_number", "Commission invoice"), FieldSpec("partner_reference", "Their reference"),
                FieldSpec("partner_notes", "Their notes", .multiline), FieldSpec("message", "Your message", .multiline),
                FieldSpec("sent_at", "Sent", .dateTime), FieldSpec("responded_at", "Answered", .dateTime),
            ]),
        ])

    // MARK: Invoice tax rates (`/api/v2/invoices/tax-rates`, RBAC `tax_rates_config`)

    static let invoiceTaxRates = ResourceDescriptor(
        id: "invoices.tax_rates", title: "Tax rates", noun: "tax rate", systemImage: "percent",
        // No single-rate GET: `/tax-rates/:uuid` would be read as an invoice id, so the row is the record.
        api: ResourceAPISpec(list: "/api/v2/invoices/tax-rates", create: "/api/v2/invoices/tax-rates",
                             update: "/api/v2/invoices/tax-rates/{id}", delete: "/api/v2/invoices/tax-rates/{id}",
                             paging: .none, searchParam: nil, idKeys: ["id", "uuid"]),
        permissions: ResourcePermissions(module: "tax_rates_config"),
        list: ListSpec(title: ["name"], subtitle: [FieldSpec("description", "Note")],
                       badge: FieldSpec("is_default", "Default", .status(StatusStyle(
                           tones: ["true": .brand, "false": .neutral], labels: ["true": "Default", "false": "—"]))),
                       trailing: FieldSpec("rate", "Rate", .percent),
                       emptyTitle: "No tax rates yet",
                       emptyDescription: "Add the VAT or sales tax rates you charge, e.g. Standard 20%. "
                           + "Invoice lines then offer them to pick from."),
        detail: [SectionSpec(nil, [
            FieldSpec("rate", "Rate", .percent), FieldSpec("description", "Note", .multiline),
            FieldSpec("is_default", "Used for new lines", .bool),
        ])],
        form: FormSpec([SectionSpec(nil, [
            FieldSpec("name", "Name", required: true, placeholder: "e.g. Standard"),
            FieldSpec("rate", "Rate (%)", .decimal(places: 3), required: true, placeholder: "20"),
            FieldSpec("description", "Note", .multiline),
            FieldSpec("is_default", "Use it for new invoice lines", .bool),
        ])]),
        summary: "The tax rates invoice lines can use.")

    // MARK: Lead alerts (`/api/v2/crm/leads/notification-settings`; only the owner may change them)

    static let leadAlertsPath = "/api/v2/crm/leads/notification-settings"

    static let leadAlerts = ResourceDescriptor(
        id: "leads.alerts", title: "Lead alerts", noun: "alerts", systemImage: "bell.badge",
        api: ResourceAPISpec(list: leadAlertsPath, item: leadAlertsPath, update: leadAlertsPath, searchParam: nil),
        list: ListSpec(title: ["admin_email"]),
        detail: [
            SectionSpec("Email", [
                FieldSpec("notify_admin", "Email me about new leads", .bool),
                FieldSpec("admin_email", "Send them to", .email),
                FieldSpec("send_confirmation", "Send the customer a confirmation", .bool),
            ]),
            SectionSpec("Telegram", [
                FieldSpec("telegram_enabled", "Telegram alerts", .bool),
                FieldSpec("telegram_chat_id", "Chat id"),
                FieldSpec("telegram_token_hint", "Bot token"),
            ], footer: "Make a bot with @BotFather, add it to your chat, then send a test message."),
        ],
        form: FormSpec([
            SectionSpec("Email", [
                FieldSpec("notify_admin", "Email me about new leads", .bool),
                FieldSpec("admin_email", "Send them to", .email, help: "Leave empty to use the workspace owner's email."),
                FieldSpec("send_confirmation", "Send the customer a confirmation", .bool,
                          help: "The person who sent the enquiry gets an email saying it arrived."),
            ]),
            SectionSpec("Telegram", [
                FieldSpec("telegram_enabled", "Telegram alerts", .bool),
                FieldSpec("telegram_chat_id", "Chat id", placeholder: "-1001234567890"),
                FieldSpec("telegram_bot_token", "Bot token", .secret),
            ], footer: "The bot token is never shown again once saved."),
        ]),
        actions: [
            ActionSpec("test", "Send a test Telegram message", systemImage: "paperplane",
                       path: "\(leadAlertsPath)/test-telegram", done: "Test message sent. Check your Telegram chat."),
        ],
        summary: "Who hears about a new lead the moment it arrives.",
        singleton: true)
}
