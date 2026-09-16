import UIKit

/// Minimal A4 page writer for the documents the app produces on device (quotations and
/// invoices — OpsAPI has no PDF download, and the quote/invoice email endpoints expect the
/// client to supply the PDF as base64).
@MainActor
enum DocumentPDF {
    static let pageSize = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 at 72 dpi
    static let margin: CGFloat = 48

    /// Draws a document and returns its bytes, or nil if rendering failed.
    static func data(_ draw: (Canvas) -> Void) -> Data? {
        let renderer = UIGraphicsPDFRenderer(bounds: pageSize)
        return renderer.pdfData { context in
            let canvas = Canvas(context: context)
            canvas.newPage()
            draw(canvas)
        }
    }

    /// Writes the document to a temporary file for sharing, named after `filename`.
    static func file(named filename: String, _ draw: (Canvas) -> Void) -> URL? {
        guard let data = data(draw) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A cursor down the page: text is drawn at `y`, which the caller advances.
    @MainActor
    final class Canvas {
        private let context: UIGraphicsPDFRendererContext
        var y: CGFloat = margin

        init(context: UIGraphicsPDFRendererContext) {
            self.context = context
        }

        func newPage() {
            context.beginPage()
            y = DocumentPDF.margin
        }

        /// Starts a new page when the cursor is close to the bottom.
        func pageBreakIfNeeded(keeping height: CGFloat = 24) {
            if y + height > DocumentPDF.pageSize.height - margin { newPage() }
        }

        /// Draws text at the cursor's line and returns the height it took.
        @discardableResult
        func text(_ string: String, x: CGFloat, font: UIFont, color: UIColor = .black,
                  width: CGFloat = 260, alignment: NSTextAlignment = .left) -> CGFloat {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let bounds = (string as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                           options: .usesLineFragmentOrigin, attributes: attributes,
                                                           context: nil)
            (string as NSString).draw(in: CGRect(x: x, y: y, width: width, height: bounds.height),
                                      withAttributes: attributes)
            return bounds.height
        }

        func rule(color: UIColor = .systemGray4) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: margin, y: y))
            path.addLine(to: CGPoint(x: DocumentPDF.pageSize.width - margin, y: y))
            color.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}
