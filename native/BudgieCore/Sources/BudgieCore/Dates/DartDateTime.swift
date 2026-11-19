import Foundation

/// A port of Dart's `DateTime` as the Dart VM implements it
/// (sdk/lib/_internal/vm_shared/lib/date_patch.dart, sdk/lib/core/date_time.dart).
///
/// The Flutter app stores every date as a local wall-clock string without an
/// offset and computes with local `DateTime`s. Matching its numbers requires
/// the same instant arithmetic (microseconds since epoch), the same
/// local-time resolution for skipped and repeated DST hours, the same
/// lenient constructor normalisation (month 13, day 0, day 31 of February),
/// and the same formatting. Swift's `Date` holds a `Double` and loses
/// microseconds at current epochs, so it is not used for stored values.
///
/// Every local conversion takes an explicit `TimeZone`; nothing reads
/// `TimeZone.current` implicitly, so tests can pin zones.
public struct DartDateTime: Hashable, Sendable, Comparable {
    public let microsecondsSinceEpoch: Int64
    public let isUtc: Bool
    /// Zone used for this value's local fields (ignored when `isUtc`).
    public let timeZone: TimeZone

    // MARK: Constants (Dart)

    static let microsecondsPerMillisecond: Int64 = 1_000
    static let microsecondsPerSecond: Int64 = 1_000_000
    static let microsecondsPerMinute: Int64 = 60_000_000
    static let microsecondsPerHour: Int64 = 3_600_000_000
    static let microsecondsPerDay: Int64 = 86_400_000_000
    static let maxMillisecondsSinceEpoch: Int64 = 8_640_000_000_000_000

    // MARK: Construction

    public init(microsecondsSinceEpoch: Int64, isUtc: Bool = false, timeZone: TimeZone) {
        self.microsecondsSinceEpoch = microsecondsSinceEpoch
        self.isUtc = isUtc
        self.timeZone = timeZone
    }

    /// Dart `DateTime(year, month, day, ...)`: local, lenient (fields may
    /// overflow or underflow and are normalised). Returns nil where Dart
    /// throws (out of range).
    public init?(
        _ year: Int, _ month: Int = 1, _ day: Int = 1, _ hour: Int = 0, _ minute: Int = 0,
        _ second: Int = 0, _ millisecond: Int = 0, _ microsecond: Int = 0,
        isUtc: Bool = false, timeZone: TimeZone
    ) {
        guard
            let value = DartDateTime.brokenDownDateToValue(
                year, month, day, hour, minute, second, millisecond, microsecond,
                isUtc: isUtc, timeZone: timeZone)
        else { return nil }
        self.init(microsecondsSinceEpoch: value, isUtc: isUtc, timeZone: timeZone)
    }

