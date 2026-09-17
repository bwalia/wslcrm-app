import PDFKit
import XCTest
@testable import WSLCRM

/// The Simpro-aligned screens added for the DBS Ltd demo: who sees them, how their payloads decode,
/// how report cells format, what the report PDF contains, and how the white-label brand resolves.
///
/// Role grants below are the real `GET /api/v2/user/menu` permissions the seeded DBS service
/// manager, service desk and engineer received from opsapi `feat/dbs-simpro-crm` (#612).
final class SimproDemoTests: XCTestCase {
    private func permissions(_ grants: [String: [String]], owner: Bool = false) -> PermissionSet {
        PermissionSet(isAdmin: false, isOwner: owner, grants: grants.mapValues(Set.init), menuKeys: [])
    }

    // MARK: - Who sees what

    func testServiceManagerSeesAssetsReportsAndReadOnlySync() {
        let p = permissions(["fs_assets": ["delete", "read", "create", "update"], "fs_contracts": ["read", "create", "update"],
                             "fs_reports": ["read"], "simpro_sync": ["read"], "fs_jobs": ["manage"]])
        XCTAssertTrue(p.can(.read, .fsAssets))
        XCTAssertTrue(p.can(.update, .fsAssets), "managers record surveys too")
        XCTAssertTrue(p.can(.read, .fsReports))
        XCTAssertTrue(p.can(.read, .simproSync))
        XCTAssertFalse(p.can(.manage, .simproSync), "running a sync writes to Simpro: owner only")
    }

    func testServiceDeskReadsAssetsAndReportsButCannotSurvey() {
        let p = permissions(["fs_quotes": ["read", "create", "update"], "fs_assets": ["read"],
                             "fs_reports": ["read"], "fs_contracts": ["read"]])
        XCTAssertTrue(p.can(.read, .fsAssets))
        XCTAssertFalse(p.can(.update, .fsAssets))
        XCTAssertTrue(p.can(.read, .fsReports))
        XCTAssertFalse(p.can(.read, .simproSync))
    }

    func testEngineerSurveysAssetsButGetsNoPortfolioReports() {
        let p = permissions(["fs_assets": ["update", "read"], "fs_contracts": ["read"], "fs_jobs": ["read"]])
        XCTAssertTrue(p.can(.update, .fsAssets))
        XCTAssertFalse(p.can(.read, .fsReports))
        XCTAssertFalse(p.can(.read, .simproSync))
    }

    func testOwnerCanManageSync() {
        XCTAssertTrue(permissions([:], owner: true).can(.manage, .simproSync))
    }

    // MARK: - Decoding

