import SwiftUI

// The email design pieces other marketing screens use (a campaign's content, the studio).
// Owned by the design part; these signatures are the contract with the campaigns part.

/// A ready-made design or a saved template, chosen for an email.
struct MktDesign: Hashable, Sendable {
    var uuid: String?
    var name: String
    var subject: String
    var previewText: String
    var bodyHTML: String
    var bodyText: String

    init(uuid: String? = nil, name: String, subject: String = "", previewText: String = "", bodyHTML: String = "",
         bodyText: String = "") {
        self.uuid = uuid
        self.name = name
        self.subject = subject
        self.previewText = previewText
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
    }
}

/// The native editor for an email's body. Edits `html` in place (the caller saves it).
/// A full screen: push it, or present it in a `NavigationStack`.
struct MktEmailEditor: View {
    @Binding var html: String
    var readOnly = false

    init(html: Binding<String>, readOnly: Bool = false) {
        _html = html
        self.readOnly = readOnly
    }

    var body: some View {
        Form {
            Section("Preview") { RichTextView(html: MktEmailSample.fill(html), appearance: .email, linksOpen: false) }
            if !readOnly {
                Section("HTML") {
                    TextEditor(text: $html).font(.system(.footnote, design: .monospaced)).frame(minHeight: 240)
                }
            }
        }
    }
}

/// Ready-made designs, the workspace's saved templates and "Create a design with AI".
/// Calls `onPick` with the chosen design, then closes itself. Present it in a `NavigationStack`.
struct MktDesignGallery: View {
    let onPick: (MktDesign) -> Void

    var body: some View {
        ContentUnavailableView("No designs yet", systemImage: "paintpalette")
    }
}

/// How an email reads for a sample person: merge tags filled in for the preview.
enum MktEmailSample {
    static func fill(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{\{\s*contact\.first_name\s*\}\}"#, with: "Alex", options: .regularExpression)
            .replacingOccurrences(of: #"\{\{\s*[\w.]+\s*\}\}"#, with: "#", options: .regularExpression)
    }
}

/// Email images: uploaded to the plugin (`POST /images`, base64, up to 2 MB) and used by address.
enum MktEmailImages {
    static let maxBytes = 2 * 1024 * 1024

    /// Uploads an image and returns its public address for `<img src>`.
    static func upload(_ file: EngageFile, using client: EngageClient) async throws -> String {
        let answer = try await client.post(Marketing.path("/images"),
                                           .object(["file_name": .string(file.name),
                                                    "content_base64": .string(file.base64)]),
                                           timeout: 60)
        guard let url = answer.payload["url"]?.stringValue else {
            throw ResourceService.problem(422, "The image was saved but no address came back. Try again.")
        }
        return url
    }
}
