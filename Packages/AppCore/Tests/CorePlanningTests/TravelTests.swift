import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

private func money(_ text: String) -> AmountE4 {
  (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
}

private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

private func id(_ number: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

private let bali = "Asia/Makassar"

private func trip(
  _ number: Int = 1, from: String = "2026-10-05", to: String = "2026-10-15",
  budget: String? = "100000", currency: String? = "IDR", budgetCurrency: CurrencyCode? = nil
) -> Event {
  Event(
    id: id(number), name: "Бали", kind: .trip, startDate: day(from), endDate: day(to),
    budgetE4: budget.map(money), tripCurrency: currency.map { CurrencyCode($0) },
    budgetCurrency: budgetCurrency)
}

@Suite("The zone an operation was recorded in keeps its day")
struct TravelDayTests {
  /// 21:00 in Bali (UTC+8) is 13:00 UTC and 16:00 in Moscow, on the same date.
  private let dinner = Date(timeIntervalSince1970: 1_791_378_000)  // 2026-10-07 13:00 UTC

  @Test func aDinnerInBaliStaysOnItsDayAndItsTimeWhenTheMacIsBackInMoscow() throws {
    let tx = CoreKit.Transaction(
      kind: .expense, occurredAt: dinner, amountE4: money("100"), timeZoneId: bali)
    #expect(TravelDay.day(of: dinner, zoneId: bali) == day("2026-10-07"))
    #expect(TravelDay.timeOfDay(of: dinner, zoneId: bali) == TimeOfDay(hour: 21, minute: 0))
    // The Mac is in Moscow now: the stored zone still decides.
    #expect(
      CalendarContext.moscow.day(of: tx.occurredAt, recordedIn: tx.timeZoneId) == day("2026-10-07"))
    #expect(
      CalendarContext.moscow.timeOfDay(tx.occurredAt, recordedIn: tx.timeZoneId)
        == TimeOfDay(hour: 21, minute: 0))
  }

  /// The case where the zones differ across midnight: 23:30 in Bali is 18:30 in Moscow on the
  /// same day, 00:30 in Bali is 19:30 the day before in Moscow.
  @Test func theDayDoesNotWanderAcrossMidnight() {
    let lateBali = Date(timeIntervalSince1970: 1_791_390_600)  // 2026-10-07 16:30 UTC = 00:30 on the 8th in Bali
    #expect(TravelDay.day(of: lateBali, zoneId: bali) == day("2026-10-08"))
    #expect(CalendarContext.moscow.day(of: lateBali) == day("2026-10-07"))
    #expect(
      CalendarContext.moscow.day(of: lateBali, recordedIn: bali) == day("2026-10-08"),
      "the Moscow calendar reads the Bali operation on its Bali day")
  }

  @Test func anOperationWithoutAZoneReadsAsMoscowOnAMacInAnotherZone() throws {
    let baliMac = CalendarContext(
      timeZone: TimeZone(identifier: bali)!, unrecordedZone: TravelDay.moscowZone)
    let evening = Date(timeIntervalSince1970: 1_791_389_400)  // 2026-10-07 16:10 UTC: 19:10 in Moscow, 00:10 on the 8th in Bali
    #expect(baliMac.day(of: evening) == day("2026-10-08"))
    #expect(baliMac.day(of: evening, recordedIn: nil) == day("2026-10-07"), "recorded in Moscow")
    #expect(baliMac.day(of: evening, recordedIn: "Not/AZone") == day("2026-10-07"))
    // A fixed-zone test calendar without an unrecorded zone reads such an operation in its own.
    #expect(CalendarContext.utc.day(of: evening, recordedIn: nil) == day("2026-10-07"))
  }

  @Test func theMoscowZoneIsRecordedAsNothing() {
    #expect(TravelDay.recordedId(in: TravelDay.moscowZone) == nil)
    #expect(TravelDay.recordedId(in: TimeZone(identifier: bali)!) == bali)
  }

  @Test func theLedgerPutsAnOperationOnItsRecordedDay() throws {
    let when = Date(timeIntervalSince1970: 1_791_390_600)  // 00:30 on the 8th in Bali, 19:30 on the 7th in Moscow
    func entry(_ number: Int, zone: String?) -> TransactionEntry {
      TransactionEntry(
        transaction: CoreKit.Transaction(
          id: id(number), kind: .expense, occurredAt: when, amountE4: money("50"),
          createdAt: when, updatedAt: when, timeZoneId: zone),
        parts: [
          TransactionPart(
            id: id(number + 100), transactionId: id(number), amountE4: money("50"))
        ])
    }
    let ledger = Ledger(
      dataset: Dataset(entries: [entry(1, zone: bali), entry(2, zone: nil)]),
      calendar: .moscow)
    let days = Dictionary(uniqueKeysWithValues: ledger.rows.map { ($0.transactionId, $0.day) })
    #expect(days[id(1)] == day("2026-10-08"), "recorded in Bali: the Bali day")
    #expect(days[id(2)] == day("2026-10-07"), "without a zone: the Moscow day")
  }
}

