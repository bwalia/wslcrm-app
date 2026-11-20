import SwiftUI
import VisionKit

/// The camera as a barcode scanner (VisionKit). Each new code is handed over once; the sheet stays open
/// so several items can be scanned in a row.
struct POSScannerView: View {
    let onCode: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var lastMessage: String?

    /// Whether this device can scan (a camera with Live Text support, and camera access not refused).
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                POSDataScanner { code in
                    lastMessage = onCode(code)
                }
                .ignoresSafeArea(edges: .bottom)
                if let lastMessage {
                    Text(lastMessage)
                        .font(.wsSubheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 32)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .navigationTitle("Scan barcodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("pos.scanner.done")
                }
            }
        }
    }
}

/// `DataScannerViewController` for barcodes, reporting each code when it first appears.
private struct POSDataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var lastCode: String?
        private var lastTime = Date.distantPast

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let code = barcode.payloadStringValue?.trimmedOrNil else { continue }
                // The same code held in view is reported once; scanning it again after a pause adds another.
                if code == lastCode && Date().timeIntervalSince(lastTime) < 1.5 { continue }
                lastCode = code
                lastTime = Date()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(code)
            }
        }
    }
}
