import SwiftUI

/// Field service pages beyond the original hand-built ones: maintenance contracts, the parts
/// catalogue and the full site-visit schedule (`/api/v2/field-service`). Jobs, requests, assets,
/// reports and Simpro sync are the app's original screens (`NativeModules.screens`).
extension ModuleGroup {
    static let fieldServiceExtras = ModuleGroup(
        id: "industry.field_service",
        descriptors: [ModuleCatalog.fsContracts, ModuleCatalog.fsContractCoverage, ModuleCatalog.fsContractSites,
                      ModuleCatalog.fsParts, ModuleCatalog.fsJobs],
        resources: ["field_service_parts": ModuleCatalog.fsParts.id],
        screens: ["field_service_contracts": FieldServiceScreens.contracts,
                  "field_service_visits": FieldServiceScreens.visits],
        screen: { id in
            switch id {
            case FieldServiceScreens.contracts: AnyView(ContractsListView())
            case FieldServiceScreens.visits: AnyView(VisitsScheduleView())
            case FieldServiceScreens.jobTypes: AnyView(JobTypesListView())
            default:
                switch NativeScreenRoute.parts(id) {
                case (FieldServiceScreens.jobType, let uuid?): AnyView(JobTypeDetailView(uuid: uuid))
                default: nil
                }
            }
        })
}

/// Screen ids of the field service part (`NativeScreenRoute`).
enum FieldServiceScreens {
    static let contracts = "fs.contracts"
    static let visits = "fs.visits"
    /// Job types and their phase templates (the dashboard's Job Types settings page; no menu key).
    static let jobTypes = "fs.job_types"
    /// One job type: `NativeScreenRoute(FieldServiceScreens.jobType, uuid)`.
    static let jobType = "fs.job_type"
}

extension ModuleCatalog {
    static let fsBase = "/api/v2/field-service"

    // MARK: Contracts

    static let contractStatus = StatusStyle(tones: ["draft": .neutral, "active": .success, "expired": .warning,
                                                    "cancelled": .danger])

    static let contractStatusChoices = [Choice("draft"), Choice("active"), Choice("expired"), Choice("cancelled")]

    /// Simpro's sync state on a record (`simpro_sync_state`).
    static let simproSyncState = StatusStyle(tones: ["synced": .success, "pending": .warning, "error": .danger,
                                                     "local_only": .neutral],
                                             labels: ["synced": "In Simpro", "pending": "Waiting to send to Simpro",
                                                      "error": "Simpro sync failed", "local_only": "Only in this app"])

