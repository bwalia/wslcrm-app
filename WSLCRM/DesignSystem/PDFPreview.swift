import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A PDF on screen, with PDFKit (native: never a web view).
struct PDFKitView: UIViewRepresentable {
    let data: Data
    var accessibilityID = "pdf.view"

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        view.accessibilityIdentifier = accessibilityID
        context.coordinator.data = data
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var data: Data?
    }
}

/// A PDF to show in `PDFPreviewSheet`: the file, its title, and what the person should know about it.
struct PDFPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    var title: String
    /// Where the look came from ("Made with your template “Classic”").
    var subtitle: String?
    /// Something to explain (the template couldn't be used, so the quick layout was).
    var notice: String?
}

/// The exact PDF a customer gets, full size, with Share, Print and Save; and the main action (Email it) when the
/// screen has one. Every invoice and order preview uses this, so they all look and work the same.
struct PDFPreviewSheet<Extra: View>: View {
    let item: PDFPreviewItem
    var sendTitle: String?
    var onSend: (() -> Void)?
    @ViewBuilder var extra: Extra
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var saving = false
    @State private var saved: String?

    init(item: PDFPreviewItem, sendTitle: String? = nil, onSend: (() -> Void)? = nil,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.item = item
        self.sendTitle = sendTitle
        self.onSend = onSend
        self.extra = extra()
        _data = State(initialValue: try? Data(contentsOf: item.url))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let data {
                    PDFKitView(data: data, accessibilityID: "pdfPreview.document")
                } else {
                    ContentUnavailableView("The PDF couldn’t be opened", systemImage: "doc.questionmark",
                                           description: Text("Close this and try again."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("pdfPreview.close")
                }
            }
            .fileExporter(isPresented: $saving, document: data.map(PDFFileDocument.init), contentType: .pdf,
                          defaultFilename: item.url.deletingPathExtension().lastPathComponent) { result in
                if case .success(let url) = result { saved = "Saved as \(url.lastPathComponent)." }
            }
        }
        .frame(minWidth: MacSupport.isMac ? 760 : nil, idealWidth: MacSupport.isMac ? 880 : nil,
               minHeight: MacSupport.isMac ? 640 : nil, idealHeight: MacSupport.isMac ? 860 : nil)
    }

    @ViewBuilder
    private var header: some View {
        if item.subtitle != nil || item.notice != nil || saved != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let subtitle = item.subtitle {
                    Label(subtitle, systemImage: "doc.richtext").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                if let notice = item.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.wsSubheadline).foregroundStyle(Tone.warning.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pdfPreview.notice")
                }
                if let saved {
                    Label(saved, systemImage: "checkmark.circle.fill").font(.wsSubheadline).foregroundStyle(Tone.success.textColor)
                }
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MacSupport.isMac ? 20 : 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                fileButtons(labelled: true)
                fileButtons(labelled: false)
            }
            Spacer(minLength: 0)
            if let onSend, let sendTitle {
                Button {
                    dismiss()
                    // After this sheet has gone: a sheet can't open while another is closing.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        onSend()
                    }
                } label: {
                    Label(sendTitle, systemImage: "envelope.fill").frame(minHeight: MacSupport.isMac ? 24 : 32)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pdfPreview.send")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, MacSupport.isMac ? 20 : 16)
        .padding(.vertical, 10)
        .background(.bar)
        .disabled(data == nil)
    }

    private func fileButtons(labelled: Bool) -> some View {
        HStack(spacing: 8) {
            ShareLink(item: item.url) { fileLabel("Share", "square.and.arrow.up", labelled) }
                .accessibilityIdentifier("pdfPreview.share")
            Button { print() } label: { fileLabel("Print", "printer", labelled) }
                .accessibilityIdentifier("pdfPreview.print")
            Button { saving = true } label: { fileLabel("Save", "square.and.arrow.down", labelled) }
                .accessibilityIdentifier("pdfPreview.save")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func fileLabel(_ title: String, _ image: String, _ labelled: Bool) -> some View {
        if labelled {
            Label(title, systemImage: image).frame(minHeight: MacSupport.isMac ? 24 : 32)
        } else {
            Image(systemName: image).frame(minWidth: 32, minHeight: 32).accessibilityLabel(title)
        }
    }

    private func print() {
        guard let data else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = item.title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
}

/// A PDF for the system's Save panel.
struct PDFFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(_ data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// The first page of a PDF as a picture (thumbnails of templates and of what an email attaches).
enum PDFThumbnail {
    static func image(_ data: Data, width: CGFloat = 360) -> UIImage? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return nil }
        return page.thumbnail(of: CGSize(width: width, height: width * box.height / box.width), for: .mediaBox)
    }
}
