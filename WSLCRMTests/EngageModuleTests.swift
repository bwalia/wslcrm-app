import XCTest
@testable import WSLCRM

/// The engage area's shared pieces: rich content is read natively (never a web view).
final class EngageModuleTests: XCTestCase {
    func testHTMLBecomesNativeBlocks() {
        let doc = RichDocument.html("""
        <h2>Hello <b>Ann</b></h2><p>First &amp; <a href="https://example.com">second</a>.</p>
        <ul><li>One</li><li>Two</li></ul><img src="https://example.com/a.png" alt="Logo"><hr>
        <script>alert(1)</script><p style="text-align:center">Middle</p>
        """)
        XCTAssertEqual(doc.blocks.count, 7)
        guard case .heading(2, let title, _) = doc.blocks[0] else { return XCTFail("\(doc.blocks[0])") }
        XCTAssertEqual(String(title.characters), "Hello Ann")
        XCTAssertEqual(doc.plainText.contains("alert"), false, "scripts are never content")
        guard case .listItem(false, 2, 0, let two) = doc.blocks[3] else { return XCTFail("\(doc.blocks[3])") }
        XCTAssertEqual(String(two.characters), "Two")
        guard case .paragraph(_, .center, _) = doc.blocks[6] else { return XCTFail("\(doc.blocks[6])") }
    }

    func testEmailButtonsColoursAndTrackingPixels() {
        let doc = RichDocument.html("""
        <div style="background-color:#111827;color:#fff;text-align:center"><p>Big sale</p></div>
        <a href="https://shop.example/sale" style="background-color:#e11d48;color:#ffffff;padding:12px 20px">Shop now</a>
        <img src="https://t.example/open.gif" width="1" height="1">
        """)
        XCTAssertEqual(doc.blocks.count, 2, "the 1×1 tracking pixel is not content")
        guard case .paragraph(_, .center, let background?) = doc.blocks[0] else { return XCTFail("\(doc.blocks[0])") }
        XCTAssertFalse(background.isLight)
        guard case .button("Shop now", let url, let fill?, _, _) = doc.blocks[1] else { return XCTFail("\(doc.blocks[1])") }
        XCTAssertEqual(url?.host(), "shop.example")
        XCTAssertEqual(fill, RichColor(css: "#e11d48"))
    }

    func testEntitiesDataTablesAndEmbeds() {
        let doc = RichDocument.html("""
        <p>&pound;5 &ndash; &#8220;fair&#8221; &amp; &#x2014; done</p>
        <table><tr><th>Plan</th><th>Price</th></tr><tr><td>Basic</td><td>£5</td></tr></table>
        <iframe src="https://www.youtube.com/embed/x"></iframe><p>After</p>
        """)
        XCTAssertEqual(doc.blocks.first?.plainText, "£5 – “fair” & — done")
        guard case .table(let rows, true) = doc.blocks[1] else { return XCTFail("\(doc.blocks[1])") }
        XCTAssertEqual(rows.map { $0.map { String($0.characters) } }, [["Plan", "Price"], ["Basic", "£5"]])
        guard case .embed("Video", let url) = doc.blocks[2] else { return XCTFail("\(doc.blocks[2])") }
        XCTAssertEqual(url?.host(), "www.youtube.com")
        XCTAssertEqual(doc.blocks.last?.plainText, "After", "content after an embed is kept")
    }

    func testLayoutTablesAreNotGrids() {
        let doc = RichDocument.html("<table><tr><td><h1>Title</h1></td></tr><tr><td><p>Body</p></td></tr></table>")
        XCTAssertEqual(doc.blocks.count, 2)
        guard case .heading(1, _, _) = doc.blocks[0] else { return XCTFail("\(doc.blocks[0])") }
    }

    func testMarkdown() {
        let doc = RichDocument.markdown("""
        # Welcome
        Some **bold** text
        on two lines.

        - one
        - two
        1. first
        2. second
        > quoted
        ```
        let x = 1
        ```
        ![Logo](https://example.com/logo.png)
        """)
        XCTAssertEqual(doc.blocks.count, 9)
        guard case .heading(1, _, _) = doc.blocks[0] else { return XCTFail() }
        guard case .listItem(true, 2, 0, _) = doc.blocks[5] else { return XCTFail("\(doc.blocks[5])") }
        guard case .code("let x = 1") = doc.blocks[7] else { return XCTFail("\(doc.blocks[7])") }
        guard case .image(let url, "Logo", _, _) = doc.blocks[8] else { return XCTFail("\(doc.blocks[8])") }
        XCTAssertEqual(url?.lastPathComponent, "logo.png")
        XCTAssertTrue(RichDocument.auto("<p>Hi</p>").blocks.count == 1)
        XCTAssertEqual(RichDocument.plainText(fromHTML: "<p>Hi <b>Ann</b></p>"), "Hi Ann")
    }

    func testDownloadNamesAndEnvelopes() throws {
        XCTAssertEqual(EngageClient.fileName(fromDisposition: "attachment; filename=\"responses.csv\""), "responses.csv")
        XCTAssertNil(EngageClient.fileName(fromDisposition: "inline"))
        let json = try ResourceService.decode(Data(#"{"success":true,"data":[{"uuid":"a"},{"uuid":"b"}],"meta":{"total":2}}"#.utf8))
        XCTAssertEqual(json.engageRecords.map(\.id), ["a", "b"])
        XCTAssertEqual(json.meta?["total"]?.numberValue, 2)
        let one = try ResourceService.decode(Data(#"{"success":true,"data":{"uuid":"c","n":"4.5"}}"#.utf8))
        XCTAssertEqual(one.engageRecord?.double("n"), 4.5)
        XCTAssertEqual(JSONValue.object([:]).listValue, [], "lua-cjson's {} is an empty list")
        XCTAssertEqual(String(decoding: EngageExport.csv([["a", "b,c"], ["d\"e", "f"]]), as: UTF8.self), "a,\"b,c\"\n\"d\"\"e\",f")
    }

    @MainActor
    func testEveryEngageMenuKeyOpensANativeScreen() {
        let keys = ["plugin:opsapi_marketing:overview", "plugin:opsapi_marketing:campaigns",
                    "plugin:opsapi_marketing:lists", "plugin:opsapi_marketing:studio",
                    "plugin:opsapi_marketing:templates", "plugin:opsapi_marketing:settings",
                    "plugin:opsapi_marketing:guide", "plugin:opsapi_marketing:unsubscribed",
                    "plugin:opsapi_marketing:suppressions", "plugin:opsapi_marketing:conversations",
                    "plugin:opsapi_marketing:pixels", "cms", "forms", "academy", "ats"]
        for key in keys {
            XCTAssertNotNil(NativeModules.destination(forKey: key), key)
            XCTAssertFalse(NativeModules.notYetNative.contains(key), key)
        }
        XCTAssertEqual(EngageArea.parts("mkt.campaign:abc").screen, "mkt.campaign")
        XCTAssertEqual(EngageArea.parts("mkt.campaign:abc").argument, "abc")
        XCTAssertNil(EngageArea.parts("mkt.lists").argument)
    }
}
