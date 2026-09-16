import SwiftUI
import UIKit

// MARK: - Tones

/// Semantic colours. Every use is paired with an icon and text, never colour alone.
enum Tone: Sendable {
    case neutral, info, progress, success, warning, danger

    /// Fills, borders and glyphs. Use `textColor` for anything a person has to read:
    /// the system greens and oranges are well under 4.5:1 against a light background.
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .progress: .indigo
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }

    /// Fill for a solid button or chip with white text on top: dark enough for 4.5:1 in both
    /// appearances, unlike the system greens/oranges (white on `.green` is about 1.9:1).
    var solidColor: Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch self {
            case .neutral: return dark ? UIColor(white: 0.32, alpha: 1) : UIColor(white: 0.26, alpha: 1)
            case .info: return dark ? UIColor(red: 0.04, green: 0.36, blue: 0.80, alpha: 1)
                                    : UIColor(red: 0.00, green: 0.31, blue: 0.72, alpha: 1)
            case .progress: return dark ? UIColor(red: 0.31, green: 0.24, blue: 0.78, alpha: 1)
                                        : UIColor(red: 0.25, green: 0.18, blue: 0.69, alpha: 1)
            case .success: return dark ? UIColor(red: 0.07, green: 0.47, blue: 0.24, alpha: 1)
                                       : UIColor(red: 0.02, green: 0.39, blue: 0.18, alpha: 1)
            case .warning: return dark ? UIColor(red: 0.53, green: 0.33, blue: 0.00, alpha: 1)
                                       : UIColor(red: 0.45, green: 0.28, blue: 0.00, alpha: 1)
            case .danger: return dark ? UIColor(red: 0.70, green: 0.10, blue: 0.10, alpha: 1)
                                      : UIColor(red: 0.61, green: 0.07, blue: 0.07, alpha: 1)
            }
        })
    }

    /// The readable version of `color`: at least 4.5:1 against this tone's tinted card in
    /// both light and dark appearance (checked by the accessibility audit in the UI tests).
    var textColor: Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch self {
            case .neutral: return dark ? UIColor(white: 0.84, alpha: 1) : UIColor(white: 0.28, alpha: 1)
            case .info: return dark ? UIColor(red: 0.45, green: 0.72, blue: 1.00, alpha: 1)
                                    : UIColor(red: 0.00, green: 0.31, blue: 0.72, alpha: 1)
            case .progress: return dark ? UIColor(red: 0.70, green: 0.67, blue: 1.00, alpha: 1)
                                        : UIColor(red: 0.25, green: 0.18, blue: 0.69, alpha: 1)
            case .success: return dark ? UIColor(red: 0.44, green: 0.85, blue: 0.55, alpha: 1)
                                       : UIColor(red: 0.02, green: 0.39, blue: 0.18, alpha: 1)
            case .warning: return dark ? UIColor(red: 1.00, green: 0.78, blue: 0.38, alpha: 1)
                                       : UIColor(red: 0.45, green: 0.28, blue: 0.00, alpha: 1)
            case .danger: return dark ? UIColor(red: 1.00, green: 0.58, blue: 0.55, alpha: 1)
                                      : UIColor(red: 0.61, green: 0.07, blue: 0.07, alpha: 1)
            }
        })
    }
}

extension ShapeStyle where Self == Color {
    /// Supporting text. `.secondary` is 60% of the label colour, which lands just under the
    /// contrast threshold on our cards, so supporting text uses this instead.
    static var secondaryText: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.78, alpha: 1)
                                                                : UIColor(white: 0.30, alpha: 1) })
    }
}

/// Section title for the sheets engineers fill in on site.
///
/// A `Form` section *header* renders in the system grey (about 2.7:1 on a grouped background)
/// and ignores `foregroundStyle`, so the title is the section's first row instead.
struct SheetSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondaryText)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status badge

/// A status pill: icon + label + tinted background. Readable without colour perception.
struct StatusBadge: View {
    let text: String
    let systemImage: String
    let tone: Tone
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline.weight(.semibold))
                // At accessibility sizes the pill wraps rather than truncating to "On…".
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(tone.textColor)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(text)")
    }
}

// MARK: - Buttons

