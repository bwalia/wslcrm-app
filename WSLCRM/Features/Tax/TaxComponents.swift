import QuickLook
import SwiftUI

/// What happened after an action, shown at the top of a tax screen until the next one.
struct TaxNotice: Equatable, Sendable {
    enum Kind: Sendable { case success, info, warning, error }
    var kind: Kind
    var text: String

    static func success(_ text: String) -> TaxNotice { TaxNotice(kind: .success, text: text) }
    static func info(_ text: String) -> TaxNotice { TaxNotice(kind: .info, text: text) }
    static func warning(_ text: String) -> TaxNotice { TaxNotice(kind: .warning, text: text) }
    static func error(_ text: String) -> TaxNotice { TaxNotice(kind: .error, text: text) }
    static func error(_ error: Error) -> TaxNotice { TaxNotice(kind: .error, text: error.asAPIError.plainMessage) }

    var tone: Tone {
        switch kind {
        case .success: .success
        case .info: .info
        case .warning: .warning
        case .error: .danger
        }
    }

    var symbol: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// A notice row (icon + words, readable without colour).
struct TaxNoticeView: View {
    let notice: TaxNotice
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.symbol).foregroundStyle(notice.tone.textColor).accessibilityHidden(true)
            Text(notice.text)
                .font(.wsSubheadline)
                .foregroundStyle(notice.tone.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").imageScale(.small) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(notice.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tax.notice")
    }
}

/// A coloured box of explanation (amber warnings, blue tips, red blockers).
struct TaxCallout<Content: View>: View {
    var tone: Tone = .info
    var systemImage = "info.circle"
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tone.textColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.wsSubheadline)
                .foregroundStyle(tone.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A label and an amount on one line.
struct TaxAmountRow: View {
    let label: String
    let value: String
    var bold = false
    var tone: Tone?

    var body: some View {
        LabeledContent {
            Text(value)
                .font((bold ? Font.wsBody.weight(.semibold) : .wsBody).monospacedDigit())
                .foregroundStyle(tone?.textColor ?? .primary)
        } label: {
            Text(label).font(bold ? .wsBody.weight(.semibold) : .wsBody)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Picks a UK tax year ("2025-26").
struct TaxYearPicker: View {
    @Binding var year: String
    var years: [String] = TaxYear.recent()
    var currentLabel = true

    var body: some View {
        Picker("Tax year", selection: $year) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .accessibilityIdentifier("tax.yearPicker")
    }

    private var options: [String] { years.contains(year) ? years : [year] + years }

    private func label(_ option: String) -> String {
        let text = "\(option.replacingOccurrences(of: "-", with: "/"))"
        return currentLabel && option == TaxYear.of() ? "\(text) (this year)" : text
    }
}

/// Downloads a file the server builds (the tax sheet, a CSV), then offers it to share or save.
struct TaxDownloadButton: View {
    let title: String
    var systemImage = "arrow.down.doc"
    let fetch: () async throws -> URL
    @State private var file: URL?
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let file {
                ShareLink(item: file) {
                    Label("Share or save \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("tax.download.share")
            } else {
                Button {
                    Task { await load() }
                } label: {
                    if busy { HStack { ProgressView(); Text("Preparing…") } } else { Label(title, systemImage: systemImage) }
                }
                .disabled(busy)
                .accessibilityIdentifier("tax.download")
            }
            if let error {
                Text(error.plainMessage).font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
            }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            file = try await fetch()
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A short, centred "nothing here" message inside a list.
struct TaxEmptyRow: View {
    let title: String
    var message: String?
    var systemImage = "tray"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondaryText).accessibilityHidden(true)
            Text(title).font(.wsHeadline).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.wsSubheadline).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

/// A checkbox row (declarations and consents): the words are the label, the whole row toggles.
struct TaxCheckbox: View {
    @Binding var isOn: Bool
    let text: String
    var identifier = "tax.checkbox"

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn ? Tone.brand.color : .secondaryText)
                    .accessibilityHidden(true)
                Text(text).font(.wsSubheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// Opens a downloaded file (an original bank statement) in Quick Look.
struct TaxQuickLook: ViewModifier {
    @Binding var url: URL?

    func body(content: Content) -> some View {
        content.quickLookPreview($url)
    }
}

extension View {
    func taxQuickLook(_ url: Binding<URL?>) -> some View { modifier(TaxQuickLook(url: url)) }
}

/// Session helpers shared by the tax screens.
extension SessionStore {
    func allows(_ action: Action, _ module: String) -> Bool { permissions.can(action, moduleName: module) }
}

extension View {
    /// A sheet has its own navigation stack: register the screens its links open.
    func taxSheetDestinations() -> some View {
        navigationDestination(for: NativeScreenRoute.self) { NativeScreenView(route: $0) }
            .navigationDestination(for: ResourceRoute.self) { ResourceDetailView(route: $0) }
            .navigationDestination(for: ResourceListRoute.self) { ResourceListView(route: $0) }
    }
}
