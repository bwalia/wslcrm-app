import XCTest
@testable import WSLCRM

final class APIDateTests: XCTestCase {
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, ms: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
        return base.addingTimeInterval(Double(ms) / 1000)
    }

    func testNaiveTimestampIsTreatedAsUTC() {
        XCTAssertEqual(APIDate.parse("2026-09-12 08:00:00"), utc(2026, 9, 12, 8, 0, 0))
    }

    func testMicrosecondsAreTruncatedToMilliseconds() {
        XCTAssertEqual(APIDate.normalize("2026-09-12 08:00:44.861944"), "2026-09-12T08:00:44.861Z")
        let parsed = APIDate.parse("2026-09-12 08:00:44.861944")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, utc(2026, 9, 12, 8, 0, 44, ms: 861).timeIntervalSince1970, accuracy: 0.0005)
    }

    func testShortFractionIsPadded() {
        XCTAssertEqual(APIDate.normalize("2026-09-12 08:00:44.5"), "2026-09-12T08:00:44.500Z")
    }

    func testISOWithZuluIsAccepted() {
        XCTAssertEqual(APIDate.parse("2026-09-12T08:00:00Z"), utc(2026, 9, 12, 8, 0, 0))
    }

    func testISOWithOffsetIsHonoured() {
        XCTAssertEqual(APIDate.parse("2026-09-12T09:00:00+01:00"), utc(2026, 9, 12, 8, 0, 0))
        XCTAssertEqual(APIDate.parse("2026-09-12 09:00:00+0100"), utc(2026, 9, 12, 8, 0, 0))
        XCTAssertEqual(APIDate.parse("2026-09-12 09:00:00+01"), utc(2026, 9, 12, 8, 0, 0))
    }

    func testDateOnlyIsMidnightUTC() {
        XCTAssertEqual(APIDate.parse("2026-09-12"), utc(2026, 9, 12, 0, 0, 0))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(APIDate.parse(""))
        XCTAssertNil(APIDate.parse("not a date"))
        XCTAssertNil(APIDate.parse("2026-09-12 8:00"))
    }

    func testOutputIsISO8601UTC() {
        XCTAssertEqual(APIDate.string(from: utc(2026, 9, 12, 8, 0, 44, ms: 861)), "2026-09-12T08:00:44Z")
    }

    func testDecoderStrategyDecodesNaiveAndISO() throws {
        struct Model: Decodable { let a: Date; let b: Date; let c: Date? }
        let json = #"{"a":"2026-09-12 08:00:00","b":"2026-09-12 08:00:00.123456","c":null}"#
        let model = try JSONDecoder.opsAPI().decode(Model.self, from: Data(json.utf8))
        XCTAssertEqual(model.a, utc(2026, 9, 12, 8, 0, 0))
        XCTAssertEqual(model.b.timeIntervalSince1970, utc(2026, 9, 12, 8, 0, 0, ms: 123).timeIntervalSince1970, accuracy: 0.0005)
        XCTAssertNil(model.c)
    }

    func testDecoderStrategyRejectsInvalidDate() {
        struct Model: Decodable { let a: Date }
        XCTAssertThrowsError(try JSONDecoder.opsAPI().decode(Model.self, from: Data(#"{"a":"yesterday"}"#.utf8)))
    }

    func testEncoderSendsISO8601UTC() throws {
        struct Body: Encodable { let scheduledStart: Date }
        let data = try JSONEncoder.opsAPI().encode(Body(scheduledStart: utc(2026, 9, 12, 8, 30, 0)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"scheduled_start":"2026-09-12T08:30:00Z"}"#)
    }

    func testCalendarDayDoesNotShiftAcrossZones() throws {
        let day = try JSONDecoder.opsAPI().decode(CalendarDay.self, from: Data(#""2026-09-30""#.utf8))
        XCTAssertEqual(day, CalendarDay(year: 2026, month: 9, day: 30))
        XCTAssertEqual(day.isoString, "2026-09-30")
        XCTAssertEqual(CalendarDay(string: "2026-09-30 00:00:00"), day)
    }
}
