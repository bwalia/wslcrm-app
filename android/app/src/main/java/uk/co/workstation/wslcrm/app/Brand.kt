package uk.co.workstation.wslcrm.app

import uk.co.workstation.wslcrm.BuildConfig

/**
 * White-label identity for this build (mirrors `Brand.swift`). Values come from the product
 * flavour's `BRAND_*` BuildConfig fields; the launcher icon, brand mark and colours come from the
 * flavour's brand resource directory (`src/brandHouse`, `src/brandDbs`).
 */
data class Brand(
    val name: String,
    /** True when `R.drawable.brand_mark` is real artwork; otherwise the house icon is drawn. */
    val hasMark: Boolean,
    val company: ReportCompany,
) {
    companion object {
        val current: Brand by lazy {
            from(
                mapOf(
                    "name" to BuildConfig.BRAND_NAME,
                    "legalName" to BuildConfig.BRAND_LEGAL_NAME,
                    "strapline" to BuildConfig.BRAND_STRAPLINE,
                    "address" to BuildConfig.BRAND_ADDRESS,
                    "phone" to BuildConfig.BRAND_PHONE,
                    "email" to BuildConfig.BRAND_EMAIL,
                    "companyNumber" to BuildConfig.BRAND_COMPANY_NUMBER,
                    "vatNumber" to BuildConfig.BRAND_VAT_NUMBER,
                ),
                hasMark = BuildConfig.BRAND_HAS_MARK,
            )
        }

        /** Builds the brand from raw values (a map, so tests can supply their own). Blank means unset. */
        fun from(values: Map<String, String?>, hasMark: Boolean): Brand {
            fun value(key: String) = values[key]?.trim()?.takeIf { it.isNotEmpty() }
            val name = value("name") ?: "WSLCRM"
            return Brand(
                name = name,
                hasMark = hasMark,
                company = ReportCompany(
                    name = name,
                    legalName = value("legalName"),
                    strapline = value("strapline"),
                    address = value("address"),
                    phone = value("phone"),
                    email = value("email"),
                    companyNumber = value("companyNumber"),
                    vatNumber = value("vatNumber"),
                ),
            )
        }
    }
}

/** The letterhead and legal footer printed on report PDFs. */
data class ReportCompany(
    val name: String,
    val legalName: String? = null,
    val strapline: String? = null,
    val address: String? = null,
    val phone: String? = null,
    val email: String? = null,
    val companyNumber: String? = null,
    val vatNumber: String? = null,
) {
    /** "David Blakey Services Limited · 6-8 Colne Way Court … · Company Registration No 03806201 · VAT No …" */
    val legalFooter: String
        get() = listOfNotNull(
            legalName, address, companyNumber?.let { "Company Registration No $it" }, vatNumber?.let { "VAT No $it" },
        ).joinToString("  ·  ")
}
