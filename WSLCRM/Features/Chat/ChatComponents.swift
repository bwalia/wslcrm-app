import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Avatar

/// Initials on a colour picked from the person's id (the same colour every time), with an optional
/// presence dot. Colour is never the only signal: the presence is also in the accessibility label.
struct ChatAvatar: View {
    let name: String
    var seed: String?
    var presence: ChatPresence?
    var size: CGFloat = 36

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(Self.initials(name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Palette.tile(for: seed ?? name), in: Circle())
            if let presence, presence != .offline {
                Circle()
                    .fill(presence.tone.color)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presence.map { "\(name), \($0.label)" } ?? name)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

/// The assistant's own avatar.
struct ChatAssistantAvatar: View {
    var size: CGFloat = 32
    var busy = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color.accentColor, Palette.tileColors[1]],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .scaleEffect(busy && pulse ? 1.08 : 1)
            .onChange(of: busy, initial: true) {
                guard !reduceMotion else { return }
                withAnimation(busy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default) {
                    pulse = busy
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Badges

/// Unread count, as the web shows it ("99+" past 99; the server caps at 100).
struct ChatUnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.wsCaption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Tone.brand.solidColor, in: Capsule())
            .accessibilityLabel("\(count) unread")
    }
}

/// Whether messages arrive instantly or by checking every few seconds.
struct ChatConnectionBadge: View {
    let status: ChatHub.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 8, height: 8)
            Text(label).font(.wsCaption)
        }
        .foregroundStyle(.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier("chat.connection")
    }

    private var label: String {
        switch status {
        case .live: "Live"
        case .connecting: "Connecting…"
        case .retrying, .off: "Checking every few seconds"
        }
    }

    private var accessibility: String {
        switch status {
        case .live: "Live: new messages arrive instantly"
        case .connecting: "Connecting for instant messages"
        case .retrying, .off: "Instant updates are unavailable; new messages are checked every few seconds"
        }
    }

    private var tone: Tone {
        switch status {
        case .live: .success
        case .connecting: .warning
        case .retrying, .off: .neutral
        }
    }
}

// MARK: - Flow layout

/// Lays chips out in rows, wrapping to the next line (reactions, the assistant's actions).
struct ChatFlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Files

enum ChatFiles {
    /// Longest edge 2048 px, JPEG quality 0.7 — a few hundred KB per photo, well under the limit.
    nonisolated static func jpeg(from image: UIImage, maxDimension: CGFloat = 2048) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func photoName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "photo-\(formatter.string(from: date)).jpg"
    }

    /// An attachment's address: absolute as the server stores it, or relative to the API.
    static func url(for attachment: ChatAttachment, apiBase: URL?) -> URL? {
        if let url = URL(string: attachment.fileUrl), url.scheme != nil { return url }
        guard let apiBase else { return nil }
        return URL(string: attachment.fileUrl, relativeTo: apiBase)?.absoluteURL
    }

    static func symbol(for attachment: ChatAttachment) -> String {
        let type = attachment.fileType?.lowercased() ?? ""
        let ext = (attachment.fileName as NSString).pathExtension.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if ["xls", "xlsx", "csv", "numbers"].contains(ext) { return "tablecells" }
        if ["zip", "gz", "tar", "7z"].contains(ext) { return "doc.zipper" }
        return "doc"
    }
}

/// Opens a message's file natively: downloads it once, then shows it in Quick Look (which can
/// zoom, play, share and save it). Images are shown inline in the conversation as well.
@MainActor
@Observable
final class ChatFileOpener {
    var previewURL: URL?
    private(set) var opening: String?
    var error: String?

    func open(_ attachment: ChatAttachment, apiBase: URL?) async {
        guard opening == nil else { return }
        guard let remote = ChatFiles.url(for: attachment, apiBase: apiBase) else {
            error = "This file's address isn't valid, so it can't be opened."
            return
        }
        opening = attachment.fileName
        defer { opening = nil }
        do {
            previewURL = try await Self.download(remote, name: attachment.fileName)
        } catch {
            self.error = "Couldn't open \(attachment.fileName): \(error.asAPIError.localizedDescription)"
        }
    }

