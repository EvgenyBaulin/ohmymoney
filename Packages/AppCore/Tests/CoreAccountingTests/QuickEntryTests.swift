import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

private let qUtc = CalendarContext.utc

private func qe4(_ text: String) -> AmountE4 {
  try! AmountE4(decimal: Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!)
}

private func qday(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
  DateOnly(year: year, month: month, day: day)
}

/// An operation with one part, on `on` at `hour`:`minute` UTC.
private func qEntry(
  _ amount: String, on date: DateOnly, hour: Int = 12, minute: Int = 0,
  kind: TransactionKind = .expense,
  currency: CurrencyCode = .rub, rate: Decimal? = nil, rateSource: RateSource? = nil,
  rubles: String? = nil, externalId: String? = nil, importBatchId: UUID? = nil, debtId: UUID? = nil,
  createdAt: Date? = nil, partAmounts: [String]? = nil, note: String? = nil
) -> TransactionEntry {
  let moment = qUtc.moment(date, hour: hour, minute: minute)
  let id = UUID()
  let total = qe4(amount)
  let transaction = Transaction(
    id: id, kind: kind, occurredAt: moment, currency: currency, amountE4: total, rate: rate,
    rateSource: rateSource, amountRubE4: rubles.map(qe4), note: note, debtId: debtId,
    importBatchId: importBatchId, externalId: externalId, createdAt: createdAt ?? moment,
    updatedAt: createdAt ?? moment)
  let amounts = partAmounts ?? [amount]
  let shares = amounts.map(qe4)
  let rubleShares = total.allocated(proportionallyTo: shares, outOf: total)
  let parts = zip(shares, rubleShares).map { share, rub in
    TransactionPart(transactionId: id, categoryId: UUID(), amountE4: share, amountRubE4: rub)
  }
  return TransactionEntry(transaction: transaction, parts: parts)
}

@Suite("Repeat yesterday")
struct RepeatDayTests {
  @Test func onlyWhatWasWrittenByHandIsOffered() {
    let hand = qEntry("250", on: qday(10, 12), hour: 9)
    let planned = qEntry("999", on: qday(10, 12), externalId: "sched:abc:2026-10-12")
    let reconcile = qEntry("5", on: qday(10, 12), externalId: "reconcile:x")
    let imported = qEntry("70", on: qday(10, 12), importBatchId: UUID())
    let income = qEntry("5000", on: qday(10, 12), kind: .income)
    let refund = qEntry("300", on: qday(10, 12), kind: .refund)
    let debt = qEntry("800", on: qday(10, 12), debtId: UUID())
    var deleted = qEntry("40", on: qday(10, 12))
    deleted.transaction.deletedAt = Date()
    var goal = qEntry("1000", on: qday(10, 12))
    goal.parts[0].goalId = UUID()
    let all = [hand, planned, reconcile, imported, income, refund, debt, deleted, goal]
    let found = RepeatDay.proposals(from: all, on: qday(10, 12), to: qday(10, 13), calendar: qUtc)
    #expect(found.map(\.id) == [hand.id])
  }