@Suite("The trip mode: on, off, ended, extended")
struct TripModeTests {
  @Test func theSettingsReadAndWriteTheirKeysAndIgnoreAJunkValue() {
    let settings = TripSettings(activeEventId: id(1), returnCardEventId: id(2))
    #expect(TripSettings(storedValues: settings.storedValues.compactMapValues { $0 }) == settings)
    #expect(TripSettings(storedValues: ["trip.activeEventId": "not a uuid"]) == .off)
    #expect(TripSettings.off.storedValues.values.allSatisfy { $0 == nil })
  }

  @Test func theModeIsOnThroughTheLastDayAndEndedAfterIt() {
    let event = trip()
    let settings = TripSettings(activeEventId: event.id)
    #expect(
      TripMode.state(settings: settings, events: [event], today: day("2026-10-15")) == .on(event))
    #expect(
      TripMode.state(settings: settings, events: [event], today: day("2026-10-16")) == .ended(event)
    )
    #expect(TripMode.state(settings: .off, events: [event], today: day("2026-10-10")) == .off)
  }

  @Test func aTripThatIsGoneArchivedOrNotATripIsNoTrip() {
    var archived = trip()
    archived.archived = true
    var other = trip(2)
    other.kind = .other
    #expect(
      TripMode.state(
        settings: .init(activeEventId: archived.id), events: [archived], today: day("2026-10-10"))
        == .off)
    #expect(
      TripMode.state(
        settings: .init(activeEventId: other.id), events: [other], today: day("2026-10-10")) == .off
    )
    #expect(
      TripMode.state(settings: .init(activeEventId: id(9)), events: [], today: day("2026-10-10"))
        == .off)
    let cleared = TripMode.afterDayChange(
      settings: .init(activeEventId: id(9)), events: [], today: day("2026-10-10"))
    #expect(cleared == .off)
  }

  @Test func theModeSwitchesItselfOffTheDayAfterTheLastDayAndTheCardWaitsForTheMorning() {
    let event = trip()
    let settings = TripSettings(activeEventId: event.id)
    #expect(
      TripMode.afterDayChange(settings: settings, events: [event], today: day("2026-10-15"))
        == settings, "on the last day it is still on")
    let after = TripMode.afterDayChange(
      settings: settings, events: [event], today: day("2026-10-16"))
    #expect(after.activeEventId == nil)
    #expect(after.returnCardEventId == event.id)
    #expect(TripMode.welcomeBack(settings: after, events: [event], today: day("2026-10-15")) == nil)
    #expect(
      TripMode.welcomeBack(settings: after, events: [event], today: day("2026-10-16")) == event)
    // A second launch the same morning changes nothing.
    #expect(
      TripMode.afterDayChange(settings: after, events: [event], today: day("2026-10-16")) == after)
    #expect(TripMode.dismissingCard(settings: after) == .off)
  }

  @Test func extendingMovesTheLastDayTurnsTheModeBackOnAndDropsTheCard() throws {
    let event = trip()
    let ended = TripSettings(activeEventId: nil, returnCardEventId: event.id)
    let result = try #require(TripMode.extending(event, to: day("2026-10-20"), settings: ended))
    #expect(result.event.endDate == day("2026-10-20"))
    #expect(result.settings == TripSettings(activeEventId: event.id))
    #expect(
      TripMode.state(settings: result.settings, events: [result.event], today: day("2026-10-17"))
        == .on(result.event))
    #expect(
      TripMode.extending(event, to: day("2026-10-15"), settings: ended) == nil, "not an extension")
    #expect(TripMode.extending(event, to: day("2026-10-01"), settings: ended) == nil)
  }

  @Test func theModeChangesOnlyTheDefaultsOfTheEntry() {
    let event = trip()
    #expect(
      TripMode.entryDefaults(.on(event)) == .init(currency: CurrencyCode("IDR"), eventId: event.id))
    #expect(TripMode.entryDefaults(.off) == nil)
    #expect(TripMode.entryDefaults(.ended(event)) == nil)
    let line = TripMode.line(for: event, budget: money("100000"))
    #expect(
      line.name == "Бали" && line.endDate == day("2026-10-15")
        && line.currency == CurrencyCode("IDR"))
  }

  @Test func switchingOnAndOffByHand() {
    let event = trip()
    let on = TripMode.switchingOn(event, settings: .init(returnCardEventId: event.id))
    #expect(on == TripSettings(activeEventId: event.id))
    #expect(TripMode.switchingOff(settings: on) == .off)
    let other = TripMode.switchingOn(event, settings: .init(returnCardEventId: id(7)))
    #expect(other.returnCardEventId == id(7), "the card of another trip waits")
  }
}

