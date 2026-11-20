import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// A bank statement chosen on the phone, checked the way the server checks it before it is sent.
struct StatementFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    let mimeType: String

    static let maxBytes = 25 * 1024 * 1024
    /// The server accepts statements by extension only.
    static let extensions = ["pdf", "csv", "jpg", "jpeg", "png", "gif", "webp"]
    static let contentTypes: [UTType] = [.pdf, .commaSeparatedText, .jpeg, .png, .gif, .webP, .plainText]

    var part: Endpoint.FilePart { Endpoint.FilePart(fieldName: "file", filename: name, mimeType: mimeType, data: data) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }

    /// Why the server would turn this file down, in plain words; nil when it's fine.
    var problem: String? {
        if !Self.extensions.contains((name as NSString).pathExtension.lowercased()) {
            return "Use a PDF, CSV or photo (JPG, PNG, GIF, WebP)."
        }
        if data.isEmpty { return "The file is empty." }
        if data.count > Self.maxBytes { return "The file is larger than 25MB." }
        return nil
    }

    /// Reads a file the person picked (security-scoped, from Files or iCloud Drive).
    static func load(_ url: URL) throws -> StatementFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        var name = url.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        // A .txt export of a CSV is sent as .csv so the server reads it.
        if ext == "txt" { name = (name as NSString).deletingPathExtension + ".csv" }
        return StatementFile(name: name, data: data, mimeType: mimeType(for: name))
    }

    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "csv": "text/csv"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }

    /// Pages from the document camera as one PDF.
    @MainActor
    static func pdf(from images: [UIImage], name: String) -> StatementFile {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { context in
            for image in images {
                context.beginPage()
                let scale = min(page.width / image.size.width, page.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
        }
        return StatementFile(name: name, data: data, mimeType: "application/pdf")
    }

    static func scanName(_ date: Date = Date()) -> String {
        "Scanned statement \(date.formatted(.iso8601.year().month().day().dateSeparator(.dash))).pdf"
    }
}

/// Apple's document camera (VisionKit): finds the page edges, straightens and cleans each page.
struct DocumentScanner: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void
    let cancel: () -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done, cancel: cancel) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        let cancel: () -> Void

        init(done: @escaping ([UIImage]) -> Void, cancel: @escaping () -> Void) {
            self.done = done
            self.cancel = cancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { cancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            cancel()
        }
    }
}
