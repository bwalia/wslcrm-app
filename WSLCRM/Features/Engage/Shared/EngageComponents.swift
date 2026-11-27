import SwiftUI
import UniformTypeIdentifiers

// Small pieces shared by the engage area's hand-built screens (marketing, website content, forms,
// academy, hiring). Built from the design system; nothing here is a web page.

// MARK: - Files in (imports, uploads)

/// A file the person picked with the system file picker, read into memory.
struct EngageFile: Sendable, Hashable {
    let name: String
    let data: Data
    let mimeType: String

    var base64: String { data.base64EncodedString() }
    /// `data:<mime>;base64,…` (some endpoints accept it whole).
    var dataURL: String { "data:\(mimeType);base64,\(base64)" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }

    var filePart: Endpoint.FilePart { filePart(field: "file") }

    func filePart(field: String) -> Endpoint.FilePart {
        Endpoint.FilePart(fieldName: field, filename: name, mimeType: mimeType, data: data)
    }

    /// Reads a picked file (security-scoped when it comes from Files or iCloud).
    static func read(_ url: URL) throws -> EngageFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        return EngageFile(name: url.lastPathComponent, data: data,
                          mimeType: type?.preferredMIMEType ?? "application/octet-stream")
    }

    /// Spreadsheets and PDFs people bring contacts or data in.
    static let spreadsheetTypes: [UTType] = [
        .commaSeparatedText, .plainText, .pdf,
        UTType(filenameExtension: "xlsx") ?? .spreadsheet, UTType(filenameExtension: "xls") ?? .spreadsheet,
    ]
}

extension View {
    /// The system file picker; the chosen file arrives read, or the reason it couldn't be read.
    func engageFileImporter(isPresented: Binding<Bool>, types: [UTType],
                            onPick: @escaping (EngageFile) -> Void,
                            onError: @escaping (String) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: types, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { onPick(try EngageFile.read(url)) } catch {
                    onError("That file couldn’t be opened. Try saving it to Files first.")
                }
            case .failure:
                onError("That file couldn’t be opened.")
            }
        }
    }
}

// MARK: - Files out (exports, downloads)

enum EngageExport {
    /// Writes data to a temporary file so it can be shared or saved with `ShareLink`.
    static func temporaryFile(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engage-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent(safe.isEmpty ? "export" : safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A CSV from rows of text (quoted where needed).
    static func csv(_ rows: [[String]]) -> Data {
        let text = rows.map { row in
            row.map { cell in
                cell.contains(",") || cell.contains("\"") || cell.contains("\n")
                    ? "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\"" : cell
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return Data(text.utf8)
    }
}

// MARK: - Saying what happened

/// The outcome of the last thing a person did on a screen.
enum EngageNotice: Equatable {
    case done(String)
    case failed(APIError)
    case info(String)

    static func == (lhs: EngageNotice, rhs: EngageNotice) -> Bool {
        switch (lhs, rhs) {
        case (.done(let a), .done(let b)), (.info(let a), .info(let b)): a == b
        case (.failed(let a), .failed(let b)): a.localizedDescription == b.localizedDescription
        default: false
        }
    }
}

/// A banner for an `EngageNotice` (put it in `.safeAreaInset(edge: .top)` or a List row).
struct EngageNoticeBar: View {
    let notice: EngageNotice?
    var retry: (() -> Void)?

    var body: some View {
        switch notice {
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.wsSubheadline)
                .foregroundStyle(Tone.success.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("engage.notice.done")
        case .info(let text):
            Label(text, systemImage: "info.circle.fill")
                .font(.wsSubheadline)
                .foregroundStyle(Tone.info.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("engage.notice.info")
        case .failed(let error):
            InlineErrorRow(error: error, retry: retry)
                .padding(.horizontal)
                .background(.bar)
                .accessibilityIdentifier("engage.notice.failed")
        case nil:
            EmptyView()
        }
    }
}

/// A plain explanation at the top of a screen (what this page is for, in beginner's words).
struct EngageIntro: View {
    let text: String
    var systemImage = "lightbulb"

    var body: some View {
        Label {
            Text(text).font(.wsSubheadline).foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Tone.info.textColor)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Numbers

/// A grid of headline numbers (an overview's tiles).
struct EngageMetricGrid: View {
    struct Metric: Identifiable, Hashable {
        let title: String
        let value: String
        let systemImage: String
        var tone: Tone = .brand
        var id: String { title }
    }

    let metrics: [Metric]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(metrics) { metric in
                MetricCard(title: metric.title, value: metric.value, systemImage: metric.systemImage, tone: metric.tone)
            }
        }
    }
}

enum EngageFormat {
    static func count(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Int(value).formatted()
    }

    /// 0.123 or 12.3 → "12.3%".
    static func percent(_ value: Double?, alreadyPercent: Bool = false) -> String {
        guard let value else { return "—" }
        let percent = alreadyPercent ? value : value * 100
        return "\(percent.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    static func money(_ value: Double?, currency: String? = Formatters.defaultCurrency, minorUnits: Bool = false) -> String {
        guard let value else { return "—" }
        let amount = Decimal(minorUnits ? value / 100 : value)
        return Formatters.money(amount, currency: currency) ?? "—"
    }

    static func dateTime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return Formatters.dateTime(APIDate.parse(raw)) ?? raw
    }

    static func day(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.count == 10, let day = CalendarDay(string: raw) { return Formatters.day(day.date()) }
        return Formatters.day(APIDate.parse(raw)) ?? raw
    }
}