  @Test func theDraftIsTheSameOperationOnTheNewDayAtTheSameTime() throws {
    let source = qEntry("250", on: qday(10, 12), hour: 9, minute: 41, note: "кофе")
    let proposal = try #require(
      RepeatDay.proposals(from: [source], on: qday(10, 12), to: qday(10, 13), calendar: qUtc).first)
    #expect(proposal.isSelected)
    let draft = proposal.draft
    #expect(qUtc.day(of: draft.occurredAt) == qday(10, 13))
    #expect(qUtc.timeOfDay(draft.occurredAt) == TimeOfDay(hour: 9, minute: 41))
    #expect(draft.amount == qe4("250"))
    #expect(draft.note == "кофе")
    #expect(draft.parts.count == 1)
    #expect(draft.parts[0].amount == qe4("250"))
    #expect(draft.parts[0].categoryId == source.parts[0].categoryId)
    #expect(draft.isBalanced)
  }

  @Test func theRateAndTheAccountLegAreLeftForTheNewDay() throws {
    var source = qEntry(
      "20", on: qday(10, 12), currency: .usd, rate: 90, rateSource: .manual, rubles: "1800")
    source.transaction.accountCurrency = .rub
    source.transaction.accountAmountE4 = qe4("1800")
    let draft = try #require(
      RepeatDay.proposals(from: [source], on: qday(10, 12), to: qday(10, 13), calendar: qUtc).first?
        .draft)
    #expect(draft.currency == .usd)
    #expect(draft.rate == nil)
    #expect(draft.rateSource == nil)
    #expect(draft.accountAmount == nil)
    #expect(draft.cashback == nil)
  }

  @Test func aSplitKeepsItsParts() throws {
    let source = qEntry("1000", on: qday(10, 12), partAmounts: ["600", "400"])
    let draft = try #require(
      RepeatDay.proposals(from: [source], on: qday(10, 12), to: qday(10, 13), calendar: qUtc).first?
        .draft)
    #expect(draft.parts.map(\.amount) == [qe4("600"), qe4("400")])
    #expect(Set(draft.parts.map(\.id)).count == 2)
    #expect(!draft.parts.map(\.id).contains(source.parts[0].id))
    #expect(draft.isBalanced)
  }

  @Test func theOtherDaysAreNotOffered() {
    let before = qEntry("1", on: qday(10, 11))
    let after = qEntry("2", on: qday(10, 13))
    #expect(
      RepeatDay.proposals(
        from: [before, after], on: qday(10, 12), to: qday(10, 13), calendar: qUtc
      )
      .isEmpty)
  }

  @Test func theProposalsAreOldestFirst() {
    let late = qEntry("2", on: qday(10, 12), hour: 20)
    let early = qEntry("1", on: qday(10, 12), hour: 8)
    let found = RepeatDay.proposals(
      from: [late, early], on: qday(10, 12), to: qday(10, 13), calendar: qUtc)
    #expect(found.map(\.id) == [early.id, late.id])
  }

  @Test func theDayIsThatOfTheZoneTheOperationWasRecordedIn() throws {
    // 21:30 UTC is already the next day in Bali (UTC+8).
    var bali = qEntry("500", on: qday(10, 12), hour: 21, minute: 30)
    bali.transaction.timeZoneId = "Asia/Makassar"
    let found = RepeatDay.proposals(
      from: [bali], on: qday(10, 13), to: qday(10, 14), calendar: qUtc)
    let draft = try #require(found.first?.draft)
    let zone = CalendarContext(timeZone: TimeZone(identifier: "Asia/Makassar")!)
    #expect(zone.day(of: draft.occurredAt) == qday(10, 14))
    #expect(zone.timeOfDay(draft.occurredAt) == TimeOfDay(hour: 5, minute: 30))
    #expect(
      RepeatDay.proposals(from: [bali], on: qday(10, 12), to: qday(10, 14), calendar: qUtc).isEmpty)
  }
}

@Suite("Oops: which operation, which amount")
struct LastCorrectionTests {
  let now = qUtc.moment(qday(10, 14), hour: 12, minute: 0)

  @Test func theLastWrittenWinsByTheTimeItWasWritten() {
    // An older operation by date, written later.
    let byDate = qEntry("1", on: qday(10, 14), createdAt: now.addingTimeInterval(-600))
    let byWriting = qEntry("2", on: qday(10, 1), createdAt: now.addingTimeInterval(-60))
    guard case .recent(let found) = CorrectionTarget.find(in: [byDate, byWriting], now: now) else {
      Issue.record("not recent")
      return
    }
    #expect(found.id == byWriting.id)
  }

  @Test func anOldWritingIsAskedAbout() {
    let old = qEntry("1", on: qday(10, 13), createdAt: now.addingTimeInterval(-3_601))
    guard case .stale(let found) = CorrectionTarget.find(in: [old], now: now) else {
      Issue.record("not stale")
      return
    }
    #expect(found.id == old.id)
    let fresh = qEntry("1", on: qday(10, 13), createdAt: now.addingTimeInterval(-3_599))
    guard case .recent = CorrectionTarget.find(in: [fresh], now: now) else {
      Issue.record("not recent")
      return
    }
  }

