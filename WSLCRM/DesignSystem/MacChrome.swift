import SwiftUI

// The app's chrome on a Mac (and the same pieces on iPhone where they apply): sheet sizes, the search field a sheet
// puts under its title, and the toolbar's pieces, so every window reads as one product.

extension View {
    /// A sheet's size on the Mac: fixed, so a picker or a list isn't hugging its content in a small default sheet.
    /// No effect on iPhone and iPad, where sheets size themselves.
    func wsMacSheetSize(width: CGFloat = 520, height: CGFloat = 600) -> some View {
        #if targetEnvironment(macCatalyst)
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }
}

extension View {
    /// Search for a list in a sheet or picker: on the Mac a full-width field under the title (a sheet's `.searchable`
    /// is squeezed into its title bar there, beside the buttons); on iPhone and iPad the system search bar.
    /// `isEnabled: false` leaves search out (a list of one or two).
    func wsSheetSearchable(text: Binding<String>, prompt: String, isEnabled: Bool = true) -> some View {
        modifier(SheetSearchable(text: text, prompt: prompt, isEnabled: isEnabled))
    }
}

private struct SheetSearchable: ViewModifier {
    @Binding var text: String
    let prompt: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if MacSupport.isMac {
            content.safeAreaInset(edge: .top, spacing: 0) {
                WSSearchField(prompt: prompt, text: $text)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
            }
        } else {
            content.searchable(text: $text, prompt: prompt)
        }
    }
}

/// A full-width search field with comfortable padding, for the top of a sheet or panel (on the Mac a sheet's
/// `.searchable` is squeezed into its title bar). Escape clears it; Return runs `onSubmit`.
struct WSSearchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear the search")
            }
        }
        .font(.wsBody)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline))
    }
}

/// A status in a toolbar ("Live", "Offline"): a dot and a word, plain text so it never reads as a button.
struct WSToolbarStatus: View {
    let text: String
    let tone: Tone
    var help: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 4)
        .help(help ?? text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help ?? text)
    }
}
