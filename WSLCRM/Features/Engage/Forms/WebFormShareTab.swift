import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Share tab: the public link and whether it works yet, filling it in here, the code to put it on a
/// website, a QR code (PNG or SVG), a prefilled link, and tracking where responses come from.
struct WebFormShareTab: View {
    let form: WebFormDetail
    let fillIn: () -> Void
    @State private var notice: EngageNotice?
    @State private var prefillKey = ""
    @State private var prefillValue = ""
    @State private var qrCode: WebFormQRCode?
    @State private var qrFiles: (png: URL?, svg: URL?)?

    private var link: String { form.publicLink }

    var body: some View {
        List {
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            statusSection
            embedSection
            qrSection
            prefillSection
            trackingSection
        }
        .task(id: link) {
            let qr = WebFormQRCode(text: link)
            qrCode = qr
            qrFiles = qr.map { (png: $0.pngFile(name: fileName + "-qr.png"), svg: $0.svgFile(name: fileName + "-qr.svg")) }
        }
    }

    private var statusSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(form.isLive ? "Your form is live" : form.status == .closed ? "This form is closed" : "Not published yet")
                        .font(.wsHeadline)
                    Text(form.isLive
                         ? "Anyone with this link can fill it in." + (form.shareDomain == nil
                            ? " Want it on your own domain? Forms → More → Custom domain." : "")
                         : form.status == .closed ? "Visitors see your closed message. Reopen it to take responses again."
                         : "Publish the form first; until then the link shows “not available”.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            } icon: {
                Image(systemName: form.isLive ? "globe" : "lock").foregroundStyle(form.isLive ? Tone.success.textColor : .secondaryText)
            }
            Text(link).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .accessibilityIdentifier("forms.share.link")
            Button { copy(link, "Link copied.") } label: { Label("Copy link", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("forms.share.copy")
            if let url = URL(string: link) {
                ShareLink(item: url, subject: Text(form.title)) { Label("Share link", systemImage: "square.and.arrow.up") }
            }
            if form.isLive {
                Button(action: fillIn) { Label("Fill it in now", systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("forms.share.fill")
            }
        }
    }

    private var embedSection: some View {
        let snippet = WebFormRules.embedSnippet(for: link)
        return Section {
            Text(snippet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Button { copy(snippet, "Code copied: paste it into your website.") } label: {
                Label("Copy code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            ShareLink(item: snippet) { Label("Send the code", systemImage: "square.and.arrow.up") }
        } header: { Text("Put it on your website") } footer: {
            Text("Paste this where the form should appear. It fits its height to the form, and campaign tags on your "
                 + "page are recorded with each response.")
        }
    }

    private var qrSection: some View {
        Section {
            if let qr = qrCode {
                HStack {
                    Spacer()
                    Image(uiImage: qr.image(size: 220))
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code of the form’s link")
                    Spacer()
                }
                if let png = qrFiles?.png {
                    ShareLink(item: png) { Label("Save or share as PNG", systemImage: "photo") }
                }
                if let svg = qrFiles?.svg {
                    ShareLink(item: svg) { Label("Save or share as SVG", systemImage: "square.on.circle") }
                }
            }
        } header: { Text("QR code") } footer: {
            Text("For posters, flyers, packaging and events: a phone camera opens the form.")
        }
    }

    private var fileName: String {
        let name = form.title.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
        return String(name.prefix(40)).trimmedOrNil ?? "form"
    }

    @ViewBuilder
    private var prefillSection: some View {
        let fields = form.fields.filter { $0.key != nil && WebFormRules.prefillable.contains($0.type) }
        if !fields.isEmpty {
            let field = fields.first { $0.key == prefillKey } ?? fields[0]
            let prefilled = WebFormRules.prefilledLink(link, key: field.key ?? "", value: prefillValue)
            Section {
                Picker("Question", selection: Binding(get: { field.key ?? "" }, set: { prefillKey = $0; prefillValue = "" })) {
                    ForEach(fields, id: \.key) { Text($0.label).tag($0.key ?? "") }
                }
                if field.options.isEmpty {
                    TextField("Answer", text: $prefillValue)
                } else {
                    Picker("Answer", selection: $prefillValue) {
                        Text("Choose…").tag("")
                        ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
                Text(prefilled).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button { copy(prefilled, "Prefilled link copied.") } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("forms.share.prefillCopy")
            } header: { Text("Prefilled link") } footer: {
                Text("Fill in an answer for people in advance, e.g. their email in a newsletter, or the event they’re booking.")
            }
        }
    }

    private var trackingSection: some View {
        Section {
            Text("Add UTM tags to the link and they are saved with each response (and on leads it creates):")
                .font(.wsSubheadline)
            Text("\(link)?utm_source=newsletter&utm_campaign=autumn")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("A Hidden question reads any other link parameter you name, e.g. ?ref=partner42.")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
        } header: { Text("Track where responses come from") }
    }

    private func copy(_ text: String, _ done: String) {
        UIPasteboard.general.string = text
        notice = .done(done)
    }
}

/// A QR code drawn natively (Core Image), as a picture or as SVG built from its squares.
struct WebFormQRCode {
    /// The modules (squares): true = dark.
    let modules: [[Bool]]

    init?(text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        modules = Self.oriented(rows)
    }

    init(modules: [[Bool]]) {
        self.modules = modules
    }

    /// A QR code has its finder squares top-left, top-right and bottom-left, never bottom-right: a matrix read
    /// upside down (bitmap rows bottom-up) is turned the right way.
    static func oriented(_ rows: [[Bool]]) -> [[Bool]] {
        guard let bounds = darkBounds(rows) else { return rows }
        // Read upside down, the finders sit top-left, bottom-left and bottom-right.
        return finder(rows, x: bounds.maxX - 6, y: bounds.maxY - 6) ? Array(rows.reversed()) : rows
    }

    private static func darkBounds(_ rows: [[Bool]]) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for (y, row) in rows.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// A 7×7 finder square at (x, y): a dark ring, a light ring, a dark 3×3 centre.
    static func finder(_ rows: [[Bool]], x: Int, y: Int) -> Bool {
        func dark(_ dx: Int, _ dy: Int) -> Bool? {
            let row = y + dy, col = x + dx
            guard rows.indices.contains(row), rows[row].indices.contains(col) else { return nil }
            return rows[row][col]
        }
        for dy in 0..<7 {
            for dx in 0..<7 {
                let ring = min(dx, dy, 6 - dx, 6 - dy)
                guard let value = dark(dx, dy), value == (ring != 1) else { return false }
            }
        }
        return true
    }

    func image(size: CGFloat) -> UIImage {
        let count = CGFloat(max(1, modules.count))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.black.setFill()
            let cell = size / count
            for (y, row) in modules.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    ctx.fill(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                }
            }
        }
    }

    /// The SVG the web downloads: a white square with one black rect per dark module.
    var svg: String {
        let n = modules.count
        var rects = ""
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark { rects += "<rect x=\"\(x)\" y=\"\(y)\" width=\"1\" height=\"1\"/>" }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(n) \(n)\" shape-rendering=\"crispEdges\">"
            + "<rect width=\"\(n)\" height=\"\(n)\" fill=\"#fff\"/><g fill=\"#000\">\(rects)</g></svg>"
    }

    func pngFile(name: String) -> URL? {
        guard let data = image(size: 1024).pngData() else { return nil }
        return try? EngageExport.temporaryFile(data, name: name)
    }

    func svgFile(name: String) -> URL? {
        try? EngageExport.temporaryFile(Data(svg.utf8), name: name)
    }
}
