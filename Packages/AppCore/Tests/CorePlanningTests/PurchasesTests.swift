import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The rules of the purchases: time to afford, the pause, regret, the cost of ownership, fuel,
/// discounts, waiting refunds, gifts, the price of a wish and the lines of «Стоит посмотреть».
/// Every day is written out and read in UTC, so no test depends on the zone of the machine.
enum PurchaseFx {
  static let calendar = CalendarContext.utc
  static let today = DateOnly(year: 2026, month: 10, day: 29)

  static func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  static func moment(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  static let shopping = CoreKit.Category(kind: .expense, name: "Shopping")
  static let rent = CoreKit.Category(kind: .expense, name: "Home", essential: true)
  static let tree = CategoryTree([shopping, rent])

  static func expense(
    _ whole: Int64, on day: DateOnly, category: CoreKit.Category? = shopping, note: String? = nil,
    configure: (inout Transaction) -> Void = { _ in }
  ) -> TransactionEntry {
    var transaction = Transaction(
      kind: .expense, occurredAt: moment(day), amountE4: rub(whole), note: note)
    configure(&transaction)
    let part = TransactionPart(
      transactionId: transaction.id, categoryId: category?.id, amountE4: rub(whole))
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  static func refund(_ whole: Int64, on day: DateOnly, waitingUntil: DateOnly?) -> TransactionEntry
  {
    var transaction = Transaction(
      kind: .refund, occurredAt: moment(day), amountE4: rub(whole),
      refundWaitingUntil: waitingUntil)
    transaction.note = "marketplace"
    let part = TransactionPart(
      transactionId: transaction.id, categoryId: shopping.id, amountE4: rub(whole))
    return TransactionEntry(transaction: transaction, parts: [part])
  }
}

@Suite("Time to afford a wish")
struct TimeToAffordTests {
  typealias Fx = PurchaseFx

  @Test func roundsTheMonthsUp() {
    let result = TimeToAfford.estimate(
      priceRubE4: Fx.rub(100_000), savedE4: Fx.rub(10_000), monthlySavingE4: Fx.rub(20_000),
      today: Fx.today)
    #expect(result.outcome == .months(5))
    #expect(result.remainingE4 == Fx.rub(90_000))
    #expect(result.readyIn == MonthKey(year: 2027, month: 3))
  }

  @Test func coveredPriceIsAffordableNow() {
    let result = TimeToAfford.estimate(
      priceRubE4: Fx.rub(5_000), savedE4: Fx.rub(5_000), monthlySavingE4: nil, today: Fx.today)
    #expect(result.outcome == .affordableNow)
    #expect(result.remainingE4 == .zero)
  }

  @Test func noPaceAndNoPriceAreSaidSo() {
    #expect(
      TimeToAfford.estimate(
        priceRubE4: Fx.rub(5_000), monthlySavingE4: nil, today: Fx.today
      ).outcome == .noSavingPace)
    #expect(
      TimeToAfford.estimate(
        priceRubE4: Fx.rub(5_000), monthlySavingE4: .zero, today: Fx.today
      ).outcome == .noSavingPace)
    #expect(
      TimeToAfford.estimate(priceRubE4: nil, monthlySavingE4: Fx.rub(1), today: Fx.today).outcome
        == .noPrice)
  }

  @Test func theMonthlySavingIsTheMiddleOfCanSave() {
    let forecast = MonthForecast.Remainder(
      p10: Fx.rub(5_000), middle: Fx.rub(10_000), p90: Fx.rub(15_000), lowData: false,
      computedFor: Fx.today, daysLeft: 2, windowDays: 40)
    let income = MonthIncomeEstimate(
      month: Fx.today.monthKey, received: Fx.rub(100_000), expectedRemaining: .zero, median3: nil,
      monthsInMedian: 0, value: Fx.rub(100_000), source: .expectations, lowData: false)
    let canSave = CanSave(
      CanSaveInputs(
        income: income, spentWithoutGoals: Fx.rub(40_000), plannedStillDue: Fx.rub(20_000),
        remainder: forecast, alreadySaved: .zero))
    #expect(TimeToAfford.monthlySaving(from: canSave) == Fx.rub(30_000))
    let wish = Wish(name: "Phone", priceE4: Fx.rub(60_000), createdOn: Fx.today)
    #expect(
      TimeToAfford.estimate(wish: wish, canSave: canSave, today: Fx.today).outcome == .months(2))
  }
}

