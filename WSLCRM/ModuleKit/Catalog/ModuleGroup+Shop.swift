import SwiftUI

/// The shop's back office pages that are lists, records and settings (`/api/v2/shop/admin`, RBAC `shop`).
/// Orders, quotes, products, suppliers and deals have hand-built screens (Features/Shop).
extension ModuleGroup {
    static let shop = ModuleGroup(
        id: "shop",
        descriptors: ModuleCatalog.shop,
        reports: ModuleCatalog.shopReports,
        // Purchase invoices are hand-built (totals and "Record a supplier invoice"); rows open the kit's detail.
        screens: ["purchase_invoices": "shop.purchase_invoices"],
        screen: { id in
            switch id {
            case "shop.purchase_invoices": AnyView(PurchaseInvoicesView())
            case "shop.price_changes": AnyView(ShopPriceChangesView())
            default: nil
            }
        })
}

extension ModuleCatalog {
    static let shopBase = "/api/v2/shop/admin"

    static let shop: [ResourceDescriptor] = [
        shopMessageTemplates, shopCredits, shopPriceChanges, shopMembers, shopMembershipSettings, shopLegal,
        shopSettings, purchaseInvoices, shopWaitlist,
    ]

    private static let gbp = FieldKind.money(currencyKey: nil, minorUnits: true, currency: Formatters.defaultCurrency)

    // MARK: Message templates

    static let templateKinds = [
        Choice("price_request", "Price request"), Choice("stock_enquiry", "Stock enquiry"),
        Choice("supplier_intro", "Supplier introduction"),
    ]

