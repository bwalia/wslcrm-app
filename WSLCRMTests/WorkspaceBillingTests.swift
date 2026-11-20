import XCTest
@testable import WSLCRM

/// Billing (selling the workspace's own apps): the menu keys open native screens, the server's
/// `{success, data, meta}` shapes parse, and the forms send what OpsAPI expects (pence, the fields a
/// kind of sale needs, only changed settings, JSON nulls for "unlimited").
@MainActor
final class WorkspaceBillingTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try ResourceService.decode(Data(text.utf8))
    }

    private func object(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let fields) = value { return fields }
        XCTFail("not an object: \(value)")
        return [:]
    }

    // MARK: Menu

    func testMenuKeysOpenTheBillingScreens() {
        XCTAssertEqual(NativeModules.destination(forKey: "billing"), .native(NativeScreenRoute(WorkspaceScreen.billing)))
        XCTAssertEqual(NativeModules.destination(forKey: "billing_subscriptions"),
                       .native(NativeScreenRoute(WorkspaceScreen.subscriptions)))
        XCTAssertEqual(NativeModules.destination(forKey: "billing_licenses"),
                       .native(NativeScreenRoute(WorkspaceScreen.licences)))
        for id in [WorkspaceScreen.billing, WorkspaceScreen.subscriptions, WorkspaceScreen.licences] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertFalse(NativeModules.notYetNative.contains("billing"))
        XCTAssertFalse(NativeModules.notYetNative.contains("billing_subscriptions"))
        XCTAssertFalse(NativeModules.notYetNative.contains("billing_licenses"))
    }

    // MARK: Apps and features

    /// `GET /api/v2/billing/apps/:app` (BillingAppQueries: effective settings + features).
    func testAnAppWithItsSettingsAndFeatures() throws {
        let record = try XCTUnwrap(WorkspaceAPI.record(try json("""
        {"success":true,"data":{"uuid":"app-1","name":"Desk Pro","slug":"desk-pro","kind":"desktop","mode":"live",
         "publishable_key":"pk_live_abc","active":true,"created_by":"u1","created_at":"2026-09-01 10:00:00+00",
         "settings":{"offline_policy":"fail_open","grace_days":7,"fingerprint_salt":"s4lt","allowed_origins":[]},
         "features":[{"uuid":"f2","key":"seats","name":"Seats","type":"limit","unit":"seats","sort_order":2,"released_at":null},
                     {"uuid":"f1","key":"pdf_export","name":"Export to PDF","description":"Save as PDF","type":"boolean",
                      "unit":null,"sort_order":1,"released_at":"2026-10-01 00:00:00+00"}]}}
        """), idKeys: ["uuid"]))
        let app = BillingAppInfo(record)
        XCTAssertEqual(app.uuid, "app-1")
        XCTAssertEqual(app.kindLabel, "Desktop app")
        XCTAssertTrue(app.isLive)
        XCTAssertTrue(app.usesLicences)
        XCTAssertEqual(app.offlineLine, "Offline: keeps last known access")
        XCTAssertEqual(app.features.map(\.key), ["pdf_export", "seats"], "in sort order")
        XCTAssertEqual(app.features[1].typeLabel, "Limit (seats)")
        XCTAssertEqual(app.features[0].typeLabel, "On / off")
    }

    func testFeatureValuesAndHowTheyRead() throws {
        let seats = BillingFeatureInfo(Record(["key": .string("seats"), "name": .string("Seats"), "type": .string("limit"),
                                               "unit": .string("seats")]))
        let pdf = BillingFeatureInfo(Record(["key": .string("pdf"), "name": .string("PDF"), "type": .string("boolean")]))
        XCTAssertEqual(BillingFeatureValue(.bool(true)), .included(true))
        XCTAssertEqual(BillingFeatureValue(.number(5)), .limit(5))
        XCTAssertEqual(BillingFeatureValue(.null), .unlimited, "null means unlimited")
        XCTAssertNil(BillingFeatureValue(nil), "missing means not set")
        XCTAssertEqual(BillingFeatureValue.describe(seats, .limit(5)), "5 seats")
        XCTAssertEqual(BillingFeatureValue.describe(seats, .unlimited), "Unlimited")
        XCTAssertEqual(BillingFeatureValue.describe(seats, .limit(0)), "—")
        XCTAssertEqual(BillingFeatureValue.describe(pdf, .included(true)), "Included")
        XCTAssertEqual(BillingFeatureValue.describe(pdf, nil), "—")
    }

    // MARK: Plans

    /// `GET /api/v2/billing/plans?app=&include_inactive=true` rows (SELECT *, maps may arrive as []).
    func testPlansParseAndDescribeTheirPrice() throws {
        let rows = WorkspaceAPI.records(try json("""
        {"success":true,"data":[
         {"id":4,"uuid":"p1","name":"Pro","plan_key":"pro","purchase_type":"recurring","plan_type":"subscription",
          "amount":"999","currency":"gbp","billing_interval":"month","interval_count":1,"trial_days":14,
          "features":{"seats":5,"pdf_export":true,"storage":null},"store_products":[],"is_default":false,"is_public":true,
          "active":true,"sort_order":0},
         {"uuid":"p2","name":"Pass","plan_key":"pass","purchase_type":"fixed_term","amount":900,"currency":"gbp",
          "term_days":30,"term_covers":"updates","features":[],"is_default":false,"is_public":false,"active":true},
         {"uuid":"p3","name":"Lifetime","plan_key":"life","purchase_type":"one_time","amount":4900,"currency":"usd",
          "updates_days":365,"features":{},"store_products":{"app_store":"com.x.life"},"is_default":true,"is_public":true,"active":false},
         {"uuid":"p4","name":"Free","plan_key":"free","purchase_type":"recurring","amount":0,"currency":"gbp","trial_days":0}
        ]}
        """), idKeys: ["uuid"]).map(BillingPlanInfo.init)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].amount, 999, "a NUMERIC sent as text still reads")
        XCTAssertEqual(rows[0].features["seats"], .limit(5))
        XCTAssertEqual(rows[0].features["storage"], .unlimited)
        XCTAssertTrue(rows[0].priceText.hasSuffix(" / month"))
        XCTAssertEqual(rows[0].typeLine, "Subscription · 14-day trial")
        XCTAssertTrue(rows[1].priceText.hasSuffix("for 30 days of updates"))
        XCTAssertEqual(rows[1].statusText, "Hidden")
        XCTAssertTrue(rows[2].priceText.hasSuffix(" once"))
        XCTAssertEqual(rows[2].typeLine, "One-time (lifetime) · 365 days of updates")
        XCTAssertEqual(rows[2].storeProducts["app_store"], "com.x.life")
        XCTAssertEqual(rows[2].statusText, "Inactive")
        XCTAssertEqual(rows[3].priceText, "Free")
    }

    func testPlanDraftSendsPenceAndOnlyTheFieldsForItsKindOfSale() throws {
        let seats = BillingFeatureInfo(Record(["key": .string("seats"), "name": .string("Seats"), "type": .string("limit")]))
        let pdf = BillingFeatureInfo(Record(["key": .string("pdf"), "name": .string("PDF"), "type": .string("boolean")]))
        var draft = BillingPlanDraft(plan: nil, features: [seats, pdf])
        XCTAssertEqual(draft.features, ["seats": .limit(0), "pdf": .included(false)], "every feature gets a value")
        draft.name = "  Pro "
        draft.price = "12.50"
        draft.trialDays = "7"
        var body = object(draft.body(app: "app-1"))
        XCTAssertEqual(body["amount"], .number(1250), "pounds typed, pence sent")
        XCTAssertEqual(body["name"], .string("Pro"))
        XCTAssertEqual(body["app"], .string("app-1"))
        XCTAssertEqual(body["billing_interval"], .string("month"))
        XCTAssertEqual(body["trial_days"], .number(7))
        XCTAssertNil(body["term_days"])
        XCTAssertNil(body["updates_days"])
        XCTAssertNil(body["plan_key"], "blank: the server makes one from the name")
        XCTAssertEqual(body["store_products"], .object([:]))
        XCTAssertEqual(body["features"], .object(["seats": .number(0), "pdf": .bool(false)]))
        XCTAssertEqual(body["is_public"], .bool(true))

        draft.purchaseType = "fixed_term"
        draft.termDays = "0"
        draft.termCovers = "updates"
        XCTAssertNotNil(draft.problem(), "a term needs at least a day")
        body = object(draft.body(app: nil))
        XCTAssertNil(body["app"], "an edit never moves a plan to another app")
        XCTAssertEqual(body["term_days"], .number(1))
        XCTAssertEqual(body["term_covers"], .string("updates"))
        XCTAssertNil(body["billing_interval"])

        draft.purchaseType = "one_time"
        draft.updatesDays = ""
        draft.features["seats"] = .unlimited
        draft.playStoreID = "pro_life"
        body = object(draft.body(app: nil))
        XCTAssertEqual(body["updates_days"], .null, "blank: every future version")
        XCTAssertEqual(body["store_products"], .object(["play_store": .string("pro_life")]))
        XCTAssertEqual(object(body["features"] ?? .null)["seats"], .null, "unlimited is null")

        draft.planKey = "Pro Plan"
        XCTAssertNotNil(draft.problem())
        draft.planKey = "pro-plan"
        draft.price = "-1"
        XCTAssertNotNil(draft.problem())
    }

    func testEditingAPlanKeepsItsValues() throws {
        let plan = BillingPlanInfo(Record([
            "uuid": .string("p1"), "name": .string("Pro"), "plan_key": .string("pro"), "purchase_type": .string("recurring"),
            "amount": .number(1999), "currency": .string("eur"), "billing_interval": .string("year"),
            "trial_days": .number(0), "features": .object(["seats": .number(3)]),
            "store_products": .object(["app_store": .string("com.x.pro")]), "is_default": .bool(true),
            "is_public": .bool(false), "active": .bool(true),
        ]))
        let seats = BillingFeatureInfo(Record(["key": .string("seats"), "name": .string("Seats"), "type": .string("limit")]))
        let draft = BillingPlanDraft(plan: plan, features: [seats])
        XCTAssertEqual(draft.price, "19.99")
        XCTAssertEqual(draft.currency, "eur")
        XCTAssertEqual(draft.interval, "year")
        XCTAssertEqual(draft.features["seats"], .limit(3))
        XCTAssertEqual(draft.appStoreID, "com.x.pro")
        XCTAssertTrue(draft.isDefault)
        XCTAssertFalse(draft.isPublic)
    }

    // MARK: Coupons

    /// `GET /api/v2/billing/coupons` rows (BillingOfferQueries).
    func testCouponsParseAndRead() throws {
        let page = WorkspaceAPI.page(try json("""
        {"success":true,"data":[
         {"uuid":"c1","code":"LAUNCH25","name":"Launch","discount_type":"percent","percent_off":25,"amount_off":null,
          "currency":null,"duration":"repeating","duration_months":3,"plans":["p1","p2"],"max_redemptions":100,
          "per_customer_limit":1,"redemptions_count":4,"starts_at":null,"expires_at":"2026-12-31 23:59:59+00",
          "active":true,"app_uuid":"app-1","app_name":"Desk Pro"},
         {"uuid":"c2","code":"TENOFF","discount_type":"amount","amount_off":1000,"currency":"gbp","duration":"forever",
          "redemptions_count":0,"active":false}
        ],"meta":{"total":2,"page":1,"per_page":20,"total_pages":1}}
        """), page: 1, perPage: 20, idKeys: ["uuid"])
        XCTAssertEqual(page.items.map(\.id), ["c1", "c2"])
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(BillingCouponText.discount(page.items[0]), "25% off, for 3 months")
        XCTAssertEqual(BillingCouponText.used(page.items[0]), "Used 4 of 100")
        XCTAssertEqual(BillingCouponText.appliesTo(page.items[0]), "Desk Pro · 2 plans")
        XCTAssertTrue(BillingCouponText.discount(page.items[1]).hasSuffix("off, every payment"))
        XCTAssertEqual(BillingCouponText.appliesTo(page.items[1]), "Every app")
        XCTAssertTrue(BillingCouponText.valid(page.items[0]).hasPrefix("Now – "))
    }

    func testANewCouponSendsItsCodeDiscountAndLimits() throws {
        var draft = BillingCouponDraft()
        draft.code = "launch25"
        draft.app = "app-1"
        draft.plans = ["p1"]
        draft.discountType = "amount"
        draft.value = "10"
        draft.duration = "repeating"
        draft.months = "6"
        draft.maxUses = ""
        draft.perCustomer = "1"
        draft.starts = CalendarDay(year: 2026, month: 12, day: 1).date()
        XCTAssertNil(draft.problem(isNew: true, used: false))
        let body = object(draft.body(isNew: true, used: false))
        XCTAssertEqual(body["code"], .string("LAUNCH25"))
        XCTAssertEqual(body["app"], .string("app-1"))
        XCTAssertEqual(body["plans"], .array([.string("p1")]))
        XCTAssertEqual(body["amount_off"], .number(1000), "pence")
        XCTAssertEqual(body["currency"], .string("gbp"))
        XCTAssertNil(body["percent_off"])
        XCTAssertEqual(body["duration_months"], .number(6))
        XCTAssertEqual(body["max_redemptions"], .null, "blank: no limit")
        XCTAssertEqual(body["per_customer_limit"], .number(1))
        XCTAssertEqual(body["starts_at"], .string("2026-12-01T00:00:00Z"))
        XCTAssertEqual(body["expires_at"], .null)

        draft.discountType = "percent"
        draft.value = "120"
        XCTAssertNotNil(draft.problem(isNew: true, used: false), "more than 100%")
        draft.code = "x"
        draft.value = "20"
        XCTAssertNotNil(draft.problem(isNew: true, used: false), "a code needs 2 characters")
    }

    func testAUsedCouponNeverSendsItsDiscountAndAnEditNeverSendsItsCode() throws {
        let coupon = Record(["uuid": .string("c1"), "code": .string("LAUNCH25"), "discount_type": .string("percent"),
                             "percent_off": .number(25), "duration": .string("once"), "redemptions_count": .number(3),
                             "active": .bool(true), "per_customer_limit": .null])
        var draft = BillingCouponDraft(coupon: coupon)
        XCTAssertEqual(draft.value, "25")
        XCTAssertEqual(draft.perCustomer, "", "null limit reads as no limit")
        draft.active = false
        let body = object(draft.body(isNew: false, used: true))
        XCTAssertNil(body["discount_type"])
        XCTAssertNil(body["percent_off"])
        XCTAssertNil(body["duration"])
        XCTAssertNil(body["code"])
        XCTAssertNil(body["app"])
        XCTAssertEqual(body["active"], .bool(false))
    }

    // MARK: Settings

    /// `GET /api/v2/billing/settings-schema?kind=` specs.
    func testSettingsSchemaParsesAndOnlyChangesAreSent() throws {
        let specs = WorkspaceAPI.records(try json("""
        {"success":true,"data":[
         {"key":"offline_policy","group":"offline","type":"enum","label":"When offline","values":["fail_closed","fail_open"],"default":"fail_closed"},
         {"key":"max_activations","group":"licences","type":"integer","label":"Devices","min":1,"nullable":true,"default":null},
         {"key":"fingerprint_salt","group":"licences","type":"string","label":"Salt","readonly":true,"default":""},
         {"key":"allowed_origins","group":"public","type":"origins","label":"Allowed origins","default":[]},
         {"key":"lockout","group":"public","type":"object","label":"Lockout","default":{},
          "fields":[{"key":"failures","min":1,"max":100,"default":10},{"key":"window_minutes","min":1,"max":1440,"default":15}]}
        ]}
        """), idKeys: ["key"]).map(BillingSettingSpec.init)
        XCTAssertEqual(specs.count, 5)
        XCTAssertEqual(specs[0].values, ["fail_closed", "fail_open"])
        XCTAssertTrue(specs[1].nullable)
        XCTAssertTrue(specs[2].readonly)
        XCTAssertEqual(specs[4].fields.map(\.key), ["failures", "window_minutes"])
        XCTAssertEqual(specs[4].fields[0].defaultValue, 10)

        let original: [String: JSONValue] = [
            "offline_policy": .string("fail_closed"), "max_activations": .number(3), "fingerprint_salt": .string("s"),
            "allowed_origins": .object([:]),  // lua-cjson's empty list
        ]
        var edited = original
        edited["allowed_origins"] = .array([])
        edited["fingerprint_salt"] = .string("changed")
        XCTAssertTrue(BillingSettings.changed(specs, original: original, edited: edited).isEmpty,
                      "{} and [] are the same; read-only settings never count")
        edited["max_activations"] = .null
        edited["offline_policy"] = .string("fail_open")
        edited["lockout"] = .object(["failures": .number(5), "window_minutes": .number(15)])
        let changed = BillingSettings.changed(specs, original: original, edited: edited)
        XCTAssertEqual(Set(changed.keys), ["max_activations", "offline_policy", "lockout"])
        XCTAssertEqual(changed["max_activations"], .null, "null = unlimited")
    }

    // MARK: Subscriptions, purchases, grants, licences

    /// `GET /api/v2/subscriptions/purchases` rows.
    func testPurchasesReadAndOnlyCardPaymentsCanBeRefunded() throws {
        let rows = WorkspaceAPI.records(try json("""
        {"success":true,"data":[
         {"uuid":"pu1","purchase_type":"one_time","source":"stripe","status":"active","access_until":null,
          "updates_until":"2027-01-01 00:00:00+00","amount":4900,"currency":"gbp","refunded_amount":0,
          "app_name":"Desk Pro","plan_name":"Lifetime","customer_email":"a@example.com","coupon_code":"LAUNCH25"},
         {"uuid":"pu2","purchase_type":"fixed_term","source":"manual","status":"active","amount":900,"currency":"gbp",
          "refunded_amount":0},
         {"uuid":"pu3","purchase_type":"one_time","source":"stripe","status":"active","amount":900,"currency":"gbp",
          "refunded_amount":900}
        ],"meta":{"total":3,"page":1,"per_page":20,"total_pages":1}}
        """), idKeys: ["uuid"])
        XCTAssertTrue(BillingPurchaseText.canRefund(rows[0]))
        XCTAssertFalse(BillingPurchaseText.canRefund(rows[1]), "recorded by hand: nothing to refund by card")
        XCTAssertFalse(BillingPurchaseText.canRefund(rows[2]), "already refunded in full")
        XCTAssertTrue(BillingPurchaseText.access(rows[0]).hasPrefix("Perpetual · updates to "))
        XCTAssertEqual(BillingSource.label("manual"), "Recorded by hand")
    }

    func testGrantsShowWhatTheyAdd() {
        let grant = Record(["uuid": .string("g1"), "features": .object(["seats": .number(10), "pdf": .bool(true),
                                                                          "storage": .null]),
                            "revoked_at": .null, "expires_at": .null])
        XCTAssertEqual(BillingGrantText.features(grant), "pdf: on, seats: 10, storage: unlimited")
        XCTAssertEqual(BillingGrantText.until(grant), "Until revoked")
        let empty = Record(["uuid": .string("g2"), "features": .array([]), "revoked_at": .string("2026-11-01 00:00:00+00")])
        XCTAssertEqual(BillingGrantText.features(empty), "", "an empty map may arrive as []")
        XCTAssertEqual(BillingGrantText.until(empty), "Revoked by hand")
    }

    /// `GET /api/v2/licenses` rows and the limits body for `PUT /api/v2/licenses/:uuid`.
    func testLicencesReadAndLimitsSendNullForUnlimited() throws {
        let row = try XCTUnwrap(WorkspaceAPI.records(try json("""
        {"success":true,"data":[{"uuid":"l1","key_prefix":"ABCD1234","status":"active","max_activations":null,
          "access_until":null,"app_name":"Desk Pro","plan_name":null,"customer_email":"a@example.com","active_activations":2}],
         "meta":{"total":1,"page":1,"per_page":20,"total_pages":1}}
        """), idKeys: ["uuid"]).first)
        XCTAssertEqual(BillingLicenceText.key(row), "ABCD1234-•••••")
        XCTAssertEqual(BillingLicenceText.devices(row), "2 of unlimited devices")
        XCTAssertEqual(BillingLicenceText.access(row), "Perpetual")
        XCTAssertEqual(BillingLicenceText.appPlan(row), "Desk Pro · customer’s plan")

        let unlimited = try XCTUnwrap(BillingLicenceLimits.body(devices: " ", accessUntil: nil, updatesUntil: nil))
        XCTAssertEqual(unlimited["max_activations"], .null)
        XCTAssertEqual(unlimited["access_until"], .null)
        let limited = try XCTUnwrap(BillingLicenceLimits.body(devices: "3", accessUntil: CalendarDay(year: 2027, month: 1, day: 31).date(),
                                                              updatesUntil: nil))
        XCTAssertEqual(limited["max_activations"], .number(3))
        XCTAssertEqual(limited["access_until"], .string("2027-01-31T23:59:59Z"))
        XCTAssertNil(BillingLicenceLimits.body(devices: "0", accessUntil: nil, updatesUntil: nil), "at least one device")
    }

    // MARK: Money and errors

    func testMoneyIsPenceOnTheWire() {
        XCTAssertEqual(BillingMoney.pence("12.50"), 1250)
        XCTAssertEqual(BillingMoney.pence("£1,000"), 100_000)
        XCTAssertEqual(BillingMoney.pence("0"), 0)
        XCTAssertNil(BillingMoney.pence("-3"))
        XCTAssertNil(BillingMoney.pence("ten"))
        XCTAssertEqual(BillingMoney.pounds(999), "9.99")
    }

    func testCouponErrorsAreSaidPlainly() {
        let server = ServerError.parse(status: 422, data: Data(#"{"success":false,"code":"coupon_expired","error":"coupon expired"}"#.utf8))
        let plain = BillingErrors.plain(.validation(server))
        XCTAssertEqual(plain.serverError?.message, "That coupon has expired.")
        let other = ServerError.parse(status: 422, data: Data(#"{"success":false,"error":"amount must be a whole number"}"#.utf8))
        XCTAssertEqual(BillingErrors.plain(.validation(other)).serverError?.message, "amount must be a whole number")
    }
}
