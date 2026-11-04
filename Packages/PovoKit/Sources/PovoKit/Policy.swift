import Foundation

/// A Gregorian calendar day, independent of time zone and daylight saving.
public struct CalendarDay: Codable, Equatable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...9999).contains(y),
              let date = Self.calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let checked = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == y, checked.month == m, checked.day == d else { return nil }
        year = y; month = m; day = d
    }
    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year!; month = components.month!; day = components.day!
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var date: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    public func localDate(hour: Int = 0, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    public func adding(days: Int) -> CalendarDay {
        CalendarDay(date: Self.calendar.date(byAdding: .day, value: days, to: date)!, timeZone: Self.calendar.timeZone)
    }
    public func days(until other: CalendarDay) -> Int {
        Self.calendar.dateComponents([.day], from: date, to: other.date).day!
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.date < rhs.date }
}

public struct SuspensionForecast: Equatable, Sendable {
    public var expiry: CalendarDay
    public var suspendsOn: CalendarDay
    public var terminatesOn: CalendarDay
    public var daysLeft: Int
    public var overdue: Bool { daysLeft < 0 }
}

public enum Suspension {
    public static func forecast(expiry: String, today: CalendarDay = CalendarDay(date: Date())) -> SuspensionForecast? {
        guard let day = CalendarDay(expiry) else { return nil }
        let suspends = day.adding(days: 181)
        return SuspensionForecast(expiry: day, suspendsOn: suspends, terminatesOn: suspends.adding(days: 30),
                                  daysLeft: today.days(until: suspends))
    }
    public static func expiry(purchasedOn date: String, durationDays: Int) -> String? {
        guard (1...3650).contains(durationDays), let day = CalendarDay(date) else { return nil }
        return day.adding(days: durationDays).description
    }
}

public struct SuspensionAnchor: Codable, Equatable, Sendable {
    public var purchaseDate: String
    public var durationDays: Int?
    public var expiryDate: String
    public var notifiedFor: String?
    public init(purchaseDate: String, durationDays: Int? = nil, expiryDate: String, notifiedFor: String? = nil) {
        self.purchaseDate = purchaseDate; self.durationDays = durationDays
        self.expiryDate = expiryDate; self.notifiedFor = notifiedFor
    }
    public func forecast(today: CalendarDay = CalendarDay(date: Date())) -> SuspensionForecast? {
        Suspension.forecast(expiry: expiryDate, today: today)
    }
}

/// Decoding a JWT here is for display/routing/expiry only, never authentication.
/// Only povo's HTTPS API validates credentials. Tokens are never logged.
public enum JWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    public static func externalID(_ token: String) -> String? { (claims(token)?["external_id"] as? String)?.nilIfBlank }
    public static func expiresAt(_ token: String) -> Date? {
        guard let body = claims(token) else { return nil }
        for key in ["exp", "expiry_time"] {
            let value = (body[key] as? NSNumber)?.doubleValue ?? (body[key] as? String).flatMap(Double.init)
            if let value, value.isFinite { return Date(timeIntervalSince1970: value) }
        }
        return nil
    }
    public static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = expiresAt(token) else { return true }
        return now >= expiry
    }
}

public enum BillsPolicy: Sendable {
    case always, ifStale
    public func wants(lastAttempt: Date?, now: Date = Date()) -> Bool {
        switch self {
        case .always: return true
        case .ifStale: return lastAttempt.map { now.timeIntervalSince($0) >= 55 * 60 } ?? true
        }
    }
}

public enum ReleaseVersion {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    private static func parts(_ text: String) -> [Int]? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        // Stable builds only: a prerelease is not a safe automatic upgrade.
        let tokens = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = tokens.compactMap { Int($0) }
        return numbers.count == tokens.count ? numbers : nil
    }
}