@Suite("The trip budget and «сегодня потрачено / осталось на день»")
struct TripAllowanceTests {
  private let rates = DayRates(series: [
    CurrencyCode("USD"): [DayRate(day: day("2026-01-01"), perUnit: 100)],
    CurrencyCode("EUR"): [DayRate(day: day("2026-01-01"), perUnit: 110)],
  ])

  @Test func theBudgetKeepsItsCurrencyAndShowsInTheDefaultOne() throws {
    let usdBudget = trip(budget: "1000", budgetCurrency: .usd)
    #expect(
      TripBudget.inDefaultCurrency(
        usdBudget, defaultCurrency: .rub, rates: rates, on: day("2026-10-10"))
        == money("100000"))
    // The owner changes the default currency to euro in the middle of the trip.
    #expect(
      try TripBudget.inDefaultCurrency(
        usdBudget, defaultCurrency: CurrencyCode("EUR"), rates: rates, on: day("2026-10-10"))
        == AmountE4(decimal: Decimal(1000) * 100 / 110))
    #expect(TripBudget.inRubles(usdBudget, rates: rates, on: day("2026-10-10")) == money("100000"))
    // A budget without a currency of its own is in the default currency of the time.
    let plain = trip(budget: "50000")
    #expect(
      TripBudget.inDefaultCurrency(
        plain, defaultCurrency: .rub, rates: rates, on: day("2026-10-10"))
        == money("50000"))
    #expect(TripBudget.inRubles(plain, rates: rates, on: day("2026-10-10")) == money("50000"))
    #expect(
      TripBudget.inDefaultCurrency(
        trip(budget: nil), defaultCurrency: .rub, rates: rates, on: day("2026-10-10")) == nil)
    let unpriced = trip(budget: "10", budgetCurrency: CurrencyCode("XYZ"))
    #expect(TripBudget.inRubles(unpriced, rates: rates, on: day("2026-10-10")) == nil)
  }

  @Test func whatIsLeftIsSharedOverTheDaysThatRemainAndTodayIsSubtracted() throws {
    // 100 000 budget, 40 000 spent before today, 6 days left (10..15), 5 000 today.
    let a = try #require(
      TripAllowance.make(
        budget: money("100000"), spentBeforeToday: money("40000"), spentToday: money("5000"),
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    #expect(a.daysLeft == 6)
    #expect(a.perDay == money("10000"))
    #expect(a.leftToday == money("5000"))
    #expect(!a.exhausted)
  }

  @Test func theDayChangesAndTheShareGrows() throws {
    // The same 40 000 spent, a day later: five days left.
    let a = try #require(
      TripAllowance.make(
        budget: money("100000"), spentBeforeToday: money("40000"), spentToday: .zero,
        endDate: day("2026-10-15"), today: day("2026-10-11")))
    #expect(a.daysLeft == 5)
    #expect(a.perDay == money("12000"))
    #expect(a.leftToday == money("12000"))
  }

  @Test func extendingTheTripSpreadsTheRest() throws {
    let before = try #require(
      TripAllowance.make(
        budget: money("100000"), spentBeforeToday: money("40000"), spentToday: .zero,
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    let after = try #require(
      TripAllowance.make(
        budget: money("100000"), spentBeforeToday: money("40000"), spentToday: .zero,
        endDate: day("2026-10-19"), today: day("2026-10-10")))
    #expect(before.perDay == money("10000"))
    #expect(after.daysLeft == 10)
    #expect(after.perDay == money("6000"))
  }

  @Test func anExhaustedBudgetLeavesNothingAndAnOverspentDayGoesNegative() throws {
    let over = try #require(
      TripAllowance.make(
        budget: money("100000"), spentBeforeToday: money("120000"), spentToday: money("1000"),
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    #expect(over.perDay == .zero)
    #expect(over.leftToday == money("-1000"))
    #expect(over.exhausted)
    let today = try #require(
      TripAllowance.make(
        budget: money("100000"), spentBeforeToday: money("50000"), spentToday: money("50000"),
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    #expect(today.exhausted, "spent exactly the budget with today")
    #expect(today.perDay == money("8333.3333"))
  }

  @Test func theLastDayAndADayAfterTheEndStillShareByOne() throws {
    let last = try #require(
      TripAllowance.make(
        budget: money("100"), spentBeforeToday: money("40"), spentToday: money("10"),
        endDate: day("2026-10-15"), today: day("2026-10-15")))
    #expect(last.daysLeft == 1 && last.perDay == money("60") && last.leftToday == money("50"))
    let past = try #require(
      TripAllowance.make(
        budget: money("100"), spentBeforeToday: money("40"), spentToday: .zero,
        endDate: day("2026-10-15"), today: day("2026-10-20")))
    #expect(past.daysLeft == 1)
    #expect(
      TripAllowance.make(
        budget: nil, spentBeforeToday: .zero, spentToday: .zero, endDate: day("2026-10-15"),
        today: day("2026-10-10")) == nil)
  }
}

