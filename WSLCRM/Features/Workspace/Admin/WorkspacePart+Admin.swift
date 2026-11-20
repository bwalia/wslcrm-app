import SwiftUI

/// Workspace settings and the people in it: `namespace` (My Workspace and everything under it) and
/// `roles` (roles and permissions).
extension WorkspacePart {
    static let admin = WorkspacePart(
        descriptors: [WorkspaceAdminCatalog.paymentMethods, WorkspaceAdminCatalog.aiProviders,
                      WorkspaceAdminCatalog.mailAccounts],
        screens: ["namespace": WorkspaceScreen.home, "roles": WorkspaceScreen.roles],
        screen: { id in
            switch id {
            case WorkspaceScreen.home: AnyView(WorkspaceHomeView())
            case WorkspaceScreen.settings: AnyView(WorkspaceSettingsView())
            case WorkspaceScreen.members: AnyView(WorkspaceMembersView())
            case WorkspaceScreen.roles: AnyView(RoleListView())
            case WorkspaceScreen.email: AnyView(MailSettingsView())
            case WorkspaceScreen.menuConfig: AnyView(MenuConfigView())
            case WorkspaceAdminCatalog.aiScreen: AnyView(WorkspaceAIProvidersView())
            default: nil
            }
        })
}

/// The described resources of the admin part: how customers pay the workspace, its AI models and
/// its email accounts.
enum WorkspaceAdminCatalog {
    /// The AI models screen (hand-built: a test shows what the model answered).
    static let aiScreen = "workspace.aiModels"

    // MARK: Getting paid (`/api/v2/namespace/payment-methods`)

    static let paymentBase = "/api/v2/namespace/payment-methods"

    static let paymentKinds = [
        Choice("bank_transfer", "Bank transfer"), Choice("card", "Card"), Choice("cheque", "Cheque"),
        Choice("other", "Other"),
    ]

    static let activeStyle = StatusStyle(tones: ["true": .success, "false": .neutral],
                                         symbols: ["true": "checkmark.circle", "false": "pause.circle"],
                                         labels: ["true": "In use", "false": "Switched off"])

    static let defaultStyle = StatusStyle(tones: ["true": .brand, "false": .neutral],
                                          labels: ["true": "Default", "false": ""])