@Suite("The pause before a purchase")
struct PurchasePauseTests {
  typealias Fx = PurchaseFx

  @Test func isOffByDefault() {
    #expect(
      PurchasePause.check(
        amountRubE4: Fx.rub(90_000), freeRubE4: Fx.rub(100_000), settings: PurchaseSettings())
        == .off)
  }

  @Test func asksAboveTheShareOnly() {
    let on = PurchaseSettings(pauseEnabled: true, pausePercent: 20)
    #expect(
      PurchasePause.check(amountRubE4: Fx.rub(20_000), freeRubE4: Fx.rub(100_000), settings: on)
        .shouldAsk == false)
    #expect(
      PurchasePause.check(amountRubE4: Fx.rub(20_001), freeRubE4: Fx.rub(100_000), settings: on)
        .shouldAsk)
  }

  @Test func noFreeSumAndEmptyFreeSum() {
    let on = PurchaseSettings(pauseEnabled: true)
    #expect(PurchasePause.check(amountRubE4: Fx.rub(1), freeRubE4: nil, settings: on) == .noFreeSum)
    #expect(
      PurchasePause.check(amountRubE4: Fx.rub(1), freeRubE4: Fx.rub(-5), settings: on)
        == .wait(sharePercent: nil))
  }

  @Test func theThresholdIsTheShareOfTheFreeSum() {
    #expect(
      PurchasePause.threshold(freeRubE4: Fx.rub(50_000), settings: PurchaseSettings())
        == Fx.rub(10_000))
    #expect(PurchasePause.threshold(freeRubE4: nil, settings: PurchaseSettings()) == nil)
  }
}

@Suite("Regret about purchases")
struct RegretScheduleTests {
  typealias Fx = PurchaseFx
  let threshold = PurchaseFx.rub(10_000)

  func due(
    _ entries: [TransactionEntry], settings: PurchaseSettings = PurchaseSettings()
  )
    -> [RegretQuestion]
  {
    RegretSchedule.due(
      entries: entries, tree: Fx.tree, settings: settings, thresholdRubE4: threshold,
      today: Fx.today, calendar: Fx.calendar)
  }

  @Test func asksOneDayAfterAnInessentialBigPurchase() {
    let yesterday = Fx.today.adding(days: -1)
    #expect(due([Fx.expense(15_000, on: yesterday)]).count == 1)
    #expect(due([Fx.expense(15_000, on: Fx.today)]).isEmpty)
  }

  @Test func leavesOutSmallEssentialAnsweredAndOldPurchases() {
    let yesterday = Fx.today.adding(days: -1)
    #expect(due([Fx.expense(9_000, on: yesterday)]).isEmpty)
    #expect(due([Fx.expense(50_000, on: yesterday, category: Fx.rent)]).isEmpty)
    #expect(due([Fx.expense(50_000, on: yesterday) { $0.regret = .no }]).isEmpty)
    #expect(
      due([Fx.expense(50_000, on: yesterday) { $0.regretAskedOn = yesterday }]).isEmpty)
    #expect(due([Fx.expense(50_000, on: Fx.today.adding(days: -31))]).isEmpty)
  }

  @Test func respectsTheSettings() {
    let entries = [Fx.expense(15_000, on: Fx.today.adding(days: -3))]
    #expect(due(entries, settings: PurchaseSettings(regretEnabled: false)).isEmpty)
    #expect(due(entries, settings: PurchaseSettings(regretAskAfterDays: 5)).isEmpty)
    #expect(due(entries, settings: PurchaseSettings(regretAskAfterDays: 3)).count == 1)
    #expect(
      RegretSchedule.due(
        entries: entries, tree: Fx.tree, settings: PurchaseSettings(), thresholdRubE4: nil,
        today: Fx.today, calendar: Fx.calendar
      ).isEmpty)
  }

  @Test func theOldestQuestionComesFirst() {
    let older = Fx.expense(20_000, on: Fx.today.adding(days: -5))
    let newer = Fx.expense(20_000, on: Fx.today.adding(days: -2))
    #expect(due([newer, older]).map(\.transactionId) == [older.id, newer.id])
  }

  @Test func statisticsCountAnswersByCategory() {
    let entries = [
      Fx.expense(100, on: Fx.today) { $0.regret = .yes },
      Fx.expense(100, on: Fx.today) { $0.regret = .no },
      Fx.expense(100, on: Fx.today) { $0.regret = .no },
      Fx.expense(100, on: Fx.today) { $0.regret = .skip },
      Fx.expense(100, on: Fx.today),
    ]
    let stats = RegretSchedule.statistics(entries: entries, tree: Fx.tree)
    #expect(stats.count == 1)
    #expect(stats[0].regretted == 1 && stats[0].notRegretted == 2 && stats[0].skipped == 1)
    #expect(stats[0].regretShareBp == 3_333)
  }

  @Test func recordingPutsTheAnswerAndTheDay() {
    let entry = Fx.expense(100, on: Fx.today)
    let edited = RegretSchedule.recording(.yes, on: entry.transaction, today: Fx.today)
    #expect(edited.regret == .yes && edited.regretAskedOn == Fx.today)
  }
}

