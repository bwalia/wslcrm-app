import XCTest
@testable import WSLCRM

/// The workspace's invoice / order design (`GET /api/v2/document-designs`) and the PDFs drawn with it.
@MainActor
final class DocumentDesignTests: XCTestCase {
    /// A real PNG logo ("NB" on a red tile), as the designer would upload it.
    static let png: String = {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 80)).image { _ in
            UIColor(red: 0.67, green: 0, blue: 0.2, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 240, height: 80), cornerRadius: 14).fill()
            ("Northbridge" as NSString).draw(at: CGPoint(x: 22, y: 22), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white])
        }
        return "data:image/png;base64," + (image.pngData() ?? Data()).base64EncodedString()
    }()

    static func payload(_ json: String) throws -> DocumentDesign.Payload {
        try JSONDecoder.opsAPI().decode(Envelope.Standard<DocumentDesign.Payload>.self, from: Data(json.utf8)).data
    }

    static let full = """
    {"success":true,"data":{"invoice":{"style":"clean","accent":"#aa0033","header":"#111111","font":"times",
      "title":"TAX INVOICE","bill_to_label":"INVOICE TO","logo_position":"right","logo_size":"large",
      "show":{"tax_column":false,"status":true,"item_numbers":false},"logo":"\(png)",
      "intro":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Thanks"}]}]},
      "terms":null,"footer":null,"is_custom":true,"updated_at":"2026-11-25T10:00:00Z"},
     "order":{"style":"minimal"}}}
    """

    func testAFullDesignDecodes() throws {
        let p = try Self.payload(Self.full)
        let d = DocumentDesign(kind: .invoice, raw: try XCTUnwrap(p.invoice))
        XCTAssertEqual(d.style, .clean)
        XCTAssertEqual(d.typeface, .times)
        XCTAssertEqual(d.title, "TAX INVOICE")
        XCTAssertEqual(d.billToLabel, "INVOICE TO")
        XCTAssertTrue(d.logoOnRight)
        XCTAssertEqual(d.logoHeight, 64)
        XCTAssertFalse(d.shows("tax_column"))
        XCTAssertFalse(d.shows("item_numbers"))
        XCTAssertTrue(d.shows("status"))
        XCTAssertTrue(d.shows("payment_details"), "a part not mentioned shows")
        XCTAssertNotNil(d.logoImage, "the data URL logo becomes an image")
        XCTAssertEqual(d.intro?.content.first?.content.first?.text, "Thanks")
        XCTAssertNil(d.terms)
        XCTAssertEqual(DocumentDesign.color("#aa0033"), d.accent)
    }

    func testAPartialDesignKeepsTheStandardValues() throws {
        let p = try Self.payload(Self.full)
        let o = DocumentDesign(kind: .order, raw: try XCTUnwrap(p.order))
        XCTAssertEqual(o.style, .minimal)
        XCTAssertEqual(o.title, "ORDER")
        XCTAssertEqual(o.billToLabel, "CUSTOMER")
        XCTAssertEqual(o.typeface, .helvetica)
        XCTAssertEqual(o.logoHeight, 44)
        XCTAssertFalse(o.logoOnRight)
        XCTAssertNil(o.logo)
    }

    func testJunkFallsBackFieldByField() throws {
        let p = try Self.payload("""
        {"data":{"invoice":{"style":"fancy","accent":"red","font":7,"title":"   ","logo":"https://x.test/logo.png",
          "show":"all","intro":"<b>hi</b>","logo_size":"huge"},"order":42}}
        """)
        XCTAssertNil(p.order, "a non-object order is dropped, not fatal")
        let d = DocumentDesign(kind: .invoice, raw: try XCTUnwrap(p.invoice))
        XCTAssertEqual(d, .standard(.invoice))
        XCTAssertEqual(try Self.payload(#"{"data":{}}"#).invoice == nil, true)
    }

    // MARK: Rich text

    static func doc(_ json: String) throws -> RichNode {
        try JSONDecoder.opsAPI().decode(RichNode.self, from: Data(json.utf8))
    }

    func testRichTextMarksAndBreaks() throws {
        let node = try Self.doc("""
        {"type":"doc","content":[{"type":"paragraph","attrs":{"textAlign":"center"},"content":[
          {"type":"text","text":"Bold","marks":[{"type":"bold"}]},{"type":"hardBreak"},
          {"type":"text","text":"Red","marks":[{"type":"textStyle","attrs":{"color":"#ff0000"}},{"type":"underline"}]},
          {"type":"text","text":"Slant","marks":[{"type":"italic"}]}]}]}
        """)
        let s = DocumentRichText.attributed(node, typeface: .helvetica, size: 10, color: .black)
        XCTAssertEqual(s.string, "Bold\u{2028}RedSlant")
        let bold = try XCTUnwrap(s.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(bold.fontName.contains("Bold"))
        let red = try XCTUnwrap(s.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor)
        XCTAssertEqual(red, DocumentDesign.color("#ff0000"))
        XCTAssertNotNil(s.attribute(.underlineStyle, at: 5, effectiveRange: nil))
        let slant = try XCTUnwrap(s.attribute(.font, at: 8, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(slant.fontName.contains("Oblique"))
        let style = try XCTUnwrap(s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
    }

    func testRichTextListsAndHeadings() throws {
        let node = try Self.doc("""
        {"type":"doc","content":[{"type":"heading","attrs":{"level":1},"content":[{"type":"text","text":"Terms"}]},
          {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"One"}]}]}]},
          {"type":"orderedList","content":[
            {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"First"}]}]},
            {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Second"}]}]}]},
          {"type":"image","attrs":{"src":"x"}}]}
        """)
        let s = DocumentRichText.attributed(node, typeface: .times, size: 10, color: .black)
        XCTAssertEqual(s.string, "Terms\n•\tOne\n1.\tFirst\n2.\tSecond")
        let heading = try XCTUnwrap(s.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(heading.pointSize, 15, accuracy: 0.01)
        XCTAssertTrue(heading.fontName.contains("Bold"))
        let item = (s.string as NSString).range(of: "One").location
        let style = try XCTUnwrap(s.attribute(.paragraphStyle, at: item, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.headIndent, 14, "wrapped lines of a list item line up after the bullet")
    }

    // MARK: PDFs

    static func designed() throws -> DocumentDesign {
        var d = DocumentDesign(kind: .invoice, raw: try XCTUnwrap(try payload(full).invoice))
        d.terms = try doc(#"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Pay within 30 days."}]}]}"#)
        d.footer = try doc(#"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Registered in England"}]}]}"#)
        return d
    }

    func testAnInvoicePDFIsDrawnWithADesign() throws {
        let invoice = try ShopEasyTests.invoice(status: "sent", due: "2099-01-01")
        for design in [try Self.designed(), .standard(.invoice), DocumentDesign(kind: .invoice, raw: try XCTUnwrap(
            try Self.payload(#"{"data":{"invoice":{"style":"minimal","font":"courier"}}}"#).invoice))] {
            let url = try XCTUnwrap(InvoicePDFRenderer.render(invoice, company: "Northbridge Services", design: design))
            let data = try Data(contentsOf: url)
            XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
            XCTAssertGreaterThan(data.count, 1000)
        }
    }

    func testAnOrderPDFIsDrawnWithADesign() throws {
        let order = try JSONDecoder.opsAPI().decode(ShopOrder.self, from: Data("""
        {"uuid":"o-1","order_number":"WSO-1042","status":"pending_payment","email":"buyer@quantlab.test",
         "customer":{"name":"Omar Haddad","company":"QuantLab"},"internal_notes":"SECRET margin note",
         "lines":[{"uuid":"l1","product_name":"RTX 6000 Ada 48GB","sku":"RTX6000","qty":2,"unit_price_minor":642000,
                   "line_subtotal_minor":1284000,"line_vat_minor":256800,"line_total_minor":1540800}],
         "subtotal_minor":1284000,"vat_minor":256800,"shipping_minor":0,"total_minor":1540800,"currency":"GBP",
         "created_at":"2026-11-25T10:00:00Z"}
        """.utf8))
        let extras = try JSONDecoder.opsAPI().decode(ShopOrderExtras.self, from: Data("""
        {"payment_method":"bank_transfer","payment_reference":"WSO-1042",
         "payment_methods":[{"uuid":"pm1","kind":"bank_transfer","label":"Main account","sort_code":"12-34-56","account_number":"12345678"}]}
        """.utf8))
        var design = try Self.designed()
        design.title = "ORDER CONFIRMATION"
        let url = try XCTUnwrap(ShopOrderPrint.file(order: order, extras: extras, company: "Northbridge Services", design: design))
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertNotNil(ShopOrderPrint.file(order: order, extras: ShopOrderExtras()), "the standard design still draws")
        if let path = ProcessInfo.processInfo.environment["DESIGN_PDF_OUT"] {
            try data.write(to: URL(fileURLWithPath: path + "/order.pdf"))
            let full = try JSONDecoder.opsAPI().decode(Invoice.self, from: Data("""
            {"id":"inv-2","invoice_number":"INV-0042","status":"sent","customer_name":"Harbour VFX Ltd",
             "customer_email":"accounts@harbourvfx.test","customer_address":"12 Quay Street, Bristol BS1 4XY",
             "issue_date":"2026-11-25","due_date":"2099-12-25","currency":"GBP","po_number":"HVFX-88",
             "subtotal":"12840.00","tax_amount":"2568.00","total_amount":"15408.00","amount_paid":"0","balance_due":"15408.00",
             "notes":"Delivered to the Bristol studio. Two-year return-to-base warranty.","payment_terms_days":30,
             "payment_method":{"uuid":"pm1","kind":"bank_transfer","label":"Main account","sort_code":"12-34-56","account_number":"12345678"},
             "line_items":[{"id":"l1","description":"RTX 6000 Ada 48GB workstation GPU","quantity":"2","unit_price":"6420.00","tax_amount":"2568.00","line_total":"15408.00"},
                           {"id":"l2","description":"Installation and burn-in test","quantity":"1","unit_price":"0","tax_amount":"0","line_total":"0"}],
             "payments":[]}
            """.utf8))
            let inv = try XCTUnwrap(InvoicePDFRenderer.render(full, company: "Northbridge Services", design: try Self.designed()))
            try Data(contentsOf: inv).write(to: URL(fileURLWithPath: path + "/invoice.pdf"))
            let plain = try XCTUnwrap(InvoicePDFRenderer.render(full, company: "Northbridge Services"))
            try Data(contentsOf: plain).write(to: URL(fileURLWithPath: path + "/invoice-standard.pdf"))
        }
    }

    // MARK: Currency

    func testTheAppCurrencyIsPoundsUnlessChangedAndADocumentKeepsItsOwn() throws {
        let saved = UserDefaults.standard.string(forKey: Formatters.currencyKey)
        defer { UserDefaults.standard.set(saved, forKey: Formatters.currencyKey) }
        UserDefaults.standard.removeObject(forKey: Formatters.currencyKey)
        XCTAssertEqual(Formatters.defaultCurrency, "GBP", "pounds, whatever the device's region")
        XCTAssertEqual(Formatters.currencySymbol, "£")
        XCTAssertEqual(Formatters.money(12.5, currency: nil), Decimal(12.5).formatted(.currency(code: "GBP")))
        XCTAssertEqual(ShopAnalyticsFormat.compactPounds(1_260), "£1.3k")

        func decode(_ currency: String?) throws -> Invoice {
            let field = currency.map { #""currency":"\#($0)","# } ?? ""
            return try JSONDecoder.opsAPI().decode(Invoice.self, from: Data("""
            {"id":"inv-9","invoice_number":"INV-0009","status":"sent",\(field)"subtotal":"10","tax_amount":"0","total_amount":"10",
             "amount_paid":"0","balance_due":"10","line_items":[],"payments":[]}
            """.utf8))
        }
        XCTAssertEqual(try decode(nil).currency, "GBP", "an invoice without a currency is in the app's")
        XCTAssertEqual(try decode("EUR").currency, "EUR", "an invoice in euros stays in euros")

        UserDefaults.standard.set("eur", forKey: Formatters.currencyKey)
        XCTAssertEqual(Formatters.defaultCurrency, "EUR", "one setting for the whole app")
        XCTAssertEqual(Formatters.currencySymbol, "€")
        XCTAssertEqual(try decode(nil).currency, "EUR")
        XCTAssertEqual(Formatters.money(5, currency: "USD"), Decimal(5).formatted(.currency(code: "USD")),
                       "an amount with its own currency ignores the setting")
    }
}