private struct TripBook {
  let tripEvent = trip(budget: "100000")
  let anna = id(501)
  let dima = id(502)
  let nobody = id(503)
  let food = id(601)
  let flights = id(602)
  var entries: [TransactionEntry] = []
  private var next = 10

  /// `amount` of `currency`, `rubles` of them; `date` is an ISO day, noon UTC.
  mutating func add(
    _ iso: String, _ amount: String, rubles: String? = nil, currency: String = "RUB",
    category: UUID? = nil, kind: TransactionKind = .expense, event: Bool = true,
    debtor: UUID? = nil, status: ReimbursementStatus = .expected, zone: String? = nil,
    refundOf: UUID? = nil
  ) -> UUID {
    next += 1
    let transactionId = id(next)
    let partId = id(next + 1_000)
    let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
    let part = TransactionPart(
      id: partId, transactionId: transactionId, categoryId: category,
      quality: .neutral, qualitySource: .manual, amountE4: money(amount),
      amountRubE4: money(rubles ?? amount), forWhom: debtor == nil ? .me : .friends,
      reimbursable: debtor != nil, debtorPersonId: debtor,
      reimbursementStatus: debtor == nil ? nil : status, eventId: event ? tripEvent.id : nil,
      refundOfPartId: refundOf)
    entries.append(
      TransactionEntry(
        transaction: CoreKit.Transaction(
          id: transactionId, kind: kind, occurredAt: when, currency: CurrencyCode(currency),
          amountE4: money(amount), amountRubE4: money(rubles ?? amount), createdAt: when,
          updatedAt: when, timeZoneId: zone),
        parts: [part]))
    return partId
  }

  /// Money that came back from a friend: the live reimbursement the links name.
  mutating func addReimbursement(_ iso: String, _ amount: String) -> UUID {
    _ = add(iso, amount, kind: .reimbursement, event: false)
    return entries[entries.count - 1].transaction.id
  }

  func ledger(links: [ReimbursementLink] = []) -> Ledger {
    let categories = [
      CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: flights, kind: .expense, name: "Flights", quality: .neutral),
    ]
    return Ledger(
      dataset: Dataset(
        entries: entries, links: links, categories: categories,
        people: [Person(id: anna, name: "Аня"), Person(id: dima, name: "Дима")],
        events: [tripEvent]),
      calendar: .utc)
  }
}