    static let shopMessageTemplates = ResourceDescriptor(
        id: "shop.message_templates", title: "Message templates", noun: "template", systemImage: "envelope.badge",
        api: .crud("\(shopBase)/message-templates", paging: .none, searchParam: nil),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("kind_label", "Kind"), FieldSpec("supplier_name", "Supplier")],
                       filters: [FilterSpec("kind", "Kind", templateKinds)],
                       emptyTitle: "No templates yet",
                       emptyDescription: "The wording for price requests, stock enquiries and supplier introductions. "
                           + "Add your own to change it; the built-in wording is used otherwise."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("kind_label", "Used for"), FieldSpec("supplier_name", "Only for supplier"),
                FieldSpec("is_default", "Default for its kind", .bool), FieldSpec("is_active", "In use", .bool),
                FieldSpec("builtin", "Built in", .bool),
            ]),
            SectionSpec("Message", [FieldSpec("subject", "Subject"), FieldSpec("body", "Wording", .multiline)],
                        footer: "Placeholders such as {customer_name} are filled in when the message is written."),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("kind", "Used for", .choice(templateKinds), required: true),
                FieldSpec("name", "Name", required: true, placeholder: "e.g. Short price request"),
                FieldSpec("supplier_uuid", "Only for supplier",
                          .reference(ReferenceSpec(list: "\(shopBase)/suppliers", displayKey: "supplier_name",
                                                   searchParam: nil)),
                          help: "Leave empty to use it for every supplier."),
            ]),
            SectionSpec("Message", [
                FieldSpec("subject", "Subject", required: true),
                FieldSpec("body", "Wording", .multiline, required: true),
            ]),
            SectionSpec(nil, [
                FieldSpec("is_default", "Default for its kind", .bool),
                FieldSpec("is_active", "In use", .bool, defaultValue: .bool(true)),
            ]),
        ]),
        summary: "The wording used when you message suppliers from a quote or a product.",
        writableWhen: .field("builtin", notIn: ["true"]))

    // MARK: Credits

    static let creditStatus = StatusStyle(tones: ["available": .success, "reserved": .warning, "used": .neutral,
                                                  "void": .danger],
                                          labels: ["reserved": "Held for an order", "void": "Cancelled"])

    static let shopCredits = ResourceDescriptor(
        id: "shop.credits", title: "Credits", noun: "credit", systemImage: "gift",
        // Giving credit is `shop.manage` on the server (POST /credits: money off a future order), so it is a list
        // action, not a create form. Cancelling one stays `shop.update`.
        api: ResourceAPISpec(list: "\(shopBase)/credits", paging: .limitOffset, searchParam: "q"),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["email"],
                       subtitle: [FieldSpec("reason", "Reason"), FieldSpec("created_at", "Given", .date)],
                       badge: FieldSpec("status", "Status", .status(creditStatus)),
                       trailing: FieldSpec("amount_minor", "Amount", gbp),
                       filters: [
                           FilterSpec("status", "Status", [Choice("available"), Choice("reserved"), Choice("used"),
                                                           Choice("void", "Cancelled")]),
                           FilterSpec("source", "Source", [Choice("loyalty", "Loyalty"), Choice("vip_refund", "VIP refund"),
                                                           Choice("admin", "Given by staff")]),
                       ],
                       emptyTitle: "No credit given yet", searchPrompt: "Search by email"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("email", "Customer", .email), FieldSpec("amount_minor", "Amount", gbp),
                FieldSpec("min_order_minor", "Minimum order", gbp),
                FieldSpec("source", "Source", .choice([Choice("loyalty", "Loyalty"), Choice("vip_refund", "VIP refund"),
                                                      Choice("admin", "Given by staff")])),
                FieldSpec("reason", "Reason", .multiline), FieldSpec("expires_at", "Expires", .date),
                FieldSpec("notified", "Customer told", .bool), FieldSpec("created_by", "Given by"),
                FieldSpec("created_at", "Given", .dateTime),
            ]),
            SectionSpec("Orders", [
                FieldSpec("earned_order_number", "Earned on"), FieldSpec("reserved_order_number", "Held for"),
                FieldSpec("used_order_number", "Used on"),
            ]),
        ],
        actions: [
            ActionSpec("void", "Cancel this credit", systemImage: "xmark.circle", path: "\(shopBase)/credits/{uuid}/void",
                       destructive: true, visibleWhen: .field("status", in: ["available"]),
                       inputs: [FieldSpec("reason", "Why", .multiline)], done: "Credit cancelled."),
        ],
        summary: "Store credit customers can spend on their next order.",
        listActions: [
            ActionSpec("grant", "Give credit", systemImage: "gift", path: "\(shopBase)/credits", action: .manage,
                       inputs: [
                           FieldSpec("email", "Customer email", .email, required: true),
                           FieldSpec("amount_minor", "Credit (before VAT)", gbp, required: true),
                           FieldSpec("min_order_minor", "On orders over (before VAT)", gbp,
                                     help: "Leave empty for any order."),
                           FieldSpec("expires_in_days", "Use within (days)", .integer, required: true,
                                     help: "1 to 3650 days.", defaultValue: .number(365)),
                           FieldSpec("reason", "Reason (saved to the CRM)", .multiline, required: true,
                                     placeholder: "e.g. Thank you for the university lab order"),
                           FieldSpec("notify", "Email the customer", .bool, defaultValue: .bool(true)),
                       ],
                       done: "Credit given. It is saved to the customer’s CRM lead."),
        ])

    // MARK: Price changes

    static let priceChangeStatus = StatusStyle(tones: [
        "pending": .warning, "applied": .success, "approved": .success, "rejected": .neutral,
        "superseded": .neutral, "blocked_below_cost": .danger,
    ], labels: ["pending": "Waiting for you", "rejected": "Kept the old price", "superseded": "Replaced by a newer one",
                "blocked_below_cost": "Below cost"])

    static let shopPriceChanges = ResourceDescriptor(
        id: "shop.price_changes", title: "Price changes", noun: "price change", systemImage: "scalemass",
        api: ResourceAPISpec(list: "\(shopBase)/price-changes", paging: .limitOffset, searchParam: nil),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["product_name"],
                       subtitle: [FieldSpec("product_sku", "SKU"), FieldSpec("supplier_name", "Supplier"),
                                  FieldSpec("change_pct", "Change %", .decimal(places: 1))],
                       badge: FieldSpec("status", "Status", .status(priceChangeStatus)),
                       trailing: FieldSpec("new_price_minor", "New price", gbp),
                       filters: [FilterSpec("status", "Status", [
                           Choice("pending", "Waiting for you"), Choice("blocked_below_cost", "Below cost"),
                           Choice("applied"), Choice("approved"), Choice("rejected"), Choice("superseded"),
                       ])],
                       emptyTitle: "No price changes",
                       emptyDescription: "When a supplier's prices move, the new selling prices wait here for you."),
        detail: [
            SectionSpec("Price", [
                FieldSpec("old_price_minor", "Was", gbp), FieldSpec("new_price_minor", "New", gbp),
                FieldSpec("current_price_minor", "Now on the shop", gbp), FieldSpec("cost_minor", "Cost", gbp),
                FieldSpec("margin_pct", "Margin %", .decimal(places: 2)),
                FieldSpec("change_pct", "Change %", .decimal(places: 1)),
            ]),
            SectionSpec("From", [
                FieldSpec("supplier_name", "Supplier"), FieldSpec("supplier_sku", "Supplier's code"),
                FieldSpec("created_at", "Found", .dateTime), FieldSpec("decided_by", "Decided by"),
                FieldSpec("decided_at", "Decided", .dateTime),
            ]),
        ],
        actions: [
            ActionSpec("approve", "Use the new price", systemImage: "checkmark.circle",
                       path: "\(shopBase)/price-changes/{uuid}/approve",
                       visibleWhen: .field("status", in: ["pending"]), done: "New price in use."),
            ActionSpec("reject", "Keep the current price", systemImage: "xmark.circle",
                       path: "\(shopBase)/price-changes/{uuid}/reject",
                       visibleWhen: .field("status", in: ["pending"]), done: "Price kept."),
        ],
        links: [LinkSpec("Open the product", key: "product_uuid", target: .shopProduct, systemImage: "shippingbox")])

    // MARK: VIP membership

    static let memberStatus = StatusStyle(tones: ["active": .success, "past_due": .warning, "canceled": .neutral,
                                                  "expired": .neutral],
                                          labels: ["past_due": "Payment late", "canceled": "Cancelled"])

    static let shopMembers = ResourceDescriptor(
        id: "shop.members", title: "VIP members", noun: "member", systemImage: "crown",
        api: ResourceAPISpec(list: "\(shopBase)/membership/members", paging: .none, searchParam: "q"),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["name", "email"],
                       subtitle: [FieldSpec("company", "Company"), FieldSpec("tier", "Tier"),
                                  FieldSpec("billing_interval", "Billed")],
                       badge: FieldSpec("status", "Status", .status(memberStatus)),
                       trailing: FieldSpec("net_minor", "Fee", gbp),
                       filters: [FilterSpec("status", "Status", [Choice("active"), Choice("past_due", "Payment late"),
                                                                 Choice("canceled", "Cancelled"), Choice("expired")])],
                       emptyTitle: "No VIP members yet", searchPrompt: "Name, company or email"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("name", "Name"), FieldSpec("company", "Company"), FieldSpec("email", "Email", .email),
                FieldSpec("phone", "Phone", .phone),
            ]),
            SectionSpec("Membership", [
                FieldSpec("tier", "Tier", .choice([Choice("founding", "Founding"), Choice("standard", "Standard")])),
                FieldSpec("billing_interval", "Billed", .choice([Choice("month", "Monthly"), Choice("year", "Yearly")])),
                FieldSpec("net_minor", "Fee (ex VAT)", gbp), FieldSpec("vat_minor", "VAT", gbp),
                FieldSpec("joined_at", "Joined", .date), FieldSpec("current_period_end", "Paid until", .date),
                FieldSpec("cancel_at_period_end", "Ends at the period end", .bool),
                FieldSpec("fees_paid_net_minor", "Fees paid", gbp), FieldSpec("fees_credited_net_minor", "Fees credited", gbp),
                FieldSpec("terms_version", "Terms"),
            ]),
        ],
        summary: "Customers on the VIP membership.",
        listActions: [
            ActionSpec("invoiced", "Record a fee paid by invoice", systemImage: "doc.text",
                       path: "\(shopBase)/membership/members/invoiced", action: .manage,
                       inputs: [FieldSpec("email", "Customer email", .email, required: true),
                                FieldSpec("invoice_ref", "Invoice number", required: true)],
                       done: "Membership fee recorded."),
        ])

    static let shopMembershipSettings = ResourceDescriptor(
        id: "shop.membership_settings", title: "VIP membership settings", noun: "settings", systemImage: "gearshape",
        api: ResourceAPISpec(list: "\(shopBase)/membership/settings", item: "\(shopBase)/membership/settings",
                             update: "\(shopBase)/membership/settings", paging: .none, searchParam: nil),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["offer_version"]),
        detail: [
            SectionSpec(nil, [FieldSpec("enabled", "Membership on", .bool), FieldSpec("offer_version", "Offer")]),
            SectionSpec("Prices", [
                FieldSpec("monthly_price_minor", "Monthly fee", gbp), FieldSpec("yearly_months_charged", "Months charged a year", .integer),
                FieldSpec("founding_cap", "Founding places", .integer), FieldSpec("vat_rate", "VAT", .percent),
            ]),
            SectionSpec("Discounts", [
                FieldSpec("founding_discount_pct", "Founding discount", .percent),
                FieldSpec("standard_discount_pct", "Standard discount", .percent),
                FieldSpec("pro_discount_pct", "Pro discount", .percent),
                FieldSpec("discount_fixed_minor", "Fixed discount", gbp),
                FieldSpec("discount_min_order_minor", "Minimum order", gbp),
                FieldSpec("discount_cap_minor", "Most off an order", gbp),
            ]),
            SectionSpec("Rules", [
                FieldSpec("lock_days", "Price lock (days)", .integer), FieldSpec("refund_threshold_minor", "Refund threshold", gbp),
                FieldSpec("credit_expiry_days", "Credit lasts (days)", .integer),
                FieldSpec("early_access_hours", "Early access (hours)", .integer),
                FieldSpec("long_lead_days", "Long lead time (days)", .integer), FieldSpec("terms_version", "Terms"),
            ]),
        ],
        form: FormSpec([
            SectionSpec(nil, [FieldSpec("enabled", "Membership on", .bool)]),
            SectionSpec("Prices", [
                FieldSpec("monthly_price_minor", "Monthly fee", gbp),
                FieldSpec("yearly_months_charged", "Months charged a year", .integer),
                FieldSpec("founding_cap", "Founding places", .integer),
            ]),
            SectionSpec("Discounts", [
                FieldSpec("founding_discount_pct", "Founding discount %", .decimal(places: 2)),
                FieldSpec("standard_discount_pct", "Standard discount %", .decimal(places: 2)),
                FieldSpec("pro_discount_pct", "Pro discount %", .decimal(places: 2)),
                FieldSpec("discount_fixed_minor", "Fixed discount", gbp),
                FieldSpec("discount_min_order_minor", "Minimum order", gbp),
                FieldSpec("discount_cap_minor", "Most off an order", gbp),
            ]),
            SectionSpec("Rules", [
                FieldSpec("lock_days", "Price lock (days)", .integer, help: "60 or 120."),
                FieldSpec("refund_threshold_minor", "Refund threshold", gbp),
                FieldSpec("credit_expiry_days", "Credit lasts (days)", .integer),
                FieldSpec("early_access_hours", "Early access (hours)", .integer),
                FieldSpec("long_lead_days", "Long lead time (days)", .integer),
            ]),
        ], sendOnlyChanges: true),
        summary: "Prices, discounts and rules for the VIP membership.",
        singleton: true)

    // MARK: Legal record

    /// The shop's legal documents (workstation-website shop/src/lib/legal); unknown keys show as sent.
    static let legalDocuments = [
        Choice("terms-of-sale", "Terms of Sale"), Choice("trade-terms", "Trade terms"),
        Choice("privacy-notice", "Privacy notice"), Choice("ai-assistant", "AI assistant notice"),
        Choice("important-information", "Important information"),
    ]

    static let legalCheckpoints = [
        Choice("register", "Signing in"), Choice("quote", "Quote request"), Choice("checkout", "Checkout"),
        Choice("trade_join", "Joining Trade"), Choice("chat", "AI chat"), Choice("enquiry", "Enquiry or waitlist"),
        Choice("contact", "Website contact form"),
    ]

    static let shopLegal = ResourceDescriptor(
        id: "shop.legal", title: "Legal record", noun: "confirmation", systemImage: "scroll",
        api: ResourceAPISpec(list: "\(shopBase)/legal/acceptances", paging: .limitOffset, searchParam: "q"),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["email"],
                       subtitle: [FieldSpec("document_key", "Document", .choice(legalDocuments)),
                                  FieldSpec("document_version", "Version"),
                                  FieldSpec("checkpoint", "Where", .choice(legalCheckpoints))],
                       badge: FieldSpec("email_confirmed", "Email", .status(StatusStyle(
                           tones: ["true": .success, "false": .neutral], labels: ["true": "Signed in", "false": "Typed"]))),
                       trailing: FieldSpec("created_at", "When", .date),
                       filters: [FilterSpec("document_key", "Document", legalDocuments),
                                 FilterSpec("checkpoint", "Where", legalCheckpoints)],
                       emptyTitle: "Nothing recorded yet",
                       emptyDescription: "Each time a customer ticks a legal confirmation, it is kept here.",
                       searchPrompt: "Search by email"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("email", "Customer", .email),
                FieldSpec("email_confirmed", "Signed in (not typed into a form)", .bool),
                FieldSpec("document_key", "Document", .choice(legalDocuments)), FieldSpec("document_version", "Version"),
                FieldSpec("checkpoint", "Where", .choice(legalCheckpoints)), FieldSpec("subject_ref", "For"),
                FieldSpec("created_at", "When", .dateTime),
            ]),
            SectionSpec("What they agreed to", [FieldSpec("statement", "Statement", .multiline)]),
            SectionSpec("Evidence", [
                FieldSpec("content_hash", "Document fingerprint"), FieldSpec("client_ip", "IP address"),
                FieldSpec("user_agent", "Browser", .multiline),
            ], footer: "The fingerprint is the SHA-256 of the document text they saw."),
        ],
        summary: "Legal confirmations customers have given, kept as evidence.",
        listActions: [
            ActionSpec("erase", "Erase a person’s records", systemImage: "person.crop.circle.badge.xmark",
                       path: "\(shopBase)/legal/acceptances/erase",
                       confirm: "This deletes every confirmation that person gave. Do this only for an erasure request.",
                       destructive: true, action: .delete,
                       inputs: [FieldSpec("email", "Their email", .email, required: true)],
                       done: "Their records were erased."),
        ])

    // MARK: Shop settings

    static let shopSettings = ResourceDescriptor(
        id: "shop.settings", title: "Shop settings", noun: "settings", systemImage: "gearshape",
        api: ResourceAPISpec(list: "\(shopBase)/settings", item: "\(shopBase)/settings",
                             update: "\(shopBase)/settings", paging: .none, searchParam: nil),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["deal_code_prefix"]),
        detail: [
            SectionSpec("Checkout", [
                FieldSpec("checkout_enabled", "Customers can pay online", .bool),
                FieldSpec("order_alert_email", "New order alerts go to", .email),
                FieldSpec("customer_delivery_notifications", "Email customers about delivery changes", .bool),
            ]),
            SectionSpec("Delivery", [
                FieldSpec("delivery_cost_minor", "Delivery charge", gbp),
                FieldSpec("delivery_handling_min_days", "Handling from (days)", .integer),
                FieldSpec("delivery_handling_max_days", "Handling up to (days)", .integer),
                FieldSpec("delivery_transit_min_days", "In transit from (days)", .integer),
                FieldSpec("delivery_transit_max_days", "In transit up to (days)", .integer),
            ]),
            SectionSpec("Quotes and deals", [
                FieldSpec("quote_valid_days", "Quotes valid for (days)", .integer),
                FieldSpec("deal_code_prefix", "Deal code starts with"), FieldSpec("deal_code_length", "Deal code length", .integer),
            ]),
            SectionSpec("Suppliers", [
                FieldSpec("supplier_portal_enabled", "Supplier portal on", .bool),
                FieldSpec("supplier_portal_emails_enabled", "Email suppliers their portal link", .bool),
            ]),
            SectionSpec("Purchase orders: bill to", purchaseOrderParty("po_bill_to")),
            SectionSpec("Purchase orders: deliver to", purchaseOrderParty("po_deliver_to")),
            SectionSpec(nil, [FieldSpec("updated_at", "Last changed", .dateTime)]),
        ],
        form: FormSpec([
            SectionSpec("Checkout", [
                FieldSpec("checkout_enabled", "Customers can pay online", .bool,
                          help: "Off: orders become enquiries and nobody pays online."),
                FieldSpec("order_alert_email", "New order alerts go to", .email),
                FieldSpec("customer_delivery_notifications", "Customer emails from the shop", .bool,
                          help: "Order update emails and delivery change decisions. Off: staff can only send test copies to themselves."),
            ]),
            SectionSpec("UK delivery and quote validity", [
                FieldSpec("delivery_cost_minor", "UK delivery cost (ex VAT)", gbp, help: "0 shows as “Included”."),
                FieldSpec("delivery_handling_min_days", "Dispatch: from (working days)", .integer,
                          help: "In-stock items. The shop says “Ships in 1–2 days”."),
                FieldSpec("delivery_handling_max_days", "Dispatch: up to (working days)", .integer,
                          help: "Out-of-stock items use their own lead time."),
                FieldSpec("delivery_transit_min_days", "Courier: from (working days)", .integer, help: "After dispatch, UK mainland."),
                FieldSpec("delivery_transit_max_days", "Courier: up to (working days)", .integer),
                FieldSpec("quote_valid_days", "Quotes hold their price for (days)", .integer,
                          help: "New quotes; also the “price valid until” search engines see. 1 to 365."),
            ], footer: "What the shop tells customers and search engines (Google Shopping) about delivery. "
                + "Keep it the same as the basket and your Terms of Sale."),
            SectionSpec("Deal codes", [
                FieldSpec("deal_code_prefix", "Prefix", help: "1 to 6 letters or numbers."),
                FieldSpec("deal_code_length", "Length (random characters)", .integer, help: "6 to 16. 8 gives XXXX-XXXX."),
            ], footer: "Deal codes are private: staff and suppliers see them, customers never do."),
            SectionSpec("Suppliers", [
                FieldSpec("supplier_portal_enabled", "Supplier portal on", .bool,
                          help: "On: suppliers can sign in, see their own purchase orders, upload proformas and invoices, "
                              + "enter dispatch and write to you."),
                FieldSpec("supplier_portal_emails_enabled", "Supplier portal emails", .bool,
                          help: "On: every supplier with a portal login is emailed straight away about new and changed purchase orders, "
                              + "so check their email addresses first. Off: nothing is emailed; they see changes when they sign in."),
            ]),
            SectionSpec("Purchase orders: bill to", purchaseOrderParty("po_bill_to")),
            SectionSpec("Purchase orders: deliver to us", purchaseOrderParty("po_deliver_to"),
                        footer: "Leave empty to use the Bill to address. Suppliers deliver here unless you confirm a drop-ship."),
        ], sendOnlyChanges: true),
        summary: "How the shop takes orders, delivers and raises purchase orders.",
        singleton: true)

    private static func purchaseOrderParty(_ key: String) -> [FieldSpec] {
        [
            FieldSpec("\(key).company", "Company"),
            FieldSpec("\(key).line1", "Address line 1"), FieldSpec("\(key).line2", "Address line 2"),
            FieldSpec("\(key).city", "Town or city"), FieldSpec("\(key).county", "County"),
            FieldSpec("\(key).postcode", "Postcode"), FieldSpec("\(key).country", "Country"),
            FieldSpec("\(key).phone", "Phone", .phone), FieldSpec("\(key).email", "Email", .email),
            FieldSpec("\(key).vat_number", "VAT number"),
        ]
    }

    // MARK: Purchase invoices (supplier bills)

    static let purchaseInvoiceStatus = StatusStyle(tones: [
        "unpaid": .warning, "part_paid": .warning, "overdue": .danger, "paid": .success, "proforma": .info,
        "credit": .neutral,
    ], labels: ["part_paid": "Part paid", "proforma": "Pro forma", "credit": "Credit note"])

    static let purchaseInvoices = ResourceDescriptor(
        id: "shop.purchase_invoices", title: "Purchase invoices", noun: "purchase invoice", systemImage: "doc.text.below.ecg",
        api: ResourceAPISpec(list: "/api/v2/purchase-invoices", paging: .limitOffset, searchParam: "q"),
        permissions: ResourcePermissions(module: "purchase_orders"),
        list: ListSpec(title: ["supplier_name"],
                       subtitle: [FieldSpec("number", "Number"), FieldSpec("invoice_date", "Dated", .date),
                                  FieldSpec("due_date", "Due", .date)],
                       badge: FieldSpec("state", "Status", .status(purchaseInvoiceStatus)),
                       trailing: FieldSpec("total", "Total", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                       filters: [FilterSpec("state", "Status", [
                           Choice("owed", "Owed"), Choice("overdue"), Choice("unpaid"), Choice("part_paid", "Part paid"),
                           Choice("paid"), Choice("proforma", "Pro forma"), Choice("credit", "Credit notes"),
                       ])],
                       emptyTitle: "No purchase invoices",
                       emptyDescription: "Bills from your suppliers, recorded by your team or sent through the supplier portal.",
                       searchPrompt: "Supplier or invoice number"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("number", "Invoice number"),
                FieldSpec("kind", "Type", .choice([Choice("invoice", "Invoice"), Choice("proforma", "Pro forma"),
                                                   Choice("credit_note", "Credit note")])),
                FieldSpec("invoice_date", "Dated", .date), FieldSpec("due_date", "Due", .date),
                FieldSpec("days_late", "Days late", .integer), FieldSpec("payment_terms", "Terms"),
                FieldSpec("supplier_order_ref", "Supplier's order ref"),
                FieldSpec("recorded_by", "Recorded by", .choice([Choice("staff", "Our team"), Choice("supplier", "The supplier")])),
            ]),
            SectionSpec("Amounts", [
                FieldSpec("net", "Net", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                FieldSpec("vat", "VAT", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                FieldSpec("total", "Total", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                FieldSpec("paid", "Paid", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
                FieldSpec("outstanding", "Still owed", .money(currencyKey: "currency", minorUnits: false, currency: Formatters.defaultCurrency)),
            ]),
        ],
        summary: "Bills from your suppliers.",
        links: [LinkSpec("Open the purchase order", key: "purchase_order.uuid", target: .purchaseOrder,
                         systemImage: "shippingbox.and.arrow.backward")])

    // MARK: Waitlist (back-in-stock requests)

    static let shopWaitlist = ResourceDescriptor(
        id: "shop.waitlist", title: "Waitlist", noun: "request", systemImage: "bell.badge",
        // One row per person per product, with no id of its own: rows are told apart by their content.
        api: ResourceAPISpec(list: "\(shopBase)/waitlist", paging: .none, searchParam: nil, idKeys: []),
        permissions: ResourcePermissions(module: "shop"),
        list: ListSpec(title: ["email"],
                       subtitle: [FieldSpec("product_name", "Product"), FieldSpec("sku", "SKU"),
                                  FieldSpec("created_at", "Asked", .date)],
                       badge: FieldSpec("is_member", "Customer", .status(StatusStyle(
                           tones: ["true": .brand, "false": .neutral], symbols: ["true": "crown"],
                           labels: ["true": "VIP member", "false": "Customer"]))),
                       filters: [FilterSpec("include_notified", "Show", [Choice("true", "Include people already told")])],
                       emptyTitle: "Nobody is waiting",
                       emptyDescription: "When a product is out of stock, customers can ask to be told when it is back. "
                           + "They appear here, VIP members first, until they have been told."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("email", "Customer", .email), FieldSpec("is_member", "VIP member", .bool),
                FieldSpec("product_name", "Product"), FieldSpec("sku", "SKU"),
                FieldSpec("created_at", "Asked", .dateTime), FieldSpec("notified_at", "Told it is back", .dateTime),
            ]),
        ],
        summary: "Customers waiting for a product to be back in stock. They are emailed when stock arrives.",
        links: [LinkSpec("Open the product", key: "product_uuid", target: .shopProduct, systemImage: "shippingbox")])

    // MARK: Reports

    static let shopReports: [ReportSpec] = [shopBelowCost]

    /// Where a known cost comes from (product `cost_source`, option `cost_source`).
    static let costSources = [
        Choice("supplier", "Supplier"), Choice("manual", "Entered by hand"), Choice("component", "Component product"),
        Choice("option", "Entered on the option"),
    ]

    static let shopBelowCost = ReportSpec(
        id: "shop.below_cost", title: "Below cost", systemImage: "chart.line.downtrend.xyaxis",
        path: "\(shopBase)/pricing/below-cost", query: ["include_quotes": "true"],
        summary: "What is priced below its known cost (the supplier’s when linked, else the one entered by hand), "
            + "what has no cost yet so its margin can’t be checked, and open quotes with a line below cost. "
            + "Saving a product with a price below cost is refused.",
        metrics: [
            FieldSpec("missing_cost.products", "Products with no cost", .integer),
            FieldSpec("missing_cost.options", "Options with no cost", .integer),
        ],
        sections: [
            ReportSectionSpec("Products below cost", key: "products",
                              list: ListSpec(title: ["name"],
                                             subtitle: [FieldSpec("sku", "SKU"), FieldSpec("cost_minor", "Cost", gbp),
                                                        FieldSpec("cost_source", "Cost from", .choice(costSources)),
                                                        FieldSpec("margin_minor", "Margin", gbp)],
                                             badge: FieldSpec("status", "Status", .status(.standard)),
                                             trailing: FieldSpec("price_minor", "Price", gbp)),
                              opens: LinkSpec("Product", key: "uuid", target: .shopProduct),
                              empty: "No product is priced below its cost."),
            ReportSectionSpec("Options below cost", key: "options",
                              list: ListSpec(title: ["option_name"],
                                             subtitle: [FieldSpec("product_name", "Product"), FieldSpec("group_name", "Group"),
                                                        FieldSpec("cost_minor", "Cost", gbp),
                                                        FieldSpec("cost_source", "Cost from", .choice(costSources)),
                                                        FieldSpec("margin_minor", "Margin", gbp)],
                                             trailing: FieldSpec("price_minor", "Price", gbp)),
                              opens: LinkSpec("Product", key: "product_uuid", target: .shopProduct),
                              empty: "No option is priced below its cost."),
            ReportSectionSpec("Products with no cost yet", key: "missing_cost_products",
                              list: ListSpec(title: ["name"], subtitle: [FieldSpec("sku", "SKU")]),
                              opens: LinkSpec("Product", key: "uuid", target: .shopProduct),
                              empty: "Every product has a cost."),
            ReportSectionSpec("Open quotes below current cost", key: "quotes",
                              list: ListSpec(title: ["quote_number"],
                                             subtitle: [FieldSpec("customer_name", "Customer"),
                                                        FieldSpec("kind", "Kind", .choice([Choice("quote", "Quote"),
                                                                                           Choice("order", "Order Authorisation")])),
                                                        FieldSpec("lines", "Lines below cost", .count)],
                                             badge: FieldSpec("status", "Status", .status(.standard))),
                              opens: LinkSpec("Quote", key: "uuid", target: .shopQuote),
                              empty: "No draft or sent quote has a line below its current cost."),
        ])
}
