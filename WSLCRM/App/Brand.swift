import Foundation

/// White-label identity for this build, from `BRAND_*` build settings through Info.plist.
///
/// The defaults in project.yml give the house brand ("WSLCRM", SF Symbol mark). A brand
/// xcconfig such as Config/Brand-DBS.xcconfig swaps in a customer's name, mark, app icon and the
/// company details printed on report PDFs, without touching code.
struct Brand: Sendable, Equatable {
    var name: String
    /// Asset catalog image for the brand mark; nil means use the house SF Symbol.
    var markImageName: String?
    var company: ReportCompany

    static let current = Brand.fromBundle()

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
        let name = value("WSLBrandName") ?? "WSLCRM"
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
                vatNumber: value("WSLBrandVATNumber")))
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
