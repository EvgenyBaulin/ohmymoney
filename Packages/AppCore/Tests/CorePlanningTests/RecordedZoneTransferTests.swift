import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A transfer and a count keep the zone they were recorded in, as an operation does: a transfer
/// at 01:30 on 1 December in Makassar (UTC+8) is December's, though in Moscow it is still 20:30
/// on 30 November; a count made then anchors its balances on 1 December.
@Suite("Transfers and counts are on the day of the zone they were recorded in")
struct RecordedZoneTransferTests {
  static let zone = "Asia/Makassar"
  static let makassar = TimeZone(identifier: zone)!
  /// 2026-11-30T17:30Z — 01:30 on 1 December in Makassar, 20:30 on 30 November in Moscow.
  static let night = Date(timeIntervalSince1970: 1_796_059_800)
  static let december = MonthKey(year: 2026, month: 12)
  static let firstOfDecember = DateOnly(year: 2026, month: 12, day: 1)
  static let moscow = CalendarContext.moscow
  static let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
  static let piggy = PaymentMethod(name: "Piggy", currency: .rub, piggy: true)

  static func transfer(
    from: PaymentMethod = main, to: PaymentMethod = piggy, at moment: Date = night,
    zone: String? = zone
  ) -> Transfer {
    Transfer(
      occurredAt: moment, fromAccountId: from.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 10_000), toAccountId: to.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 10_000), createdAt: moment, updatedAt: moment,
      timeZoneId: zone)
  }

  static func ledger(_ transfers: [Transfer], accounts: [PaymentMethod] = [main, piggy]) -> Ledger {
    Ledger(
      dataset: Dataset(paymentMethods: accounts, planning: PlanningBook(), transfers: transfers),
      calendar: moscow)
  }

  /// One count of `account` at `at`, made in `zone`.
  static func count(
    _ account: PaymentMethod, _ amount: Int64, at moment: Date = night, zone: String? = zone
  ) -> (Reconciliation, ReconciledBalance) {
    let reconciliation = Reconciliation(
      date: firstOfDecember, reconciledAt: moment, actualTotalRubE4: .zero, kind: .accounts,
      timeZoneId: zone)
    let balance = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: account.id, currency: .rub,
      actualE4: AmountE4(whole: amount))
    return (reconciliation, balance)
  }

  static func balances(
    counts: [(Reconciliation, ReconciledBalance)], accounts: [PaymentMethod],
    transfers: [Transfer] = [], now: Date = night.addingTimeInterval(86_400 * 5)
  ) -> AccountBalances {
    AccountBalances.build(
      entries: [], transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: counts.map(\.0), balances: counts.map(\.1), accounts: accounts,
      tree: CategoryTree(), now: now, calendar: moscow)
  }

  // MARK: - The day of a transfer and of a count

  @Test func aTransferAndACountAreReadInTheirOwnZone() {
    #expect(Self.moscow.day(of: Self.transfer()) == Self.firstOfDecember)
    #expect(
      Self.moscow.day(of: Self.transfer(zone: nil)) == DateOnly(year: 2026, month: 11, day: 30))
    #expect(Self.moscow.day(of: Self.count(Self.main, 1).0) == Self.firstOfDecember)
    // A count without a zone is on the day it was dated (see the test of an old count below).
    #expect(Self.moscow.day(of: Self.count(Self.main, 1, zone: nil).0) == Self.firstOfDecember)
    // A total has no moment: it is on the day it was dated.
    let total = Reconciliation(
      date: DateOnly(year: 2026, month: 5, day: 4), actualTotalRubE4: .zero,
      timeZoneId: Self.zone)
    #expect(Self.moscow.day(of: total) == DateOnly(year: 2026, month: 5, day: 4))
  }

  // MARK: - What a write records

  @Test func aNewTransferRecordsTheZoneOfTheDevice() {
    let plain = Self.transfer(zone: nil)
    #expect(plain.recorded(in: Self.makassar).timeZoneId == Self.zone)
    // Moscow is written as none, as every older transfer reads.
    #expect(plain.recorded(in: TravelDay.moscowZone).timeZoneId == nil)
  }

  @Test func anEditThatKeepsTheMomentKeepsTheZone() {
    let written = Self.transfer()
    var edited = written
    edited.note = "Piggy"
    edited.timeZoneId = nil
    // Edited at home, the moment kept: still Makassar's.
    #expect(
      edited.recorded(in: TravelDay.moscowZone, replacing: written).timeZoneId == Self.zone)
    // The moment moved at home: a new date of this device.
    edited.occurredAt = Self.night.addingTimeInterval(3_600)
    #expect(edited.recorded(in: TravelDay.moscowZone, replacing: written).timeZoneId == nil)
  }

  @Test func aCountRecordsTheZoneOfTheDeviceAndIsDatedByIt() {
    let rows = [
      ReconcileRow(
        key: BalanceKey(accountId: Self.main.id, currency: .rub), expected: nil,
        lastCountedAt: nil, isHeld: true)
    ]
    let calendar = CalendarContext(timeZone: Self.makassar, unrecordedZone: TravelDay.moscowZone)
    let record = AccountReconciliation.record(
      counted: [BalanceKey(accountId: Self.main.id, currency: .rub): AmountE4(whole: 5)],
      rows: rows, writeDifference: false, kind: .accounts, at: Self.night, calendar: calendar,
      tree: CategoryTree(), categories: (UUID(), UUID()), rubPerUnit: [:], makeId: { UUID() })
    #expect(record.reconciliation.timeZoneId == Self.zone)
    #expect(record.reconciliation.date == Self.firstOfDecember)
    // Back home the count is still on the day it was dated.
    #expect(Self.moscow.day(of: record.reconciliation) == record.reconciliation.date)
    let home = AccountReconciliation.record(
      counted: [BalanceKey(accountId: Self.main.id, currency: .rub): AmountE4(whole: 5)],
      rows: rows, writeDifference: false, kind: .accounts, at: Self.night,
      calendar: Self.moscow, tree: CategoryTree(), categories: (UUID(), UUID()),
      rubPerUnit: [:], makeId: { UUID() })
    #expect(home.reconciliation.timeZoneId == nil)
  }

  // MARK: - Transfers

  @Test func aNightTransferAbroadIsPutAsideInItsOwnMonth() {
    let ledger = Self.ledger([Self.transfer()])
    let december = Period.month(Self.december).range
    let november = Period.month(MonthKey(year: 2026, month: 11)).range
    #expect(
      SavingsTotals.putAside(into: Self.piggy.id, ledger: ledger, in: december).amount
        == AmountE4(whole: 10_000))
    #expect(
      SavingsTotals.putAside(into: Self.piggy.id, ledger: ledger, in: november).amount == .zero)
    #expect(
      SavingsTotals(ledger: ledger, in: december, income: .zero).accounts
        == AmountE4(whole: 10_000))
  }

  @Test func aNightContributionToTheInvestmentAccountIsOfTheYearOfItsZone() {
    let iis = PaymentMethod(name: "IIS", currency: .rub, taxDeduction: .iis)
    // 2026-12-31T17:30Z — 01:30 on 1 January 2027 in Makassar.
    let newYear = Date(timeIntervalSince1970: 1_798_738_200)
    let ledger = Self.ledger(
      [Self.transfer(to: iis, at: newYear)], accounts: [Self.main, iis])
    let next = TaxDeductionReport.year(2027, ledger: ledger, rubPerUnit: [:], income: nil)
    #expect(next.groups.first { $0.key == .iis }?.spent == AmountE4(whole: 10_000))
    let last = TaxDeductionReport.year(2026, ledger: ledger, rubPerUnit: [:], income: nil)
    #expect(last.groups.first { $0.key == .iis } == nil)
  }

  @Test func theHistoryOfAnAccountIsInTheMonthOfItsTransfersZone() {
    let records = Namesakes.financialRecords(
      accounts: [Self.main, Self.piggy], cards: [], banks: [], entries: [],
      transfers: [Self.transfer()], calendar: Self.moscow)
    let piggy = records.first { $0.record.id == Self.piggy.id }
    #expect(piggy?.record.period?.first == Self.december)
    #expect(piggy?.record.period?.last == Self.december)
  }

  @Test func aNightTransferFromACreditCardIsOnItsOwnDay() {
    let card = PaymentMethod(name: "Credit", currency: .rub)
    let ledger = Self.ledger(
      [Self.transfer(from: card, to: Self.main)], accounts: [card, Self.main])
    let moves = CreditStatements.movements(
      account: card, ledger: ledger, transfers: ledger.dataset.transfers)
    #expect(moves.map(\.day) == [Self.firstOfDecember])
  }

  // MARK: - Counts

  @Test func theFirstCountOfACreditCardOpensOnTheDayOfItsZone() {
    let card = PaymentMethod(name: "Credit", currency: .rub)
    let count = Self.count(card, -3_000)
    let balances = Self.balances(counts: [count], accounts: [card])
    let opened = CreditStatements.withOpening(
      [], account: card, balances: balances, calendar: Self.moscow)
    #expect(opened.map(\.day) == [Self.firstOfDecember])
    #expect(
      balances[BalanceKey(accountId: card.id, currency: .rub)]?.anchorDay == Self.firstOfDecember)
  }

  @Test func aCountMadeAbroadAsksAboutTheMovementsOfItsOwnDay() {
    let count = Self.count(Self.main, 100)
    let balances = Self.balances(counts: [count], accounts: [Self.main])
    let key = BalanceKey(accountId: Self.main.id, currency: .rub)
    // Typed back home for 1 December, at its noon in Moscow, after the count was made.
    let typed = Self.moscow.noon(of: Self.firstOfDecember)
    let saved = Self.night.addingTimeInterval(86_400 * 3)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: typed, savedAt: saved, keys: [key], balances: balances,
        calendar: Self.moscow) == Self.night)
    let counts = AccountReconciliation.countsOfTheDay(
      occurredAt: typed, savedAt: saved, keys: [key], balances: balances, calendar: Self.moscow)
    #expect(counts.map(\.reconciliation) == [count.0.id])
    // The evening of 30 November in Moscow is not the day of that count.
    let evening = Self.moscow.noon(of: DateOnly(year: 2026, month: 11, day: 30))
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: evening, savedAt: saved, keys: [key], balances: balances,
        calendar: Self.moscow) == nil)
  }

  @Test func theAccountsSnapshotCarriesTheDayOfTheCountsZone() {
    let count = Self.count(Self.main, 100)
    let dataset = Dataset(
      paymentMethods: [Self.main],
      planning: PlanningBook(reconciliations: [count.0], reconciledBalances: [count.1]))
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: Self.night.addingTimeInterval(86_400), calendar: Self.moscow,
      rubPerUnit: [:], localeIdentifier: "en")
    let line = snapshot.line(of: Self.main.id)
    #expect(line?.keys.first?.anchorDay == Self.firstOfDecember)
  }

  // MARK: - A copy of a period

  /// A copy of December keeps the transfer made at 01:30 on 1 December in Makassar, and a copy
  /// of November leaves it out.
  @Test func aCopyOfAPeriodCutsATransferByTheDayOfItsZone() {
    let dataset = Dataset(
      paymentMethods: [Self.main, Self.piggy], planning: PlanningBook(),
      transfers: [Self.transfer()])
    let december = Period.month(Self.december).range
    let november = Period.month(MonthKey(year: 2026, month: 11)).range
    #expect(PeriodScope.apply(december, to: dataset).transfers.count == 1)
    #expect(PeriodScope.apply(november, to: dataset).transfers.isEmpty)
  }

  /// The difference a count made abroad records is an operation of the count's own day: it is
  /// spent in December with its count, not on the evening of 30 November back home.
  @Test func theDifferenceOfACountMadeAbroadIsOnTheDayOfTheCount() throws {
    let key = BalanceKey(accountId: Self.main.id, currency: .rub)
    let rows = [ReconcileRow(key: key, expected: AmountE4(whole: 100), lastCountedAt: nil, isHeld: true)]
    let calendar = CalendarContext(timeZone: Self.makassar, unrecordedZone: TravelDay.moscowZone)
    let record = AccountReconciliation.record(
      counted: [key: AmountE4(whole: 90)], rows: rows, writeDifference: true, kind: .accounts,
      at: Self.night, calendar: calendar, tree: CategoryTree(), categories: (UUID(), UUID()),
      rubPerUnit: [.rub: 1], makeId: { UUID() })
    let difference = try #require(record.differences.first)
    #expect(difference.transaction.timeZoneId == Self.zone)
    #expect(Self.moscow.day(of: difference.transaction) == Self.firstOfDecember)
  }

  /// The difference a count settles later — following the books — is written in the count's
  /// zone too.
  @Test func aDifferenceSettledLaterKeepsTheZoneOfItsCount() throws {
    let count = ReconciledBalance(
      reconciliationId: UUID(), accountId: Self.main.id, currency: .rub,
      actualE4: AmountE4(whole: 90), expectedE4: AmountE4(whole: 100),
      differenceE4: AmountE4(whole: -10), recordsDifference: true)
    let settled = LiveCounts.settle(
      CountState(count: count, countAt: Self.night, countZoneId: Self.zone),
      expected: AmountE4(whole: 100), rate: nil,
      categories: ReconcileCategories(expense: UUID(), income: UUID()), tree: CategoryTree(),
      now: Self.night)
    guard case .create(let entry) = settled.operation else {
      Issue.record("no operation of the difference")
      return
    }
    #expect(entry.transaction.timeZoneId == Self.zone)
    #expect(Self.moscow.day(of: entry.transaction) == Self.firstOfDecember)
  }

  // MARK: - An old count, made before the zone was kept

  /// A count made at 01:40 on 1 December in Makassar by a version that kept no zone: its moment
  /// in Moscow is 30 November, but the day it was dated with on the trip — `date` — is
  /// 1 December, and that is the day it anchors on.
  @Test func anOldCountMadeOnATripAtNightIsOnTheDayItWasDated() {
    let old = Self.count(Self.main, 100, zone: nil)
    #expect(old.0.date == Self.firstOfDecember)
    #expect(Self.moscow.day(of: old.0) == Self.firstOfDecember)
    #expect(CalendarContext.system.day(of: old.0) == Self.firstOfDecember)
    // A name no system knows reads as none: the dated day too.
    var odd = old.0
    odd.timeZoneId = "Mars/Olympus"
    #expect(Self.moscow.day(of: odd) == Self.firstOfDecember)
    let balances = Self.balances(counts: [old], accounts: [Self.main])
    let key = BalanceKey(accountId: Self.main.id, currency: .rub)
    #expect(balances[key]?.anchorDay == Self.firstOfDecember)
    let typed = Self.moscow.noon(of: Self.firstOfDecember)
    let counts = AccountReconciliation.countsOfTheDay(
      occurredAt: typed, savedAt: Self.night.addingTimeInterval(86_400), keys: [key],
      balances: balances, calendar: Self.moscow)
    #expect(counts.map(\.reconciliation) == [old.0.id])
  }

  // MARK: - The answer about a count

  /// Typed back home for 1 December about a count made at 01:40 on 1 December in Makassar
  /// (still 30 November in Moscow): «Да» and «Нет» both keep the movement on the day the owner
  /// typed, as on any other count.
  @Test func theAnswerAboutACountMadeAbroadKeepsTheTypedDay() {
    let count = Self.night.addingTimeInterval(600)
    let typed = Self.moscow.noon(of: Self.firstOfDecember)
    for wasBefore in [true, false] {
      let stamp = AccountReconciliation.stamped(
        occurredAt: typed, count: count, wasBefore: wasBefore, calendar: Self.moscow)
      #expect(Self.moscow.day(of: stamp) == Self.firstOfDecember, "wasBefore: \(wasBefore)")
    }
  }

  // MARK: - The days missed

  /// The wizard of the days missed lays money out from the day of the latest count, read in the
  /// zone it was made in: a count made at 01:40 on 1 December in Makassar leaves 30 November out.
  @Test func theDaysMissedStartOnTheDayOfTheCountsZone() throws {
    let count = Self.count(Self.main, 100)
    let dataset = Dataset(
      paymentMethods: [Self.main],
      planning: PlanningBook(reconciliations: [count.0], reconciledBalances: [count.1]))
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: Self.night.addingTimeInterval(86_400 * 2), calendar: Self.moscow,
      rubPerUnit: [:], localeIdentifier: "en")
    let balance = try #require(MissedDaysWizard.balances(snapshot).first)
    let gap = MissedDays(
      lastActive: DateOnly(year: 2026, month: 11, day: 28),
      today: DateOnly(year: 2026, month: 12, day: 2))
    #expect(
      balance.days(of: gap, calendar: Self.moscow) == [
        Self.firstOfDecember, DateOnly(year: 2026, month: 12, day: 2),
      ])
  }
}
