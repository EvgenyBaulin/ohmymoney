import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The first count is the truth. A count of a pair that rested only on the zero openings older
/// versions wrote for empty fields — and the first reconciliation of one total after zero ones —
/// is offered to be made the starting point it was; a new count of such a pair is one by
/// default. A zero written in 1.2 is a real count.
@Suite("The first count: candidates, the fix and the sheet's starting point")
struct FirstCountFixTests {
  private static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "F1C00000-0000-0000-0000-%012d", number))!
  }
  private static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  private static func at(_ iso: String, _ hour: Int) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(TimeInterval(hour * 3_600))
  }
  private static func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private let cash = PaymentMethod(id: id(1), name: "Cash", kind: .cash, currency: .rub)
  private let card = PaymentMethod(
    id: id(2), name: "Т-Банк", currency: .rub, isDefault: true)
  private var cashKey: BalanceKey { BalanceKey(accountId: cash.id, currency: .rub) }
  private var cardKey: BalanceKey { BalanceKey(accountId: card.id, currency: .rub) }

  /// An opening of `accounts` at `hour` of `iso`, from `origin` (`nil`: written before 1.2).
  private func opening(
    _ number: Int, _ iso: String, _ hour: Int, origin: ReconciliationOrigin? = nil,
    _ counts: [(UUID, Int64)]
  ) -> (Reconciliation, [ReconciledBalance]) {
    let reconciliation = Reconciliation(
      id: Self.id(number), date: Self.day(iso), reconciledAt: Self.at(iso, hour),
      actualTotalRubE4: .zero, kind: .opening, origin: origin)
    let balances = counts.enumerated().map { index, count in
      ReconciledBalance(
        id: Self.id(number * 10 + index), reconciliationId: reconciliation.id,
        accountId: count.0, currency: .rub, actualE4: Self.money(count.1))
    }
    return (reconciliation, balances)
  }

  /// A sheet of `accounts` counting `actual` against `expected` at `hour` of `iso`, its
  /// difference recorded by `operation`.
  private func sheet(
    _ number: Int, _ iso: String, _ hour: Int, account: UUID, actual: Int64, expected: Int64,
    operation: UUID? = nil
  ) -> (Reconciliation, [ReconciledBalance]) {
    let reconciliation = Reconciliation(
      id: Self.id(number), date: Self.day(iso), reconciledAt: Self.at(iso, hour),
      actualTotalRubE4: Self.money(actual), kind: .accounts)
    let balance = ReconciledBalance(
      id: Self.id(number * 10), reconciliationId: reconciliation.id, accountId: account,
      currency: .rub, actualE4: Self.money(actual), expectedE4: Self.money(expected),
      differenceE4: Self.money(actual - expected), transactionId: operation,
      recordsDifference: true)
    return (reconciliation, [balance])
  }

  private func total(
    _ number: Int, _ iso: String, actual: Int64, difference: Int64?, operation: UUID? = nil
  ) -> Reconciliation {
    Reconciliation(
      id: Self.id(number), date: Self.day(iso), actualTotalRubE4: Self.money(actual),
      expectedTotalRubE4: difference.map { Self.money(actual - $0) },
      differenceE4: difference.map(Self.money), transactionId: operation, kind: .total)
  }

  private func expense(
    _ number: Int, _ iso: String, _ amount: Int64, on account: UUID
  )
    -> TransactionEntry
  {
    let when = Self.at(iso, 12)
    let id = Self.id(1_000 + number)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: when, currency: .rub, amountE4: Self.money(amount),
        amountRubE4: Self.money(amount), paymentMethodId: account, createdAt: when,
        updatedAt: when),
      parts: [
        TransactionPart(
          id: Self.id(2_000 + number), transactionId: id, quality: .neutral,
          qualitySource: .category, amountE4: Self.money(amount),
          amountRubE4: Self.money(amount))
      ])
  }

  private func book(
    _ pieces: [(Reconciliation, [ReconciledBalance])], totals: [Reconciliation] = [],
    entries: [TransactionEntry] = [], now: Date = at("2026-09-30", 12)
  ) -> (PlanningBook, AccountBalances) {
    let reconciliations = (totals + pieces.map(\.0)).sorted {
      ($0.date, $0.reconciledAt ?? .distantPast) < ($1.date, $1.reconciledAt ?? .distantPast)
    }
    let counted = pieces.flatMap(\.1)
    let book = PlanningBook(reconciliations: reconciliations, reconciledBalances: counted)
    let balances = AccountBalances.build(
      entries: entries, transfers: [], debtEntries: [], debts: [:],
      reconciliations: reconciliations, balances: counted, accounts: [card, cash],
      tree: CategoryTree(), now: now, calendar: .utc)
    return (book, balances)
  }

  // MARK: Candidates

  /// The owner's own case: «Cash» left empty in the setup of 20.09 (0 ₽), first counted at
  /// 3,500 on 26.09 and recorded as «Сверка» income: a candidate, with its live operation.
  @Test func aCountAfterZeroOpeningsIsACandidate() throws {
    let operation = Self.id(900)
    let (book, balances) = book([
      opening(1, "2026-09-20", 6, [(cash.id, 0), (card.id, 50_000)]),
      sheet(
        2, "2026-09-26", 12, account: cash.id, actual: 3_500, expected: 0, operation: operation),
    ])
    let found = FirstCountFix.candidates(
      book: book, balances: balances, liveOperations: [operation], kept: [])
    #expect(found.count == 1)
    let candidate = try #require(found.first)
    #expect(candidate.id == Self.id(20))
    #expect(candidate.key == cashKey)
    #expect(candidate.difference == Self.money(3_500))
    #expect(candidate.currency == .rub)
    #expect(candidate.day == Self.day("2026-09-26"))
    #expect(candidate.operationId == operation)

    // Its operation already in the bin: still a candidate, with nothing to take back.
    let binned = FirstCountFix.candidates(
      book: book, balances: balances, liveOperations: [], kept: [])
    #expect(binned.map(\.id) == [Self.id(20)])
    #expect(binned.first?.operationId == nil)
  }

  /// A pair counted at a real balance before — an opening of 1,000, or an earlier sheet — has
  /// a real difference at its next count.
  @Test func aCountAfterARealOpeningIsNot() {
    let (book, balances) = book([
      opening(1, "2026-09-20", 6, [(cash.id, 1_000)]),
      sheet(2, "2026-09-26", 12, account: cash.id, actual: 3_500, expected: 1_000),
    ])
    #expect(
      FirstCountFix.candidates(book: book, balances: balances, liveOperations: [], kept: [])
        .isEmpty)

    // Zero opening, a sheet, then another sheet: only the first sheet rests on the zero.
    let (second, secondBalances) = self.book([
      opening(1, "2026-09-20", 6, [(cash.id, 0)]),
      sheet(2, "2026-09-22", 12, account: cash.id, actual: 2_000, expected: 0),
      sheet(3, "2026-09-26", 12, account: cash.id, actual: 1_500, expected: 2_000),
    ])
    #expect(
      FirstCountFix.candidates(
        book: second, balances: secondBalances, liveOperations: [], kept: []
      ).map(\.id) == [Self.id(20)])
  }

  /// A zero typed in the setup of 1.2 is a real count: its pair compares as usual, the count
  /// after it is no candidate, and the sheet offers no starting point for it.
  @Test func aTypedZeroOfOneTwoComparesAsUsual() {
    let (book, balances) = book([
      opening(1, "2026-09-20", 6, origin: .setup, [(cash.id, 0)]),
      sheet(2, "2026-09-26", 12, account: cash.id, actual: 500, expected: 0),
    ])
    #expect(
      FirstCountFix.candidates(book: book, balances: balances, liveOperations: [], kept: [])
        .isEmpty)
    let rows = [
      ReconcileRow(key: cashKey, expected: .zero, lastCountedAt: nil, isHeld: true)
    ]
    #expect(
      FirstCountFix.startingPointKeys(
        rows, balances: balances, reconciliations: book.reconciliations
      ).isEmpty)
    // The same zero given to a new account in 1.2.
    let (account, accountBalances) = self.book([
      opening(1, "2026-09-20", 6, origin: .account, [(cash.id, 0)])
    ])
    #expect(
      FirstCountFix.startingPointKeys(
        rows, balances: accountBalances, reconciliations: account.reconciliations
      ).isEmpty)
  }

  /// A zero a merge of 1.2 left on the source is a real count too.
  @Test func aMergeZeroIsNoCandidate() {
    let (book, balances) = book([
      opening(1, "2026-09-20", 6, origin: .merge, [(cash.id, 0)]),
      sheet(2, "2026-09-26", 12, account: cash.id, actual: 700, expected: 0),
    ])
    #expect(
      FirstCountFix.candidates(book: book, balances: balances, liveOperations: [], kept: [])
        .isEmpty)
  }

  /// The first reconciliation of one total (1.0.0) with a difference is a candidate, and so is
  /// one after totals of zero; one after a total of money is not, nor one without a difference.
  @Test func aFirstLegacyTotalWithADifferenceIsACandidate() throws {
    let operation = Self.id(901)
    let (book, balances) = book(
      [], totals: [total(1, "2026-08-20", actual: 98_800, difference: 98_800, operation: operation)]
    )
    let found = FirstCountFix.candidates(
      book: book, balances: balances, liveOperations: [operation], kept: [])
    let candidate = try #require(found.first)
    #expect(found.count == 1)
    #expect(candidate.id == Self.id(1))
    #expect(candidate.key == nil)
    #expect(candidate.currency == .rub)
    #expect(candidate.difference == Self.money(98_800))
    #expect(candidate.operationId == operation)

    let (afterZero, afterZeroBalances) = self.book(
      [],
      totals: [
        total(1, "2026-08-01", actual: 0, difference: nil),
        total(2, "2026-08-20", actual: 5_000, difference: 5_000),
      ])
    #expect(
      FirstCountFix.candidates(
        book: afterZero, balances: afterZeroBalances, liveOperations: [], kept: []
      ).map(\.id) == [Self.id(2)])
  }

  @Test func aTotalAfterANonZeroTotalIsNot() {
    let (book, balances) = book(
      [],
      totals: [
        total(1, "2026-08-01", actual: 10_000, difference: nil),
        total(2, "2026-08-20", actual: 12_000, difference: 2_000),
        total(3, "2026-08-25", actual: 0, difference: -12_000),
      ])
    #expect(
      FirstCountFix.candidates(book: book, balances: balances, liveOperations: [], kept: [])
        .isEmpty)
    let (none, noneBalances) = self.book(
      [], totals: [total(1, "2026-08-01", actual: 10_000, difference: 0)])
    #expect(
      FirstCountFix.candidates(book: none, balances: noneBalances, liveOperations: [], kept: [])
        .isEmpty, "a total without a difference has nothing to take back")
  }

  /// «Это настоящая разница» leaves a candidate out for good; the rest are listed newest first,
  /// counts and totals together.
  @Test func keptCandidatesAreLeftOut() {
    let (book, balances) = book(
      [
        opening(1, "2026-09-20", 6, [(cash.id, 0), (card.id, 0)]),
        sheet(2, "2026-09-24", 12, account: card.id, actual: 40_000, expected: 0),
        sheet(3, "2026-09-26", 12, account: cash.id, actual: 3_500, expected: 0),
      ],
      totals: [total(4, "2026-08-20", actual: 1_000, difference: 1_000)])
    #expect(
      FirstCountFix.candidates(book: book, balances: balances, liveOperations: [], kept: [])
        .map(\.id) == [Self.id(30), Self.id(20), Self.id(4)])
    #expect(
      FirstCountFix.candidates(
        book: book, balances: balances, liveOperations: [], kept: [Self.id(30), Self.id(4)]
      ).map(\.id) == [Self.id(20)])
    #expect(
      FirstCountFix.keeping([Self.id(30)], in: [Self.id(4)])
        == [Self.id(30), Self.id(4)].map(\.uuidString).sorted().joined(separator: "\n"))
    #expect(FirstCountFix.keeping([Self.id(4)], in: [Self.id(4)]) == Self.id(4).uuidString)
  }

  // MARK: The fix

  /// The fix makes the count a starting point — nothing expected, no difference, no link, no
  /// way of keeping one — and bins its live operation; the count and the balance stay.
  @Test func theFixMakesAStartingPointAndBinsTheOperation() throws {
    let operation = Self.id(900)
    let (book, balances) = book([
      opening(1, "2026-09-20", 6, [(cash.id, 0)]),
      sheet(
        2, "2026-09-26", 12, account: cash.id, actual: 3_500, expected: 0, operation: operation),
    ])
    let candidate = try #require(
      FirstCountFix.candidates(
        book: book, balances: balances, liveOperations: [operation], kept: []
      ).first)
    let write = FirstCountFix.fix(candidate)
    let fixed = try #require(write.balances.first)
    #expect(write.balances.count == 1)
    #expect(fixed.id == candidate.id)
    #expect(fixed.actualE4 == Self.money(3_500))
    #expect(fixed.isStartingPoint)
    #expect(fixed.differenceE4 == nil)
    #expect(fixed.transactionId == nil)
    #expect(fixed.recordsDifference == nil)
    #expect(write.reconciliations.isEmpty)
    #expect(write.softDeleted == [operation])

    // The balance after the fix: the count itself.
    let after = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations,
      balances: book.reconciledBalances.map { $0.id == fixed.id ? fixed : $0 },
      accounts: [card, cash], tree: CategoryTree(), now: Self.at("2026-09-30", 12),
      calendar: .utc)
    #expect(after.balance(cashKey, at: Self.at("2026-09-30", 12)) == Self.money(3_500))

    // A total and an operation already binned.
    let legacy = FirstCountCandidate.total(
      total(5, "2026-08-20", actual: 98_800, difference: 98_800, operation: Self.id(901)),
      operationId: nil)
    let totalWrite = FirstCountFix.fix(legacy)
    let reconciliation = try #require(totalWrite.reconciliations.first)
    #expect(reconciliation.differenceE4 == nil)
    #expect(reconciliation.expectedTotalRubE4 == nil)
    #expect(reconciliation.transactionId == nil)
    #expect(reconciliation.actualTotalRubE4 == Self.money(98_800))
    #expect(totalWrite.softDeleted.isEmpty)
    #expect(totalWrite.balances.isEmpty)
  }

  // MARK: The sheet

  /// A row whose pair rests only on zero openings of before 1.2 offers the starting point; a
  /// pair never counted, one counted at money, or counted by a sheet after the zero does not.
  @Test func restsOnZeroOpenings() {
    let (book, balances) = book([
      opening(1, "2026-09-20", 6, [(cash.id, 0), (card.id, 10_000)])
    ])
    let dollars = BalanceKey(accountId: card.id, currency: .usd)
    let rows = [cashKey, cardKey, dollars].map {
      ReconcileRow(key: $0, expected: .zero, lastCountedAt: nil, isHeld: true)
    }
    #expect(
      FirstCountFix.startingPointKeys(
        rows, balances: balances, reconciliations: book.reconciliations) == [cashKey])

    let (counted, countedBalances) = self.book([
      opening(1, "2026-09-20", 6, [(cash.id, 0)]),
      sheet(2, "2026-09-22", 12, account: cash.id, actual: 2_000, expected: 0),
    ])
    #expect(
      FirstCountFix.startingPointKeys(
        rows, balances: countedBalances, reconciliations: counted.reconciliations
      ).isEmpty)
  }

  /// «Наличные» left empty in the setup of 25.09, 2,000 spent on 26.09, 3,000 counted on 28.09:
  /// the sheet expects −2,000, and the count is its starting point anyway — 3,000 on the
  /// account, nothing compared, the spending of September stays 2,000.
  @Test func aPreOneTwoZeroOpeningDefaultsToTheStartingPointWhateverMoved() throws {
    let spent = expense(1, "2026-09-26", 2_000, on: cash.id)
    let t0 = Self.at("2026-09-28", 18)
    let (book, balances) = book(
      [opening(1, "2026-09-25", 6, [(cash.id, 0)])], entries: [spent], now: t0)
    let rows = AccountReconciliation.rows(
      accounts: [card, cash], groups: [], balances: balances, at: t0,
      locale: Locale(identifier: "en"))
    let row = try #require(rows.first { $0.key == cashKey })
    #expect(row.expected == Self.money(-2_000))
    let starting = FirstCountFix.startingPointKeys(
      rows, balances: balances, reconciliations: book.reconciliations)
    #expect(starting == [cashKey], "on whatever the books expect")

    let record = AccountReconciliation.record(
      counted: [cashKey: Self.money(3_000)], rows: rows, writeDifference: true, kind: .accounts,
      at: t0, calendar: .utc, tree: CategoryTree(), categories: (Self.id(70), Self.id(71)),
      rubPerUnit: [:], makeId: { UUID() }, startingPoints: starting)
    let count = try #require(record.balances.first)
    #expect(count.isStartingPoint)
    #expect(count.recordsDifference == nil)
    #expect(record.differences.isEmpty, "no «Сверка» for the first count")

    let after = AccountBalances.build(
      entries: [spent], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations + [record.reconciliation],
      balances: book.reconciledBalances + record.balances, accounts: [card, cash],
      tree: CategoryTree(), now: t0, calendar: .utc)
    #expect(after.balance(cashKey, at: t0) == Self.money(3_000))
  }
}
