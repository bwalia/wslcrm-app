import SwiftUI

/// Tax (Self Assessment with HMRC), VAT and bookkeeping. Most of these pages are workflows (uploads that
/// are read and sorted on the server, the File My Tax wizard, the tax assistant chat, VAT returns,
/// double-entry bookkeeping), so they are hand-built screens under `Features/Tax` and
/// `Features/Accounting`; lists that are plain records use the module kit.
///
/// Screen ids may carry one parameter after a colon (`tax.income:employment`), so a screen can open
/// another with an id without a route type of its own.
extension ModuleGroup {
    static let tax = ModuleGroup(
        id: "tax",
        descriptors: ModuleCatalog.taxDescriptors,
        reports: [],
        resources: [:],
        screens: [
            "tax": "tax.home",
            "tax_bank_accounts": "tax.bank_accounts",
            "tax_statements": "tax.statements",
            "tax_transactions": "tax.transactions",
            "tax_categories": "tax.categories",
            "tax_reports": "tax.reports",
            "tax_hmrc": "tax.hmrc",
            "tax_file": "tax.file",
            "tax_agent": "tax.agent",
            "tax_filing_requests": "tax.filing_requests",
            "tax_my_income": "tax.my_income",
            "tax_income_types": "tax.income_types",
            "tax_vat": "tax.vat",
            "tax_vat_clients": "tax.vat_clients",
            "accounting": "accounting.home",
        ],
        screen: { id in TaxScreens.view(id) })
}

/// Draws the tax group's hand-built screens.
enum TaxScreens {
    @MainActor
    static func view(_ id: String) -> AnyView? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let parameter = parts.count > 1 ? parts[1] : nil
        switch parts[0] {
        case "tax.home": return AnyView(TaxHomeView())
        case "tax.bank_accounts": return AnyView(TaxBankAccountsView())
        case "tax.statements": return AnyView(TaxStatementsView())
        case "tax.transactions": return AnyView(TaxTransactionsView())
        case "tax.categories": return AnyView(TaxCategoriesView())
        case "tax.reports": return AnyView(TaxReportsView())
        case "tax.hmrc": return AnyView(TaxHMRCSettingsView())
        case "tax.file": return AnyView(FileMyTaxView(taxYear: parameter))
        case "tax.review": return AnyView(TaxTransactionReviewView(taxYear: parameter ?? TaxYear.filing()))
        case "tax.agent": return AnyView(TaxAgentChatView(taxYear: parameter))
        case "tax.filing_requests": return AnyView(TaxFilingRequestsView())
        case "tax.my_income": return AnyView(MyIncomeView(taxYear: parameter))
        case "tax.income":
            // "tax.income:<type key>|<tax year>"
            let bits = (parameter ?? "").split(separator: "|").map(String.init)
            guard let key = bits.first, !key.isEmpty else { return nil }
            return AnyView(IncomeTypeView(key: key, year: bits.count > 1 ? bits[1] : TaxYear.filing()))
        case "tax.income_types": return AnyView(IncomeTypesAdminView())
        case "tax.vat": return AnyView(VATView(context: VATContext(parameter: parameter)))
        case "tax.vat_clients": return AnyView(VATClientsView())
        case "accounting.home": return AnyView(AccountingHomeView())
        case "accounting.bank": return AnyView(AccountingBankView())
        case "accounting.expenses": return AnyView(AccountingExpensesView())
        case "accounting.reports": return AnyView(AccountingReportsView())
        case "accounting.money": return AnyView(MoneyInOutView(moneyIn: parameter != "out"))
        case "accounting.sales_ledger": return AnyView(SalesLedgerView())
        case "accounting.purchase_ledger": return AnyView(PurchaseLedgerView())
        default: return nil
        }
    }
}

extension ModuleCatalog {
    static let taxDescriptors: [ResourceDescriptor] = [taxCategories, accountingAccounts, accountingJournal,
                                                       accountingJournalLines, accountingExpenses]

    static let taxCategoryTypes = [Choice("expense", "Expense"), Choice("income", "Income")]

    /// `GET/POST /api/v2/tax/categories`, `PUT/DELETE /api/v2/tax/categories/{uuid}` (RBAC `tax_categories`).
    /// Shared categories (`is_global`) are read only; the list itself is `TaxCategoriesView`.
    static let taxCategories = ResourceDescriptor(
        id: "tax.categories", title: "Categories", noun: "category", systemImage: "tag",
        api: ResourceAPISpec(list: "/api/v2/tax/categories", create: "/api/v2/tax/categories",
                             update: "/api/v2/tax/categories/{uuid}", delete: "/api/v2/tax/categories/{uuid}",
                             paging: .none, searchParam: nil, idKeys: ["uuid", "id"]),
        permissions: ResourcePermissions(module: "tax_categories"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("category_type", "Type", .choice(taxCategoryTypes)),
                                  FieldSpec("description", "Description")],
                       emptyTitle: "No categories found"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("category_type", "Type", .choice(taxCategoryTypes)),
                FieldSpec("is_deductible", "Allowable for tax", .bool),
                FieldSpec("non_business", "Left off the return", .bool),
                FieldSpec("is_global", "Shared (read only)", .bool),
                FieldSpec("description", "Description", .multiline),
                FieldSpec("key", "Key"),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true, placeholder: "e.g. Office supplies, Consulting income"),
                FieldSpec("category_type", "Type", .choice(taxCategoryTypes), required: true,
                          defaultValue: .string("expense")),
                FieldSpec("is_deductible", "Allowable for tax", .bool, help: "Can it be claimed as a business expense?",
                          defaultValue: .bool(false)),
                FieldSpec("description", "Description", .multiline,
                          placeholder: "Optional notes about what belongs in this category"),
            ]),
        ]),
        summary: "Categories your transactions are sorted into.",
        writableWhen: .field("is_global", notIn: ["true"]))
}

