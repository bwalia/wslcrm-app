import SwiftUI

/// The brand mark: the signed-in workspace's logo when it has one, otherwise the house mark
/// (BRAND_MARK), otherwise an SF Symbol.
struct BrandMark: View {
    var size: CGFloat = 44
    /// nil follows the workspace (BrandStore); set only in previews and tests.
    var brand: Brand?
    @State private var store = BrandStore.shared
    @State private var theme = ThemeStore.shared
    /// Decorative where the brand name is already spelled out beside it (sign-in).
    /// In a navigation bar there is no such label, so the mark names itself instead.
    var isDecorative: Bool = true

    var body: some View {
        let brand = self.brand ?? personalised(store.brand)
        Group {
            if self.brand == nil, let custom = theme.customLogo {
                // The person's own picture (Settings › Appearance).
                Image(uiImage: custom)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .id(theme.logoVersion)
            } else if let file = brand.logoFile, let logo = UIImage(contentsOfFile: file.path) {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else if let name = brand.markImageName, UIImage(named: name) != nil {
                Image(name)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(isDecorative ? Text(verbatim: "") : Text(brand.name))
        .accessibilityIdentifier(isDecorative ? "" : "brand.mark")
    }
}

extension BrandMark {
    /// "Workstation logo" chosen in Settings › Appearance: the house mark, whatever the workspace.
    fileprivate func personalised(_ brand: Brand) -> Brand {
        guard theme.logo == .house else { return brand }
        var house = brand
        house.logoFile = nil
        house.markImageName = Brand.house.markImageName
        return house
    }
}

extension View {
    /// Carries the brand into the navigation bar of a screen someone lands on after
    /// signing in — otherwise a white-label build only looks white-labelled until
    /// the moment it is used.
    func brandedNavigationBar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandMark(size: 36, isDecorative: false)
            }
        }
    }
}