    /// Dart `DateTime.now()` for a given clock instant.
    public static func now(_ date: Date = Date(), timeZone: TimeZone) -> DartDateTime {
        // Round to the microsecond the way Dart's clock reports it.
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
        return DartDateTime(microsecondsSinceEpoch: micros, isUtc: false, timeZone: timeZone)
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(microsecondsSinceEpoch) / 1_000_000)
    }

    // MARK: Fields (Dart `_parts`)

    public struct Fields: Hashable, Sendable {
        public var year, month, day, hour, minute, second, millisecond, microsecond, weekday: Int
    }

    public var fields: Fields {
        DartDateTime.computeUpperPart(localDateInUtcMicros)
    }

    public var year: Int { fields.year }
    public var month: Int { fields.month }
    public var day: Int { fields.day }
    public var hour: Int { fields.hour }
    public var minute: Int { fields.minute }
    public var second: Int { fields.second }
    public var millisecond: Int { fields.millisecond }
    public var microsecond: Int { fields.microsecond }
    /// Monday = 1 ... Sunday = 7 (Dart).
    public var weekday: Int { fields.weekday }

    var localDateInUtcMicros: Int64 {
        if isUtc { return microsecondsSinceEpoch }
        return microsecondsSinceEpoch
            + Int64(DartDateTime.timeZoneOffsetInSeconds(microsecondsSinceEpoch, timeZone))
            * DartDateTime.microsecondsPerSecond
    }

    // MARK: Arithmetic (elapsed time, like Dart)

    /// Dart `add(Duration)`: elapsed microseconds, not calendar units.
    public func adding(microseconds: Int64) -> DartDateTime {
        DartDateTime(microsecondsSinceEpoch: microsecondsSinceEpoch + microseconds, isUtc: isUtc, timeZone: timeZone)
    }

    /// Dart `add(Duration(days: n))`: n * 24 hours of elapsed time.
    public func adding(days: Int) -> DartDateTime {
        adding(microseconds: Int64(days) * DartDateTime.microsecondsPerDay)
    }

    /// Dart `difference(other)` in microseconds.
    public func difference(_ other: DartDateTime) -> Int64 {
        microsecondsSinceEpoch - other.microsecondsSinceEpoch
    }

    /// Dart `difference(other).inDays`: truncated toward zero.
    public func differenceInDays(_ other: DartDateTime) -> Int {
        Int(difference(other) / DartDateTime.microsecondsPerDay)
    }

    public func isBefore(_ other: DartDateTime) -> Bool { microsecondsSinceEpoch < other.microsecondsSinceEpoch }
    public func isAfter(_ other: DartDateTime) -> Bool { microsecondsSinceEpoch > other.microsecondsSinceEpoch }

    public static func < (lhs: DartDateTime, rhs: DartDateTime) -> Bool {
        lhs.microsecondsSinceEpoch < rhs.microsecondsSinceEpoch
    }

    /// Dart `==`: same instant and same UTC flag (the zone is not part of
    /// a Dart DateTime's identity).
    public static func == (lhs: DartDateTime, rhs: DartDateTime) -> Bool {
        lhs.microsecondsSinceEpoch == rhs.microsecondsSinceEpoch && lhs.isUtc == rhs.isUtc
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(microsecondsSinceEpoch)
        hasher.combine(isUtc)
    }

    // MARK: Formatting

    /// Dart `toIso8601String()`.
    public func toIso8601String() -> String {
        let f = fields
        let pad = DartCalendar.pad
        let y = (-9999...9999).contains(f.year) ? pad(f.year, 4) : DartDateTime.sixDigits(f.year)
        let us = f.microsecond == 0 ? "" : pad(f.microsecond, 3)
        let body = "\(y)-\(pad(f.month, 2))-\(pad(f.day, 2))T"
            + "\(pad(f.hour, 2)):\(pad(f.minute, 2)):\(pad(f.second, 2))"
            + ".\(pad(f.millisecond, 3))\(us)"
        return isUtc ? body + "Z" : body
    }

    static func sixDigits(_ n: Int) -> String {
        let absN = abs(n)
        let sign = n < 0 ? "-" : "+"
        if absN >= 100_000 { return "\(sign)\(absN)" }
        return "\(sign)0\(absN)"
    }

    // MARK: Parsing (Dart `DateTime.parse`)

    public enum ParseError: Error, Equatable {
        case invalidFormat
        case outOfRange
    }

    /// Dart `DateTime.parse`. Accepts exactly what Dart's `_parseFormat`
    /// regular expression accepts:
    /// `^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?)?$`
    public static func parse(_ text: String, timeZone: TimeZone) throws(ParseError) -> DartDateTime {
        guard let match = DartDateTime.matchParseFormat(Array(text.utf8)) else { throw .invalidFormat }
        var minute = match.minute ?? 0
        var isUtc = false
        if match.hasZone {
            isUtc = true
            if let sign = match.zoneSign {
                let difference = (match.zoneMinute ?? 0) + 60 * (match.zoneHour ?? 0)
                minute -= sign * difference
            }
        }
        let fraction = match.fraction ?? []
        var micros = 0
        for i in 0..<6 {
            micros *= 10
            if i < fraction.count { micros += Int(fraction[i] ^ 0x30) }
        }
        guard
            let value = brokenDownDateToValue(
                match.year, match.month, match.day, match.hour ?? 0, minute, match.second ?? 0,
                micros / 1000, micros % 1000, isUtc: isUtc, timeZone: timeZone)
        else { throw .outOfRange }
        return DartDateTime(microsecondsSinceEpoch: value, isUtc: isUtc, timeZone: timeZone)
    }

    /// Dart `DateTime.tryParse`.
    public static func tryParse(_ text: String, timeZone: TimeZone) -> DartDateTime? {
        try? parse(text, timeZone: timeZone)
    }

    struct ParseMatch {
        var year = 0, month = 0, day = 0
        var hour: Int?, minute: Int?, second: Int?
        var fraction: [UInt8]?
        var hasZone = false
        var zoneSign: Int?
        var zoneHour: Int?, zoneMinute: Int?
    }

    /// A hand-written matcher for `_parseFormat` (ASCII digits only, like
    /// Dart's non-Unicode `\d`). Returns nil where the regex does not match.
    static func matchParseFormat(_ s: [UInt8]) -> ParseMatch? {
        var i = 0
        let n = s.count
        func isDigit(_ k: Int) -> Bool { k < n && s[k] >= 0x30 && s[k] <= 0x39 }
        func digits(_ k: Int, _ count: Int) -> Int? {
            guard k + count <= n else { return nil }
            var value = 0
            for j in k..<(k + count) {
                guard isDigit(j) else { return nil }
                value = value * 10 + Int(s[j] - 0x30)
            }
            return value
        }
        var m = ParseMatch()

        // Year: [+-]?\d{4,6}, then -?(\d\d)-?(\d\d). The regex backtracks
        // over the year length; try the greedy length first.
        var yearSign = 1
        var yearStart = 0
        if i < n && (s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-")) {
            if s[i] == UInt8(ascii: "-") { yearSign = -1 }
            yearStart = 1
        }
        var run = 0
        while isDigit(yearStart + run) { run += 1 }
        var matchedDay = false
        for yearLength in stride(from: min(6, run), through: 4, by: -1) {
            var k = yearStart + yearLength
            guard let year = digits(yearStart, yearLength) else { continue }
            if k < n && s[k] == UInt8(ascii: "-") { k += 1 }
            guard let month = digits(k, 2) else { continue }
            k += 2
            if k < n && s[k] == UInt8(ascii: "-") { k += 1 }
            // A '-' is never a digit, so retrying without consuming it cannot match.
            guard let day = digits(k, 2) else { continue }
            k += 2
            m.year = yearSign * year
            m.month = month
            m.day = day
            i = k
            matchedDay = true
            break
        }
        guard matchedDay else { return nil }
        if i == n { return m }

        // Time part (optional group): [ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?(zone)?
        guard s[i] == UInt8(ascii: " ") || s[i] == UInt8(ascii: "T") else { return nil }
        i += 1
        guard let hour = digits(i, 2) else { return nil }
        m.hour = hour
        i += 2
        // Minutes.
        var k = i
        if k < n && s[k] == UInt8(ascii: ":") { k += 1 }
        if let minute = digits(k, 2) {
            m.minute = minute
            i = k + 2
            // Seconds.
            k = i
            if k < n && s[k] == UInt8(ascii: ":") { k += 1 }
            if let second = digits(k, 2) {
                m.second = second
                i = k + 2
                // Fraction.
                if i < n && (s[i] == UInt8(ascii: ".") || s[i] == UInt8(ascii: ",")) && isDigit(i + 1) {
                    var j = i + 1
                    while isDigit(j) { j += 1 }
                    m.fraction = Array(s[(i + 1)..<j])
                    i = j
                }
            }
        }
        if i == n { return m }

        // Zone: ( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)
        k = i
        if k < n && s[k] == UInt8(ascii: " ") { k += 1 }
        guard k < n else { return nil }
        if s[k] == UInt8(ascii: "z") || s[k] == UInt8(ascii: "Z") {
            m.hasZone = true
            return k + 1 == n ? m : nil
        }
        guard s[k] == UInt8(ascii: "+") || s[k] == UInt8(ascii: "-") else { return nil }
        m.hasZone = true
        m.zoneSign = s[k] == UInt8(ascii: "-") ? -1 : 1
        k += 1
        guard let zoneHour = digits(k, 2) else { return nil }
        m.zoneHour = zoneHour
        k += 2
        if k == n { return m }
        if s[k] == UInt8(ascii: ":") { k += 1 }
        guard let zoneMinute = digits(k, 2), k + 2 == n else { return nil }
        m.zoneMinute = zoneMinute
        return m
    }

    // MARK: Dart VM internals, ported

    static func flooredDivision(_ a: Int64, _ b: Int64) -> Int64 {
        (a - (a < 0 ? b - 1 : 0)) / b
    }

    static func isLeapYear(_ y: Int) -> Bool {
        (y % 4 == 0) && ((y % 16 == 0) || (y % 100 != 0))
    }

    static func dayFromYear(_ year: Int) -> Int64 {
        let y = Int64(year)
        return 365 * (y - 1970) + flooredDivision(y - 1969, 4) - flooredDivision(y - 1901, 100)
            + flooredDivision(y - 1601, 400)
    }

    static let daysUntilMonth: [[Int64]] = [
        [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334],
        [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335],
    ]

    static func brokenDownDateToValue(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int,
        _ millisecond: Int, _ microsecond: Int, isUtc: Bool, timeZone: TimeZone
    ) -> Int64? {
        var year = year
        var month = month - 1
        if month >= 12 {
            year += month / 12
            month = month % 12
        } else if month < 0 {
            let realMonth = ((month % 12) + 12) % 12
            year += (month - realMonth) / 12
            month = realMonth
        }
        var days = Int64(day - 1)
        days += daysUntilMonth[isLeapYear(year) ? 1 : 0][month]
        days += dayFromYear(year)
        var micros = days * microsecondsPerDay
        micros += Int64(hour) * microsecondsPerHour
        micros += Int64(minute) * microsecondsPerMinute
        micros += Int64(second) * microsecondsPerSecond
        micros += Int64(millisecond) * microsecondsPerMillisecond
        micros += Int64(microsecond)
        if !isUtc {
            if abs(micros) > maxMillisecondsSinceEpoch * microsecondsPerMillisecond + microsecondsPerDay {
                return nil
            }
            micros -= toLocalTimeOffset(micros, timeZone)
        }
        if abs(micros) > maxMillisecondsSinceEpoch * microsecondsPerMillisecond { return nil }
        return micros
    }

    /// Dart `_toLocalTimeOffset`: the offset (in microseconds) of the local
    /// time whose wall clock equals the given UTC-interpreted fields. Skipped
    /// wall times resolve as in the earlier zone; repeated ones to the
    /// earliest instant.
    static func toLocalTimeOffset(_ micros: Int64, _ zone: TimeZone) -> Int64 {
        func offsetAt(_ m: Int64) -> Int64 {
            Int64(timeZoneOffsetInSeconds(m, zone)) * microsecondsPerSecond
        }
        var offset = offsetAt(micros)
        if offset != 0 {
            let offset2 = offsetAt(micros - offset)
            if offset2 != offset {
                let offset3 = offsetAt(micros - offset2)
                return offset2 <= offset3 ? offset2 : offset3
            }
            offset = offset2
        }
        let offset4 = offsetAt(micros - offset - 2 * microsecondsPerHour)
        if offset4 > offset {
            if offset4 == offset + 2 * microsecondsPerHour { return offset4 }
            let offset5 = offsetAt(micros - offset4)
            if offset5 == offset4 { return offset4 }
        }
        return offset
    }

    /// Dart `_timeZoneOffsetInSeconds`: the zone offset at an instant, with
    /// instants outside the 32-bit seconds range mapped to an equivalent year
    /// (as the VM does before calling localtime_r).
    static func timeZoneOffsetInSeconds(_ micros: Int64, _ zone: TimeZone) -> Int {
        let seconds = equivalentSeconds(micros)
        return zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func equivalentSeconds(_ micros: Int64) -> Int64 {
        let cutOff: Int64 = 0x7FFF_FFFF
        var seconds = flooredDivision(micros, microsecondsPerSecond)
        if abs(seconds) > cutOff {
            let year = yearsFromSecondsSinceEpoch(seconds)
            let days = dayFromYear(year)
            let equivalentDays = dayFromYear(equivalentYear(year))
            seconds += (equivalentDays - days) * 86_400
        }
        return seconds
    }

    static func weekDay(_ y: Int) -> Int {
        Int(((dayFromYear(y) + 4) % 7 + 7) % 7)
    }

    static func equivalentYear(_ year: Int) -> Int {
        let recentYear = (isLeapYear(year) ? 1956 : 1967) + weekDay(year) * 12
        return 2008 + ((recentYear - 2008) % 28 + 28) % 28
    }

    static func yearsFromSecondsSinceEpoch(_ seconds: Int64) -> Int {
        let daysIn4Years: Int64 = 4 * 365 + 1
        let daysIn100Years: Int64 = 25 * daysIn4Years - 1
        let daysYear2098: Int64 = daysIn100Years + 6 * daysIn4Years
        let days = seconds / 86_400
        if days > 0 && days < daysYear2098 {
            return Int(1970 + (4 * days + 2) / daysIn4Years)
        }
        return computeUpperPart(seconds * microsecondsPerSecond).year
    }

    /// Dart `_computeUpperPart`: breaks UTC-interpreted micros into fields.
    static func computeUpperPart(_ localMicros: Int64) -> Fields {
        let daysIn4Years: Int64 = 4 * 365 + 1
        let daysIn100Years: Int64 = 25 * daysIn4Years - 1
        let daysIn400Years: Int64 = 4 * daysIn100Years + 1
        let days1970To2000: Int64 = 30 * 365 + 7
        let daysOffset: Int64 = 1000 * daysIn400Years + 5 * daysIn400Years - days1970To2000
        let yearsOffset: Int64 = 400_000

        let daysSince1970 = flooredDivision(localMicros, microsecondsPerDay)
        var days = daysSince1970 + daysOffset
        var resultYear = 400 * (days / daysIn400Years) - yearsOffset
        days = days % daysIn400Years
        days -= 1
        let yd1 = days / daysIn100Years
        days = days % daysIn100Years
        resultYear += 100 * yd1
        days += 1
        let yd2 = days / daysIn4Years
        days = days % daysIn4Years
        resultYear += 4 * yd2
        days -= 1
        let yd3 = days / 365
        days = days % 365
        resultYear += yd3
        let isLeap = (yd1 == 0 || yd2 != 0) && yd3 == 0
        if isLeap { days += 1 }
        let table = daysUntilMonth[isLeap ? 1 : 0]
        var resultMonth = 12
        while table[resultMonth - 1] > days { resultMonth -= 1 }
        let resultDay = days - table[resultMonth - 1] + 1

        func mod(_ a: Int64, _ b: Int64) -> Int64 { ((a % b) + b) % b }
        let microsecond = mod(localMicros, microsecondsPerMillisecond)
        let millisecond = mod(flooredDivision(localMicros, microsecondsPerMillisecond), 1000)
        let second = mod(flooredDivision(localMicros, microsecondsPerSecond), 60)
        let minute = mod(flooredDivision(localMicros, microsecondsPerMinute), 60)
        let hour = mod(flooredDivision(localMicros, microsecondsPerHour), 24)
        // 1970-01-01 was a Thursday; Monday = 1.
        let weekday = mod(daysSince1970 + 4 - 1, 7) + 1
        return Fields(
            year: Int(resultYear), month: resultMonth, day: Int(resultDay), hour: Int(hour),
            minute: Int(minute), second: Int(second), millisecond: Int(millisecond),
            microsecond: Int(microsecond), weekday: Int(weekday))
    }
}
