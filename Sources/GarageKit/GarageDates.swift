import Foundation

/// Calendar-style wording for when something happened, like Messages/Mail:
/// "today at 3:30 PM", "yesterday at 3:30 PM", "Tuesday at 3:30 PM",
/// "Oct 28 at 3:30 PM", "Oct 28, 2025 at 3:30 PM". Never a running counter.
enum GarageDates {
    static func phrase(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) || isYesterday(date, now: now, calendar: calendar) {
            return "yesterday at \(time)"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day().year())) at \(time)"
    }

    /// isDateInYesterday uses the real clock; this honours an injected `now` (tests).
    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let y = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: y)
    }
}
