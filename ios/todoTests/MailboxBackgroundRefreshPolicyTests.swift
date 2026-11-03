import Foundation
import Testing
@testable import todo

@Suite("Periodic cache and daily analysis policy")
struct MailboxBackgroundRefreshPolicyTests {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Periodic cache opportunities cannot repeat the daily analysis")
    func dailyAttemptBoundary() {
        let before = date("2026-11-03T06:59:59Z")
        let target = date("2026-11-03T07:00:00Z")
        let later = date("2026-11-03T08:00:00Z")
        #expect(!MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 7, lastAttempt: nil, now: before, calendar: utc))
        #expect(MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 7, lastAttempt: nil, now: target, calendar: utc))
        #expect(!MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 7, lastAttempt: target, now: later, calendar: utc))
        #expect(MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 7, lastAttempt: target, now: date("2026-11-04T07:00:00Z"), calendar: utc))
    }

    @Test("Midnight is a valid selected analysis time, not the unset default")
    func midnightSelection() {
        let midnight = date("2026-11-03T00:00:00Z")
        #expect(MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 0, lastAttempt: nil, now: midnight, calendar: utc))
        #expect(!MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 7, lastAttempt: nil, now: midnight, calendar: utc))
    }

    @Test("A missing spring hour and repeated autumn hour still allow only one daily attempt")
    func daylightSavingTransitions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = date("2026-03-08T03:00:00-04:00")
        #expect(MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 2, lastAttempt: nil, now: spring, calendar: calendar))
        let firstHour = date("2026-11-01T01:30:00-04:00")
        let repeatedHour = date("2026-11-01T01:30:00-05:00")
        #expect(MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 1, lastAttempt: nil, now: firstHour, calendar: calendar))
        #expect(!MailboxPagingPolicy.backgroundAnalysisIsDue(hour: 1, lastAttempt: firstHour, now: repeatedHour, calendar: calendar))
    }
}
