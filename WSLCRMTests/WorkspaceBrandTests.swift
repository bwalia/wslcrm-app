import UIKit
import XCTest
@testable import WSLCRM

/// One build for every business: the logo and letterhead come from the workspace and stay on the phone.
@MainActor
final class WorkspaceBrandTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let house = Brand(name: "Workstation AI-native CRM", markImageName: "BrandMark-WSLCRM",
                              company: ReportCompany(name: "Workstation AI-native CRM"))
    private let dbs = "dbs-0000"
    private let logo = URL(string: "https://int-opsapi-ui.workstation.co.uk/brands/dbs-ltd.png")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = UserDefaults(suiteName: "WorkspaceBrandTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        Brand.setCurrent(.house)
        super.tearDown()
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
    }

    private func store(fetch: @escaping @Sendable (URL) async throws -> Data) -> BrandStore {
        BrandStore(defaults: defaults, directory: directory, house: house, fetchLogo: fetch)
    }

    private var company: WorkspaceBrand.Company {
        WorkspaceBrand.Company(displayName: "DBS Ltd", legalName: "David Blakey Services Limited",
                               companyNumber: "03806201", vatNumber: "GB 743 5371 32", address: "Watford",
                               phone: nil, email: nil, strapline: nil)
    }

    func testEveryoneStartsOnTheHouseBrand() {
        let store = store { _ in XCTFail("nothing to fetch"); return Data() }
        XCTAssertEqual(store.brand, house)
        XCTAssertNil(store.brand.logoFile)
    }

    func testAWorkspaceWithALogoShowsItsOwnBrand() async {
        let data = png()
        let store = store { _ in data }
        await store.update(workspaceUuid: dbs, name: "DBS Group", logoURL: logo, company: company)
        XCTAssertEqual(store.brand.name, "DBS Ltd", "the letterhead's display name wins over the workspace name")
        XCTAssertNotNil(store.brand.logoFile.flatMap { UIImage(contentsOfFile: $0.path) })
        XCTAssertEqual(store.brand.company.legalName, "David Blakey Services Limited")
        XCTAssertEqual(Brand.current, store.brand, "non-view code (PDFs, prompts) sees the same brand")
    }

    func testTheBrandSurvivesARelaunchAndAnUpdate() async {
        let data = png()
        await store { _ in data }.update(workspaceUuid: dbs, name: "DBS Group", logoURL: logo, company: company)
        // A new process (app update, relaunch, signed out): nothing is fetched, DBS is still shown.
        let relaunched = store { _ in XCTFail("no download on launch"); return Data() }
        XCTAssertEqual(relaunched.brand.name, "DBS Ltd")
        XCTAssertNotNil(relaunched.brand.logoFile)
    }

    func testAWorkspaceWithoutALogoIsWorkstation() async {
        let data = png()
        let store = store { _ in data }
        await store.update(workspaceUuid: dbs, name: "DBS Group", logoURL: logo, company: company)
        await store.update(workspaceUuid: "ws-1", name: "Workstation", logoURL: nil, company: nil)
        XCTAssertEqual(store.brand, house)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], "old logo removed")
    }

    func testOfflineKeepsTheLogoAlreadyOnThePhone() async {
        let data = png()
        await store { _ in data }.update(workspaceUuid: dbs, name: "DBS Group", logoURL: logo, company: company)
        let offline = store { _ in throw URLError(.notConnectedToInternet) }
        let changed = URL(string: "https://int-opsapi-ui.workstation.co.uk/brands/dbs-2.png")!
        await offline.update(workspaceUuid: dbs, name: "DBS Group", logoURL: changed, company: company)
        XCTAssertNotNil(offline.brand.logoFile)
        XCTAssertEqual(offline.brand.name, "DBS Ltd")
    }

    func testALogoThatCannotBeShownFallsBackToWorkstation() async {
        let store = store { _ in Data("not an image".utf8) }
        await store.update(workspaceUuid: dbs, name: "DBS Group", logoURL: logo, company: company)
        XCTAssertEqual(store.brand, house)
    }

    func testLogoURLsResolveAgainstTheDashboard() {
        let dashboard = URL(string: "https://int-opsapi-ui.workstation.co.uk")!
        XCTAssertEqual(WorkspaceBrand.logoURL("/brands/dbs-ltd.svg", dashboard: dashboard)?.absoluteString,
                       "https://int-opsapi-ui.workstation.co.uk/brands/dbs-ltd.svg")
        XCTAssertEqual(WorkspaceBrand.logoURL("https://cdn.example.com/a.png", dashboard: nil)?.absoluteString,
                       "https://cdn.example.com/a.png")
        XCTAssertNil(WorkspaceBrand.logoURL("/brands/x.svg", dashboard: nil))
        XCTAssertNil(WorkspaceBrand.logoURL("  ", dashboard: dashboard))
        XCTAssertNil(WorkspaceBrand.logoURL("javascript:alert(1)", dashboard: dashboard))
    }

    func testTheNamespaceListCarriesTheLetterhead() throws {
        let json = """
        {"data":[{"uuid":"dbs-0000","name":"DBS Group","logo_url":"/brands/dbs-ltd.svg",
          "settings":{"company":{"display_name":"DBS Ltd","legal_name":"David Blakey Services Limited",
            "company_number":"03806201","financials":{"years":[]}},"theme":"x"}},
         {"uuid":"ws-1","name":"Workstation","logo_url":null,"settings":"{}"}],"total":2}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct List: Decodable { let data: [WorkspaceBrandDetails] }
        let list = try decoder.decode(List.self, from: Data(json.utf8))
        XCTAssertEqual(list.data.count, 2)
        XCTAssertEqual(list.data[0].logoUrl, "/brands/dbs-ltd.svg")
        XCTAssertEqual(list.data[0].company?.displayName, "DBS Ltd")
        XCTAssertEqual(list.data[0].company?.companyNumber, "03806201")
        XCTAssertNil(list.data[1].company)
    }

    func testSVGLogosAreRecognised() {
        XCTAssertTrue(BrandStore.looksLikeSVG(Data(), url: URL(string: "https://x/brands/a.svg")!))
        XCTAssertTrue(BrandStore.looksLikeSVG(Data("<?xml version=\"1.0\"?><svg></svg>".utf8), url: URL(string: "https://x/logo")!))
        XCTAssertFalse(BrandStore.looksLikeSVG(Data("<html>".utf8), url: URL(string: "https://x/logo")!))
    }

    func testAnSVGLogoIsDrawnIntoABitmap() async throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96"><rect x="0" y="0" width="96" height="96" fill="#0b2545"/></svg>
        """
        let rendered = await SVGRasterizer.render(Data(svg.utf8), side: 60, timeout: .seconds(60))
        let image = try XCTUnwrap(rendered)
        XCTAssertGreaterThan(image.size.width, 0)
        // The middle pixel is the navy fill, not transparent: WebKit really drew it.
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
        XCTAssertGreaterThan(pixel[3], 200, "opaque")
        XCTAssertLessThan(pixel[0], 40, "navy, not white")
    }
}