    static let paymentMethods = ResourceDescriptor(
        id: "workspace.payment_methods", title: "Getting paid", noun: "payment method", systemImage: "banknote",
        api: ResourceAPISpec(list: paymentBase, create: paymentBase, update: "\(paymentBase)/{uuid}",
                             delete: "\(paymentBase)/{uuid}", paging: .none, searchParam: nil,
                             listQuery: ["include_inactive": "true"], idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: "namespace"),
        list: ListSpec(title: ["label", "bank_name", "kind"],
                       subtitle: [FieldSpec("kind", "Kind", .choice(paymentKinds)),
                                  FieldSpec("account_name", "Account name"), FieldSpec("currency", "Currency")],
                       badge: FieldSpec("is_active", "In use", .status(activeStyle)),
                       trailing: FieldSpec("is_default", "Default", .status(defaultStyle)),
                       emptyTitle: "No payment methods yet",
                       emptyDescription: "How customers pay you: your bank details, card, cheque. The ones you choose "
                           + "are printed on your invoices and quotes."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("label", "Name"), FieldSpec("kind", "Kind", .choice(paymentKinds)),
                FieldSpec("currency", "Currency"), FieldSpec("is_default", "Default", .bool),
                FieldSpec("show_on_documents", "Printed on invoices and quotes", .bool),
                FieldSpec("is_active", "In use", .bool),
            ]),
            SectionSpec("Bank details", [
                FieldSpec("account_name", "Account name"), FieldSpec("bank_name", "Bank"),
                FieldSpec("sort_code", "Sort code"), FieldSpec("account_number", "Account number"),
                FieldSpec("iban", "IBAN"), FieldSpec("swift_bic", "SWIFT / BIC"),
            ]),
            SectionSpec("Instructions", [FieldSpec("instructions", "Instructions for the customer", .multiline)]),
            SectionSpec(nil, [FieldSpec("created_at", "Added", .dateTime), FieldSpec("updated_at", "Changed", .dateTime)]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("kind", "Kind", .choice(paymentKinds), required: true, defaultValue: .string("bank_transfer")),
                FieldSpec("label", "Name", placeholder: "e.g. Barclays GBP account",
                          help: "Leave empty and a name is made for you."),
                FieldSpec("currency", "Currency", placeholder: "GBP", help: "Three letters, such as GBP.",
                          defaultValue: .string("GBP")),
            ]),
            SectionSpec("Bank details", [
                FieldSpec("account_name", "Account name", help: "Needed for a bank transfer."),
                FieldSpec("bank_name", "Bank"),
                FieldSpec("sort_code", "Sort code", placeholder: "6 digits, e.g. 20-00-00"),
                FieldSpec("account_number", "Account number", placeholder: "6 to 10 digits"),
                FieldSpec("iban", "IBAN", help: "Instead of a sort code and account number, for payments from abroad."),
                FieldSpec("swift_bic", "SWIFT / BIC", help: "8 or 11 characters."),
            ], footer: "Only for a bank transfer. A bank transfer needs the account name and either a sort code "
                + "with an account number, or an IBAN."),
            SectionSpec("Instructions", [
                FieldSpec("instructions", "Instructions for the customer", .multiline,
                          placeholder: "e.g. Use your invoice number as the reference"),
            ]),
            SectionSpec(nil, [
                FieldSpec("show_on_documents", "Print on invoices and quotes", .bool, defaultValue: .bool(true)),
                FieldSpec("is_default", "Default way to pay", .bool),
                FieldSpec("is_active", "In use", .bool, defaultValue: .bool(true)),
            ]),
        ], sendOnlyChanges: true),
        actions: [
            ActionSpec("default", "Make this the default", systemImage: "star", method: .put,
                       path: "\(paymentBase)/{uuid}", visibleWhen: .field("is_default", notIn: ["true"]),
                       body: ["is_default": .bool(true)], done: "This is now the default way to pay."),
            ActionSpec("show", "Print on invoices and quotes", systemImage: "doc.text", method: .put,
                       path: "\(paymentBase)/{uuid}", visibleWhen: .field("show_on_documents", notIn: ["true"]),
                       body: ["show_on_documents": .bool(true)], done: "It’s now printed on invoices and quotes."),
            ActionSpec("hide", "Don’t print on invoices and quotes", systemImage: "doc.text.magnifyingglass",
                       method: .put, path: "\(paymentBase)/{uuid}", visibleWhen: .field("show_on_documents", in: ["true"]),
                       body: ["show_on_documents": .bool(false)], done: "It’s no longer printed on invoices and quotes."),
            ActionSpec("deactivate", "Switch off", systemImage: "pause.circle", method: .put,
                       path: "\(paymentBase)/{uuid}",
                       confirm: "Customers won’t be shown this way to pay any more. You can switch it on again later.",
                       visibleWhen: .field("is_active", in: ["true"]), body: ["is_active": .bool(false)],
                       done: "Switched off."),
            ActionSpec("activate", "Switch on", systemImage: "play.circle", method: .put,
                       path: "\(paymentBase)/{uuid}", visibleWhen: .field("is_active", notIn: ["true"]),
                       body: ["is_active": .bool(true)], done: "Switched on."),
        ],
        summary: "How customers pay you. A method an invoice already uses is switched off instead of deleted, "
            + "so old invoices still show it. The workspace owners get an email about every change.")

    // MARK: AI models (`/api/v2/namespace/ai-providers`)

    static let aiBase = "/api/v2/namespace/ai-providers"

    static let providerTypes = [
        Choice("platform", "Platform model (self-hosted — same as the chat assistant)"),
        Choice("anthropic", "Anthropic (Claude)"), Choice("openai", "OpenAI"), Choice("gemini", "Google Gemini"),
        Choice("azure_openai", "Azure OpenAI"), Choice("mistral", "Mistral"),
        Choice("openai_compatible", "OpenAI-compatible (LM Studio, vLLM, llama.cpp, LocalAI…)"),
        Choice("ollama", "Ollama"), Choice("jobshout", "JobShout link"),
    ]

    static let enabledStyle = StatusStyle(tones: ["true": .success, "false": .neutral],
                                          labels: ["true": "On", "false": "Off"])

    static let aiProviders = ResourceDescriptor(
        id: "workspace.ai_providers", title: "AI models", noun: "AI model", systemImage: "cpu",
        api: ResourceAPISpec(list: aiBase, item: "\(aiBase)/{uuid}", create: aiBase, update: "\(aiBase)/{uuid}",
                             delete: "\(aiBase)/{uuid}", paging: .none, searchParam: nil, idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: "namespace"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("provider_type", "Provider", .choice(providerTypes)),
                                  FieldSpec("default_model", "Model")],
                       badge: FieldSpec("enabled", "On", .status(enabledStyle)),
                       emptyTitle: "No AI models yet",
                       emptyDescription: "Connect a cloud AI (Claude, OpenAI, Gemini…), a model on your own computer, "
                           + "or a JobShout link. Keys go in and are never shown again."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("provider_type", "Provider", .choice(providerTypes)), FieldSpec("base_url", "Address", .url),
                FieldSpec("default_model", "Model"), FieldSpec("models", "Other models", .tags),
                FieldSpec("username", "Username"), FieldSpec("options.deployment", "Azure deployment"),
                FieldSpec("enabled", "On", .bool), FieldSpec("is_local", "Runs on your own computer", .bool),
                FieldSpec("options.assistant", "Runs the AI assistant", .bool),
            ]),
            SectionSpec("Key", [FieldSpec("has_secret", "Key saved", .bool), FieldSpec("secret_hint", "Key ends")]),
            SectionSpec("Cost", [
                FieldSpec("input_cost_per_mtok", "Input, per million tokens", .decimal(places: 4)),
                FieldSpec("output_cost_per_mtok", "Output, per million tokens", .decimal(places: 4)),
            ]),
            SectionSpec("Last check", [
                FieldSpec("last_tested_at", "Tested", .dateTime), FieldSpec("last_error", "Problem", .multiline),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true, placeholder: "e.g. Claude for the office"),
                FieldSpec("provider_type", "Provider", .choice(providerTypes), required: true,
                          defaultValue: .string("anthropic")),
                FieldSpec("default_model", "Model", placeholder: "e.g. claude-sonnet-4-5",
                          help: "For Azure OpenAI, the deployment name works here too."),
                FieldSpec("models", "Other models", .tags, help: "Separate with commas."),
            ]),
            SectionSpec("Connection", [
                FieldSpec("base_url", "Address", .url, placeholder: "https://…",
                          help: "Needed for Azure OpenAI, OpenAI-compatible servers and JobShout."),
                FieldSpec("secret", "API key", .secret, help: "Leave blank to keep the saved key."),
                FieldSpec("username", "Username", help: "Needed for a JobShout link."),
                FieldSpec("options.deployment", "Azure deployment", help: "Azure OpenAI only."),
            ]),
            SectionSpec("Cost", [
                FieldSpec("input_cost_per_mtok", "Input, per million tokens", .decimal(places: 4)),
                FieldSpec("output_cost_per_mtok", "Output, per million tokens", .decimal(places: 4)),
            ], footer: "Used to estimate what AI costs on the Activity page."),
            SectionSpec(nil, [
                FieldSpec("enabled", "On", .bool, defaultValue: .bool(true)),
                FieldSpec("is_local", "Runs on your own computer", .bool),
                FieldSpec("options.assistant", "Runs the AI assistant", .bool,
                          help: "Only one model runs the assistant. It must be able to use tools."),
            ]),
        ], sendOnlyChanges: true),
        summary: "AI providers this workspace can use. Keys go in and are never shown again.")

    // MARK: Email accounts (`/api/v2/namespace/mail-accounts`)

    static let mailBase = "/api/v2/namespace/mail-accounts"

    static let mailSecurity = [Choice("starttls", "STARTTLS"), Choice("ssl", "SSL/TLS"), Choice("none", "None")]

    static let mailAccounts = ResourceDescriptor(
        id: "workspace.mail_accounts", title: "Email accounts", noun: "email account", systemImage: "envelope",
        api: ResourceAPISpec(list: mailBase, item: "\(mailBase)/{uuid}", create: mailBase, update: "\(mailBase)/{uuid}",
                             delete: "\(mailBase)/{uuid}", paging: .none, searchParam: nil, listKey: "data.accounts",
                             idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: "namespace"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("from_email", "Sends as", .email), FieldSpec("host", "Server")],
                       badge: FieldSpec("enabled", "On", .status(enabledStyle)),
                       trailing: FieldSpec("is_default", "Default", .status(defaultStyle)),
                       emptyTitle: "No email accounts yet",
                       emptyDescription: "Until you add one, emails go out from the platform's own server."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("from_email", "Sends as", .email), FieldSpec("from_name", "Sender name"),
                FieldSpec("reply_to", "Replies go to", .email), FieldSpec("enabled", "On", .bool),
                FieldSpec("is_default", "Default account", .bool),
            ]),
            SectionSpec("Server", [
                FieldSpec("host", "Server"), FieldSpec("port", "Port", .integer),
                FieldSpec("security", "Security", .choice(mailSecurity)), FieldSpec("username", "Username"),
                FieldSpec("has_password", "Password saved", .bool),
            ]),
            SectionSpec("Last test", [
                FieldSpec("last_tested_at", "Tested", .dateTime), FieldSpec("last_error", "Problem", .multiline),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true, placeholder: "e.g. Sales mailbox"),
                FieldSpec("from_email", "Sends as", .email, required: true, placeholder: "sales@yourcompany.co.uk"),
                FieldSpec("from_name", "Sender name", placeholder: "e.g. Acme Sales"),
                FieldSpec("reply_to", "Replies go to", .email),
            ]),
            SectionSpec("Server", [
                FieldSpec("host", "Server", required: true, placeholder: "smtp.example.com"),
                FieldSpec("port", "Port", .integer, required: true, defaultValue: .number(587)),
                FieldSpec("security", "Security", .choice(mailSecurity), required: true,
                          defaultValue: .string("starttls")),
                FieldSpec("username", "Username"),
                FieldSpec("password", "Password", .secret, help: "Leave blank to keep the saved password."),
            ], footer: "Your email provider lists these. Port 587 with STARTTLS is the most common."),
            SectionSpec(nil, [
                FieldSpec("enabled", "On", .bool, defaultValue: .bool(true)),
                FieldSpec("is_default", "Default account", .bool,
                          help: "Emails without their own account go out from the default one."),
            ]),
        ], sendOnlyChanges: true),
        actions: [
            ActionSpec("test", "Send a test email", systemImage: "paperplane", path: "\(mailBase)/{uuid}/test",
                       inputs: [FieldSpec("to", "Send it to", .email, required: true)],
                       done: "Test email sent. Check that inbox."),
            ActionSpec("default", "Make this the default", systemImage: "star", path: "\(mailBase)/{uuid}/default",
                       visibleWhen: .field("is_default", notIn: ["true"]),
                       done: "Emails without their own account now go out from this one."),
            ActionSpec("forget_password", "Remove the saved password", systemImage: "key.slash", method: .put,
                       path: "\(mailBase)/{uuid}", confirm: "Sending stops working if the server needs a password.",
                       destructive: true, visibleWhen: .field("has_password", in: ["true"]),
                       body: ["password": .string("")], done: "The password was removed."),
        ],
        summary: "Your own mail servers. If the default account is deleted, the next one becomes the default.")
}