@Suite("The summary of a trip: total, days, categories, currencies, budget")
struct TripSummaryTests {
  @Test func everyOperationOfTheEventCountsWhateverItsDateInRubles() throws {
    var book = TripBook()
    // Tickets bought three months ago, the hotel, then the days of the trip.
    _ = book.add("2026-07-01", "42000", category: book.flights)
    _ = book.add("2026-10-05", "38000", category: book.food)
    _ = book.add("2026-10-06", "1000000", rubles: "5000", currency: "IDR", category: book.food)
    _ = book.add("2026-10-06", "500000", rubles: "2500", currency: "IDR", category: book.food)
    _ = book.add("2026-10-08", "100", rubles: "9000", currency: "USD", category: book.food)
    _ = book.add("2026-10-09", "777", event: false)  // not the trip
    let summary = TripSummary(
      event: book.tripEvent, ledger: book.ledger(), budgetRub: money("100000"))
    #expect(summary.total == money("96500"), "42000 + 38000 + 5000 + 2500 + 9000")
    #expect(summary.budget == money("100000"))
    #expect(summary.versusBudget == money("3500"))
    #expect(
      summary.byDay.map(\.day) == [
        day("2026-07-01"), day("2026-10-05"), day("2026-10-06"), day("2026-10-08"),
      ])
    #expect(summary.spent(on: day("2026-10-06")) == money("7500"))
    #expect(summary.byCategory.first?.categoryId == book.food)
    #expect(summary.byCategory.first?.amount == money("54500"))
    #expect(summary.byCategory.last?.amount == money("42000"))
    let rub = summary.byCurrency.first { $0.currency == .rub }
    #expect(rub?.amount == money("80000") && rub?.rubles == money("80000"))
    let idr = try #require(summary.byCurrency.first { $0.currency == CurrencyCode("IDR") })
    #expect(idr.amount == money("1500000") && idr.rubles == money("7500"))
    #expect(
      AmountE4.sum(summary.byCurrency.map(\.rubles)) == summary.total,
      "the rubles of the debits are the total")
  }

  @Test func theRublesOfTheDebitReplaceTheRateOfTheDay() {
    // The same purchase first at a rate of the Bank of Russia (≈ 4 800), then as the bank debited.
    var estimated = TripBook()
    _ = estimated.add("2026-10-06", "1000000", rubles: "4800", currency: "IDR")
    var debited = TripBook()
    _ = debited.add("2026-10-06", "1000000", rubles: "5120", currency: "IDR")
    let before = TripSummary(event: estimated.tripEvent, ledger: estimated.ledger(), budgetRub: nil)
    let after = TripSummary(event: debited.tripEvent, ledger: debited.ledger(), budgetRub: nil)
    #expect(before.total == money("4800"))
    #expect(after.total == money("5120"))
    #expect(after.versusBudget == nil)
  }

  @Test func aRefundTakesItsPurchaseDownOnTheDayOfThePurchase() {
    var book = TripBook()
    let purchase = book.add("2026-10-06", "3000", category: book.food)
    _ = book.add("2026-10-08", "1000", category: book.food, kind: .refund, refundOf: purchase)
    let summary = TripSummary(event: book.tripEvent, ledger: book.ledger(), budgetRub: nil)
    #expect(summary.total == money("2000"))
    #expect(summary.spent(on: day("2026-10-06")) == money("2000"))
    #expect(summary.spent(on: day("2026-10-08")) == .zero)
  }

  @Test func theDaysAreTheDaysOfTheZoneEachOperationWasRecordedIn() {
    var book = TripBook()
    // 22:00 UTC on the 6th is 06:00 on the 7th in Bali.
    let late = CalendarContext.utc.startOfDay(day("2026-10-06")).addingTimeInterval(22 * 3600)
    let partId = book.add("2026-10-06", "300", zone: bali)
    book.entries[0].transaction.occurredAt = late
    _ = partId
    let summary = TripSummary(event: book.tripEvent, ledger: book.ledger(), budgetRub: nil)
    #expect(summary.byDay.map(\.day) == [day("2026-10-07")])
  }

  @Test func theAllowanceReadsTheSummaryByDay() throws {
    var book = TripBook()
    _ = book.add("2026-07-01", "40000")  // the tickets, before today
    _ = book.add("2026-10-10", "5000")
    let summary = TripSummary(
      event: book.tripEvent, ledger: book.ledger(), budgetRub: money("100000"))
    let allowance = try #require(summary.allowance(event: book.tripEvent, today: day("2026-10-10")))
    #expect(allowance.spentBeforeToday == money("40000") && allowance.spentToday == money("5000"))
    #expect(allowance.perDay == money("10000") && allowance.leftToday == money("5000"))
    let without = TripSummary(event: book.tripEvent, ledger: book.ledger(), budgetRub: nil)
    #expect(without.allowance(event: book.tripEvent, today: day("2026-10-10")) == nil)
  }
}

@Suite("The settlement with the company: what each person still owes")
struct TripSettlementTests {
  @Test func eachPersonOwesTheirPartsLessWhatCameBack() throws {
    var book = TripBook()
    // A dinner for two, halved with Аня: her half is the reimbursable part.
    _ = book.add("2026-10-06", "2000", debtor: book.anna)
    // A taxi shared evenly with Аня and Дима: each owes a third.
    _ = book.add("2026-10-07", "1000", debtor: book.anna)
    _ = book.add("2026-10-07", "1000", debtor: book.dima)
    // A part already returned and one written off do not count.
    _ = book.add("2026-10-08", "5000", debtor: book.dima, status: .returned)
    _ = book.add("2026-10-08", "700", debtor: book.dima, status: .writtenOff)
    // My own spending and an operation of another event are nobody's debt.
    _ = book.add("2026-10-09", "300")
    _ = book.add("2026-10-09", "900", event: false, debtor: book.dima)
    let summary = TripSummary(event: book.tripEvent, ledger: book.ledger(), budgetRub: nil)
    #expect(summary.settlement.map(\.personId) == [book.anna, book.dima])
    #expect(summary.settlement.map(\.owed) == [money("3000"), money("1000")])
    #expect(summary.settlement.map(\.parts) == [2, 1])
  }

