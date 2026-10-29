import CoreAnalytics
import CoreKit
import CoreParse
import Foundation
import Testing

@testable import CoreInsights

/// The spans, the list and the reminders of warranties and return terms. Every day is written
/// out, so no test depends on the time zone of the machine.
@Suite("Warranty and return terms")
struct WarrantyTests {
  static let today = DateOnly(year: 2026, month: 10, day: 29)
  static let moment = Date(timeIntervalSince1970: 1_790_000_000)

  static func item(
    _ name: String?, warranty: DateOnly? = nil, place: String? = nil, returnUntil: DateOnly? = nil
  ) -> WarrantyItem {
    WarrantyItem(
      id: UUID(), title: name, occurredAt: moment, warrantyUntil: warranty, warrantyWhere: place,
      returnUntil: returnUntil)
  }

  // MARK: - Spans

  @Test func spansCountFromTheDayOfThePurchase() {
    let day = DateOnly(year: 2026, month: 10, day: 29)
    #expect(
      WarrantyTerms.end(of: TermReading(count: 2, unit: .year), from: day)
        == DateOnly(year: 2028, month: 10, day: 29))
    #expect(
      WarrantyTerms.end(of: TermReading(count: 14, unit: .day), from: day)
        == DateOnly(year: 2026, month: 11, day: 12))
    #expect(
      WarrantyTerms.end(of: TermReading(count: 2, unit: .week), from: day)
        == DateOnly(year: 2026, month: 11, day: 12))
    #expect(
      WarrantyTerms.end(of: TermReading(count: 6, unit: .month), from: day)
        == DateOnly(year: 2027, month: 4, day: 29))
  }

  @Test func aShorterMonthClipsTheDay() {
    #expect(
      WarrantyTerms.end(
        of: TermReading(count: 1, unit: .month), from: DateOnly(year: 2026, month: 1, day: 31))
        == DateOnly(year: 2026, month: 2, day: 28))
    #expect(
      WarrantyTerms.end(
        of: TermReading(count: 1, unit: .year), from: DateOnly(year: 2028, month: 2, day: 29))
        == DateOnly(year: 2029, month: 2, day: 28))
  }

  // MARK: - Reminders

  @Test func theReturnTermSpeaksFromTwoDaysBefore() {
    let days = [3, 2, 1, 0, -1]
    let items = days.map { Self.item("x", returnUntil: Self.today.adding(days: $0)) }
    let lefts = WarrantyReminders.list(items, today: Self.today).map(\.daysLeft)
    #expect(lefts == [0, 1, 2])
  }

  @Test func theWarrantySpeaksFromThirtyDaysBeforeAndOnTheLastDay() {
    let days = [31, 30, 1, 0, -1]
    let items = days.map { Self.item("x", warranty: Self.today.adding(days: $0)) }
    let lefts = WarrantyReminders.list(items, today: Self.today).map(\.daysLeft)
    #expect(lefts == [0, 1, 30])
  }

  @Test func aPastTermNeverSpeaks() {
    let past = Self.item(
      "x", warranty: Self.today.adding(days: -400), returnUntil: Self.today.adding(days: -3))
    #expect(WarrantyReminders.list([past], today: Self.today).isEmpty)
  }

  @Test func bothTermsOfOneThingSpeakWithTheReturnFirstOnTheSameDay() {
    let until = Self.today.adding(days: 2)
    let both = Self.item("Наушники", warranty: until, returnUntil: until)
    let list = WarrantyReminders.list([both], today: Self.today)
    #expect(list.count == 2)
    if case .returnEnds = list[0] {} else { Issue.record("the return term goes first") }
    if case .warrantyEnds = list[1] {} else { Issue.record("the warranty goes second") }
  }

  @Test func theWarrantyLineCarriesTheOriginalPlace() {
    let kept = Self.item("Холодильник", warranty: Self.today.adding(days: 14), place: "коробка")
    guard case .warrantyEnds(_, let title, _, _, let place)? = WarrantyReminders.list(
      [kept], today: Self.today
    ).first else {
      Issue.record("expected the warranty line")
      return
    }
    #expect(title == "Холодильник")
    #expect(place == "коробка")
  }

  @Test func doneSilencesOnlyThatTermOnThatDay() {
    let thing = Self.item("x", returnUntil: Self.today.adding(days: 1))
    let first = WarrantyReminders.list([thing], today: Self.today)
    #expect(first.count == 1)
    let silenced = WarrantyReminders.list([thing], today: Self.today, dismissed: [first[0].id])
    #expect(silenced.isEmpty)
    var moved = thing
    moved.returnUntil = Self.today.adding(days: 2)
    #expect(
      WarrantyReminders.list([moved], today: Self.today, dismissed: [first[0].id]).count == 1)
  }

  @Test func theLinesAreNearestFirst() {
    let far = Self.item("far", warranty: Self.today.adding(days: 20))
    let near = Self.item("near", returnUntil: Self.today.adding(days: 1))
    let list = WarrantyReminders.list([far, near], today: Self.today)
    #expect(list.map(\.daysLeft) == [1, 20])
  }

  @Test func theNoteHoldsTheLines() {
    let reminders = WarrantyReminders.list(
      [Self.item("x", returnUntil: Self.today)], today: Self.today)
    #expect(reminders.count == 1)
    let id = reminders[0].id
    #expect(WorthALookNote.warranty(reminders[0]).id == id)
  }

  // MARK: - List

  @Test func theListTakesLiveOperationsWithATerm() throws {
    func entry(
      _ note: String, warranty: DateOnly? = nil, returnUntil: DateOnly? = nil, deleted: Bool = false
    ) throws -> TransactionEntry {
      var draft = TransactionDraft(
        amount: AmountE4(whole: 100), note: note, warrantyUntil: warranty, returnUntil: returnUntil)
      draft.normalizeSinglePart()
      var made = try draft.materialize()
      if deleted { made.transaction.deletedAt = Self.moment }
      return made
    }
    let items = WarrantyList.items(from: [
      try entry("a", warranty: Self.today),
      try entry("b"),
      try entry("c", returnUntil: Self.today, deleted: true),
      try entry("  ", returnUntil: Self.today),
    ])
    #expect(items.count == 2)
    #expect(items.contains { $0.title == "a" })
    #expect(items.contains { $0.title == nil })
  }

  @Test func runningTermsGoFirstTheNearestFirstThenTheEndedFreshestFirst() {
    let ended = Self.item("ended", warranty: Self.today.adding(days: -10))
    let endedOld = Self.item("endedOld", warranty: Self.today.adding(days: -100))
    let soon = Self.item("soon", returnUntil: Self.today.adding(days: 3))
    let later = Self.item("later", warranty: Self.today.adding(days: 300))
    let today = Self.item("today", warranty: Self.today)
    let sorted = WarrantyList.sorted([endedOld, later, ended, soon, today], today: Self.today)
    #expect(sorted.map(\.title) == ["today", "soon", "later", "ended", "endedOld"])
  }

  @Test func searchLooksAtTheNameAndThePlaceAndIgnoresCaseAndYo() {
    let one = Self.item("Холодильник Bosch", warranty: Self.today, place: "Коробка в шкафу")
    let two = Self.item("Ёлка", warranty: Self.today)
    #expect(WarrantyList.matching([one, two], query: "бокс").isEmpty)
    #expect(WarrantyList.matching([one, two], query: "bosch") == [one])
    #expect(WarrantyList.matching([one, two], query: "ШКАФ") == [one])
    #expect(WarrantyList.matching([one, two], query: "елка") == [two])
    #expect(WarrantyList.matching([one, two], query: "  ").count == 2)
  }
}
