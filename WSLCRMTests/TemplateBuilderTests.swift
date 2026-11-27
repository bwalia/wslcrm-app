import XCTest
@testable import WSLCRM

/// The designer's page and compiler (Features/Invoices/Templates/TemplateBuilder.swift) against the web's own.
/// `Fixtures/template_builder_compile.json` was made by running opsapi-dashboard's builder/model.ts and compile.ts in
/// node (scratch script: copy model.ts and compile.ts, import with ".ts", build docs with stable piece ids, write
/// `[{ name, doc, html, css, footer_html, margins, editor_html }]`): each ready-made design for invoices and orders,
/// two pages that use every other setting, and one of awkward numbers, with what the TypeScript compiled from them. The Swift output must match it character for character, so a template designed in
/// the app prints and opens in the web's designer exactly as one designed there.
final class TemplateBuilderTests: XCTestCase {
    struct Case: Decodable {
        let name: String
        let doc: JSONValue
        let html: String
        let css: String
        // swiftlint:disable:next identifier_name
        let footer_html: String
        let margins: [String: String]
        // swiftlint:disable:next identifier_name
        let editor_html: String
    }

    private func cases() throws -> [Case] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "template_builder_compile", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    private func doc(_ json: JSONValue) throws -> BuilderDoc {
        try JSONDecoder().decode(BuilderDoc.self, from: JSONEncoder().encode(json))
    }

    func testTheCompilerMatchesTheWebCharacterForCharacter() throws {
        let all = try cases()
        XCTAssertEqual(all.count, 11)
        for c in all {
            let d = try doc(c.doc)
            let out = TemplateCompiler.compile(d)
            XCTAssertEqual(out.html, c.html, "\(c.name): html")
            XCTAssertEqual(out.css, c.css, "\(c.name): css")
            XCTAssertEqual(out.footerHTML, c.footer_html, "\(c.name): footer")
            XCTAssertEqual(out.marginTB, c.margins["tb"], "\(c.name): margins")
            XCTAssertEqual(out.marginLR, c.margins["lr"], "\(c.name): margins")
            XCTAssertEqual(TemplateCompiler.compile(d, editor: true).html, c.editor_html, "\(c.name): editor html")
            if out.html != c.html { firstDifference(out.html, c.html, c.name) }
        }
    }

    func testTheReadyMadeDesignsAreTheWebsOwn() throws {
        let all = try cases()
        for kind in [BuilderKind.invoice, .order] {
            for preset in BuilderPresets.all {
                let web = try XCTUnwrap(all.first { $0.name == "\(preset.key)-\(kind.rawValue)" }, "\(preset.key) \(kind)")
                var mine = preset.make(kind)
                for i in mine.pieces.indices { mine.pieces[i].id = "p\(i + 1)" }
                XCTAssertEqual(mine.json, web.doc, "\(preset.key) for \(kind.rawValue)")
            }
        }
        XCTAssertEqual(BuilderPresets.all.map(\.key), ["classic", "modern", "bold", "boxed"])
    }

    func testAPageRoundTripsThroughConfigBuilderWithoutLosingAnything() throws {
        for c in try cases() {
            let d = try doc(c.doc)
            XCTAssertEqual(d.json, c.doc, "\(c.name) comes back the same")
            XCTAssertEqual(BuilderDoc.read(["builder": c.doc, "other": .string("kept")]), d)
        }
        XCTAssertNil(BuilderDoc.read([:]))
        XCTAssertNil(BuilderDoc.read(["builder": .object(["v": .number(2)])]), "an unknown version opens in the code editor")
    }