  @Test func aPartialReturnLeavesTheRest() throws {
    var book = TripBook()
    let part = book.add("2026-10-06", "4000", debtor: book.anna)
    let returnId = book.addReimbursement("2026-10-10", "1500")
    let link = ReimbursementLink(
      id: id(901), reimbursementTxId: returnId, partId: part, amountE4: money("1500"))
    let summary = TripSummary(
      event: book.tripEvent, ledger: book.ledger(links: [link]), budgetRub: nil)
    #expect(summary.settlement == [.init(personId: book.anna, owed: money("2500"), parts: 1)])
  }

  @Test func aPersonWithoutPartsAndATripNobodyPaidForAreNotListed() {
    var book = TripBook()
    _ = book.add("2026-10-06", "100")
    let summary = TripSummary(event: book.tripEvent, ledger: book.ledger(), budgetRub: nil)
    #expect(summary.settlement.isEmpty)
    // A fully returned part: nothing left, nobody listed.
    var paid = TripBook()
    let part = paid.add("2026-10-06", "800", debtor: paid.anna)
    let back = paid.addReimbursement("2026-10-10", "800")
    let link = ReimbursementLink(
      id: id(902), reimbursementTxId: back, partId: part, amountE4: money("800"))
    let settled = TripSummary(
      event: paid.tripEvent, ledger: paid.ledger(links: [link]), budgetRub: nil)
    #expect(settled.settlement.isEmpty)
  }
}

@Suite("The fees abroad and the best card")
struct TravelFeesTests {
  private func percent(_ text: String) -> CashbackPercent {
    CashbackPercent(decimal: Decimal(string: text)!)!
  }

  @Test func theAtmFeeIsThePercentPlusTheFixedPart() throws {
    let terms = CardForeignTerms(
      atmFeePercent: percent("2"), atmFeeFixed: Money(amount: money("3"), currency: .usd))
    let fee = try #require(
      TravelFees.atmFee(for: Money(amount: money("200"), currency: .usd), terms: terms))
    #expect(fee.percentPart == Money(amount: money("4"), currency: .usd))
    #expect(fee.total == Money(amount: money("7"), currency: .usd))
  }

  @Test func aFixedPartInAnotherCurrencyNeedsAConverterOtherwiseTheFeeStaysInTwoParts() throws {
    let terms = CardForeignTerms(
      atmFeePercent: percent("1"), atmFeeFixed: Money(amount: money("300"), currency: .rub))
    let amount = Money(amount: money("1000"), currency: .usd)
    let apart = try #require(TravelFees.atmFee(for: amount, terms: terms))
    #expect(apart.percentPart.amount == money("10") && apart.total == nil)
    let converted = try #require(
      TravelFees.atmFee(for: amount, terms: terms) { _, _ in money("3") })
    #expect(converted.total == Money(amount: money("13"), currency: .usd))
  }

  @Test func noAtmTermsNoFee() {
    #expect(
      TravelFees.atmFee(for: Money(amount: money("100"), currency: .usd), terms: CardForeignTerms())
        == nil)
    let onlyFixed = CardForeignTerms(atmFeeFixed: Money(amount: money("5"), currency: .usd))
    #expect(
      TravelFees.atmFee(for: Money(amount: money("100"), currency: .usd), terms: onlyFixed)?.total
        == Money(amount: money("5"), currency: .usd))
  }

  @Test func theConversionFeeIsAPercentOfThePurchaseAndOnlyWhenTyped() {
    let terms = CardForeignTerms(conversionFee: percent("1.5"))
    #expect(TravelFees.conversionFee(for: money("10000"), terms: terms) == money("150"))
    #expect(TravelFees.conversionFee(for: money("10000"), terms: CardForeignTerms()) == nil)
    #expect(TravelFees.conversionFee(for: money("0.01"), terms: terms) == money("0.0002"))
  }

  @Test func theCardsAreComparedByTheConversionFeeAndTheOnesWithoutTermsAreMarked() throws {
    func card(_ number: Int, _ name: String, fee: String?, archived: Bool = false) -> PaymentCard {
      PaymentCard(
        id: id(number), accountId: id(1), name: name, archived: archived,
        foreign: CardForeignTerms(conversionFee: fee.map(percent)))
    }
    let cards = [
      card(1, "Сбер", fee: "2"), card(2, "Т-Банк", fee: "0.5"), card(3, "Альфа", fee: nil),
      card(4, "Мир", fee: "0"), card(5, "Старая", fee: "0.1", archived: true),
      card(6, "Райф", fee: "2"),
    ]
    let comparison = TravelCardComparison(cards: cards, sample: money("100000"))
    #expect(comparison.entries.map(\.name) == ["Мир", "Т-Банк", "Райф", "Сбер", "Альфа"])
    #expect(comparison.best?.name == "Мир", "a card without a fee is the best there is")
    #expect(comparison.best?.loss == .zero)
    #expect(comparison.entries[1].loss == money("500"))
    #expect(comparison.withoutTerms.map(\.name) == ["Альфа"])
  }

  @Test func withNoTermsAtAllThereIsNoBestCard() {
    let comparison = TravelCardComparison(
      cards: [PaymentCard(accountId: id(1), name: "A")], sample: money("1000"))
    #expect(comparison.best == nil)
    #expect(comparison.withoutTerms.count == 1)
    #expect(TravelCardComparison(cards: [], sample: money("1000")).best == nil)
  }
}