@Suite("The cost of ownership")
struct OwnershipCostTests {
  typealias Fx = PurchaseFx

  @Test func monthsAreWholeAndAtLeastOne() {
    let start = DateOnly(year: 2026, month: 1, day: 15)
    #expect(
      OwnershipCost.monthsOwned(from: start, to: DateOnly(year: 2026, month: 1, day: 20)) == 1)
    #expect(
      OwnershipCost.monthsOwned(from: start, to: DateOnly(year: 2026, month: 3, day: 14)) == 1)
    #expect(
      OwnershipCost.monthsOwned(from: start, to: DateOnly(year: 2026, month: 3, day: 15)) == 2)
    #expect(
      OwnershipCost.monthsOwned(from: start, to: DateOnly(year: 2027, month: 1, day: 15)) == 12)
  }

  @Test func priceRunningCostsMinusSaleOverMonths() {
    let tag = Tag(name: "bike")
    let boughtOn = DateOnly(year: 2026, month: 1, day: 10)
    let purchase = Fx.expense(60_000, on: boughtOn) {
      $0.warrantyUntil = DateOnly(year: 2028, month: 1, day: 10)
    }
    let service = Fx.expense(3_000, on: DateOnly(year: 2026, month: 5, day: 1))
    let before = Fx.expense(999, on: DateOnly(year: 2025, month: 12, day: 1))
    var income = Transaction(
      kind: .income, occurredAt: Fx.moment(DateOnly(year: 2026, month: 7, day: 10)),
      amountE4: Fx.rub(30_000))
    income.note = "sold"
    let incomeEntry = TransactionEntry(
      transaction: income,
      parts: [TransactionPart(transactionId: income.id, amountE4: Fx.rub(30_000))])
    let links = [purchase, service, before].flatMap(\.parts).map {
      PartTag(partId: $0.id, tagId: tag.id)
    }
    let subject = OwnershipSubject(
      source: .ownedItem(UUID()), name: "Bike", priceRubE4: Fx.rub(60_000), boughtOn: boughtOn,
      soldOn: DateOnly(year: 2026, month: 7, day: 10), tagId: tag.id,
      saleTransactionId: income.id)
    let cost = OwnershipCost.compute(
      subject, entries: [purchase, service, before, incomeEntry],
      tagBook: TagBook(tags: [tag], links: links), today: Fx.today, calendar: Fx.calendar)
    #expect(cost.runningRubE4 == Fx.rub(3_000))
    #expect(cost.saleRubE4 == Fx.rub(30_000))
    #expect(cost.totalRubE4 == Fx.rub(33_000))
    #expect(cost.months == 6)
    #expect(cost.perMonthRubE4 == Fx.rub(5_500))
    #expect(cost.isSold)
    #expect(cost.warrantyUntil == DateOnly(year: 2028, month: 1, day: 10))
  }

  @Test func aNamedPurchaseIsNotCountedTwice() {
    let tag = Tag(name: "laptop")
    let day = DateOnly(year: 2026, month: 6, day: 1)
    let purchase = Fx.expense(80_000, on: day)
    let links = purchase.parts.map { PartTag(partId: $0.id, tagId: tag.id) }
    var subject = OwnershipSubject(
      source: .ownedItem(UUID()), name: "Laptop", priceRubE4: Fx.rub(80_000), boughtOn: day,
      tagId: tag.id, purchaseTransactionId: purchase.id)
    let book = TagBook(tags: [tag], links: links)
    let named = OwnershipCost.compute(
      subject, entries: [purchase], tagBook: book, today: Fx.today, calendar: Fx.calendar)
    subject.purchaseTransactionId = nil
    let found = OwnershipCost.compute(
      subject, entries: [purchase], tagBook: book, today: Fx.today, calendar: Fx.calendar)
    #expect(named.runningRubE4 == .zero)
    #expect(found.runningRubE4 == .zero)
  }

  @Test func anAssetStandsForItsFirstValuation() {
    let asset = Asset(name: "Camera", kind: .equipment)
    let valuations = [
      AssetValuation(
        assetId: asset.id, day: DateOnly(year: 2026, month: 3, day: 1), valueE4: Fx.rub(50_000)),
      AssetValuation(
        assetId: asset.id, day: DateOnly(year: 2026, month: 9, day: 1), valueE4: Fx.rub(40_000)),
    ]
    let subject = OwnershipSubject(asset: asset, valuations: valuations)
    #expect(subject.priceRubE4 == Fx.rub(50_000))
    #expect(subject.boughtOn == DateOnly(year: 2026, month: 3, day: 1))
  }

  @Test func saleClosesTheThing() {
    let item = OwnedItem(name: "Chair")
    let saleId = UUID()
    let sold = OwnershipSale.sold(item, on: Fx.today, by: saleId)
    #expect(sold.isSold && sold.saleTransactionId == saleId)
  }
}

