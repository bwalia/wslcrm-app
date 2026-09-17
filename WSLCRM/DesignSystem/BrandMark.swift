import SwiftUI

/// The white-label brand mark: the brand's own artwork when the build sets one
/// (BRAND_MARK), otherwise the house SF Symbol.
struct BrandMark: View {
    var size: CGFloat = 44
    var brand: Brand = .current

    var body: some View {
        Group {
            if let name = brand.markImageName, UIImage(named: name) != nil {
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
        .accessibilityHidden(true)
    }
}
