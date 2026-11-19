import XCTest
@testable import PhotosBackupCore

final class DateFilterTests: XCTestCase {
    private let ny = TimeZone(identifier: "America/New_York")!

    func testInclusiveBoundsAndUnfilteredSelection() throws {
        let filter = try DateFilter(from: "2024-05-10", to: "2024-05-11", timeZone: ny)
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(timeZone: ny, year: 2024, month: 5, day: 10))!
        XCTAssertTrue(filter.includes(start))
        XCTAssertTrue(filter.includes(start.addingTimeInterval(60 * 60 * 36)))
        XCTAssertFalse(filter.includes(start.addingTimeInterval(-1)))
        XCTAssertFalse(filter.includes(start.addingTimeInterval(60 * 60 * 48)))
        XCTAssertFalse(filter.includes(nil))
        XCTAssertTrue(try DateFilter(from: nil, to: nil, timeZone: ny).includes(nil))
    }

    func testSingleSidedBoundsAndDSTDay() throws {
        let fromOnly = try DateFilter(from: "2024-03-10", to: nil, timeZone: ny)
        let from = fromOnly.from!
        XCTAssertFalse(fromOnly.includes(from.addingTimeInterval(-1)))
        XCTAssertTrue(fromOnly.includes(from.addingTimeInterval(60 * 60 * 23)))
        let toOnly = try DateFilter(from: nil, to: "2024-03-10", timeZone: ny)
        XCTAssertTrue(toOnly.includes(from.addingTimeInterval(60 * 60 * 22)))
        XCTAssertFalse(toOnly.includes(from.addingTimeInterval(60 * 60 * 24)))
        XCTAssertEqual(toOnly.untilExclusive!.timeIntervalSince(from), 23 * 60 * 60, accuracy: 1)
    }

    func testRejectsInvalidAndReversedDates() {
        XCTAssertThrowsError(try DateFilter(from: "2024-02-30", to: nil, timeZone: ny))
        XCTAssertThrowsError(try DateFilter(from: "2024-05-12", to: "2024-05-11", timeZone: ny))
        XCTAssertThrowsError(try DateFilter(from: "24-05-10", to: nil, timeZone: ny))
    }

    func testCivilDaysWithMidnightDSTTransitionsUseRealDayIntervals() throws {
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        for day in ["2018-11-04", "2017-10-15"] {
            let from = try DateFilter(from: day, to: nil, timeZone: saoPaulo)
            let to = try DateFilter(from: nil, to: day, timeZone: saoPaulo)
            let start = try XCTUnwrap(from.from)
            let end = try XCTUnwrap(to.untilExclusive)
            XCTAssertTrue(from.includes(start))
            XCTAssertFalse(from.includes(start.addingTimeInterval(-1)))
            XCTAssertTrue(to.includes(end.addingTimeInterval(-1)))
            XCTAssertFalse(to.includes(end))

            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = saoPaulo
            let next = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
            XCTAssertEqual(next.hour, 0, "the next civil day must begin at local midnight")
            XCTAssertEqual(next.minute, 0)
        }
    }

    func testRejectsCivilDaySkippedEntirelyByTimeZoneChange() {
        let samoa = TimeZone(identifier: "Pacific/Apia")!
        XCTAssertThrowsError(try DateFilter(from: "2011-12-30", to: nil, timeZone: samoa))
    }
}