@Suite("Fuel economy")
struct FuelEconomyTests {
  typealias Fx = PurchaseFx

  @Test(
    "Litres are read from the note",
    arguments: [
      ("бензин 45л", Decimal(45)), ("бензин 45 л", Decimal(45)),
      ("АЗС 38,5 литров", Decimal(string: "38.5")!), ("fuel 40 l", Decimal(40)),
      ("fuel 40.2L", Decimal(string: "40.2")!),
    ])
  func readsLiters(note: String, expected: Decimal) {
    #expect(FuelEconomy.liters(inNote: note) == expected)
  }

  @Test func readsNoLitersFromOtherNotes() {
    #expect(FuelEconomy.liters(inNote: "кофе 250") == nil)
    #expect(FuelEconomy.liters(inNote: nil) == nil)
    #expect(FuelEconomy.liters(inNote: "0л") == nil)
  }

  func fill(_ km: Int, liters: Decimal, cost: Int64, day: Int) -> FuelFill {
    FuelFill(
      transactionId: UUID(), day: DateOnly(year: 2026, month: 10, day: day), odometerKm: km,
      liters: liters, costRubE4: Fx.rub(cost))
  }

  @Test func litersPer100KmFromNeighbouringFills() {
    let segments = FuelEconomy.segments([
      fill(10_000, liters: 40, cost: 2_000, day: 1),
      fill(10_500, liters: 40, cost: 2_100, day: 8),
      fill(11_300, liters: 60, cost: 3_000, day: 15),
    ])
    #expect(segments.map(\.litersPer100Km) == [Decimal(8), Decimal(string: "7.5")!])
    #expect(segments[0].costPer100KmRubE4 == Fx.rub(420))
    // 100 litres over 1 300 km, not the mean of 8 and 7.5.
    #expect(FuelEconomy.average(segments) == Decimal(string: "7.69")!)
  }

  @Test func aMileageThatDidNotGrowIsSkipped() {
    let segments = FuelEconomy.segments([
      fill(10_000, liters: 40, cost: 1, day: 1), fill(10_000, liters: 40, cost: 1, day: 2),
    ])
    #expect(segments.isEmpty)
    #expect(FuelEconomy.average(segments) == nil)
  }