    /// Kept in the caches folder by address, so opening it again is instant.
    nonisolated static func download(_ remote: URL, name: String) async throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-files", isDirectory: true)
            .appendingPathComponent(stableKey(remote.absoluteString), isDirectory: true)
        let safeName = name.replacingOccurrences(of: "/", with: "-").trimmedOrNil ?? remote.lastPathComponent
        let destination = folder.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let (temp, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.from(status: http.statusCode, data: Data(), headers: http.allHeaderFields)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    /// The same folder name for the same address on every launch (`hashValue` is seeded per launch).
    nonisolated static func stableKey(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// One attachment in a message: the picture itself for an image, a file chip otherwise.
struct ChatAttachmentView: View {
    let attachment: ChatAttachment
    let apiBase: URL?
    var mine = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            if attachment.isImage, let url = ChatFiles.url(for: attachment, apiBase: apiBase) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        fileChip
                    default:
                        Rectangle().fill(Color(.tertiarySystemFill)).overlay(ProgressView())
                    }
                }
                .frame(maxWidth: 240, minHeight: 120, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                fileChip
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.isImage ? "Picture \(attachment.fileName)" : "File \(attachment.fileName)")
        .accessibilityHint("Opens it")
    }

    private var fileChip: some View {
        HStack(spacing: 10) {
            Image(systemName: ChatFiles.symbol(for: attachment))
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName).font(.wsSubheadline.weight(.semibold)).lineLimit(2)
                if let size = attachment.sizeLabel {
                    Text(size).font(.wsCaption).opacity(0.8)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.circle")
                .opacity(0.8)
        }
        .padding(10)
        .frame(maxWidth: 260)
        .background(mine ? Color.white.opacity(0.16) : Color(.systemBackground).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    /// Quick Look for a chat file, with a "Opening…" overlay and a plain error if it fails.
    func chatFilePreview(_ opener: ChatFileOpener) -> some View {
        modifier(ChatFilePreviewModifier(opener: opener))
    }
}

private struct ChatFilePreviewModifier: ViewModifier {
    @Bindable var opener: ChatFileOpener

    func body(content: Content) -> some View {
        content
            .quickLookPreview($opener.previewURL)
            .overlay(alignment: .top) {
                if let name = opener.opening {
                    Label("Opening \(name)…", systemImage: "arrow.down.circle")
                        .font(.wsFootnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .alert("Couldn't open the file", isPresented: Binding(get: { opener.error != nil },
                                                                 set: { if !$0 { opener.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(opener.error ?? "")
            }
    }
}

// MARK: - Alerts banner

extension View {
    /// Shows the hub's heads-up about other conversations at the top of a chat screen.
    func chatAlerts(open: @escaping (ChatAlert.Target) -> Void) -> some View {
        modifier(ChatAlertBannerModifier(open: open))
    }
}

private struct ChatAlertBannerModifier: ViewModifier {
    let open: (ChatAlert.Target) -> Void
    private var hub: ChatHub { ChatHub.shared }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let alert = hub.alert {
                Button {
                    hub.dismissAlert()
                    open(alert.target)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isAssistant(alert) ? "sparkles" : "bubble.left.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title).font(.wsSubheadline.weight(.semibold)).lineLimit(1)
                            Text(alert.body).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text("Open").font(.wsFootnote.weight(.semibold)).foregroundStyle(Tone.brand.textColor)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("chat.alert")
                .accessibilityHint("Opens that conversation")
            }
        }
        .animation(.snappy, value: hub.alert)
    }

    private func isAssistant(_ alert: ChatAlert) -> Bool {
        if case .assistant = alert.target { return true }
        return false
    }
}

// MARK: - Day labels

enum ChatDates {
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The list's trailing time: the time today, the day otherwise.
    static func shortLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
