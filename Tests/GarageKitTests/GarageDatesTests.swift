import Foundation
import Testing
@testable import GarageKit

struct GarageDatesTests {
    // Fixed clock: Friday 2026-11-06 15:00 local.
    let cal = Calendar.current
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15))! }
    func at(_ d: Int, _ m: Int = 11, _ y: Int = 2026, h: Int = 9) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: 30))!
    }

    @Test func today() { #expect(GarageDates.phrase(at(6), now: now).hasPrefix("today at ")) }
    @Test func yesterday() { #expect(GarageDates.phrase(at(5), now: now).hasPrefix("yesterday at ")) }
    @Test func thisWeekUsesWeekday() {
        let s = GarageDates.phrase(at(3), now: now) // Tuesday
        #expect(s.hasPrefix(at(3).formatted(.dateTime.weekday(.wide))))
    }
    @Test func olderThisYearUsesMonthDay() {
        let s = GarageDates.phrase(at(28, 10), now: now)
        #expect(s.hasPrefix(at(28, 10).formatted(.dateTime.month(.abbreviated).day())))
        #expect(!s.contains("2026"))
    }
    @Test func lastYearIncludesYear() { #expect(GarageDates.phrase(at(28, 10, 2025), now: now).contains("2025")) }
    @Test func neverACounter() {
        let s = GarageDates.phrase(at(1, 1, 2026), now: now)
        #expect(!s.contains("ago") && !s.contains("min"))
    }
}