  @Test func fillsComeFromOperationsWithMileageAndLiters() {
    let good = Fx.expense(2_000, on: Fx.today, note: "бензин 40л") { $0.odometerKm = 10_000 }
    let noKm = Fx.expense(2_000, on: Fx.today, note: "бензин 40л")
    let noLiters = Fx.expense(2_000, on: Fx.today, note: "мойка") { $0.odometerKm = 10_100 }
    let fills = FuelEconomy.fills(entries: [good, noKm, noLiters], calendar: Fx.calendar)
    #expect(fills.map(\.transactionId) == [good.id])
  }

  @Test func asksTheMileageOnlyWhenOnAndMissing() {
    var transaction = Transaction(
      kind: .expense, occurredAt: Fx.moment(Fx.today), amountE4: Fx.rub(2_000), note: "бензин 40л")
    #expect(FuelEconomy.shouldAskMileage(transaction, settings: PurchaseSettings()))
    #expect(
      !FuelEconomy.shouldAskMileage(transaction, settings: PurchaseSettings(fuelAskMileage: false)))
    transaction.odometerKm = 5
    #expect(!FuelEconomy.shouldAskMileage(transaction, settings: PurchaseSettings()))
  }

  @Test func theVehicleCostAddsFuelAndKilometres() {
    let tag = Tag(name: "car")
    let boughtOn = DateOnly(year: 2026, month: 1, day: 1)
    let first = Fx.expense(2_000, on: DateOnly(year: 2026, month: 3, day: 1), note: "40л") {
      $0.odometerKm = 10_000
    }
    let second = Fx.expense(2_400, on: DateOnly(year: 2026, month: 4, day: 1), note: "40л") {
      $0.odometerKm = 10_500
    }
    let links = [first, second].flatMap(\.parts).map { PartTag(partId: $0.id, tagId: tag.id) }
    let subject = OwnershipSubject(
      source: .ownedItem(UUID()), name: "Car", priceRubE4: .zero, boughtOn: boughtOn, tagId: tag.id)
    let cost = VehicleCost.compute(
      subject, entries: [first, second], tagBook: TagBook(tags: [tag], links: links),
      today: Fx.today, calendar: Fx.calendar)
    #expect(cost.fuelRubE4 == Fx.rub(4_400))
    #expect(cost.distanceKm == 500)
    #expect(cost.ownership.runningRubE4 == Fx.rub(4_400))
    #expect(cost.perKmRubE4 == AmountE4(raw: 88_000))
    #expect(cost.fuelAverageLitersPer100Km == Decimal(8))
  }
}

@Suite("Discounts")
struct DiscountSavingsTests {
  typealias Fx = PurchaseFx

  @Test func sumsByMonthAndYear() {
    let entries = [
      Fx.expense(900, on: DateOnly(year: 2026, month: 9, day: 3)) { $0.discountE4 = Fx.rub(100) },
      Fx.expense(700, on: DateOnly(year: 2026, month: 10, day: 3)) { $0.discountE4 = Fx.rub(300) },
      Fx.expense(500, on: DateOnly(year: 2025, month: 10, day: 3)) { $0.discountE4 = Fx.rub(50) },
      Fx.expense(500, on: DateOnly(year: 2026, month: 10, day: 4)),
    ]
    let summary = DiscountSavings.summarize(entries: entries, calendar: Fx.calendar)
    #expect(summary.totalRubE4 == Fx.rub(450))
    #expect(summary.count == 3)
    #expect(summary.byYear[2026] == Fx.rub(400))
    #expect(summary.byMonth[MonthKey(year: 2026, month: 10)] == Fx.rub(300))
    #expect(summary.fullPriceRubE4 == Fx.rub(2_100 + 450))
    let limited = DiscountSavings.summarize(
      entries: entries, range: DayRange(DateOnly(year: 2026, month: 1, day: 1), Fx.today),
      calendar: Fx.calendar)
    #expect(limited.totalRubE4 == Fx.rub(400))
  }