  @Test func whatTheApplicationWroteIsNotWhatTheOwnerMeans() {
    let planned = qEntry("1", on: qday(10, 14), externalId: "sched:x", createdAt: now)
    let imported = qEntry("1", on: qday(10, 14), importBatchId: UUID(), createdAt: now)
    var deleted = qEntry("1", on: qday(10, 14), createdAt: now)
    deleted.transaction.deletedAt = now
    #expect(CorrectionTarget.find(in: [planned, imported, deleted], now: now) == .none)
    #expect(CorrectionTarget.find(in: [], now: now) == .none)
  }

  @Test func anIncomeCanBeCorrectedToo() {
    let income = qEntry("5000", on: qday(10, 14), kind: .income, createdAt: now)
    guard case .recent = CorrectionTarget.find(in: [income], now: now) else {
      Issue.record("not recent")
      return
    }
  }

  @Test func theAmountChangesAndNothingElse() throws {
    let source = qEntry("250", on: qday(10, 14), note: "кофе")
    let fixed = try CorrectedAmount.apply(source, amount: 350, expression: nil, now: now).get()
    #expect(fixed.transaction.amountE4 == qe4("350"))
    #expect(fixed.transaction.amountRubE4 == qe4("350"))
    #expect(fixed.parts[0].amountE4 == qe4("350"))
    #expect(fixed.parts[0].amountRubE4 == qe4("350"))
    #expect(fixed.transaction.note == "кофе")
    #expect(fixed.transaction.updatedAt == now)
    #expect(fixed.parts[0].categoryId == source.parts[0].categoryId)
    #expect(fixed.isBalanced)
  }

  @Test func theFormulaIsKept() throws {
    let source = qEntry("250", on: qday(10, 14))
    let fixed = try CorrectedAmount.apply(source, amount: 800, expression: "(1000+600)/2", now: now)
      .get()
    #expect(fixed.transaction.amountExpr == "(1000+600)/2")
  }

  @Test func aSplitKeepsItsProportions() throws {
    let source = qEntry("1000", on: qday(10, 14), partAmounts: ["600", "400"])
    let fixed = try CorrectedAmount.apply(source, amount: 500, now: now).get()
    #expect(fixed.parts.map(\.amountE4) == [qe4("300"), qe4("200")])
    #expect(fixed.isBalanced)
  }

  @Test func rubleSharesStillAddUpToTheOperationWithAnOddCount() throws {
    let source = qEntry("30", on: qday(10, 14), partAmounts: ["10", "10", "10"])
    let fixed = try CorrectedAmount.apply(source, amount: qdec("100.01"), now: now).get()
    #expect(AmountE4.sum(fixed.parts.map(\.amountE4)) == fixed.transaction.amountE4)
    #expect(AmountE4.sum(fixed.parts.map(\.amountRubE4)) == fixed.transaction.amountRubE4)
    #expect(fixed.parts.allSatisfy { $0.amountE4 > .zero })
  }

  @Test func aForeignAmountIsPricedByTheRateItHas() throws {
    let source = qEntry(
      "20", on: qday(10, 14), currency: .usd, rate: 90, rateSource: .manual, rubles: "1800")
    let fixed = try CorrectedAmount.apply(source, amount: 30, now: now).get()
    #expect(fixed.transaction.amountE4 == qe4("30"))
    #expect(fixed.transaction.amountRubE4 == qe4("2700"))
    #expect(fixed.transaction.rate == 90)
    #expect(fixed.transaction.rateSource == .manual)
    #expect(fixed.parts[0].amountRubE4 == qe4("2700"))
  }

  @Test func withoutARateTheCostOfAUnitPricesIt() throws {
    let source = qEntry("20", on: qday(10, 14), currency: .usd, rubles: "1800")
    let fixed = try CorrectedAmount.apply(source, amount: 10, now: now).get()
    #expect(fixed.transaction.amountRubE4 == qe4("900"))
  }

  @Test func aChargeInRublesOnTheAccountFollows() throws {
    var source = qEntry("20", on: qday(10, 14), currency: .usd, rate: 90, rubles: "1800")
    source.transaction.accountCurrency = .rub
    source.transaction.accountAmountE4 = qe4("1800")
    let fixed = try CorrectedAmount.apply(source, amount: 30, now: now).get()
    #expect(fixed.transaction.accountAmountE4 == qe4("2700"))
  }

