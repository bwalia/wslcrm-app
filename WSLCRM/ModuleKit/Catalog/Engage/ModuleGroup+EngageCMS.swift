import SwiftUI

/// Website content (headless CMS) — pages, posts and the media library.
///
/// `cms` opens the content hub (`CMSHomeView`): blog posts, pages, the media library, categories,
/// tags and website updates. Categories and tags are module kit lists; the rest are hand-built
/// (a native content editor, an image library with cropping, the website-update guide).
extension ModuleGroup {
    static let engageCMS = ModuleGroup(
        id: "engage.cms",
        descriptors: [ModuleCatalog.cmsCategories, ModuleCatalog.cmsTags],
        resources: [:],
        screens: ["cms": CMS.Screen.home],
        screen: { id in
            switch EngageArea.parts(id).screen {
            case CMS.Screen.home: AnyView(CMSHomeView())
            case CMS.Screen.posts: AnyView(CMSPostsListView())
            case CMS.Screen.pages: AnyView(CMSPagesListView())
            case CMS.Screen.media: AnyView(CMSMediaLibraryView())
            case CMS.Screen.webhooks: AnyView(CMSWebhooksView())
            case "cms.post": AnyView(CMSPostEditorView(uuid: EngageArea.parts(id).argument))
            case "cms.page": AnyView(CMSPageEditorView(uuid: EngageArea.parts(id).argument))
            default: nil
            }
        })
}

extension ModuleCatalog {
    /// Blog categories (`lapis/routes/cms-taxonomy.lua`). There is no single-category read: a row is the record.
    static let cmsCategories = ResourceDescriptor(
        id: "cms.categories", title: "Categories", noun: "category", systemImage: "folder",
        api: ResourceAPISpec(list: "\(CMS.base)/categories", create: "\(CMS.base)/categories",
                             update: "\(CMS.base)/categories/{uuid}", delete: "\(CMS.base)/categories/{uuid}",
                             paging: .none, searchParam: "search", idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: CMS.module),
        list: ListSpec(title: ["name"],
                       subtitle: [FieldSpec("slug", "Address"), FieldSpec("description", "Description")],
                       trailing: FieldSpec("post_count", "Posts", .integer),
                       emptyTitle: "No categories yet",
                       emptyDescription: "Group blog posts into categories people can browse on your website.",
                       searchPrompt: "Search categories"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("name", "Name"), FieldSpec("slug", "Web address (slug)"),
                FieldSpec("description", "Description", .multiline), FieldSpec("post_count", "Posts", .integer),
                FieldSpec("position", "Order", .integer),
            ], footer: "Deleting a category leaves its posts in place, without this category."),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true, placeholder: "Announcements"),
                FieldSpec("description", "Description", .multiline, placeholder: "Optional"),
            ]),
            SectionSpec("More", [
                FieldSpec("slug", "Web address (slug)", placeholder: "announcements",
                          help: "Made from the name when left empty."),
                FieldSpec("position", "Order", .integer, help: "Lower numbers are listed first."),
            ]),
        ], sendOnlyChanges: true),
        summary: "Group blog posts into browsable categories.")

    /// Blog tags (`lapis/routes/cms-taxonomy.lua`). Tags are also made when a post is saved with a new one.
    static let cmsTags = ResourceDescriptor(
        id: "cms.tags", title: "Tags", noun: "tag", systemImage: "tag",
        api: ResourceAPISpec(list: "\(CMS.base)/tags", create: "\(CMS.base)/tags",
                             update: "\(CMS.base)/tags/{uuid}", delete: "\(CMS.base)/tags/{uuid}",
                             paging: .none, searchParam: "search", idKeys: ["uuid"]),
        permissions: ResourcePermissions(module: CMS.module),
        list: ListSpec(title: ["name"], subtitle: [FieldSpec("slug", "Address")],
                       trailing: FieldSpec("post_count", "Posts", .integer),
                       emptyTitle: "No tags yet",
                       emptyDescription: "Lightweight labels for topics that cut across categories.",
                       searchPrompt: "Search tags"),
        detail: [
            SectionSpec(nil, [
                FieldSpec("name", "Name"), FieldSpec("slug", "Web address (slug)"),
                FieldSpec("post_count", "Posts", .integer), FieldSpec("created_at", "Added", .dateTime),
            ], footer: "Deleting a tag removes it from every post."),
        ],
        form: FormSpec([
            SectionSpec(nil, [
                FieldSpec("name", "Name", required: true, placeholder: "e.g. Recipes"),
                FieldSpec("slug", "Web address (slug)", help: "Made from the name when left empty."),
            ]),
        ], sendOnlyChanges: true),
        summary: "Lightweight labels for cross-cutting topics.")
}