  @Test func aForeignDiscountIsConvertedAtTheRateOfTheOperation() {
    var entry = Fx.expense(100, on: Fx.today)
    entry.transaction.currency = .usd
    entry.transaction.amountRubE4 = Fx.rub(9_000)
    entry.transaction.discountE4 = Fx.rub(10)
    #expect(DiscountSavings.rubles(of: entry.transaction) == Fx.rub(900))
  }

  @Test func deletedOperationsDoNotCount() {
    let entry = Fx.expense(500, on: Fx.today) {
      $0.discountE4 = Fx.rub(50)
      $0.deletedAt = Date()
    }
    #expect(DiscountSavings.summarize(entries: [entry], calendar: Fx.calendar).count == 0)
  }
}

@Suite("Refunds that are waited for")
struct WaitingRefundsTests {
  typealias Fx = PurchaseFx

  @Test func listsOnlyTheWaitingOnesSoonestFirst() {
    let late = Fx.refund(
      1_000, on: Fx.today.adding(days: -10), waitingUntil: Fx.today.adding(days: -2))
    let soon = Fx.refund(
      2_000, on: Fx.today.adding(days: -3), waitingUntil: Fx.today.adding(days: 4))
    let done = Fx.refund(500, on: Fx.today, waitingUntil: nil)
    let list = WaitingRefunds.list(entries: [soon, done, late], calendar: Fx.calendar)
    #expect(list.items.map(\.transactionId) == [late.id, soon.id])
    #expect(list.totalRubE4 == Fx.rub(3_000))
    #expect(list.impactByCategory[Fx.shopping.id] == Fx.rub(3_000))
    #expect(list.items[0].isLate(today: Fx.today))
    #expect(list.items[0].daysWaiting(today: Fx.today) == 10)
    #expect(list.items[1].daysLeft(today: Fx.today) == 4)
  }

  @Test func creditingMakesAnOrdinaryRefund() {
    let entry = Fx.refund(1_000, on: Fx.today, waitingUntil: Fx.today.adding(days: 3))
    #expect(WaitingRefunds.isWaiting(entry.transaction))
    let credited = WaitingRefunds.credited(entry.transaction)
    #expect(!WaitingRefunds.isWaiting(credited))
    #expect(
      WaitingRefunds.expecting(credited, by: Fx.today).refundWaitingUntil == Fx.today)
  }

  @Test func aWaitingRefundDoesNotReduceSpendingOrMoveMoney() {
    let purchase = Fx.expense(1_000, on: Fx.today.adding(days: -5))
    var waiting = Fx.refund(1_000, on: Fx.today, waitingUntil: Fx.today.adding(days: 3))
    waiting.parts[0].refundOfPartId = purchase.parts[0].id
    let tree = Fx.tree
    #expect(
      MyExpensesRule.contribution(part: waiting.parts[0], in: waiting.transaction) == .zero)
    #expect(!AccountBalances.movesMoney(waiting, tree: tree))
    let index = RefundIndex(entries: [purchase, waiting], debts: [:])
    #expect(index.refunded(part: purchase.parts[0].id) == .zero)
    var credited = waiting
    credited.transaction = WaitingRefunds.credited(waiting.transaction)
    #expect(AccountBalances.movesMoney(credited, tree: tree))
    let after = RefundIndex(entries: [purchase, credited], debts: [:])
    #expect(after.refunded(part: purchase.parts[0].id) == Fx.rub(1_000))
  }
}

@Suite("The calendar of gifts")
struct GiftCalendarTests {
  typealias Fx = PurchaseFx

  func person(
    _ name: String, month: Int, day: Int, year: Int? = nil, budget: AmountE4? = nil
  )
    -> Person
  {
    Person(
      name: name, birthday: Birthday(month: month, day: day, year: year), giftBudgetE4: budget)
  }

  @Test func listsTheNearestFirstAndRemindsAWeekBefore() {
    let people = [
      person("Far", month: 12, day: 20), person("Soon", month: 11, day: 3, year: 1990),
      person("Today", month: 10, day: 29), person("Passed", month: 10, day: 1),
    ]
    let days = GiftCalendar.upcoming(people: people, today: Fx.today, withinDays: 60)
    #expect(days.map(\.name) == ["Today", "Soon", "Far"])
    #expect(days[0].daysLeft == 0 && days[0].reminderDue)
    #expect(days[1].daysLeft == 5 && days[1].reminderDue && days[1].turnsAge == 36)
    #expect(!days[2].reminderDue)
  }

