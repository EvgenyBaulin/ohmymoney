import CoreAnalytics
import CoreKit
import Testing

@Suite("Previous month comparison length")
struct ComparisonLengthTests {
  @Test func marchReportsTheMissingDaysWithoutScalingMoney() {
    #expect(Period.previousMonthShorterBy(today: .init(year: 2026, month: 3, day: 31)) == 3)
    #expect(Period.previousMonthShorterBy(today: .init(year: 2028, month: 3, day: 31)) == 2)
    #expect(Period.previousMonthShorterBy(today: .init(year: 2026, month: 3, day: 28)) == 0)
    #expect(Period.previousMonthShorterBy(today: .init(year: 2026, month: 4, day: 30)) == 0)
  }
}