  @Test func aChargeInTheOperationsOwnCurrencyFollowsToo() throws {
    var source = qEntry("20", on: qday(10, 14), currency: .usd, rate: 90, rubles: "1800")
    source.transaction.accountCurrency = .usd
    source.transaction.accountAmountE4 = qe4("20")
    let fixed = try CorrectedAmount.apply(source, amount: 25, now: now).get()
    #expect(fixed.transaction.accountAmountE4 == qe4("25"))
  }

  @Test func theBanksFigureForAnotherCurrencyIsNeverGuessed() {
    var source = qEntry("20", on: qday(10, 14), currency: .usd, rate: 90, rubles: "1800")
    source.transaction.accountCurrency = .eur
    source.transaction.accountAmountE4 = qe4("18")
    #expect(CorrectedAmount.apply(source, amount: 30, now: now) == .failure(.accountAmountUnknown))
  }

  @Test func refusals() {
    let source = qEntry("250", on: qday(10, 14))
    #expect(CorrectedAmount.apply(source, amount: 0, now: now) == .failure(.notAnAmount))
    #expect(CorrectedAmount.apply(source, amount: -5, now: now) == .failure(.notAnAmount))
    #expect(
      CorrectedAmount.apply(source, amount: 5, currency: .usd, now: now) == .failure(.otherCurrency)
    )
    var noRate = qEntry("20", on: qday(10, 14), currency: .usd)
    noRate.transaction.amountRubE4 = .zero
    #expect(CorrectedAmount.apply(noRate, amount: 5, now: now) == .failure(.noRate))
    #expect(
      CorrectedAmount.apply(source, amount: qdec("1000000000000.5"), now: now)
        == .failure(.notAnAmount))
  }

  @Test func whatMovesADebtOrASettlementIsNotCorrectedQuietly() {
    let debtPayment = qEntry("800", on: qday(10, 14), debtId: UUID())
    #expect(CorrectedAmount.apply(debtPayment, amount: 5, now: now) == .failure(.debtOperation))
    var onCredit = qEntry("800", on: qday(10, 14))
    onCredit.transaction.creditDebtId = UUID()
    #expect(CorrectedAmount.apply(onCredit, amount: 5, now: now) == .failure(.debtOperation))
    let moneyBack = qEntry("800", on: qday(10, 14), kind: .reimbursement)
    #expect(CorrectedAmount.apply(moneyBack, amount: 5, now: now) == .failure(.moneyBack))
    var refund = qEntry("300", on: qday(10, 14), kind: .refund)
    refund.parts[0].refundOfPartId = UUID()
    #expect(CorrectedAmount.apply(refund, amount: 5, now: now) == .failure(.settledParts))
    var returned = qEntry("300", on: qday(10, 14))
    returned.parts[0].reimbursable = true
    returned.parts[0].reimbursementStatus = .returned
    #expect(CorrectedAmount.apply(returned, amount: 5, now: now) == .failure(.settledParts))
    returned.parts[0].reimbursementStatus = .writtenOff
    #expect(CorrectedAmount.apply(returned, amount: 5, now: now) == .failure(.settledParts))
  }

  @Test func aPartSomethingLeansOnIsRefused() {
    let source = qEntry("300", on: qday(10, 14))
    let leaned: Set<UUID> = [source.parts[0].id]
    #expect(
      CorrectedAmount.apply(source, amount: 5, leaned: leaned, now: now) == .failure(.partsLeanedOn)
    )
    #expect(
      CorrectedAmount.apply(source, amount: 5, leaned: [UUID()], now: now)
        != .failure(.partsLeanedOn))
  }

  @Test func aPartPaidForSomebodyWhoHasNotPaidBackIsCorrected() throws {
    var source = qEntry("300", on: qday(10, 14))
    source.parts[0].reimbursable = true
    source.parts[0].reimbursementStatus = .expected
    let fixed = try CorrectedAmount.apply(source, amount: 350, now: now).get()
    #expect(fixed.parts[0].amountE4 == qe4("350"))
  }

  @Test func theSameCurrencyNamedIsFine() {
    let source = qEntry("250", on: qday(10, 14))
    #expect(throws: Never.self) {
      _ = try CorrectedAmount.apply(source, amount: 5, currency: .rub, now: now).get()
    }
  }
}

