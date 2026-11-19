import Foundation

public struct DateFilter: Equatable {
    public let from: Date?
    public let untilExclusive: Date?
    public let timeZone: TimeZone

    public init(from: String?, to: String?, timeZone: TimeZone = .current) throws {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        struct CivilDay {
            let parts: (Int, Int, Int)
            let interval: DateInterval
            let anchor: Date
        }
        func parse(_ value: String?) throws -> CivilDay? {
            guard let value else { return nil }
            guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
                throw BackupError.invalidArgument("date must use a valid YYYY-MM-DD value")
            }
            let pieces = value.split(separator: "-").compactMap { Int($0) }
            guard pieces.count == 3 else { throw BackupError.invalidArgument("date must use a valid YYYY-MM-DD value") }
            let (year, month, day) = (pieces[0], pieces[1], pieces[2])
            // Noon exists on ordinary DST transition days where local midnight does not.
            // Verify the civil components after Calendar resolves the date, which also
            // rejects impossible dates and dates skipped entirely by a time-zone change.
            var components = DateComponents()
            components.calendar = calendar; components.timeZone = timeZone
            components.year = year; components.month = month; components.day = day; components.hour = 12
            guard let anchor = calendar.date(from: components) else {
                throw BackupError.invalidArgument("date must use a valid YYYY-MM-DD value")
            }
            let roundTrip = calendar.dateComponents([.year, .month, .day], from: anchor)
            guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
                  let interval = calendar.dateInterval(of: .day, for: anchor) else {
                throw BackupError.invalidArgument("date must use a valid YYYY-MM-DD value")
            }
            return CivilDay(parts: (year, month, day), interval: interval, anchor: anchor)
        }
        let start = try parse(from)
        let endDay = try parse(to)
        if let start, let endDay, start.parts > endDay.parts { throw BackupError.invalidArgument("--from must be on or before --to") }
        self.from = start?.interval.start
        if let endDay {
            guard let nextAnchor = calendar.date(byAdding: .day, value: 1, to: endDay.anchor),
                  let nextInterval = calendar.dateInterval(of: .day, for: nextAnchor) else {
                throw BackupError.invalidArgument("--to is outside the supported calendar")
            }
            untilExclusive = nextInterval.start
        } else { untilExclusive = nil }
    }

    public var includesUnfiltered: Bool { from == nil && untilExclusive == nil }

    public func includes(_ date: Date?) -> Bool {
        guard let date else { return includesUnfiltered }
        if let from, date < from { return false }
        if let untilExclusive, date >= untilExclusive { return false }
        return true
    }
}