/// Large, high-contrast button for one-handed/gloved use. Minimum 56pt tall.
struct LargeButtonStyle: ButtonStyle {
    var tone: Tone = .info
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        LargeButtonBody(configuration: configuration, tone: tone, prominent: prominent)
    }

    private struct LargeButtonBody: View {
        let configuration: Configuration
        let tone: Tone
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 16)
                .foregroundStyle(prominent ? Color.white : tone.textColor)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(prominent ? tone.solidColor : tone.color.opacity(0.12))
                }
                .overlay {
                    if !prominent {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(tone.textColor, lineWidth: 2)
                    }
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == LargeButtonStyle {
    static func large(_ tone: Tone = .info, prominent: Bool = true) -> LargeButtonStyle {
        LargeButtonStyle(tone: tone, prominent: prominent)
    }
}

// MARK: - Loading skeleton

/// Placeholder rows shown while a list loads for the first time.
struct SkeletonList: View {
    var rows = 6

    var body: some View {
        List {
            ForEach(0..<rows, id: \.self) { _ in
                SkeletonRow()
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

struct SkeletonRow: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 16)
            RoundedRectangle(cornerRadius: 4).frame(width: 240, height: 12)
            RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 12)
        }
        .foregroundStyle(Color.secondary.opacity(pulse ? 0.18 : 0.30))
        .padding(.vertical, 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Errors

/// Inline error with a retry action and a link to technical details (correlation id).
struct InlineErrorRow: View {
    let error: APIError
    var retry: (() -> Void)?
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(error.localizedDescription)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: error.isConnectivityProblem ? "wifi.slash" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.danger.textColor)
            }
            HStack(spacing: 12) {
                if let retry {
                    Button("Try again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                if error.serverError != nil || isDecoding {
                    Button("Details") { showingDetails = true }
                        .buttonStyle(.borderless)
                        .controlSize(.large)
                        .accessibilityHint("Shows technical details you can copy for support")
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showingDetails) {
            ErrorDetailsView(error: error)
        }
    }

    private var isDecoding: Bool {
        if case .decoding = error { return true }
        return false
    }
}

/// Full-screen error state for when a screen has nothing to show.
struct ErrorStateView: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: error.isConnectivityProblem ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
                InlineErrorRow(error: error, retry: retry)
                    .frame(maxWidth: 420)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Copyable technical details. Support asks for the correlation id.
struct ErrorDetailsView: View {
    let error: APIError
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let server = error.serverError {
                    if let correlation = server.correlationId {
                        CopyableRow(label: "Correlation ID", value: correlation)
                    }
                    CopyableRow(label: "HTTP status", value: String(server.status))
                    if let code = server.code { CopyableRow(label: "Error code", value: code) }
                    if let title = server.title { CopyableRow(label: "Title", value: title) }
                    CopyableRow(label: "Message", value: server.message)
                    if let reason = server.reason { CopyableRow(label: "Reason", value: reason) }
                    if let occurrence = server.occurrenceUuid { CopyableRow(label: "Occurrence", value: occurrence) }
                    if let required = server.requiredPermission {
                        CopyableRow(label: "Required permission", value: "\(required.module).\(required.action)")
                    }
                    if !server.rawBody.isEmpty {
                        Section("Response") {
                            Text(server.rawBody).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                if case .decoding(let endpoint, let description, let body) = error {
                    CopyableRow(label: "Endpoint", value: endpoint)
                    CopyableRow(label: "Problem", value: description)
                    Section("Response") {
                        Text(body).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Error details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy all", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = summary
                    }
                }
            }
        }
    }

    private var summary: String {
        var lines: [String] = []
        if let server = error.serverError {
            lines.append("status=\(server.status)")
            if let c = server.correlationId { lines.append("correlation_id=\(c)") }
            if let c = server.code { lines.append("code=\(c)") }
            lines.append("message=\(server.message)")
        }
        if case .decoding(let endpoint, let description, _) = error {
            lines.append("endpoint=\(endpoint)")
            lines.append("decoding=\(description)")
        }
        return lines.joined(separator: "\n")
    }
}

struct CopyableRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondaryText)
                HStack {
                    Text(value).font(.body.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(.secondaryText)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel("\(label): \(value)")
        .accessibilityHint(copied ? "Copied" : "Double tap to copy")
    }
}

// MARK: - Rows

/// A label/value row used on detail screens.
struct DetailRow: View {
    let label: String
    let value: String?
    var systemImage: String?

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent {
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            } label: {
                if let systemImage {
                    Label(label, systemImage: systemImage)
                } else {
                    Text(label)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Large tap target that dials a number.
struct PhoneLinkRow: View {
    let name: String?
    let phone: String

    var body: some View {
        if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
            Link(destination: url) {
                HStack(spacing: 14) {
                    Image(systemName: "phone.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Tone.success.color.opacity(0.15), in: Circle())
                        .foregroundStyle(Tone.success.color)
                    VStack(alignment: .leading) {
                        Text(name ?? "Call").font(.headline).foregroundStyle(.primary)
                        Text(phone).font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                }
                .frame(minHeight: 56)
            }
            .accessibilityLabel("Call \(name ?? "") \(phone)")
        }
    }
}

/// Opens the address in Apple Maps.
struct MapsLinkRow: View {
    let address: String

    var body: some View {
        if let url = MapsLink.url(for: address) {
            Link(destination: url) {
                HStack(spacing: 14) {
                    Image(systemName: "map.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Tone.info.color.opacity(0.15), in: Circle())
                        .foregroundStyle(Tone.info.color)
                    VStack(alignment: .leading) {
                        Text("Directions").font(.headline).foregroundStyle(.primary)
                        Text(address).font(.subheadline).foregroundStyle(.secondaryText).multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
                .frame(minHeight: 56)
            }
            .accessibilityLabel("Get directions to \(address)")
        }
    }
}

enum MapsLink {
    static func url(for address: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        return components?.url
    }
}

/// Banner for offline mode and unsynced writes.
struct SyncStatusBanner: View {
    let isOnline: Bool
    let pendingCount: Int
    let failedCount: Int

    var body: some View {
        if !isOnline || pendingCount > 0 || failedCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(failedCount > 0 ? Tone.danger.color : (isOnline ? Tone.progress.color : Color.gray))
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        if failedCount > 0 { return "exclamationmark.icloud.fill" }
        return isOnline ? "arrow.triangle.2.circlepath.icloud" : "wifi.slash"
    }

    private var message: String {
        var parts: [String] = []
        if !isOnline { parts.append("Offline") }
        if pendingCount > 0 { parts.append("\(pendingCount) change\(pendingCount == 1 ? "" : "s") waiting to sync") }
        if failedCount > 0 { parts.append("\(failedCount) failed — tap to review") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// Applies the standard empty state when `isEmpty`.
    @ViewBuilder
    func emptyState(_ isEmpty: Bool, title: String, systemImage: String, description: String? = nil) -> some View {
        overlay {
            if isEmpty {
                ContentUnavailableView {
                    Label(title, systemImage: systemImage)
                } description: {
                    if let description { Text(description) }
                }
            }
        }
    }
}