@Suite("Splitting by dragging")
struct SplitBarTests {
  @Test func aBorderStopsAtEveryTenRubles() throws {
    let bar = try #require(SplitBar(total: qe4("2340")))
    #expect(bar.step == qe4("10"))
    #expect(bar.snapped(first: qe4("1234")) == qe4("1230"))
    #expect(bar.snapped(first: qe4("1235")) == qe4("1240"))
    #expect(bar.snapped(first: qe4("1236")) == qe4("1240"))
  }

  @Test func theBorderStaysInsideTheBar() throws {
    let bar = try #require(SplitBar(total: qe4("2340")))
    #expect(bar.snapped(first: .zero) == qe4("10"))
    #expect(bar.snapped(first: qe4("-50")) == qe4("10"))
    #expect(bar.snapped(first: qe4("2340")) == qe4("2330"))
    #expect(bar.snapped(first: qe4("9999")) == qe4("2330"))
  }

  @Test func theFractionGivesTwoPartsThatAddUp() throws {
    let bar = try #require(SplitBar(total: qe4("2340")))
    let halves = bar.parts(atFraction: qdec("0.5"))
    #expect(halves.first == qe4("1170"))
    #expect(halves.second == qe4("1170"))
    let third = bar.parts(atFraction: qdec("0.3333"))
    #expect(third.first + third.second == qe4("2340"))
    #expect(bar.parts(atFraction: -1).first == qe4("10"))
    #expect(bar.parts(atFraction: 7).second == qe4("10"))
  }

  @Test func theRemainderOfAnOddTotalIsInTheLastPart() throws {
    let bar = try #require(SplitBar(total: qe4("2345.67")))
    let parts = bar.parts(atFraction: qdec("0.5"))
    #expect(parts.first == qe4("1170"))
    #expect(parts.second == qe4("1175.67"))
  }

  @Test func aSmallBarHasFinerStops() throws {
    #expect(try #require(SplitBar(total: qe4("10"))).step == qe4("1"))
    #expect(try #require(SplitBar(total: qe4("1"))).step == qe4("0.01"))
    #expect(try #require(SplitBar(total: qe4("10.01"))).step == qe4("10"))
    #expect(SplitBar(total: qe4("0.01")) == nil)
    #expect(SplitBar(total: .zero) == nil)
  }

  @Test func theExactAmountIsTypedToTheKopek() throws {
    let bar = try #require(SplitBar(total: qe4("2340")))
    let parts = try #require(bar.parts(exactFirst: qe4("1234.56")))
    #expect(parts.first == qe4("1234.56"))
    #expect(parts.second == qe4("1105.44"))
    #expect(bar.parts(exactFirst: .zero) == nil)
    #expect(bar.parts(exactFirst: qe4("2340")) == nil)
    #expect(bar.parts(exactFirst: qe4("-1")) == nil)
  }

  @Test func severalBordersMakePartsThatAddUp() throws {
    let bar = try #require(SplitBar(total: qe4("2340")))
    let parts = try #require(bar.parts(atFractions: [qdec("0.25"), qdec("0.5"), qdec("0.9")]))
    #expect(parts.count == 4)
    #expect(AmountE4.sum(parts) == qe4("2340"))
    #expect(parts.allSatisfy { $0 >= qe4("10") })
    #expect(parts.dropLast().allSatisfy { $0.raw % qe4("10").raw == 0 })
  }

  @Test func bordersThatMeetAreMovedApart() throws {
    let bar = try #require(SplitBar(total: qe4("100")))
    let parts = try #require(bar.parts(atFractions: [qdec("0.5"), qdec("0.5"), qdec("0.5")]))
    #expect(parts.count == 4)
    #expect(AmountE4.sum(parts) == qe4("100"))
    #expect(parts.allSatisfy { $0 >= qe4("10") })
  }

  @Test func bordersAtTheEndAreMovedBack() throws {
    let bar = try #require(SplitBar(total: qe4("100")))
    let parts = try #require(bar.parts(atFractions: [qdec("1"), qdec("1")]))
    #expect(parts.count == 3)
    #expect(AmountE4.sum(parts) == qe4("100"))
    #expect(parts.allSatisfy { $0 >= qe4("10") })
  }

