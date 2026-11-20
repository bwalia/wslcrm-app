import UIKit
import XCTest
@testable import WSLCRM

/// Marketing Cloud's design side: the native email block editor (reading designs into blocks and
/// writing them back unchanged), inline formatting, templates, merge fields and website pixels.
/// Shapes come from projects/opsapi-marketing (blocks.lua, templates.lua, api/pixels.lua).
final class EngageMarketingDesignTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    /// The "Welcome — new customer" ready-made design, built exactly as blocks.lua builds it.
    static let welcome: String = {
        let font = "font-family:Poppins,'Helvetica Neue',Helvetica,Arial,sans-serif"
        let display = "font-family:Unbounded,Poppins,'Helvetica Neue',Helvetica,Arial,sans-serif;"
        let inner = [
            "<p style=\"margin:0 0 28px;font-family:'JetBrains Mono',ui-monospace,Menlo,Consolas,monospace;font-size:12px;"
                + "font-weight:500;letter-spacing:2px;text-transform:uppercase;color:#059669\">[Your business name]</p>",
            "<h1 style=\"margin:0 0 24px;padding:40px 28px;background:#059669;color:#ffffff;border-radius:12px;" + display
                + "font-size:28px;line-height:1.2;font-weight:700;text-align:center\">Welcome aboard</h1>",
            "<p style=\"margin:0 0 16px\">Hi {{contact.first_name}},</p>",
            "<h2 style=\"margin:28px 0 8px;" + display + "font-size:19px;line-height:1.3;font-weight:700;color:#111827\">"
                + "What you can expect</h2>",
            "<ul><li><p><strong>Helpful tips</strong> — no more than one email a month.</p></li>"
                + "<li><p><strong>First access</strong> to new products and offers.</p></li></ul>",
            "<p style=\"margin:28px 0;text-align:center\"><a href=\"https://yourwebsite.co.uk\" style=\"display:inline-block;"
                + "background:#059669;color:#ffffff;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:600\">"
                + "Get started</a></p>",
            "<p style=\"margin:28px 0 0\">Best wishes,<br><strong>[Your name]</strong><br>[Your business name]</p>",
            "<p style=\"margin:32px 0 0;padding-top:20px;border-top:1px solid #e5e7eb;font-size:12px;line-height:1.5;"
                + "color:#6b7280;text-align:center\">You’re getting this because you’re a customer.<br>"
                + "<a href=\"{{unsubscribe_url}}\" style=\"color:#6b7280\">Unsubscribe</a> · "
                + "<a href=\"{{preferences_url}}\" style=\"color:#6b7280\">Email preferences</a></p>",
        ]
        return "<div style=\"" + font + ";max-width:600px;margin:0 auto;padding:36px 32px;background:#ffffff;"
            + "color:#1f2937;font-size:16px;line-height:1.65;border:1px solid #e5e7eb;border-radius:16px\">\n"
            + inner.joined(separator: "\n") + "\n</div>"
    }()

    // MARK: Blocks

    func testAReadyMadeDesignBecomesBlocksOnItsCard() {
        let document = MktEmailDocument.parse(Self.welcome)
        XCTAssertNotNil(document.frameOpen, "the white card is kept around the blocks")
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .heading, .paragraph, .heading, .list, .button,
                                                     .paragraph, .paragraph])
        XCTAssertEqual(document.blocks[1].level, 1)
        XCTAssertEqual(document.blocks[1].style.align, .center)
        XCTAssertEqual(document.blocks[4].items.count, 2)
        XCTAssertTrue(document.blocks[4].itemsInParagraphs)
        XCTAssertEqual(document.blocks[5].text, "Get started")
        XCTAssertEqual(document.blocks[5].href, "https://yourwebsite.co.uk")
        XCTAssertEqual(document.blocks[5].buttonColour, "#059669")
        XCTAssertFalse(document.blocks.contains(where: \.simplified), "the designs use only what the editor keeps")
    }

    func testOpeningAndSavingNeverChangesADesign() {
        XCTAssertEqual(MktEmailDocument.parse(Self.welcome).html, Self.welcome)
    }

    func testEditingOneBlockRewritesOnlyThatBlock() {
        var document = MktEmailDocument.parse(Self.welcome)
        var greeting = document.blocks[2]
        greeting.text = "Hello {{contact.first_name}},"
        greeting.original = nil
        document.blocks[2] = greeting
        let html = document.html
        XCTAssertTrue(html.contains("<p style=\"margin:0 0 16px\">Hello {{contact.first_name}},</p>"))
        XCTAssertFalse(html.contains("Hi {{contact.first_name}}"))
        XCTAssertEqual(html.replacingOccurrences(of: "Hello {{contact", with: "Hi {{contact"), Self.welcome)
    }

    func testButtonColoursFollowTheWebStudio() {
        var button = MktEmailDocument.parse(Self.welcome).blocks[5]
        button.setButtonColour("#fde68a")
        button.original = nil
        XCTAssertEqual(button.linkStyle["background"], "#fde68a")
        XCTAssertEqual(button.linkStyle["color"], "#111827", "dark words on a light button")
        XCTAssertEqual(button.linkStyle["padding"], "14px 28px", "the design's own spacing is kept")
        XCTAssertEqual(MktEmailHTML.textOn("#111827"), "#ffffff")
        XCTAssertTrue(button.html.hasPrefix("<p style=\"margin:28px 0;text-align:center\"><a href=\"https://yourwebsite.co.uk\""))

        let fresh = MktEmailBlock.newButton(label: "Book a call & save", href: "https://example.com/?a=1&b=2", colour: "#2563eb")
        XCTAssertEqual(fresh.html, "<p style=\"margin:24px 0;text-align:center\"><a href=\"https://example.com/?a=1&amp;b=2\""
                       + " style=\"display:inline-block;background:#2563eb;color:#ffffff;padding:12px 22px;border-radius:6px;"
                       + "text-decoration:none;font-weight:600\">Book a call &amp; save</a></p>")
        let reread = MktEmailDocument.blocks(fresh.html)
        XCTAssertEqual(reread.first?.kind, .button)
        XCTAssertEqual(reread.first?.href, "https://example.com/?a=1&b=2")
        XCTAssertEqual(reread.first?.text, "Book a call & save")
    }

    func testTableLayoutsAndUnknownMarkupAreKeptAsWritten() {
        let html = "<table width=\"100%\"><tr><td>Left</td><td>Right</td></tr></table>\n<!-- note -->\n"
            + "<blockquote>Quote</blockquote>\n<p>After</p>"
        let document = MktEmailDocument.parse(html)
        XCTAssertNil(document.frameOpen)
        XCTAssertEqual(document.blocks.map(\.kind), [.html, .html, .html, .paragraph])
        XCTAssertEqual(document.html, html.replacingOccurrences(of: "\n\n", with: "\n"))
        XCTAssertTrue(MktEmailDocument.hasTableLayout(html))
        XCTAssertTrue(MktEmailDocument.isWholeDocument("<!doctype html><html><body>x</body></html>"))
    }

    func testNestedElementsOfTheSameNameAreMatched() {
        let nodes = MktEmailHTMLScanner.nodes("<div a=\"1\"><div>in</div><p>x</p></div>tail<br/>")
        XCTAssertEqual(nodes.count, 3)
        guard case .element(let outer) = nodes[0] else { return XCTFail() }
        XCTAssertEqual(outer.inner, "<div>in</div><p>x</p>")
        XCTAssertEqual(outer.attributes["a"], "1")
        guard case .text("tail") = nodes[1], case .element(let br) = nodes[2] else { return XCTFail() }
        XCTAssertEqual(br.name, "br")
    }

    func testSpacersListsAndPictures() {
        let spacer = MktEmailBlock.newSpacer(height: 32)
        XCTAssertEqual(MktEmailDocument.blocks(spacer.html).first?.kind, .spacer)
        XCTAssertEqual(MktEmailDocument.blocks(spacer.html).first?.height, 32)

        var list = MktEmailBlock.newList(ordered: true)
        list.items = ["One", "<strong>Two</strong>"]
        XCTAssertEqual(list.html, "<ol><li><p>One</p></li><li><p><strong>Two</strong></p></li></ol>")
        let plain = MktEmailDocument.blocks("<ul><li>a</li><li>b <em>c</em></li></ul>").first
        XCTAssertEqual(plain?.items, ["a", "b <em>c</em>"])
        XCTAssertEqual(plain?.itemsInParagraphs, false)
        XCTAssertEqual(MktEmailDocument.blocks("<ul><li>a<ul><li>b</li></ul></li></ul>").first?.kind, .html,
                       "nested lists are kept as HTML")

        var picture = MktEmailBlock.newImage(src: "https://example.com/a.png", alt: "Shop \"front\"")
        picture.setImageWidth("200px")
        XCTAssertEqual(picture.html, "<img src=\"https://example.com/a.png\" alt=\"Shop &quot;front&quot;\" "
                       + "style=\"width:200px;max-width:100%;height:auto;display:block\">")
        let wrapped = MktEmailDocument.blocks("<p style=\"text-align:center\"><img src=\"x.png\" alt=\"\"></p>").first
        XCTAssertEqual(wrapped?.kind, .image)
        XCTAssertEqual(wrapped?.imageWrapped, true)
        XCTAssertEqual(wrapped?.style.align, .center)
    }

    func testTheUnsubscribeBlockIsAParagraphWithLinks() {
        let blocks = MktEmailDocument.blocks(MktEmailBlock.unsubscribeHTML)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(blocks.first?.html, MktEmailBlock.unsubscribeHTML)
        XCTAssertTrue(blocks.first?.summary.contains("Unsubscribe") ?? false)
    }

    func testCSSEditsKeepTheOrder() {
        var css = MktEmailCSS("margin:0 0 16px; color: #111; text-align:left")
        XCTAssertEqual(css["color"], "#111")
        css.setAlign(.center)
        css["color"] = nil
        css["padding"] = "4px"
        XCTAssertEqual(css.text, "margin:0 0 16px;text-align:center;padding:4px")
        XCTAssertEqual(MktEmailHTML.hex("rgb(5, 150, 105)"), "#059669")
        XCTAssertEqual(MktEmailHTML.hex("#ABC"), "#aabbcc")
    }

    func testLinksMustGoSomewhereReal() {
        XCTAssertNil(MktEmailHTML.hrefProblem("https://example.com"))
        XCTAssertNil(MktEmailHTML.hrefProblem("mailto:me@example.com"))
        XCTAssertNil(MktEmailHTML.hrefProblem("tel:+44 7700 900123"))
        XCTAssertNil(MktEmailHTML.hrefProblem("{{unsubscribe_url}}"))
        XCTAssertNotNil(MktEmailHTML.hrefProblem("example.com"))
        XCTAssertNotNil(MktEmailHTML.hrefProblem("javascript:alert(1)"))
    }

    // MARK: Inline formatting

    func testInlineFormattingSurvivesTheTextEditor() {
        let source = "Hi <strong>Ann</strong>, <em>see</em> <u>this</u>. "
            + "<a href=\"{{unsubscribe_url}}\" style=\"color:#6b7280\">Unsubscribe</a>"
        let styled = MktEmailInline.attributed(source)
        XCTAssertEqual(styled.string, "Hi Ann, see this. Unsubscribe")
        XCTAssertEqual(MktEmailInline.html(styled), source)
    }

    func testColoursHighlightsAndLineBreaks() {
        let source = "<span style=\"color:#e11d48\">Red</span> and <mark>marked</mark><br>next line"
        let styled = MktEmailInline.attributed(source)
        XCTAssertEqual(styled.string, "Red and marked\nnext line")
        XCTAssertEqual(MktEmailInline.html(styled), source)
        XCTAssertTrue(MktEmailInline.isSupported(source))
        XCTAssertFalse(MktEmailInline.isSupported("<span style=\"font-size:20px\">Big</span>"))
        XCTAssertFalse(MktEmailInline.isSupported("Text <img src=\"x.png\">"))
        XCTAssertEqual(MktEmailInline.html(NSAttributedString(string: "Fish & <chips>")), "Fish &amp; &lt;chips&gt;")
    }

    // MARK: Templates

    static let templateRow = """
    {"id":5,"uuid":"6f1c3a52-6a0e-4a9e-9a3e-1d2b3c4d5e6f","namespace_id":1,"name":"Welcome","channel":"email",
     "subject":"Hi {{contact.first_name}}","preview_text":null,"body_html":"<p>Hi</p>","body_text":"Hi","status":"published",
     "version":2,"parent_uuid":null,"created_by":null,"published_at":"2026-10-20 12:00:00+00",
     "created_at":"2026-10-20 11:00:00+00","updated_at":"2026-10-21 09:30:00+00"}
    """

    func testTemplatesParseFromTheCrudList() throws {
        let page = ResourceService.parsePage(try json("""
        {"success":true,"data":[\(Self.templateRow)],"meta":{"page":1,"per_page":25,"total":1,"total_pages":1}}
        """), listKey: nil, idKeys: ["uuid"], requestedPage: 1, perPage: 25)
        let template = MktTemplate(record: try XCTUnwrap(page.items.first))
        XCTAssertEqual(template.uuid, "6f1c3a52-6a0e-4a9e-9a3e-1d2b3c4d5e6f")
        XCTAssertEqual(template.previewText, "")
        XCTAssertEqual(template.version, 2)
        XCTAssertEqual(template.status, "published")
        XCTAssertEqual(template.design.bodyHTML, "<p>Hi</p>")
        XCTAssertFalse(page.hasMore)
    }

    func testStudioBodiesMatchTheServer() {
        let sms = MktTemplate(name: "  ", channel: "sms", bodyHTML: "<p>ignored</p>", bodyText: "Hi. Reply STOP")
        XCTAssertEqual(sms.body(status: "draft"), .object([
            "name": .string("Untitled"), "channel": .string("sms"), "subject": .string(""), "preview_text": .string(""),
            "body_text": .string("Hi. Reply STOP"), "status": .string("draft"),
        ]), "an SMS template sends no body_html (null would be stored as an empty string)")
        let email = MktTemplate(name: "News", subject: "Hello", bodyHTML: "<p>x</p>", bodyText: "x")
        XCTAssertEqual(email.body(status: nil)["body_html"], .string("<p>x</p>"))
        XCTAssertNil(email.body(status: nil)["status"], "publishing keeps the stored status until the publish call")
        XCTAssertEqual(MktDesignAPI.previewBody(sms)["body_html"], nil)
        XCTAssertEqual(MktDesignAPI.previewBody(email)["name"], .string("News"))
    }

    func testStudioSaveAndPreviewAnswers() throws {
        let saved = MktDesignAPI.studioSaved(try json("""
        {"success":true,"data":{"template":\(Self.templateRow),
         "analysis":{"ok":false,"warnings":["missing_unsubscribe_link","unknown_merge:contact.nickname"],
                     "merge_fields":[],"unknown_merge":["contact.nickname"],"sanitised":{}}}}
        """), fallback: MktTemplate())
        XCTAssertEqual(saved.0.name, "Welcome")
        XCTAssertEqual(saved.1, ["missing_unsubscribe_link", "unknown_merge:contact.nickname"])
        XCTAssertTrue(MktTemplateWarnings.describe(saved.1[1]).contains("{{contact.nickname}}"))
        XCTAssertTrue(MktTemplateWarnings.describe("missing_unsubscribe_link").contains("unsubscribe"))
        XCTAssertNotNil(MktTemplateWarnings.publishProblem("unknown_merge_fields"))
        XCTAssertNil(MktTemplateWarnings.publishProblem("not_found"))

        let preview = MktTemplatePreview(try json("""
        {"success":true,"data":{"channel":"email","subject":"Hi Alex","html":"<p>Hi Alex</p>","text":"Hi Alex",
         "warnings":{},"merge_fields":["contact.first_name"],"opens_estimated":true}}
        """).payload)
        XCTAssertEqual(preview.subject, "Hi Alex")
        XCTAssertEqual(preview.warnings, [], "lua-cjson's {} is an empty list")
        XCTAssertTrue(preview.opensEstimated)
    }

    func testMergeFieldsGoIntoTheLastParagraph() {
        let html = MktTemplateEditorView.appendToLastParagraph(Self.welcome, "{{contact.company}}")
        XCTAssertTrue(html.contains("Email preferences</a> {{contact.company}}</p>"))
        XCTAssertTrue(html.hasSuffix("\n</div>"), "the card stays")
        XCTAssertEqual(MktTemplateEditorView.appendToLastParagraph("", "{{contact.first_name}}"),
                       "<p>{{contact.first_name}}</p>")
        let plain = MktTemplateEditorView.plainVersion(of: Self.welcome)
        XCTAssertTrue(plain.contains("- Helpful tips — no more than one email a month."))
        XCTAssertTrue(plain.contains("Get started: https://yourwebsite.co.uk"))
        XCTAssertEqual(MktEmailSample.fill("Hi {{contact.first_name}}, {{unsubscribe_url}}"), "Hi Alex, #")
        let field = MktTemplateMergeField(record: Record(["key": .string("contact.first_name"), "label": .string("First name")]))
        XCTAssertEqual(field?.token, "{{contact.first_name}}")
    }

    // MARK: Pictures

    func testPicturesAreMadeReadyForEmail() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let png = renderer.pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let kept = try XCTUnwrap(MktEmailImages.prepare(png, type: .png, name: "dot.png"))
        XCTAssertEqual(kept.data, png, "a small PNG goes as it is")
        XCTAssertEqual(kept.mimeType, "image/png")
        let converted = try XCTUnwrap(MktEmailImages.prepare(png, type: .heic, name: "IMG_1.heic"))
        XCTAssertEqual(converted.mimeType, "image/jpeg", "the server takes PNG, JPEG, GIF or WebP only")
        XCTAssertEqual(converted.name, "IMG_1.jpg")
        XCTAssertNil(MktEmailImages.prepare(Data("not a picture".utf8), type: .plainText, name: "a.txt"))
    }

    // MARK: Pixels

    static let pixelRow = """
    {"id":3,"uuid":"0b5d1e3c-1111-4222-8333-944455566677","namespace_id":1,"name":"Main site","public_key":"px_ab12",
     "allowed_domains":["example.com","shop.example.com"],"attribution_window_days":30,"is_active":true,
     "last_event_at":null,"created_at":"2026-11-01 10:00:00+00","updated_at":"2026-11-01 10:00:00+00",
     "events_24h":12,"conversions_30d":"3","install_status":"waiting"}
    """

    func testPixelsParseWithTheirStatus() throws {
        let rows = try json(#"{"success":true,"data":[\#(Self.pixelRow)]}"#).engageRecords
        let pixel = MktPixel(record: try XCTUnwrap(rows.first))
        XCTAssertEqual(pixel.allowedDomains, ["example.com", "shop.example.com"])
        XCTAssertEqual(pixel.events24h, 12)
        XCTAssertEqual(pixel.conversions30d, 3)
        XCTAssertEqual(pixel.statusLabel, "Waiting for first event")
        var paused = pixel
        paused.isActive = false
        XCTAssertEqual(paused.statusLabel, "Paused")
        let empty = MktPixel(record: Record(["uuid": .string("p"), "allowed_domains": .object([:])]))
        XCTAssertEqual(empty.allowedDomains, [], "lua-cjson's {} is an empty list")
    }

    func testPixelFormsSendWhatTheServerReads() {
        XCTAssertEqual(MktPixel.parseDomains("Example.com, shop.example.com\nexample.com; a.io"),
                       ["example.com", "shop.example.com", "a.io"])
        XCTAssertNil(MktPixel.windowProblem("30"))
        XCTAssertNotNil(MktPixel.windowProblem("0"))
        XCTAssertNotNil(MktPixel.windowProblem("91"))
        XCTAssertNotNil(MktPixel.windowProblem("7.5"))
        XCTAssertEqual(MktDesignAPI.pixelBody(name: "Site", domains: ["a.io"], windowDays: 7, active: nil), .object([
            "name": .string("Site"), "allowed_domains": .array([.string("a.io")]), "attribution_window_days": .number(7),
        ]))
        XCTAssertEqual(MktDesignAPI.pixelBody(name: "Site", domains: [], windowDays: 7, active: false)["is_active"], .bool(false))
    }

    func testLiveEventsMergeNewestFirst() throws {
        let rows = try json("""
        {"success":true,"data":[{"id":42,"uuid":"e1","event_name":"purchase","url":"https://shop.example.com/thanks?o=1",
         "referrer":null,"value":"49.99","currency":"GBP","order_id":"ORDER-123","utm_source":"newsletter",
         "utm_medium":"email","utm_campaign":"spring","properties":{},"is_bot":false,"is_test":false,"is_conversion":true,
         "contact_uuid":"c1","created_at":"2026-11-20 10:00:00+00","campaign_name":"Spring sale","campaign_uuid":"k1",
         "visitor_key":"v1","contact_name":"Ann Lee"},
         {"id":41,"uuid":"e0","event_name":"page_view","url":"https://shop.example.com/","is_bot":true,"is_test":false,
          "is_conversion":false,"created_at":"2026-11-20 09:59:00+00"}]}
        """).engageRecords
        let events = rows.map(MktPixelEvent.init(record:))
        XCTAssertEqual(events[0].value, 49.99)
        XCTAssertEqual(events[0].campaignUUID, "k1")
        XCTAssertTrue(events[0].matches(.conversions))
        XCTAssertTrue(events[0].matches(.attributed))
        XCTAssertTrue(events[1].matches(.bots))
        XCTAssertFalse(events[1].matches(.attributed))
        XCTAssertEqual(MktPixelEvent.path(events[0].url), "shop.example.com/thanks?o=1")

        let older = [events[1]]
        let merged = MktPixelEvent.merge(older, events)
        XCTAssertEqual(merged.map(\.id), [42, 41], "no repeats, newest first")
        XCTAssertEqual(MktPixelEvent.merge(merged, []), merged)
        let many = (1...250).map { id in MktPixelEvent(record: Record(["id": .number(Double(id))])) }
        XCTAssertEqual(MktPixelEvent.merge([], many).count, 200)
    }

    func testPixelResultsReadTheStatsRoute() throws {
        let stats = try XCTUnwrap(try json("""
        {"success":true,"data":{"days":30,"totals":{"events":120,"visitors":40,"identified":5,"attributed_events":9,
         "conversions":3,"revenue":149.5,"bot_events":2},
         "daily":[{"day":"2026-11-19","page_views":30,"conversions":1,"visitors":10},
                  {"day":"2026-11-20","page_views":50,"conversions":2,"visitors":20}],
         "top_events":[{"event_name":"page_view","n":100}],"top_pages":{},
         "forwards":[{"destination":"meta","status":"dry_run","n":2}]}}
        """).engageRecord)
        XCTAssertEqual(stats.double("totals.revenue"), 149.5)
        let days = MktPixelDay.rows(stats)
        XCTAssertEqual(days.map(\.pageViews), [30, 50])
        XCTAssertEqual(days.last?.conversions, 2)
        XCTAssertEqual(stats.records("top_pages").count, 0)
        XCTAssertEqual(MktPixelForwarding.destination("meta"), "Meta Conversions API")
        XCTAssertEqual(MktPixelForwarding.status("dry_run"), "Test mode (not sent)")
    }

    // MARK: Menu

    @MainActor
    func testEveryDesignMenuKeyOpensANativeScreen() {
        let group = ModuleGroup.engageMarketingDesign
        XCTAssertEqual(Set(group.screens.keys), ["plugin:opsapi_marketing:studio", "plugin:opsapi_marketing:templates",
                                                 "plugin:opsapi_marketing:pixels"])
        for (key, id) in group.screens {
            XCTAssertNotNil(group.screen(id), key)
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
        }
        XCTAssertNil(group.screen("mkt.campaigns"), "other parts' screens aren't drawn here")
    }
}
