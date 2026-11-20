import UIKit
import XCTest
@testable import WSLCRM

/// Website content (CMS): the server's response shapes, the bodies the app sends, the native content
/// editor's HTML reading and writing (nothing lost), media, website updates and cropping.
@MainActor
final class EngageCMSTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func record(_ text: String) throws -> Record {
        try XCTUnwrap(ResourceService.parseRecord(json(text), itemKey: nil, idKeys: ["uuid"]))
    }

    // A post as `CmsPostQueries.getByUuid` returns it (hydrated with category, categories and tags).
    private let postJSON = """
    {"success":true,"data":{"id":7,"uuid":"p-1","namespace_id":3,"title":"Spring sale","slug":"spring-sale",
    "excerpt":"Ten percent off","content_html":"<p>Hello <strong>all</strong></p>","content_json":"{\\"type\\":\\"doc\\"}",
    "featured_image_url":"/img/cms/ns/a.jpg","status":"scheduled","visibility":"public","is_featured":true,
    "author_uuid":"u-1","author_name":"Ann Lee","published_at":null,"scheduled_at":"2026-12-01 09:00:00",
    "seo_title":"Sale","seo_description":"","seo_keywords":"sale, spring","reading_minutes":1,"view_count":12,
    "category_id":4,"category":{"uuid":"c-1","name":"News","slug":"news"},
    "categories":[{"uuid":"c-1","name":"News","slug":"news"},{"uuid":"c-2","name":"Offers","slug":"offers"}],
    "tags":[{"uuid":"t-1","name":"Garden","slug":"garden"}],"created_at":"2026-11-01 10:00:00","updated_at":"2026-11-02 10:00:00"}}
    """

    // MARK: Lists

    func testThePostsListAndItsCamelCasePaging() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"uuid":"p-1","title":"A"},{"uuid":"p-2","title":"B"}],
         "meta":{"total":30,"page":1,"perPage":25,"totalPages":2}}
        """), listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 25)
        XCTAssertEqual(page.items.map(\.id), ["p-1", "p-2"])
        XCTAssertEqual(page.total, 30)
        XCTAssertTrue(page.hasMore)
    }

    func testMediaAndPagesShapes() throws {
        let media = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"uuid":"m-1","storage":"minio","url":"https://api.example.com/api/v2/public/media/m-1.jpg",
         "filename":"shop.jpg","mime_type":"image/jpeg","size_bytes":245760,"width":1200,"height":630,"alt_text":null,
         "title":null,"source_uuid":null,"uploaded_by_name":"Ann Lee"}],
         "meta":{"page":1,"per_page":24,"total":1,"total_pages":1}}
        """), listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 24)
        let asset = try XCTUnwrap(media.items.first)
        XCTAssertEqual(CMSMedia.facts(asset), "JPEG · 240 KB · 1200 × 630 px")
        XCTAssertEqual(CMSMedia.name(asset), "shop.jpg")
        XCTAssertFalse(media.hasMore)

        // Pages come all at once; lua-cjson sends no pages as {}.
        XCTAssertEqual(try json(#"{"success":true,"data":[{"uuid":"g-1","title":"About"}]}"#).engageRecords.map(\.id), ["g-1"])
        XCTAssertTrue(try json(#"{"success":true,"data":{}}"#).engageRecords.isEmpty)
    }

    func testCategoriesAndTagsAreDescribedAndParse() throws {
        let categories = try XCTUnwrap(ModuleCatalog.descriptor("cms.categories"))
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[{"id":4,"uuid":"c-1","namespace_id":3,"name":"News","slug":"news","description":"",
         "parent_id":null,"position":0,"post_count":"3"}]}
        """), listKey: categories.api.listKey, idKeys: categories.api.idKeys, requestedPage: 1, perPage: 0)
        XCTAssertEqual(page.items.first?.id, "c-1")
        XCTAssertEqual(RecordRow(record: try XCTUnwrap(page.items.first), list: categories.list).title, "News")
        XCTAssertNil(categories.api.item, "there is no single-category read: the row is the record")
        XCTAssertEqual(categories.permissions.module, "cms")
        XCTAssertEqual(try XCTUnwrap(ModuleCatalog.descriptor("cms.tags")).api.update, "/api/v2/cms/tags/{uuid}")
        // A category edit sends only what changed, so a blank slug or parent is never sent by accident.
        XCTAssertEqual(categories.form?.sendOnlyChanges, true)
    }

    func testTheMenuKeyOpensTheNativeContentHub() {
        XCTAssertEqual(NativeModules.destination(forKey: "cms"), .native(NativeScreenRoute(CMS.Screen.home)))
        for id in [CMS.Screen.home, CMS.Screen.posts, CMS.Screen.pages, CMS.Screen.media, CMS.Screen.webhooks,
                   "cms.post:p-1", "cms.page:g-1"] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertFalse(NativeModules.notYetNative.contains("cms"))
    }

    // MARK: Drafts and the bodies the server reads

    func testAPostIsReadIntoTheEditor() throws {
        let draft = CMSDraft(kind: .post, record: try record(postJSON))
        XCTAssertEqual(draft.title, "Spring sale")
        XCTAssertEqual(draft.status, .scheduled)
        XCTAssertEqual(draft.categoryUUIDs, ["c-1", "c-2"])
        XCTAssertEqual(draft.tags, ["Garden"])
        XCTAssertTrue(draft.isFeatured)
        XCTAssertNotNil(draft.scheduledAt)
        XCTAssertTrue(draft.slugTouched, "a saved slug never follows the title")
    }

    func testAnEditedPostSendsWhatCmsPostsLuaReads() throws {
        var draft = CMSDraft(kind: .post, record: try record(postJSON))
        draft.excerpt = ""
        draft.addTag("garden")      // already there, any case
        draft.addTag("  Tools ")
        let body = draft.body(isNew: false, contentChanged: false)
        XCTAssertEqual(body["excerpt"], .string(""), "a cleared summary is cleared on the server")
        XCTAssertNil(body["content_html"], "unchanged content isn't sent again")
        XCTAssertEqual(body["tags"], .array([.string("Garden"), .string("Tools")]))
        XCTAssertEqual(body["category_uuids"], .array([.string("c-1"), .string("c-2")]))
        XCTAssertEqual(body["is_featured"], .bool(true))
        XCTAssertEqual(body["status"], .string("scheduled"))
        XCTAssertEqual(body["scheduled_at"], .string("2026-12-01T09:00:00Z"))
        XCTAssertNil(body["template"], "pages only")

        let changed = draft.body(status: .draft, isNew: false, contentChanged: true)
        XCTAssertEqual(changed["status"], .string("draft"), "Save as draft")
        XCTAssertNil(changed["scheduled_at"])
        XCTAssertEqual(changed["content_json"], .string(""), "the web editor's stored JSON no longer matches")
        XCTAssertEqual(changed["content_html"], .string("<p>Hello <strong>all</strong></p>"))
    }

    func testANewPostLeavesBlanksOutAndNeedsATitle() {
        var draft = CMSDraft(kind: .post)
        XCTAssertEqual(draft.problem(saving: .draft), "Give it a title first.")
        draft.setTitle("Hello, World! Our 2026 News")
        XCTAssertEqual(draft.slug, "hello-world-our-2026-news", "the slug follows the title")
        draft.setSlug("my-own-")
        XCTAssertEqual(draft.slug, "my-own-", "a hyphen can be typed")
        draft.setTitle("Changed")
        XCTAssertEqual(draft.slug, "my-own-", "a slug the person typed stays")
        draft.status = .scheduled
        XCTAssertEqual(draft.problem(saving: .scheduled), "Choose when it should be published.")
        let body = draft.body(isNew: true, contentChanged: false)
        XCTAssertEqual(body["slug"], .string("my-own"))
        XCTAssertNil(body["excerpt"])
        XCTAssertNil(body["author_name"], "the server uses the signed-in person")
        XCTAssertEqual(body["visibility"], .string("public"))
    }

    func testAPageSendsItsMenuAndLayout() throws {
        var draft = CMSDraft(kind: .page, record: try record("""
        {"success":true,"data":{"uuid":"g-1","title":"About","slug":"about","status":"published","template":"",
         "menu_order":2,"show_in_nav":true,"content_html":"<p>Hi</p>"}}
        """))
        XCTAssertEqual(draft.menuOrder, 2)
        XCTAssertTrue(draft.showInNav)
        draft.template = ""
        let body = draft.body(isNew: false, contentChanged: false)
        XCTAssertEqual(body["template"], .string("default"))
        XCTAssertEqual(body["menu_order"], .number(2))
        XCTAssertEqual(body["show_in_nav"], .bool(true))
        XCTAssertNil(body["tags"])
        XCTAssertNil(body["visibility"])
        XCTAssertEqual(CMSPostStatus.pageCases, [.draft, .published, .archived])
    }

    func testSlugs() {
        XCTAssertEqual(CMSSlug.make("  Café & Bar — Opening!! "), "caf-bar-opening")
        XCTAssertEqual(CMSSlug.make("a--b__c"), "a-b__c")
        XCTAssertEqual(CMSSlug.typing("New post-"), "new-post-")
    }

    // MARK: The content editor: HTML in, blocks, HTML out

    private let editorHTML = """
    <p>Hello <strong>world</strong> and <a target="_blank" rel="noopener noreferrer nofollow" href="https://x.com">a link</a></p>\
    <h2 style="text-align: center">Title</h2>
    <ul><li><p>One</p></li><li><p>Two <em>it</em></p></li></ul><blockquote><p>Quote</p></blockquote>\
    <pre><code>let a = 1 &lt; 2</code></pre><img src="/img/a.png" alt="A"><hr>\
    <div class="academy-video"><iframe src="https://www.youtube.com/embed/abcdef" frameborder="0"></iframe></div>\
    <table style="min-width: 75px"><colgroup><col><col></colgroup><tbody><tr><th colspan="1" rowspan="1"><p>H1</p></th>\
    <th colspan="1" rowspan="1"><p>H2</p></th></tr><tr><td colspan="1" rowspan="1"><p>a</p></td><td colspan="1" \
    rowspan="1"><p>b</p></td></tr></tbody></table><div class="hero"><p>Kept</p></div>loose text<p class="lead">styled</p>
    """

    func testABodyIsReadIntoBlocksAndWrittenBackUntouched() {
        let document = CMSContentDocument(html: editorHTML)
        XCTAssertEqual(document.html, editorHTML, "nothing is lost or reformatted")
        XCTAssertEqual(document.blocks.map(\.title), [
            "Text", "Heading 2", "Bullet list", "Quote", "Code", "Picture", "Divider", "Video", "Table", "HTML", "Text", "HTML",
        ])
        guard case .heading(2, "Title", .center) = document.blocks[1].kind else { return XCTFail("\(document.blocks[1].kind)") }
        guard case .list(false, let items) = document.blocks[2].kind else { return XCTFail() }
        XCTAssertEqual(items, ["One", "Two <em>it</em>"])
        guard case .code("let a = 1 < 2") = document.blocks[4].kind else { return XCTFail("\(document.blocks[4].kind)") }
        guard case .table(let rows, true) = document.blocks[8].kind else { return XCTFail() }
        XCTAssertEqual(rows, [["H1", "H2"], ["a", "b"]])
        guard case .html(let raw) = document.blocks[11].kind else { return XCTFail() }
        XCTAssertEqual(raw, #"<p class="lead">styled</p>"#, "a paragraph with a class is kept as HTML")
    }

    func testChangedBlocksAreWrittenTheWayTheWebEditorWritesThem() {
        var document = CMSContentDocument(html: editorHTML)
        for index in document.blocks.indices {
            document.blocks[index] = document.blocks[index].changed(to: document.blocks[index].kind)
        }
        let again = CMSContentDocument(html: document.html)
        XCTAssertEqual(again.blocks.map(\.kind), CMSContentDocument(html: editorHTML).blocks.map(\.kind))
        XCTAssertTrue(document.html.contains("<ul><li><p>One</p></li><li><p>Two <em>it</em></p></li></ul>"))
        XCTAssertTrue(document.html.contains(#"<div class="academy-video"><iframe src="https://www.youtube.com/embed/abcdef""#))
        XCTAssertTrue(document.html.contains("<table><tbody><tr><th><p>H1</p></th>"))
        XCTAssertEqual(CMSBlock.html(.paragraph(html: "Hi", align: .right)), #"<p style="text-align: right">Hi</p>"#)
        XCTAssertEqual(CMSBlock.html(.image(src: "a\"b.png", alt: "", title: "")), #"<img src="a&quot;b.png">"#)
        XCTAssertTrue(CMSContentDocument(html: "").blocks.isEmpty)
    }

    func testInlineFormattingRoundTrips() {
        let html = "Plain <strong>bold</strong> <em>it</em> <u>u</u> <s>gone</s> <code>x()</code> "
            + "<mark>hi</mark> <span style=\"color: #e11d48\">red</span> H<sub>2</sub>O "
            + "<a target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"https://a.co?x=1&amp;y=2\">go</a><br>next"
        XCTAssertTrue(CMSInline.isEditable(html))
        let text = CMSInline.attributed(html)
        XCTAssertEqual(text.string, "Plain bold it u gone x() hi red H2O go\nnext")
        XCTAssertEqual(CMSInline.html(text), html)
        let nested = #"<strong>bold <em>both</em></strong> <a target="_blank" rel="noopener noreferrer nofollow" "#
            + #"href="https://x"><strong>b</strong>l</a>"#
        XCTAssertEqual(CMSInline.html(CMSInline.attributed(nested)), nested, "only what changes is closed and opened")
        XCTAssertFalse(CMSInline.isEditable(#"<span class="x">a</span>"#), "unknown styling is kept as HTML instead")
        XCTAssertFalse(CMSInline.isEditable(#"<span style="font-size: 20px">a</span>"#))
        XCTAssertEqual(CMSInline.hex(fromCSS: "rgb(225, 29, 72)"), "#e11d48")
    }

    func testEachLineOfAListIsAnItem() {
        let text = CMSInline.attributed("<strong>One</strong><br>Two<br><br>Three")
        guard case .list(true, let items) = CMSBlockEditorView.textKind(.numbers, text: text, align: .left, headingLevel: 2) else {
            return XCTFail()
        }
        XCTAssertEqual(items, ["<strong>One</strong>", "Two", "Three"], "empty lines are dropped")
        guard case .heading(1, "Hi", .center) = CMSBlockEditorView.textKind(.heading1, text: NSAttributedString(string: "\nHi\n"),
                                                                             align: .center, headingLevel: 2) else {
            return XCTFail()
        }
    }

    func testVideoLinksAndSitePaths() {
        XCTAssertEqual(CMSVideo.embedURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "https://www.youtube.com/embed/dQw4w9WgXcQ")
        XCTAssertEqual(CMSVideo.embedURL("https://youtu.be/dQw4w9WgXcQ"), "https://www.youtube.com/embed/dQw4w9WgXcQ")
        XCTAssertEqual(CMSVideo.embedURL("https://vimeo.com/76979871"), "https://player.vimeo.com/video/76979871")
        XCTAssertNil(CMSVideo.embedURL("https://example.com/video.mp4"))
        XCTAssertEqual(CMSPreview.resolve(#"<img src="/img/a.png"><a href="//cdn.x/y">"#, siteURL: "https://site.com/"),
                       #"<img src="https://site.com/img/a.png"><a href="//cdn.x/y">"#)
        XCTAssertEqual(CMSMedia.displayURL("/img/a.png", siteURL: "https://site.com")?.absoluteString, "https://site.com/img/a.png")
        XCTAssertNil(CMSMedia.displayURL("/img/a.png", siteURL: nil), "a site path with no website address can't be shown")
        XCTAssertEqual(CMSMedia.displayURL("https://cdn.x/a.png", siteURL: nil)?.host(), "cdn.x")
    }

    // MARK: Media

    func testDeletingSaysWhereAnImageIsUsed() throws {
        let used = try record("""
        {"data":{"uuid":"m-1","storage":"minio","url":"u","used_in":[{"kind":"post","uuid":"p-1","title":"Sale","status":"published"}]}}
        """)
        let message = CMSMedia.deleteMessage(used)
        XCTAssertEqual(message.title, "Delete this image?")
        XCTAssertTrue(message.message.hasPrefix("It is used in 1 post or page (“Sale”). They will show a broken image."))
        let link = try record(#"{"data":{"uuid":"m-2","storage":"link","url":"/img/x.jpg","used_in":{}}}"#)
        XCTAssertEqual(CMSMedia.deleteMessage(link).button, "Remove from library")
    }

    func testUploadFieldsAndPreparedPhotos() throws {
        XCTAssertTrue(CMSUploadFields().multipart.isEmpty)
        let fields = CMSUploadFields(altText: "Shop front", title: " ", width: 1200, height: 630, sourceUUID: "m-1")
        XCTAssertEqual(fields.multipart.map(\.0), ["alt_text", "source_uuid", "width", "height"])

        let wide = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000),
                                           format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { context in UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000)) }
        let prepared = try CMSImagePrep.prepare(try XCTUnwrap(wide.jpegData(compressionQuality: 0.8)), type: .jpeg, name: "big.jpeg")
        XCTAssertEqual(prepared.width, 2560)
        XCTAssertEqual(prepared.height, 853)
        XCTAssertEqual(prepared.file.name, "big.jpg")
        XCTAssertEqual(prepared.file.mimeType, "image/jpeg")
        XCTAssertThrowsError(try CMSImagePrep.prepare(Data("not a picture".utf8), type: .plainText, name: "a.txt")) { error in
            XCTAssertEqual(error as? CMSImagePrep.Problem, .notAnImage("a.txt"))
        }
    }

    func testCroppingMaths() throws {
        // A 2000 × 1000 picture in a 300 × 300 frame: it fills the frame by height.
        var geometry = CMSCropGeometry(image: CGSize(width: 2000, height: 1000), frame: CGSize(width: 300, height: 300),
                                       zoom: 1, offset: .zero)
        XCTAssertEqual(geometry.area.minX, 500, accuracy: 0.001)
        XCTAssertEqual(geometry.area.minY, 0, accuracy: 0.001)
        XCTAssertEqual(geometry.area.width, 1000, accuracy: 0.001)
        XCTAssertEqual(geometry.area.height, 1000, accuracy: 0.001)
        let clamped = geometry.clamped(CGSize(width: 999, height: 50))
        XCTAssertEqual(clamped.width, 150, accuracy: 0.001, "the picture always covers the frame")
        XCTAssertEqual(clamped.height, 0, accuracy: 0.001)
        geometry.zoom = 2
        geometry.offset = CGSize(width: 75, height: 0)
        XCTAssertEqual(geometry.area.width, 500, accuracy: 0.001)
        XCTAssertEqual(geometry.area.minX, 625, accuracy: 0.001)
        XCTAssertEqual(CMSCropGeometry.frame(ratio: 16.0 / 9.0, in: CGSize(width: 320, height: 320)).height, 180, accuracy: 0.01)

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20),
                                              format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20)) }
        XCTAssertEqual(CMSImagePrep.rotated(picture, quarterTurns: 1).size, CGSize(width: 20, height: 40))
        let cropped = try XCTUnwrap(CMSImagePrep.crop(picture, area: CGRect(x: 10, y: 0, width: 20, height: 20), width: 64))
        XCTAssertEqual(cropped.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(CMSImagePrep.editedType(for: "image/gif").ext, "png", "GIF and WebP copies are saved as PNG")
    }

    // MARK: Website updates

    func testDeliveriesInPlainWords() {
        XCTAssertTrue(CMSWebhookText.explain(status: 204).ok)
        XCTAssertTrue(CMSWebhookText.explain(status: 401).text.contains("secret key"))
        XCTAssertTrue(CMSWebhookText.explain(status: 404).text.hasPrefix("Nothing was found"))
        XCTAssertTrue(CMSWebhookText.explain(status: nil, error: "host resolves to a private address").text
            .contains("public website address"))
        XCTAssertTrue(CMSWebhookText.explain(status: nil, error: "timeout").text.hasPrefix("Couldn’t reach"))

        // A refused delivery comes back as HTTP 502 with the receiver's status: an answer, not an error.
        let refused = CMSDelivery(rawBody: #"{"success":false,"error":"HTTP 500","status":500}"#)
        XCTAssertEqual(refused, CMSDelivery(success: false, status: 500, error: "HTTP 500"))
        XCTAssertTrue(refused?.explanation.text.contains("HTTP 500") ?? false)
        XCTAssertEqual(CMSDelivery(answer: .object(["success": .bool(true), "status": .number(200)])).explanation.ok, true)
    }

    func testWebsitesAreSavedAsTheServerReadsThem() throws {
        XCTAssertEqual(CMSAPI.webhookBody(name: " ", url: " https://site.com/hook ", active: false),
                       .object(["url": .string("https://site.com/hook"), "active": .bool(false)]))
        XCTAssertTrue(CMSWebhookText.looksLikeAddress("https://vercel.com/api/deploy/abc"))
        XCTAssertFalse(CMSWebhookText.looksLikeAddress("www.site.com"))
        XCTAssertEqual(CMSWebhookText.saveError("url must be a public host"),
                       "That address can’t be used: it must be a public website address (https://…).")
        let never = try record(#"{"data":{"uuid":"w-1","url":"https://s.com","active":true,"last_triggered_at":null}}"#)
        XCTAssertNil(CMSWebhookText.lastDelivery(never).ok)
        let failed = try record(#"{"data":{"uuid":"w-1","url":"https://s.com","last_status":403,"last_triggered_at":"2026-11-02 10:00:00"}}"#)
        XCTAssertEqual(CMSWebhookText.lastDelivery(failed).ok, false)
        XCTAssertTrue(CMSWebhookText.developerMessage(url: "https://s.com/h").contains("https://s.com/h"))
        XCTAssertFalse(CMSWebhookText.developerMessage(url: "https://s.com/h").contains("secret\":"), "never the key itself")
    }
}
