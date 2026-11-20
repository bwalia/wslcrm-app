import Foundation
import os

/// Who the app is presenting itself as: the house brand (Workstation, from `BRAND_*` build
/// settings in Config/Brand-Default.xcconfig), or the signed-in workspace's own name, logo and
/// letterhead from the server (`WorkspaceBrand`, kept by `BrandStore`). Every business uses
/// the same build; a business's look is data, never a release.
struct Brand: Sendable, Equatable {
    var name: String
    /// Asset catalog image for the brand mark; nil falls back to an SF Symbol.
    var markImageName: String?
    /// The workspace's own logo, rendered on this phone; wins over `markImageName`.
    var logoFile: URL?
    var company: ReportCompany
    /// The accent colour set; `<name>-Fill` and `<name>-Text` sit beside it (Tone.brand).
    var accentColorName: String = "AccentColor"

    /// The house brand compiled into the app: what everyone sees before signing in for the first time.
    static let house = Brand.fromBundle()

    private static let storage = OSAllocatedUnfairLock(initialState: Brand.house)

    /// The brand on screen now. Views observe `BrandStore.shared.brand`; this is for code that
    /// isn't a view (sign-in prompts, report PDFs).
    static var current: Brand { storage.withLock { $0 } }

    static func setCurrent(_ brand: Brand) { storage.withLock { $0 = brand } }

    static func fromBundle(_ bundle: Bundle = .main) -> Brand {
        from(info: { bundle.object(forInfoDictionaryKey: $0) })
    }

    /// Builds the brand from Info.plist-style values (a closure, so tests can supply a dictionary).
    static func from(info: (String) -> Any?) -> Brand {
        func value(_ key: String) -> String? {
            guard let raw = info(key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // An unexpanded "$(BRAND_X)" means the setting was never defined for this build.
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
        }
        let name = value("WSLBrandName") ?? "Workstation AI‑native CRM"
        return Brand(
            name: name,
            markImageName: value("WSLBrandMark"),
            company: ReportCompany(
                name: name,
                legalName: value("WSLBrandLegalName"),
                strapline: value("WSLBrandStrapline"),
                address: value("WSLBrandAddress"),
                phone: value("WSLBrandPhone"),
                email: value("WSLBrandEmail"),
                companyNumber: value("WSLBrandCompanyNumber"),
                vatNumber: value("WSLBrandVATNumber")),
            accentColorName: value("WSLBrandAccentColor") ?? "AccentColor")
    }
}

/// The letterhead and legal footer printed on report PDFs.
struct ReportCompany: Sendable, Equatable {
    var name: String
    var legalName: String?
    var strapline: String?
    var address: String?
    var phone: String?
    var email: String?
    var companyNumber: String?
    var vatNumber: String?

    init(name: String, legalName: String? = nil, strapline: String? = nil, address: String? = nil,
         phone: String? = nil, email: String? = nil, companyNumber: String? = nil, vatNumber: String? = nil) {
        self.name = name
        self.legalName = legalName
        self.strapline = strapline
        self.address = address
        self.phone = phone
        self.email = email
        self.companyNumber = companyNumber
        self.vatNumber = vatNumber
    }

    /// "David Blakey Services Limited · 6-8 Colne Way Court … · Company Registration No 03806201 · VAT No …"
    var legalFooter: String {
        [legalName, address, companyNumber.map { "Company Registration No \($0)" }, vatNumber.map { "VAT No \($0)" }]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }
}
