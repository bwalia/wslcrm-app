import SwiftUI
import UIKit
import VisionKit

/// Scan paper with the camera (Apple's document scanner) into one PDF, ready to upload.
struct PortalDocumentScanner: UIViewControllerRepresentable {
    let onScanned: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The scanner needs a camera: not on the simulator, nor on some iPads.
    @MainActor static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Each scanned page becomes an A4-width PDF page.
    static func pdf(_ pages: [UIImage]) -> Data {
        let width: CGFloat = 595
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 842))
        return renderer.pdfData { context in
            for image in pages {
                let height = image.size.width > 0 ? width * image.size.height / image.size.width : 842
                context.beginPage(withBounds: CGRect(x: 0, y: 0, width: width, height: height), pageInfo: [:])
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: PortalDocumentScanner
        init(_ parent: PortalDocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onScanned(PortalDocumentScanner.pdf(pages))
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
