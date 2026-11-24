import SwiftUI

/// A picture (a course's, a lesson's, a profile photo, a form's logo): picked, or uploaded and cropped, in
/// the website's media library (`GET /api/v2/cms/media` needs `cms.read`; uploading there needs
/// `cms.update`), or a pasted link. Rows only: put it inside a Section.
struct EngageImageField: View {
    @Binding var url: String
    var alt = "Picture"
    var placeholder = "https://…/picture.jpg"
    var previewWidth: Double?
    var previewHeight: CGFloat = 160
    let id: String
    @Environment(SessionStore.self) private var session
    @State private var choosing = false
    @State private var showingLink = false

    static func canPick(_ permissions: PermissionSet) -> Bool { permissions.can(.read, moduleName: CMS.module) }

    /// Only web addresses a learner's or visitor's device can load are previewed.
    static func preview(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("http") else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        if let preview = Self.preview(url) {
            RichImage(url: preview, alt: alt, width: previewWidth).frame(maxHeight: previewHeight)
        }
        if Self.canPick(session.permissions) {
            Button { choosing = true } label: {
                Label(url.isEmpty ? "Choose a picture" : "Change the picture", systemImage: "photo.on.rectangle")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("\(id).choose")
            // On the row, never on the Section (a Section's modals are copied onto every row).
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    CMSMediaLibraryView(pick: { asset in url = asset.string("url") ?? url })
                }
            }
            if !url.isEmpty {
                Button(role: .destructive) { url = "" } label: { Label("Remove the picture", systemImage: "xmark.circle") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("\(id).remove")
            }
            DisclosureGroup("Paste a link instead", isExpanded: $showingLink) { linkField }
        } else {
            linkField
            Text("To pick or upload pictures, ask a workspace admin for access to the website's media library. "
                 + "Until then, paste the picture's web address; it must start with https://.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    private var linkField: some View {
        TextField(placeholder, text: $url)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(id)
    }
}