@Suite("Cash in a foreign currency is spent at the rate it was bought at")
struct CashRateTests {
  private func transfer(
    _ rubles: String, _ foreign: String, to account: Int = 7, from: CurrencyCode = .rub,
    currency: String = "USD"
  ) -> Transfer {
    Transfer(
      occurredAt: Date(), fromAccountId: id(1), fromCurrency: from, fromAmountE4: money(rubles),
      toAccountId: id(account), toCurrency: CurrencyCode(currency), toAmountE4: money(foreign))
  }

  @Test func oneBuyGivesItsRateSeveralGiveTheWeightedAverage() throws {
    let one = CashRate.purchases(
      transfers: [transfer("98000", "1000")], accountId: id(7), currency: .usd)
    #expect(CashRate.average(one) == 98)
    // 1 000 at 98 and 500 at 100: (98 000 + 50 000) / 1 500.
    let two = CashRate.purchases(
      transfers: [transfer("98000", "1000"), transfer("50000", "500")], accountId: id(7),
      currency: .usd)
    let average = try #require(CashRate.average(two))
    #expect(average == Decimal(148_000) / Decimal(1_500))
    #expect(CashRate.rubles(for: money("30"), at: average) == money("2960"))
  }

  @Test func onlyBuysIntoThisCashAccountForRublesCount() {
    let transfers = [
      transfer("98000", "1000"),
      transfer("5000", "50", to: 8),  // another account
      transfer("1000", "10", currency: "EUR"),  // another currency
      transfer("900", "9", from: .usd),  // not paid for in rubles
    ]
    let purchases = CashRate.purchases(transfers: transfers, accountId: id(7), currency: .usd)
    #expect(purchases.count == 1)
  }

  @Test func noBuyNoRate() {
    #expect(CashRate.average([]) == nil)
    #expect(CashRate.rubles(for: money("10"), at: nil) == nil)
  }
}

@Suite("The rate difference of the period")
struct CurrencyGainTests {
  private let usd = BalanceKey(accountId: id(1), currency: .usd)
  private let eur = BalanceKey(accountId: id(1), currency: CurrencyCode("EUR"))

  private func rates(_ points: [(String, Decimal)], _ currency: CurrencyCode = .usd) -> DayRates {
    DayRates(series: [currency: points.map { DayRate(day: day($0.0), perUnit: $0.1) }])
  }

  private func gain(_ input: CurrencyGain.Input, _ rates: DayRates) -> CurrencyGain {
    CurrencyGain(inputs: [input], rates: rates, from: day("2026-10-01"), to: day("2026-10-31"))
  }

  @Test func theRateGrowsOnAHeldBalance() {
    // 1 000 $ held all month: 90 → 95 gives +5 000.
    let result = gain(
      .init(key: usd, balanceAtStart: money("1000"), balanceAtEnd: money("1000"), flows: []),
      rates([("2026-09-30", 90), ("2026-10-31", 95)]))
    #expect(result.total == money("5000"))
    #expect(result.pairs.map(\.key) == [usd])
  }

  @Test func theRateFalls() {
    let result = gain(
      .init(key: usd, balanceAtStart: money("1000"), balanceAtEnd: money("1000"), flows: []),
      rates([("2026-09-30", 95), ("2026-10-31", 92)]))
    #expect(result.total == money("-3000"))
  }

  @Test func aTopUpInTheMiddleIsValuedAtItsOwnDay() {
    // 1 000 $ at 90 at the start; 500 $ bought on the 15th at 93; 95 at the end:
    // end 1 500 × 95 = 142 500; start 90 000; flow 46 500 → +6 000 (5 000 on the first 1 000
    // and 1 000 on the 500 bought at 93).
    let result = gain(
      .init(
        key: usd, balanceAtStart: money("1000"), balanceAtEnd: money("1500"),
        flows: [.init(day: day("2026-10-15"), amount: money("500"))]),
      rates([("2026-09-30", 90), ("2026-10-15", 93), ("2026-10-31", 95)]))
    #expect(result.total == money("6000"))
  }