    static let fsContracts = ResourceDescriptor(
        id: "fs.contracts", title: "Contracts", noun: "contract", systemImage: "doc.text.magnifyingglass",
        api: .crud("\(fsBase)/contracts"),
        permissions: ResourcePermissions(module: "fs_contracts"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("contract_number", "Number"), FieldSpec("customer_name", "Customer"),
                                  FieldSpec("end_date", "Ends", .date)],
                       badge: FieldSpec("status", "Status", .status(contractStatus)),
                       trailing: FieldSpec("annual_value", "A year", .money(currencyKey: "currency", minorUnits: false,
                                                                           currency: Formatters.defaultCurrency)),
                       filters: [FilterSpec("status", "Status", contractStatusChoices),
                                 FilterSpec("expiring_within_days", "Renewal", [Choice("90", "Ends within 90 days")])],
                       emptyTitle: "No contracts yet",
                       emptyDescription: "Maintenance contracts set the service levels the desk works to.",
                       searchPrompt: "Contract name or number"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("contract_number", "Contract number"), FieldSpec("customer_name", "Customer"),
                FieldSpec("status", "Status", .status(contractStatus)),
                FieldSpec("description", "Description", .multiline),
            ]),
            SectionSpec("Term", [
                FieldSpec("start_date", "Starts", .date), FieldSpec("end_date", "Ends", .date),
                FieldSpec("days_to_expiry", "Days until it ends", .integer),
                FieldSpec("extension_months", "Can be extended by (months)", .integer),
            ], footer: "No end date means the contract runs until it is cancelled."),
            SectionSpec("Value", [
                FieldSpec("annual_value", "A year", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
            ]),
            SectionSpec("Service levels", [
                FieldSpec("response_hours", "Respond within (hours)", .integer),
                FieldSpec("resolve_hours", "Fix within (hours)", .integer),
                FieldSpec("quote_turnaround_hours", "Quote within (hours)", .integer),
                FieldSpec("covers_out_of_hours", "24/7 cover", .bool),
            ], footer: "New service requests for this customer copy these targets."),
            SectionSpec("Covers", [
                FieldSpec("asset_count", "Assets", .integer), FieldSpec("site_count", "Sites", .integer),
            ]),
            SectionSpec("Notes", [FieldSpec("notes", "Notes", .multiline)]),
            SectionSpec("Simpro", [
                FieldSpec("simpro_sync_state", "Sync", .status(simproSyncState)), FieldSpec("simpro_id", "Simpro ID"),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("customer_uuid", "Customer",
                          .reference(ReferenceSpec(list: "/api/v2/customers", titleKeys: ["company_name", "email"],
                                                   subtitleKeys: ["first_name", "last_name"], displayKey: "customer_name",
                                                   paging: .pageAndCamelPerPage)),
                          required: true),
                FieldSpec("name", "Contract name", required: true, placeholder: "e.g. Chillers PPM 2026"),
                FieldSpec("contract_number", "Contract number"),
                FieldSpec("status", "Status", .choice(contractStatusChoices), required: true,
                          defaultValue: .string("active")),
                FieldSpec("description", "Description", .multiline),
            ]),
            SectionSpec("Term", [
                FieldSpec("start_date", "Starts", .date), FieldSpec("end_date", "Ends", .date,
                                                                   help: "Leave empty when it runs until cancelled."),
                FieldSpec("extension_months", "Can be extended by (months)", .integer),
            ]),
            SectionSpec("Value", [
                FieldSpec("annual_value", "Value a year", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                FieldSpec("currency", "Currency", .choice([Choice("GBP", "Pounds (GBP)"), Choice("EUR", "Euros (EUR)"),
                                                           Choice("USD", "US dollars (USD)")]),
                          defaultValue: .string(Formatters.defaultCurrency)),
            ]),
            SectionSpec("Service levels", [
                FieldSpec("response_hours", "Respond within (hours)", .integer),
                FieldSpec("resolve_hours", "Fix within (hours)", .integer),
                FieldSpec("quote_turnaround_hours", "Quote within (hours)", .integer),
                FieldSpec("covers_out_of_hours", "24/7 cover", .bool),
            ]),
            SectionSpec("Notes", [FieldSpec("notes", "Notes", .multiline)]),
        ]),
        related: [
            RelatedSpec("Plant covered", descriptorID: "fs.contract_coverage", embeddedKey: "coverage"),
            RelatedSpec("Sites covered", descriptorID: "fs.contract_sites", embeddedKey: "sites"),
        ],
        summary: "Maintenance contracts: term, value, the service levels the desk works to and the plant they cover.")

    /// One kind of plant on a contract (`coverage` in `GET /contracts/:uuid`); only shown inside a contract.
    static let fsContractCoverage = ResourceDescriptor(
        id: "fs.contract_coverage", title: "Plant covered", noun: "kind of plant", systemImage: "fan",
        api: ResourceAPISpec(list: "\(fsBase)/contracts", paging: .none, searchParam: nil, idKeys: ["asset_type"]),
        list: ListSpec(title: ["asset_type"],
                       subtitle: [FieldSpec("avg_condition", "Average condition", .decimal(places: 1)),
                                  FieldSpec("needs_replacement", "Needing replacement", .integer)],
                       trailing: FieldSpec("assets", "Assets", .integer)))

    /// A site on a contract (`sites` in `GET /contracts/:uuid`), opened read-only from the contract.
    static let fsContractSites = ResourceDescriptor(
        id: "fs.contract_sites", title: "Sites", noun: "site", systemImage: "building.2",
        api: ResourceAPISpec(list: "\(fsBase)/sites", item: "\(fsBase)/sites/{uuid}", searchParam: "search"),
        list: ListSpec(title: ["name"], subtitle: [FieldSpec("city", "Town"), FieldSpec("postal_code", "Postcode")],
                       trailing: FieldSpec("assets", "Assets", .integer)),
        detail: [
            SectionSpec(nil, [FieldSpec("customer_name", "Customer"), FieldSpec("address", "Address", .multiline)]),
            SectionSpec("Contact", [FieldSpec("contact_name", "Name"), FieldSpec("contact_phone", "Phone", .phone)]),
            SectionSpec("Getting in", [FieldSpec("access_notes", "Access notes", .multiline)]),
            SectionSpec(nil, [FieldSpec("job_count", "Jobs here", .integer)]),
        ])

    // MARK: Jobs (create and edit; the list and the job itself are hand-built screens)

    static let jobPriorityChoices = [Choice("low", "Low"), Choice("normal", "Normal"), Choice("high", "High"),
                                     Choice("urgent", "Urgent")]

    /// The job form (`POST /jobs`, `PUT /jobs/:uuid` — only what changed is sent).
    static let fsJobs = ResourceDescriptor(
        id: "fs.jobs", title: "Jobs", noun: "job", systemImage: "wrench.and.screwdriver",
        api: ResourceAPISpec(list: "\(fsBase)/jobs", item: "\(fsBase)/jobs/{uuid}", create: "\(fsBase)/jobs",
                             update: "\(fsBase)/jobs/{uuid}", searchParam: "search"),
        permissions: ResourcePermissions(module: "fs_jobs"),
        list: ListSpec(title: ["title"], subtitle: [FieldSpec("job_number", "Number"), FieldSpec("customer_name", "Customer")],
                       badge: FieldSpec("status", "Status")),
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("title", "Title", required: true, placeholder: "e.g. AC repair — Ward 5"),
                FieldSpec("job_type_uuid", "Job type",
                          .reference(ReferenceSpec(list: "\(fsBase)/job-types", subtitleKeys: ["description"],
                                                   displayKey: "job_type_name", searchParam: nil)),
                          help: "A job type copies its phases onto a new job."),
                FieldSpec("priority", "Priority", .choice(jobPriorityChoices), required: true,
                          defaultValue: .string("normal")),
            ]),
            SectionSpec("Customer and site", [
                FieldSpec("customer_uuid", "Customer",
                          .reference(ReferenceSpec(list: "/api/v2/customers", titleKeys: ["company_name", "email"],
                                                   subtitleKeys: ["first_name", "last_name"], displayKey: "customer_name",
                                                   paging: .pageAndCamelPerPage))),
                FieldSpec("site_uuid", "Site",
                          .reference(ReferenceSpec(list: "\(fsBase)/sites", subtitleKeys: ["customer_name", "address"],
                                                   displayKey: "site_name", paging: .pageAndPerPage))),
                FieldSpec("product_uuid", "Product (the item serviced)",
                          .reference(ReferenceSpec(list: "/api/v2/products", subtitleKeys: ["sku"],
                                                   displayKey: "product_name", searchParam: nil, paging: .limitOffset))),
                FieldSpec("product_ref", "Unit serial or reference"),
                FieldSpec("service_address", "Service address", placeholder: "Where the engineer visits"),
                FieldSpec("service_postcode", "Postcode"),
            ]),
            SectionSpec("Planning", [
                FieldSpec("service_manager_uuid", "Service manager",
                          .reference(ReferenceSpec(list: "\(fsBase)/engineers", titleKeys: ["name", "email"],
                                                   subtitleKeys: ["email"], displayKey: "service_manager_name")),
                          help: "Leave empty on a new job to manage it yourself."),
                FieldSpec("due_date", "Due date", .date),
                FieldSpec("customer_reference", "Customer reference or PO"),
                FieldSpec("hourly_rate", "Hourly rate", .decimal(places: 2),
                          help: "Leave empty to use the job type's rate."),
                FieldSpec("estimated_hours", "Estimated hours", .decimal(places: 2)),
            ]),
            SectionSpec(nil, [
                FieldSpec("description", "What needs doing", .multiline),
                FieldSpec("notes", "Internal notes", .multiline),
            ]),
        ], sendOnlyChanges: true),
        summary: "Service jobs: phases, visits, parts and invoicing.")

    // MARK: Parts

    static let partActive = StatusStyle(tones: ["true": .success, "false": .neutral],
                                        symbols: ["true": "checkmark.circle", "false": "pause.circle"],
                                        labels: ["true": "Active", "false": "Not in use"])

    private static let partMoney = FieldKind.money(currencyKey: nil, minorUnits: false, currency: Formatters.defaultCurrency)

    static let fsParts = ResourceDescriptor(
        id: "fs.parts", title: "Parts", noun: "part", systemImage: "shippingbox",
        api: ResourceAPISpec(list: "\(fsBase)/parts", item: "\(fsBase)/parts/{uuid}", create: "\(fsBase)/parts",
                             update: "\(fsBase)/parts/{uuid}", delete: "\(fsBase)/parts/{uuid}",
                             searchParam: "search", listQuery: ["include_inactive": "true"]),
        permissions: ResourcePermissions(module: "fs_parts"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("sku", "SKU"), FieldSpec("category", "Category"),
                                  FieldSpec("stock_quantity", "In stock", .decimal(places: 2))],
                       badge: FieldSpec("is_active", "Status", .status(partActive)),
                       trailing: FieldSpec("unit_price", "Sell price", partMoney),
                       filters: [FilterSpec("is_active", "Status", [Choice("true", "Active only"),
                                                                    Choice("false", "Not in use only")])],
                       emptyTitle: "No parts yet",
                       emptyDescription: "The parts and products you fit on jobs. Engineers pick from this list.",
                       searchPrompt: "Name, SKU or category"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("sku", "Part code (SKU)"), FieldSpec("category", "Category"),
                FieldSpec("is_active", "Status", .status(partActive)),
                FieldSpec("description", "Description", .multiline),
            ]),
            SectionSpec("Prices", [
                FieldSpec("unit_cost", "Cost (what you pay)", partMoney),
                FieldSpec("unit_price", "Sell price (what the customer pays)", partMoney),
                FieldSpec("tax_rate", "VAT %", .decimal(places: 2)),
            ]),
            SectionSpec("Stock", [
                FieldSpec("stock_quantity", "In stock", .decimal(places: 2)),
                FieldSpec("reorder_level", "Reorder at", .decimal(places: 2)),
            ], footer: "Stock goes down when a part line on a job is approved."),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Part name", required: true, placeholder: "e.g. Compressor 1HP"),
                FieldSpec("sku", "Part code (SKU)", placeholder: "e.g. CMP-100", help: "Your own reference code."),
                FieldSpec("category", "Category", placeholder: "e.g. spares"),
                FieldSpec("description", "Description", .multiline),
            ]),
            SectionSpec("Prices", [
                FieldSpec("unit_cost", "Cost (what you pay)", partMoney),
                FieldSpec("unit_price", "Sell price (what the customer pays)", partMoney),
                FieldSpec("tax_rate", "VAT %", .decimal(places: 2), defaultValue: .number(20)),
            ]),
            SectionSpec("Stock", [
                FieldSpec("stock_quantity", "In stock", .decimal(places: 2), help: "How many you hold now."),
                FieldSpec("reorder_level", "Reorder at", .decimal(places: 2), help: "Warn when stock drops to this."),
            ]),
            SectionSpec(nil, [
                FieldSpec("is_active", "In use", .bool, help: "Parts not in use aren't offered on jobs.",
                          defaultValue: .bool(true)),
            ]),
        ]),
        summary: "Your parts and products catalogue for jobs. Job lines keep their own copy if a part is deleted.")
}
