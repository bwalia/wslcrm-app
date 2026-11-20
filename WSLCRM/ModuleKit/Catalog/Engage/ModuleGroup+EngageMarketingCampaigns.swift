import SwiftUI

/// Marketing Cloud — campaigns, overview and replies.
///
/// Overview and Campaigns are hand-built (results, a lifecycle, five tabs); Replies (the old
/// "Conversations" menu item) is a described list of `mkt_replies` with a way to record a reply.
extension ModuleGroup {
    static let engageMarketingCampaigns = ModuleGroup(
        id: "engage.marketing.campaigns",
        descriptors: [ModuleCatalog.marketingReplies],
        resources: [:],
        screens: [
            "plugin:opsapi_marketing:overview": Marketing.Screen.overview,
            "plugin:opsapi_marketing:campaigns": Marketing.Screen.campaigns,
            "plugin:opsapi_marketing:conversations": Marketing.Screen.conversations,
        ],
        screen: { id in
            let parts = EngageArea.parts(id)
            switch parts.screen {
            case Marketing.Screen.overview: return AnyView(MktOverviewView())
            case Marketing.Screen.campaigns: return AnyView(MktCampaignsListView())
            case Marketing.Screen.campaign:
                // `<uuid>`, or `<uuid>?list=<list uuid>` to choose who gets it on the way in.
                guard let argument = parts.argument?.trimmedOrNil else { return nil }
                return AnyView(MktCampaignDetailView(argument: argument))
            case Marketing.Screen.conversations:
                return AnyView(ResourceListView(ModuleCatalog.marketingReplies))
            default: return nil
            }
        })
}

/// How a reply was sorted (`opsapi_marketing/replies.lua` CLASSES), in plain words.
enum MktReplyStyle {
    static let classes: [Choice] = [
        Choice("interested", "Interested"), Choice("more_info", "Wants more information"), Choice("pricing", "Asked about price"),
        Choice("meeting", "Wants a meeting"), Choice("not_interested", "Not interested"), Choice("unsubscribe", "Asked to stop"),
        Choice("out_of_office", "Out of office"), Choice("complaint", "Complaint"), Choice("bounce", "Bounced"),
        Choice("human_assist", "Needs a person"), Choice("uncertain", "Not sure"),
    ]

    static func label(_ raw: String) -> String { classes.first { $0.value == raw }?.label ?? Formatters.humanize(raw) }

    static let status = StatusStyle(
        tones: ["interested": .success, "more_info": .info, "pricing": .info, "meeting": .success,
                "not_interested": .neutral, "unsubscribe": .warning, "out_of_office": .neutral, "complaint": .danger,
                "bounce": .danger, "human_assist": .warning, "uncertain": .neutral],
        labels: Dictionary(uniqueKeysWithValues: classes.map { ($0.value, $0.label) }))
}

extension ModuleCatalog {
    /// Replies to campaigns (`GET /replies`, `{success, data: {data: [...]}}`), sorted in code. Nothing is ever
    /// sent automatically from a reply; "asked to stop" unsubscribes the person.
    static let marketingReplies = ResourceDescriptor(
        id: "mkt.campaigns.replies", title: "Replies", noun: "reply", systemImage: "bubble.left.and.bubble.right",
        api: ResourceAPISpec(list: Marketing.path("/replies"), item: Marketing.path("/replies/{uuid}"),
                             paging: .pageAndPerPage, searchParam: nil, idKeys: ["uuid", "id"]),
        permissions: ResourcePermissions(module: Marketing.RBAC.conversations),
        list: ListSpec(title: ["subject", "address"],
                       subtitle: [FieldSpec("address", "From"), FieldSpec("channel", "Channel"),
                                  FieldSpec("created_at", "Received", .dateTime)],
                       badge: FieldSpec("classification", "Sorted as", .status(MktReplyStyle.status)),
                       filters: [FilterSpec("classification", "Sorted as", MktReplyStyle.classes)],
                       emptyTitle: "No replies yet",
                       emptyDescription: "Replies to your campaigns appear here, sorted by what they say. Email replies "
                           + "also arrive in your normal inbox; a reply asking to stop unsubscribes the person."),
        detail: [
            SectionSpec(nil, [
                FieldSpec("classification", "Sorted as", .status(MktReplyStyle.status)),
                FieldSpec("confidence", "How sure", .percent),
                FieldSpec("needs_human", "Needs a person to look", .bool),
                FieldSpec("address", "From"), FieldSpec("channel", "Channel", .choice(MktCamp.channels)),
                FieldSpec("created_at", "Received", .dateTime), FieldSpec("classified_by", "Sorted by"),
            ]),
            SectionSpec("Message", [FieldSpec("subject", "Subject"), FieldSpec("body_text", "Words", .multiline)]),
        ],
        summary: "Replies to your campaigns, sorted by what they say. Nothing is sent back automatically.",
        listActions: [
            ActionSpec("ingest", "Record a reply you received", systemImage: "square.and.pencil",
                       path: Marketing.path("/replies/ingest"), module: Marketing.RBAC.conversations, action: .create,
                       inputs: [
                           FieldSpec("address", "Their email or mobile", required: true),
                           FieldSpec("channel", "Came by", .choice(MktCamp.channels), defaultValue: .string("email")),
                           FieldSpec("subject", "Subject"),
                           FieldSpec("body_text", "What they said", .multiline, required: true),
                       ],
                       done: "Reply recorded and sorted. If they asked to stop, they’re unsubscribed."),
        ])
}