    func testSavingADesignWritesTheTemplatesPartsAndKeepsTheRestOfItsConfig() throws {
        let d = BuilderPresets.make("modern", .order)
        let fields = TemplateCompiler.templateFields(d, config: ["primary_color": .string("#123456")])
        let c = TemplateCompiler.compile(d)
        XCTAssertEqual(fields["template_html"], .string(c.html))
        XCTAssertEqual(fields["template_css"], .string(c.css))
        XCTAssertEqual(fields["footer_html"], .string(c.footerHTML))
        XCTAssertEqual(fields["margin_top"], .string("16mm"))
        XCTAssertEqual(fields["margin_left"], .string("15mm"))
        XCTAssertEqual(fields["page_size"], .string("A4"))
        XCTAssertEqual(fields["config"]?["primary_color"], .string("#123456"))
        XCTAssertEqual(fields["config"]?["builder"], d.json)
        XCTAssertFalse(c.css.contains("{{"), "the server doesn't fill CSS in")
    }

    func testNumbersPrintAsJavaScriptPrintsThem() {
        XCTAssertEqual(TemplateCompiler.js(45), "45")
        XCTAssertEqual(TemplateCompiler.js(8.5), "8.5")
        XCTAssertEqual(TemplateCompiler.js(0.04), "0.04")
        XCTAssertEqual(TemplateCompiler.js(85.0 / 100), "0.85")
        XCTAssertEqual(TemplateCompiler.n(81.333), "81.33")
        XCTAssertEqual(TemplateCompiler.n(0.125), "0.13", "Math.round rounds halves up")
        XCTAssertEqual(TemplateCompiler.words("a & <b>\n{% x %}"), "a &amp; &lt;b&gt;<br>{ % x %}")
        XCTAssertEqual(TemplateCompiler.whenFilled("VAT {{ company.vat_number }} {{ a.b | upper }} {{ company.vat_number }}", "X"),
                       "{% if company.vat_number %}{% if a.b %}X{% endif %}{% endif %}")
    }

    func testPiecesStayInsideTheirBandAndThePage() {
        var d = BuilderPresets.make("classic", .invoice)
        d.pieces[0].x = -20
        d.pieces[0].w = 400
        d.pieces[1].y = 500
        let c = d.clamped()
        XCTAssertEqual(c.pieces[0].x, 0)
        XCTAssertEqual(c.pieces[0].w, d.contentWidth)
        XCTAssertEqual(c.pieces[1].y, d.header.h - c.pieces[1].h)
        XCTAssertEqual(d.contentWidth, 180)
    }

    func testTheCatalogueOffersEachKindItsOwnPieces() {
        XCTAssertFalse(BuilderCatalog.pieces(for: .invoice).contains(.delivery))
        XCTAssertTrue(BuilderCatalog.pieces(for: .order).contains(.delivery))
        XCTAssertFalse(BuilderCatalog.pieces(for: .order).contains(.notes))
        XCTAssertEqual(BuilderCatalog.pieces.count, PieceType.allCases.count, "every piece has its settings")
        let text = BuilderCatalog.makePiece(.text, kind: .invoice, band: .header, x: 1, y: 2)
        XCTAssertEqual(text.text, "Your words here")
        XCTAssertEqual(BuilderCatalog.name(text), "Your words here")
        var number = text
        number.text = "Invoice {{ invoice.number }}"
        XCTAssertEqual(BuilderCatalog.name(number), "Invoice invoice.number")
        XCTAssertEqual(BuilderCatalog.makePiece(.customer, kind: .order, band: .header, x: 0, y: 0).label, "Customer")
        XCTAssertTrue(BuilderCatalog.placeholders(.order).contains { $0.1 == "{{ order.number }}" })
    }

    /// Prints where two long strings first differ (a failing comparison of 8 KB of HTML says little by itself).
    private func firstDifference(_ a: String, _ b: String, _ name: String) {
        let x = Array(a), y = Array(b)
        let i = zip(x, y).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(x.count, y.count)
        let lo = max(0, i - 60)
        print("[\(name)] first difference at \(i):\n  swift: …\(String(x[lo..<min(x.count, i + 60)]))\n  web:   …\(String(y[lo..<min(y.count, i + 60)]))")
    }
}