  @Test func thereIsNoRoomForMoreThanTheStepsAllow() throws {
    let bar = try #require(SplitBar(total: qe4("30")))
    #expect(bar.parts(atFractions: [qdec("0.3"), qdec("0.6")])?.count == 3)
    #expect(bar.parts(atFractions: [qdec("0.2"), qdec("0.4"), qdec("0.6")]) == nil)
    #expect(bar.parts(atFractions: []) == [qe4("30")])
  }

  @Test(arguments: [
    qdec("0"), qdec("0.01"), qdec("0.2"), qdec("0.5"), qdec("0.77"), qdec("0.99"), qdec("1"),
  ])
  func manyTotalsAlwaysSplitToTheUnit(_ fraction: Decimal) throws {
    for raw in stride(from: Int64(200_000), through: 3_000_000_000, by: 7_777_777) {
      guard let bar = SplitBar(total: AmountE4(raw: raw)) else { continue }
      let parts = bar.parts(atFraction: fraction)
      #expect(parts.first + parts.second == bar.total)
      #expect(parts.first > .zero && parts.second > .zero)
    }
  }
}

@Suite("Moving an operation to another day")
struct MoveToDayTests {
  let today = qday(10, 14)

  func transaction(
    _ date: DateOnly, hour: Int = 19, minute: Int = 45, currency: CurrencyCode = .rub,
    source: RateSource? = nil
  )
    -> Transaction
  {
    qEntry(
      "3500", on: date, hour: hour, minute: minute, currency: currency,
      rate: currency == .rub ? nil : 90, rateSource: source,
      rubles: currency == .rub ? nil : "315000"
    ).transaction
  }

  @Test func theClockTimeStaysOnTheNewDay() throws {
    let plan = try #require(
      MoveToDay.plan(for: transaction(qday(10, 13)), to: qday(10, 12), today: today, calendar: qUtc)
    )
    #expect(qUtc.day(of: plan.occurredAt) == qday(10, 12))
    #expect(qUtc.timeOfDay(plan.occurredAt) == TimeOfDay(hour: 19, minute: 45))
    #expect(plan.fromDay == qday(10, 13))
    #expect(plan.toDay == qday(10, 12))
  }

  @Test func theSameDayIsNoMove() {
    #expect(
      MoveToDay.plan(for: transaction(qday(10, 13)), to: qday(10, 13), today: today, calendar: qUtc)
        == nil)
  }

  @Test func aMonthChangeIsReported() throws {
    let across = try #require(
      MoveToDay.plan(for: transaction(qday(10, 1)), to: qday(9, 30), today: today, calendar: qUtc))
    #expect(across.changesMonth)
    let within = try #require(
      MoveToDay.plan(for: transaction(qday(10, 5)), to: qday(10, 4), today: today, calendar: qUtc))
    #expect(!within.changesMonth)
  }

  @Test func theBanksRateIsReplacedButAHandTypedOneStays() throws {
    let bank = try #require(
      MoveToDay.plan(
        for: transaction(qday(10, 13), currency: .usd, source: .cbr), to: qday(10, 12),
        today: today,
        calendar: qUtc))
    #expect(bank.needsRateOfNewDay)
    let typed = try #require(
      MoveToDay.plan(
        for: transaction(qday(10, 13), currency: .usd, source: .manual), to: qday(10, 12),
        today: today, calendar: qUtc))
    #expect(!typed.needsRateOfNewDay)
    let imported = try #require(
      MoveToDay.plan(
        for: transaction(qday(10, 13), currency: .usd, source: .imported), to: qday(10, 12),
        today: today, calendar: qUtc))
    #expect(!imported.needsRateOfNewDay)
    let rubles = try #require(
      MoveToDay.plan(for: transaction(qday(10, 13)), to: qday(10, 12), today: today, calendar: qUtc)
    )
    #expect(!rubles.needsRateOfNewDay)
  }

  @Test func aDayAfterTodayIsAhead() throws {
    let ahead = try #require(
      MoveToDay.plan(for: transaction(qday(10, 13)), to: qday(10, 20), today: today, calendar: qUtc)
    )
    #expect(ahead.isAhead)
    let todayPlan = try #require(
      MoveToDay.plan(for: transaction(qday(10, 13)), to: today, today: today, calendar: qUtc))
    #expect(!todayPlan.isAhead)
  }

  @Test func theClockOfTheRecordingZoneIsKept() throws {
    var bali = transaction(qday(10, 13), hour: 15, minute: 30)  // 23:30 in Bali
    bali.timeZoneId = "Asia/Makassar"
    let plan = try #require(
      MoveToDay.plan(for: bali, to: qday(10, 12), today: today, calendar: qUtc))
    let zone = CalendarContext(timeZone: TimeZone(identifier: "Asia/Makassar")!)
    #expect(zone.day(of: plan.occurredAt) == qday(10, 12))
    #expect(zone.timeOfDay(plan.occurredAt) == TimeOfDay(hour: 23, minute: 30))
  }
}

