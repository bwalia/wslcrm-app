import SwiftUI

/// Website content: the web dashboard's Content page, whose tabs are the rows here.
struct CMSHomeView: View {
    @Environment(\.services) private var services
    @State private var counts: [String: Int] = [:]

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Manage your website’s pages and blog: articles, pictures, categories and tags. "
                            + "When you publish, you can tell your website to update.", systemImage: "globe")
            }
            Section("Write") {
                NavigationLink { CMSPostsListView() } label: {
                    row("Blog posts", "Articles for your website’s blog.", "newspaper", count: counts["posts"])
                }
                .accessibilityIdentifier("cms.home.posts")
                NavigationLink { CMSPagesListView() } label: {
                    row("Pages", "About, Contact and other pages of your website.", "doc.on.doc", count: counts["pages"])
                }
                .accessibilityIdentifier("cms.home.pages")
                NavigationLink { CMSMediaLibraryView() } label: {
                    row("Media library", "Pictures to use in posts and pages: upload, describe, crop.", "photo.on.rectangle",
                        count: counts["media"])
                }
                .accessibilityIdentifier("cms.home.media")
            }
            Section("Organise") {
                NavigationLink(value: ResourceListRoute(ModuleCatalog.cmsCategories.id)) {
                    row("Categories", "Group posts into categories people can browse.", "folder", count: nil)
                }
                .accessibilityIdentifier("cms.home.categories")
                NavigationLink(value: ResourceListRoute(ModuleCatalog.cmsTags.id)) {
                    row("Tags", "Short labels for topics.", "tag", count: nil)
                }
                .accessibilityIdentifier("cms.home.tags")
            }
            Section("Publish") {
                NavigationLink { CMSWebhooksView() } label: {
                    row("Website updates", "Tell your website to refresh after you publish or change content.", "globe",
                        count: nil)
                }
                .accessibilityIdentifier("cms.home.webhooks")
            }
        }
        .navigationTitle("Content")
        .task { await loadCounts() }
        .wsRefreshable { await loadCounts() }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, count: Int?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 32, height: 32)
                .foregroundStyle(Tone.brand.textColor)
                .background(Tone.brand.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wsHeadline)
                Text(detail).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 4)
            if let count {
                Text(count.formatted()).font(.wsSubheadline.monospacedDigit()).foregroundStyle(.secondaryText)
                    .accessibilityLabel("\(count)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// How many posts, pages and images there are (each request is small; failures just hide the number).
    private func loadCounts() async {
        let api = services.cms
        async let posts = try? api.posts(page: 1, search: "", status: nil, category: nil, tag: nil, featuredOnly: false)
        async let pages = try? api.pages(search: "", status: nil)
        async let media = try? api.media(page: 1, search: "", type: nil, sort: nil)
        var found: [String: Int] = [:]
        if let posts = await posts { found["posts"] = posts.total }
        if let pages = await pages { found["pages"] = pages.count }
        if let media = await media { found["media"] = media.total }
        counts = found
    }
}