// MARK: - Bookkeeping (`/api/v2/accounting`, JSON bodies, `page` + `per_page`, paging under `meta`)

extension ModuleCatalog {
    static let accountingBase = "/api/v2/accounting"

    static let accountTypes = [Choice("asset", "Asset"), Choice("liability", "Liability"), Choice("equity", "Equity"),
                               Choice("revenue", "Revenue"), Choice("expense", "Expense")]

    private static let pounds = FieldKind.money(currencyKey: "currency", minorUnits: false, currency: "GBP")

    /// The chart of accounts. Accounts with postings can't be deleted (the server says why).
    static let accountingAccounts = ResourceDescriptor(
        id: "accounting.accounts", title: "Chart of accounts", noun: "account", systemImage: "list.number",
        api: .crud("\(accountingBase)/accounts", searchParam: nil),
        permissions: ResourcePermissions(module: "accounting"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("code", "Code"), FieldSpec("account_type", "Type", .choice(accountTypes))],
                       badge: FieldSpec("is_active", "Status", .choice([Choice("true", "Active"), Choice("false", "Inactive")])),
                       trailing: FieldSpec("current_balance", "Balance", pounds),
                       filters: [FilterSpec("type", "Type", accountTypes),
                                 FilterSpec("is_active", "Status", [Choice("true", "Active"), Choice("false", "Inactive")])],
                       emptyTitle: "No accounts",
                       emptyDescription: "Set up your chart of accounts to start bookkeeping: add a bank account (code 1000) "
                           + "and a VAT account (code 2100) first."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("code", "Code"), FieldSpec("account_type", "Type", .choice(accountTypes)),
                FieldSpec("sub_type", "Sub-type"), FieldSpec("normal_balance", "Normal balance",
                                                             .choice([Choice("debit", "Debit"), Choice("credit", "Credit")])),
                FieldSpec("description", "Description", .multiline), FieldSpec("is_active", "Active", .bool),
                FieldSpec("is_system", "Built in", .bool),
            ]),
            SectionSpec("Balance", [
                FieldSpec("current_balance", "Balance", pounds), FieldSpec("total_debits", "Total debits", pounds),
                FieldSpec("total_credits", "Total credits", pounds), FieldSpec("opening_balance", "Opening balance", pounds),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("code", "Code", required: true, placeholder: "e.g. 4100"),
                FieldSpec("name", "Name", required: true, placeholder: "Account name"),
                FieldSpec("account_type", "Type", .choice(accountTypes), required: true, defaultValue: .string("expense")),
                FieldSpec("parent_id", "Parent account (optional)",
                          .reference(ReferenceSpec(list: "\(accountingBase)/accounts", valueKey: "id", titleKeys: ["name"],
                                                   subtitleKeys: ["code"], searchParam: nil))),
                FieldSpec("description", "Description", .multiline, placeholder: "Optional description"),
                FieldSpec("is_active", "Active", .bool, defaultValue: .bool(true)),
            ]),
        ]),
        summary: "The accounts your journal entries post to.",
        writableWhen: .field("is_system", notIn: ["true"]))

    static let journalStatus = StatusStyle(tones: ["posted": .success, "draft": .neutral, "void": .danger],
                                           labels: ["void": "Voided"])

    /// Journal entries: listed and opened here; new ones come from Bookkeeping → Create a journal entry.
    static let accountingJournal = ResourceDescriptor(
        id: "accounting.journal", title: "Journal entries", noun: "journal entry", systemImage: "book",
        api: ResourceAPISpec(list: "\(accountingBase)/journal-entries", item: "\(accountingBase)/journal-entries/{uuid}",
                             searchParam: nil),
        permissions: ResourcePermissions(module: "accounting"),
        list: ListSpec(title: ["description"],
                       subtitle: [FieldSpec("entry_number", "Number"), FieldSpec("entry_date", "Date", .date),
                                  FieldSpec("reference", "Reference")],
                       badge: FieldSpec("status", "Status", .status(journalStatus)),
                       trailing: FieldSpec("total_amount", "Amount", pounds),
                       filters: [FilterSpec("status", "Status", [Choice("posted"), Choice("draft"), Choice("void", "Voided")])],
                       emptyTitle: "No journal entries",
                       emptyDescription: "Entries appear here when you reconcile, approve an expense, record money in or out, "
                           + "or create one from Bookkeeping."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("entry_number", "Number"), FieldSpec("entry_date", "Date", .date),
                FieldSpec("reference", "Reference"), FieldSpec("total_amount", "Total", pounds),
                FieldSpec("void_reason", "Why it was voided", .multiline), FieldSpec("voided_at", "Voided", .dateTime),
                FieldSpec("created_at", "Created", .dateTime),
            ]),
        ],
        actions: [
            ActionSpec("void", "Void this entry", systemImage: "xmark.circle",
                       path: "\(accountingBase)/journal-entries/{uuid}/void",
                       confirm: "Voiding reverses this entry’s postings. It can’t be undone.", destructive: true,
                       visibleWhen: .field("status", notIn: ["void"]),
                       inputs: [FieldSpec("reason", "Why", .multiline, required: true)], done: "Entry voided."),
        ],
        related: [RelatedSpec("Lines", descriptorID: "accounting.journal_lines", embeddedKey: "lines")],
        summary: "Every posting in your books.")

    /// A journal line, shown under its entry.
    static let accountingJournalLines = ResourceDescriptor(
        id: "accounting.journal_lines", title: "Lines", noun: "line", systemImage: "line.3.horizontal",
        api: ResourceAPISpec(list: "\(accountingBase)/journal-entries", searchParam: nil),
        list: ListSpec(title: ["account_name", "account_code"],
                       subtitle: [FieldSpec("account_code", "Code"), FieldSpec("description", "Description"),
                                  FieldSpec("debit_amount", "Debit", pounds), FieldSpec("credit_amount", "Credit", pounds)]),
        detail: [
            SectionSpec(nil, [
                FieldSpec("account_code", "Account code"), FieldSpec("account_name", "Account"),
                FieldSpec("debit_amount", "Debit", pounds), FieldSpec("credit_amount", "Credit", pounds),
                FieldSpec("description", "Description"),
            ]),
        ])

    static let expenseStatus = StatusStyle(tones: ["pending": .warning, "approved": .success, "rejected": .danger,
                                                   "posted": .info],
                                           labels: ["pending": "Waiting for approval"])

    /// An expense opened from Expenses or the purchase ledger: change it, approve, reject or delete it.
    static let accountingExpenses = ResourceDescriptor(
        id: "accounting.expenses", title: "Expenses", noun: "expense", systemImage: "receipt",
        api: ResourceAPISpec(list: "\(accountingBase)/expenses", item: "\(accountingBase)/expenses/{uuid}",
                             update: "\(accountingBase)/expenses/{uuid}", delete: "\(accountingBase)/expenses/{uuid}",
                             searchParam: nil),
        permissions: ResourcePermissions(module: "accounting"),
        list: ListSpec(title: ["description"],
                       subtitle: [FieldSpec("expense_date", "Date", .date), FieldSpec("vendor", "Supplier"),
                                  FieldSpec("category", "Category")],
                       badge: FieldSpec("status", "Status", .status(expenseStatus)),
                       trailing: FieldSpec("amount", "Amount", pounds),
                       filters: [FilterSpec("status", "Status", [Choice("pending", "Waiting for approval"), Choice("approved"),
                                                                  Choice("rejected"), Choice("posted")])]),
        detail: [
            SectionSpec(nil, [
                FieldSpec("expense_date", "Date", .date), FieldSpec("amount", "Amount", pounds),
                FieldSpec("category", "Category"), FieldSpec("vendor", "Supplier"),
                FieldSpec("payment_method", "Paid by"), FieldSpec("notes", "Notes", .multiline),
            ]),
            SectionSpec("VAT", [
                FieldSpec("vat_rate", "VAT rate", .percent), FieldSpec("vat_amount", "VAT", pounds),
                FieldSpec("is_vat_reclaimable", "Reclaimable", .bool),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("expense_date", "Date", .date), FieldSpec("description", "Description", required: true),
                FieldSpec("amount", "Amount (including VAT)", .decimal(places: 2), required: true),
                FieldSpec("category", "Category", required: true), FieldSpec("vendor", "Supplier"),
                FieldSpec("notes", "Notes", .multiline),
            ]),
            SectionSpec("VAT", [
                FieldSpec("vat_rate", "VAT rate %", .decimal(places: 2)), FieldSpec("vat_amount", "VAT", .decimal(places: 2)),
                FieldSpec("is_vat_reclaimable", "Reclaimable", .bool),
            ]),
        ]),
        actions: [
            ActionSpec("approve", "Approve", systemImage: "checkmark.circle", path: "\(accountingBase)/expenses/{uuid}/approve",
                       visibleWhen: .field("status", notIn: ["approved"]), done: "Expense approved."),
            ActionSpec("reject", "Reject", systemImage: "xmark.circle", path: "\(accountingBase)/expenses/{uuid}/reject",
                       destructive: true, visibleWhen: .field("status", in: ["pending"]),
                       inputs: [FieldSpec("reason", "Why (optional)", .multiline)], done: "Expense rejected."),
        ],
        summary: "Money spent by the business, waiting for approval or approved.")
}