@Suite("Lines for later")
struct DraftReminderTests {
  func draft(_ text: String, at date: Date, resolved: Bool = false) -> PendingDraft {
    PendingDraft(text: text, createdAt: date, resolvedAt: resolved ? date : nil)!
  }

  @Test func theRowAppearsFromNineInTheEvening() {
    let morning = qUtc.moment(qday(10, 14), hour: 9, minute: 0)
    let drafts = [draft("а", at: morning), draft("б", at: morning.addingTimeInterval(60))]
    #expect(
      DraftReminder.line(
        drafts: drafts, now: qUtc.moment(qday(10, 14), hour: 20, minute: 59), calendar: qUtc) == nil
    )
    #expect(
      DraftReminder.line(
        drafts: drafts, now: qUtc.moment(qday(10, 14), hour: 21, minute: 0), calendar: qUtc)?.count
        == 2)
    #expect(
      DraftReminder.line(
        drafts: drafts, now: qUtc.moment(qday(10, 14), hour: 23, minute: 59), calendar: qUtc)?.count
        == 2)
  }

  @Test func resolvedLinesAreNotCounted() {
    let morning = qUtc.moment(qday(10, 14), hour: 9, minute: 0)
    let drafts = [draft("а", at: morning), draft("б", at: morning, resolved: true)]
    #expect(
      DraftReminder.line(
        drafts: drafts, now: qUtc.moment(qday(10, 14), hour: 22, minute: 0), calendar: qUtc)?.count
        == 1)
    #expect(
      DraftReminder.line(
        drafts: [drafts[1]], now: qUtc.moment(qday(10, 14), hour: 22, minute: 0), calendar: qUtc)
        == nil)
    #expect(
      DraftReminder.line(
        drafts: [], now: qUtc.moment(qday(10, 14), hour: 22, minute: 0), calendar: qUtc) == nil)
  }

  @Test func waitingLinesAreOldestFirst() {
    let base = qUtc.moment(qday(10, 14), hour: 9, minute: 0)
    let late = draft("поздно", at: base.addingTimeInterval(100))
    let early = draft("рано", at: base)
    #expect(DraftReminder.waiting([late, early]).map(\.text) == ["рано", "поздно"])
  }

  @Test func theNextReminderIsTheNext9pm() {
    let morning = qUtc.moment(qday(10, 14), hour: 9, minute: 0)
    #expect(
      DraftReminder.nextFire(after: morning, calendar: qUtc)
        == qUtc.moment(qday(10, 14), hour: 21, minute: 0))
    let exactly = qUtc.moment(qday(10, 14), hour: 21, minute: 0)
    #expect(
      DraftReminder.nextFire(after: exactly, calendar: qUtc)
        == qUtc.moment(qday(10, 15), hour: 21, minute: 0))
    let night = qUtc.moment(qday(10, 14), hour: 23, minute: 30)
    #expect(
      DraftReminder.nextFire(after: night, calendar: qUtc)
        == qUtc.moment(qday(10, 15), hour: 21, minute: 0))
  }

  @Test func theReminderCrossesTheEndOfAMonth() {
    let lastDay = qUtc.moment(qday(10, 31), hour: 22, minute: 0)
    #expect(
      DraftReminder.nextFire(after: lastDay, calendar: qUtc)
        == qUtc.moment(qday(11, 1), hour: 21, minute: 0))
  }
}

private func qdec(_ text: String) -> Decimal {
  Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}