  @Test func theBirthdayThatPassedComesNextYear() {
    let birthday = Birthday(month: 10, day: 1)!
    #expect(
      GiftCalendar.nextOccurrence(of: birthday, from: Fx.today)
        == DateOnly(year: 2027, month: 10, day: 1))
  }

  @Test func the29thOfFebruaryFallsOnThe28thInACommonYear() {
    let leapDay = Birthday(month: 2, day: 29, year: 2000)!
    #expect(GiftCalendar.date(of: leapDay, in: 2027) == DateOnly(year: 2027, month: 2, day: 28))
    #expect(GiftCalendar.date(of: leapDay, in: 2028) == DateOnly(year: 2028, month: 2, day: 29))
    #expect(
      GiftCalendar.nextOccurrence(of: leapDay, from: Fx.today)
        == DateOnly(year: 2028, month: 2, day: 29)
        || GiftCalendar.nextOccurrence(of: leapDay, from: Fx.today)
          == DateOnly(year: 2027, month: 2, day: 28)
    )
  }

  @Test func archivedPeopleAndPeopleWithoutABirthdayAreLeftOut() {
    var archived = person("A", month: 10, day: 30)
    archived.archived = true
    let none = Person(name: "B")
    #expect(GiftCalendar.upcoming(people: [archived, none], today: Fx.today).isEmpty)
  }

  @Test func theEventCarriesTheGiftBudget() {
    let people = [person("Anya", month: 11, day: 3, budget: Fx.rub(5_000))]
    let day = GiftCalendar.upcoming(people: people, today: Fx.today)[0]
    let event = GiftCalendar.event(for: day, name: "Anya's birthday")
    #expect(event.kind == .birthday && event.budgetE4 == Fx.rub(5_000))
    #expect(event.startDate == day.date && event.endDate == day.date && event.recurringYearly)
  }
}

@Suite("The prices of a wish")
struct WishPriceTrackingTests {
  typealias Fx = PurchaseFx

  func prices(_ wish: Wish, _ values: [(Int, Int64)]) -> [WishPrice] {
    values.map {
      WishPrice(
        wishId: wish.id, onDate: Fx.today.adding(days: -$0.0), priceE4: Fx.rub($0.1))
    }
  }

  @Test func keepsLowestHighestAndLastChange() {
    var wish = Wish(name: "TV", priceE4: Fx.rub(90), createdOn: Fx.today.adding(days: -30))
    wish.priceE4 = Fx.rub(90)
    let history = prices(wish, [(30, 100), (20, 120), (10, 95)])
    let tracked = WishPriceTracking.track(wish: wish, prices: history, today: Fx.today)
    #expect(tracked.lowestE4 == Fx.rub(90) && tracked.highestE4 == Fx.rub(120))
    #expect(tracked.currentE4 == Fx.rub(90))
    #expect(tracked.lastChangeE4 == Fx.rub(-5))
    #expect(tracked.history.count == 4)
  }

  @Test func timeToBuyWhenBelowExpected() {
    let wish = Wish(name: "TV", priceE4: Fx.rub(100), createdOn: Fx.today, expectedE4: Fx.rub(100))
    let tracked = WishPriceTracking.track(wish: wish, prices: [], today: Fx.today)
    #expect(tracked.timeToBuy == .belowExpected)
  }

  @Test func timeToBuyWhenTheFallIsBigEnough() {
    let wish = Wish(name: "TV", priceE4: Fx.rub(80), createdOn: Fx.today)
    let history = prices(wish, [(20, 100)])
    let tracked = WishPriceTracking.track(
      wish: wish, prices: history, dropPercent: 15, today: Fx.today)
    #expect(tracked.fallFromHighestBp == 2_000)
    #expect(tracked.timeToBuy == .fellFromHighest(percent: 15))
    let small = WishPriceTracking.track(
      wish: wish, prices: history, dropPercent: 25, today: Fx.today)
    #expect(small.timeToBuy == nil)
  }