    func testAssetDecodesFlexibleValuesAndSyncState() throws {
        let json = #"""
        {"success":true,"data":{"uuid":"a1","asset_tag":"NBS-VRV-02","name":"Daikin VRV condenser 2",
         "condition_rating":"5","refrigerant_type":"R410A","refrigerant_charge_kg":"16.8","co2e_tonnes":35.08,
         "leak_check_months":12,"next_service_date":"2020-01-01","simpro_id":40021,"simpro_sync_state":"pending",
         "service_levels":[{"uuid":"s1","name":"Quarterly PPM (SFG20)","kind":"service","frequency_months":"3",
                            "next_service_date":"2026-12-12"}],
         "recent_tests":[{"uuid":"t1","tested_at":"2026-06-12 10:30:00","result":"fail","condition_rating":5,
                          "readings":[{"key":"suction_bar","label":"Suction pressure","value":9.1,"unit":"bar"}],
                          "failure_points":[{"key":"low_charge","label":"Low charge"}]}]}}
        """#
        let asset = try JSONDecoder.opsAPI().decode(Envelope.Standard<CustomerAsset>.self, from: Data(json.utf8)).data
        XCTAssertEqual(asset.conditionRating, 5)
        XCTAssertEqual(asset.refrigerantChargeKg, Decimal(string: "16.8"))
        XCTAssertEqual(asset.simproId, "40021")
        XCTAssertEqual(asset.syncState, .pending)
        XCTAssertTrue(asset.isServiceOverdue())
        XCTAssertEqual(asset.serviceLevels.first?.frequencyMonths, 3)
        XCTAssertEqual(asset.recentTests.first?.failurePoints.first?.label, "Low charge")
        XCTAssertEqual(asset.recentTests.first?.readings.first?.displayValue, "9.1 bar")
    }

    func testUnknownSyncStateFallsBackToLocalOnly() throws {
        let json = #"{"uuid":"a2","name":"Boiler","simpro_sync_state":"something_new"}"#
        let asset = try JSONDecoder.opsAPI().decode(CustomerAsset.self, from: Data(json.utf8))
        XCTAssertEqual(asset.syncState, .localOnly)
        XCTAssertFalse(asset.isServiceOverdue(), "no service level means nothing is overdue")
    }

    func testReportDecodesAndTreatsEmptyObjectRowsAsNoRows() throws {
        // The server encodes an empty Lua table as {}.
        let json = #"""
        {"key":"fgas_register","title":"F-Gas register","description":"Refrigerant held.",
         "columns":[{"key":"asset_tag","label":"Asset","type":"text"},{"key":"co2e_tonnes","label":"tCO2e","type":"number"}],
         "rows":{},"summary":{"systems":0,"total_co2e_tonnes":0,"by_month":{}}}
        """#
        let report = try JSONDecoder.opsAPI().decode(Report.self, from: Data(json.utf8))
        XCTAssertEqual(report.rows.count, 0)
        XCTAssertEqual(report.columns.count, 2)
        XCTAssertEqual(report.summaryItems.map(\.label), ["Systems", "Total co2e tonnes"],
                       "nested breakdowns stay off the summary strip")
    }

    // MARK: - Formatting

    func testReportCellFormatting() {
        XCTAssertEqual(ReportFormat.cell(.number(1626.93), type: "number"), "1,626.93")
        XCTAssertEqual(ReportFormat.cell(.string("208.5"), type: "hours"), "208.5 h")
        XCTAssertEqual(ReportFormat.cell(.number(38000), type: "money"), "£38,000.00")
        XCTAssertEqual(ReportFormat.cell(.bool(true), type: "text"), "Yes")
        XCTAssertEqual(ReportFormat.cell(.null, type: "text"), "—")
        XCTAssertEqual(ReportFormat.cell(nil, type: "number"), "—")
        XCTAssertEqual(ReportFormat.summaryLabel("failure_rate_pct"), "Failure rate %")
        XCTAssertEqual(ReportFormat.cell(.string("2026-03-17"), type: "date"),
                       SimproDates.display("2026-03-17"))
    }

    // MARK: - PDF

    func testReportPDFCarriesLetterheadFooterAndPaginates() throws {
        let company = ReportCompany(name: "DBS Ltd", legalName: "David Blakey Services Limited",
                                    strapline: "Air Conditioning // Refrigeration", address: "Watford WD24 7NE",
                                    phone: "01923 246381", email: "info@dbsservices.co.uk",
                                    companyNumber: "03806201", vatNumber: "GB 743 5371 32")
        let rows: [[String: JSONValue]] = (1...120).map {
            ["asset_tag": .string("COL-BLR-\($0)"), "site_name": .string("City of London portfolio"), "co2e_tonnes": .number(Double($0))]
        }
        let report = Report(key: "ppm_forecast", title: "Programmed maintenance forecast", description: "Due soon.",
                            generatedAt: nil,
                            columns: [ReportColumn(key: "asset_tag", label: "Asset", type: "text"),
                                      ReportColumn(key: "site_name", label: "Site", type: "text"),
                                      ReportColumn(key: "co2e_tonnes", label: "tCO2e", type: "number")],
                            rows: rows, summary: ["due": .number(120)])

        let data = ReportPDFRenderer(company: company).render(report)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1, "120 rows must spill onto more pages")
        let first = try XCTUnwrap(document.page(at: 0)?.string)
        XCTAssertTrue(first.contains("DBS Ltd"))
        XCTAssertTrue(first.contains("Programmed maintenance forecast"))
        XCTAssertTrue(first.contains("Company Registration No 03806201"), "legal footer on every page")
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("COL-BLR-120"), "the last row is not dropped")
        XCTAssertTrue(last.contains("VAT No GB 743 5371 32"))
    }

    func testWideReportsNoteTheColumnsLeftToTheCSV() throws {
        let columns = (1...20).map { ReportColumn(key: "c\($0)", label: "Col \($0)", type: "text") }
        let report = Report(key: "powerbi_extract", title: "Power BI extract", description: "", generatedAt: nil,
                            columns: columns, rows: [["c1": .string("x")]], summary: [:])
        let document = try XCTUnwrap(PDFDocument(data: ReportPDFRenderer(company: ReportCompany(name: "DBS Ltd")).render(report)))
        XCTAssertTrue(try XCTUnwrap(document.page(at: 0)?.string).contains("The CSV export includes all of them"))
    }

    // MARK: - Brand

    func testBrandReadsWhiteLabelValues() {
        let info: [String: String] = ["WSLBrandName": "DBS Ltd", "WSLBrandMark": "BrandMark-DBS",
                                      "WSLBrandCompanyNumber": "03806201", "WSLBrandVATNumber": "GB 743 5371 32",
                                      "WSLBrandLegalName": "David Blakey Services Limited"]
        let brand = Brand.from(info: { info[$0] })
        XCTAssertEqual(brand.name, "DBS Ltd")
        XCTAssertEqual(brand.markImageName, "BrandMark-DBS")
        XCTAssertEqual(brand.company.legalFooter,
                       "David Blakey Services Limited  ·  Company Registration No 03806201  ·  VAT No GB 743 5371 32")
    }

    func testBrandFallsBackToHouseBrandForEmptyOrUnexpandedValues() {
        let info: [String: String] = ["WSLBrandName": "$(BRAND_NAME)", "WSLBrandMark": "  "]
        let brand = Brand.from(info: { info[$0] })
        XCTAssertEqual(brand.name, "WSLCRM")
        XCTAssertNil(brand.markImageName)
        XCTAssertEqual(brand.company.legalFooter, "")
    }
}
