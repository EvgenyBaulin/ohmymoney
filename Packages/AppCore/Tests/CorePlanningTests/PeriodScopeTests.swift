import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Period scope")
struct PeriodScopeTests {
  let fx = PrivacyFixture()
  let june = DayRange(PrivacyFixture.day(2026, 6, 1), PrivacyFixture.day(2026, 6, 30))

  @Test("operations, transfers and the dated records outside the span are cut")
  func cuts() {
    let scoped = PeriodScope.apply(june, to: fx.dataset)
    let ids = Set(scoped.entries.map(\.id))
    #expect(ids.contains(fx.refundId))
    #expect(ids.contains(fx.hiddenOpId))
    #expect(scoped.transfers.count == 3)
    #expect(scoped.dayNotes.isEmpty)  // the note is on 2 May
    #expect(scoped.planning.expected.isEmpty)  // due 10 May
    #expect(scoped.planning.debtEntries.isEmpty)  // 4 May
  }

  @Test("the reference books and the plans without a day stay whole")
  func referencesStay() {
    let scoped = PeriodScope.apply(june, to: fx.dataset)
    #expect(scoped.people == fx.dataset.people)
    #expect(scoped.paymentMethods == fx.dataset.paymentMethods)
    #expect(scoped.categories == fx.dataset.categories)
    #expect(scoped.debts == fx.dataset.debts)
    #expect(scoped.planning.scheduled == fx.dataset.planning.scheduled)
    #expect(scoped.rules == fx.dataset.rules)
  }

  @Test("a refund pulls its purchase in from outside the span")
  func refundPullsPurchase() {
    let result = PeriodScope.scope(june, of: fx.dataset)
    #expect(result.pulledIn == [fx.purchaseId])
    #expect(result.dataset.entries.contains { $0.id == fx.purchaseId })
    #expect(result.unresolved.isEmpty)
    #expect(result.dataset.tagBook.links == fx.dataset.tagBook.links)
  }

  @Test("without pulling in, the dangling reference is cleared and listed")
  func refundWithoutPull() {
    let result = PeriodScope.scope(june, of: fx.dataset, pullIn: false)
    #expect(!result.dataset.entries.contains { $0.id == fx.purchaseId })
    #expect(result.unresolved == [fx.refundId])
    let refund = result.dataset.entries.first { $0.id == fx.refundId }
    #expect(refund?.parts[0].refundOfPartId == nil)
    #expect(result.dataset.tagBook.links.isEmpty)
  }

  @Test("the day is read in the zone the operation was recorded in")
  func zoneOfTheOperation() {
    var data = fx.dataset
    // 23:30 on 31 May in Moscow is already 1 June in Vladivostok.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Vladivostok")!
    let instant = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 1))!
    data.entries[2].transaction.occurredAt = instant
    data.entries[2].transaction.timeZoneId = "Asia/Vladivostok"
    let firstOfJune = DayRange(PrivacyFixture.day(2026, 6, 1), PrivacyFixture.day(2026, 6, 1))
    let scoped = PeriodScope.apply(firstOfJune, to: data, pullIn: false)
    #expect(scoped.entries.map(\.id) == [fx.hiddenOpId])
  }

  @Test("an empty span keeps no operation and a span of everything keeps all")
  func edges() {
    let none = DayRange(PrivacyFixture.day(2000, 1, 1), PrivacyFixture.day(2000, 1, 2))
    #expect(PeriodScope.apply(none, to: fx.dataset).entries.isEmpty)
    let all = DayRange(PrivacyFixture.day(2000, 1, 1), PrivacyFixture.day(2100, 1, 1))
    let scoped = PeriodScope.scope(all, of: fx.dataset)
    #expect(scoped.dataset.entries.count == fx.dataset.entries.count)
    #expect(scoped.pulledIn.isEmpty)
  }
}