  @Test func aBoughtWishIsNeverTimeToBuy() {
    let wish = Wish(
      name: "TV", priceE4: Fx.rub(50), createdOn: Fx.today, boughtTransactionId: UUID(),
      expectedE4: Fx.rub(100))
    #expect(WishPriceTracking.track(wish: wish, prices: [], today: Fx.today).timeToBuy == nil)
  }

  @Test func theOutcomeComparesExpectedAndPaid() {
    let wish = Wish(name: "TV", createdOn: Fx.today, expectedE4: Fx.rub(100))
    #expect(WishOutcome.compare(wish: wish, paidE4: Fx.rub(90))?.differenceE4 == Fx.rub(-10))
    #expect(
      WishOutcome.compare(wish: Wish(name: "x", createdOn: Fx.today), paidE4: Fx.rub(1)) == nil)
  }
}

@Suite("Lines about purchases")
struct PurchaseNotesTests {
  typealias Fx = PurchaseFx

  @Test func aWishWithinTheFreeSumSpeaksMostWantedFirst() {
    let wishes = [
      Wish(name: "A", priceE4: Fx.rub(10), priority: 2, createdOn: Fx.today),
      Wish(name: "B", priceE4: Fx.rub(20), priority: 1, createdOn: Fx.today),
      Wish(name: "C", priceE4: Fx.rub(500), priority: 1, createdOn: Fx.today),
      Wish(name: "D", priceE4: Fx.rub(5), createdOn: Fx.today, boughtTransactionId: UUID()),
      Wish(name: "E", createdOn: Fx.today),
    ]
    let notes = PurchaseNotes.list(
      wishes: wishes, freeRubE4: Fx.rub(100), waiting: WaitingRefunds(items: []), gifts: [],
      regret: [], today: Fx.today)
    let names = notes.compactMap { note -> String? in
      if case .wishReady(_, let name, _) = note { return name }
      return nil
    }
    #expect(names == ["B", "A"])
  }

  @Test func aRefundSpeaksFromItsExpectedDayAndDismissalWorks() {
    let late = Fx.refund(
      1_000, on: Fx.today.adding(days: -9), waitingUntil: Fx.today.adding(days: -1))
    let soon = Fx.refund(1_000, on: Fx.today, waitingUntil: Fx.today.adding(days: 2))
    let waiting = WaitingRefunds.list(entries: [late, soon], calendar: Fx.calendar)
    let notes = PurchaseNotes.list(
      wishes: [], freeRubE4: nil, waiting: waiting, gifts: [], regret: [], today: Fx.today)
    #expect(notes.count == 1)
    if case .refundWaiting(_, _, _, _, let waited, let lateBy)? = notes.first {
      #expect(waited == 9 && lateBy == 1)
    } else {
      Issue.record("the late refund speaks")
    }
    let dismissed = PurchaseNotes.list(
      wishes: [], freeRubE4: nil, waiting: waiting, gifts: [], regret: [], today: Fx.today,
      dismissed: [notes[0].id])
    #expect(dismissed.isEmpty)
  }

  @Test func birthdaysAWeekAwayAndRegretQuestionsSpeak() {
    let near = Person(name: "Anya", birthday: Birthday(month: 11, day: 4))
    let far = Person(name: "Boris", birthday: Birthday(month: 12, day: 4))
    let gifts = GiftCalendar.upcoming(people: [near, far], today: Fx.today)
    let questions = (0..<5).map { index in
      RegretQuestion(
        transactionId: UUID(), boughtOn: Fx.today.adding(days: -index - 1), categoryId: nil,
        amountRubE4: Fx.rub(100), note: nil)
    }
    let notes = PurchaseNotes.list(
      wishes: [], freeRubE4: nil, waiting: WaitingRefunds(items: []), gifts: gifts,
      regret: questions, today: Fx.today)
    let birthdays = notes.filter { if case .birthday = $0 { true } else { false } }
    let regrets = notes.filter { if case .regret = $0 { true } else { false } }
    #expect(birthdays.count == 1)
    #expect(regrets.count == RegretSchedule.maxQuestionsAtOnce)
  }
}