  @Test func aWithdrawalInTheMiddleIsAFlowOutAndNoLoss() {
    // Spent 400 $ on the 10th at 91; the rest 600 $ gained 5 on the start part... end 600×95=57 000;
    // start 90 000; flow −36 400 → 57 000 − 90 000 + 36 400 = 3 400.
    let result = gain(
      .init(
        key: usd, balanceAtStart: money("1000"), balanceAtEnd: money("600"),
        flows: [.init(day: day("2026-10-10"), amount: money("-400"))]),
      rates([("2026-09-30", 90), ("2026-10-10", 91), ("2026-10-31", 95)]))
    #expect(result.total == money("3400"))
  }

  @Test func theRubleAndASteadyRateGiveNothing() {
    let steady = gain(
      .init(key: usd, balanceAtStart: money("10"), balanceAtEnd: money("10"), flows: []),
      rates([("2026-09-30", 90), ("2026-10-31", 90)]))
    #expect(steady.total == .zero)
    let rubles = gain(
      .init(
        key: BalanceKey(accountId: id(1), currency: .rub), balanceAtStart: money("10"),
        balanceAtEnd: money("20"), flows: []),
      .empty)
    #expect(rubles.pairs.isEmpty && rubles.uncounted.isEmpty && rubles.unpriced.isEmpty)
  }

  @Test func aPairWithoutARateOrNotCountedIsListedAndNotGuessed() {
    let inputs: [CurrencyGain.Input] = [
      .init(key: usd, balanceAtStart: money("100"), balanceAtEnd: money("100"), flows: []),
      .init(key: eur, balanceAtStart: money("100"), balanceAtEnd: money("100"), flows: []),
      .init(
        key: BalanceKey(accountId: id(2), currency: .usd), balanceAtStart: nil,
        balanceAtEnd: money("5"), flows: []),
    ]
    let result = CurrencyGain(
      inputs: inputs, rates: rates([("2026-09-30", 90), ("2026-10-31", 91)]),
      from: day("2026-10-01"), to: day("2026-10-31"))
    #expect(result.total == money("100"))
    #expect(result.unpriced == [eur])
    #expect(result.uncounted == [BalanceKey(accountId: id(2), currency: .usd)])
  }

  @Test func theTotalIsTheSumOfThePairs() {
    let two = CurrencyGain(
      inputs: [
        .init(key: usd, balanceAtStart: money("10"), balanceAtEnd: money("10"), flows: []),
        .init(key: eur, balanceAtStart: money("10"), balanceAtEnd: money("10"), flows: []),
      ],
      rates: DayRates(series: [
        .usd: [
          DayRate(day: day("2026-09-30"), perUnit: 90),
          DayRate(day: day("2026-10-31"), perUnit: 95),
        ],
        CurrencyCode("EUR"): [
          DayRate(day: day("2026-09-30"), perUnit: 100),
          DayRate(day: day("2026-10-31"), perUnit: 98),
        ],
      ]), from: day("2026-10-01"), to: day("2026-10-31"))
    #expect(two.total == money("30"), "+50 on dollars, −20 on euros")
    #expect(two.pairs.count == 2)
  }
}

@Suite("A holiday goal turns into a trip")
struct TripGoalTests {
  @Test func theBudgetIsReadyOnlyOnceTheTargetIsGathered() {
    #expect(TripGoal.readyBudget(target: money("100000"), saved: money("99999")) == nil)
    #expect(
      TripGoal.readyBudget(target: money("100000"), saved: money("100000")) == money("100000"))
    #expect(
      TripGoal.readyBudget(target: money("100000"), saved: money("120000")) == money("120000"))
    #expect(TripGoal.readyBudget(target: .zero, saved: money("5")) == nil)
  }

  @Test func theTripMadeFromTheGoalIsATripWithItsBudgetAndDays() {
    let event = TripGoal.event(
      goalName: "Отпуск", budget: money("150000"), budgetCurrency: .rub,
      startDate: day("2027-02-01"),
      days: 10, tripCurrency: CurrencyCode("TRY"))
    #expect(event.kind == .trip && event.name == "Отпуск")
    #expect(event.endDate == day("2027-02-10"))
    #expect(event.budgetE4 == money("150000") && event.budgetCurrency == .rub)
    #expect(event.tripCurrency == CurrencyCode("TRY"))
    #expect(
      TripGoal.event(
        goalName: "x", budget: .zero, budgetCurrency: .rub, startDate: day("2027-02-01"), days: 0,
        tripCurrency: nil
      ).endDate == day("2027-02-01"))
  }
}
