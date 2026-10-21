import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Not counted yet»: a zero starting balance written before the origin of an opening was kept
/// is no count — an empty field of the old setup and a typed 0 look the same there —, so a later
/// count that has only such rows before it is the pair's first real count.
@Suite("Zero openings of the older setup are no counts")
struct ZeroOpeningsTests {
  let categories = StartingCategories()
  let calendar = CalendarContext.utc

  var card: PaymentMethod {
    PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  }
  var cash: PaymentMethod { PaymentMethod(id: id(2), name: "Cash", kind: .cash, currency: .rub) }

  func key(_ account: UUID) -> BalanceKey { BalanceKey(accountId: account, currency: .rub) }

  func at(_ iso: String, hour: Int) -> Date {
    moment(iso).addingTimeInterval(TimeInterval(hour * 3600))
  }

  /// A reconciliation `number` counting `counts` at `hour` of `iso`; its rows are
  /// `id(number * 100 + index)`. `compared` gives every row an expected balance equal to 0.
  func count(
    _ number: Int, on iso: String, hour: Int = 10, kind: ReconciliationKind = .accounts,
    origin: ReconciliationOrigin? = nil, compared: Bool = false, _ counts: [(BalanceKey, Int)]
  ) -> (Reconciliation, [ReconciledBalance]) {
    let reconciliation = Reconciliation(
      id: id(number), date: day(iso), reconciledAt: at(iso, hour: hour),
      actualTotalRubE4: .zero, kind: kind, origin: origin)
    let rows = counts.enumerated().map { index, count in
      ReconciledBalance(
        id: id(number * 100 + index), reconciliationId: id(number),
        accountId: count.0.accountId, currency: count.0.currency, actualE4: money(count.1),
        expectedE4: compared ? .zero : nil, differenceE4: compared ? money(count.1) : nil)
    }
    return (reconciliation, rows)
  }

  func balances(_ counts: [(Reconciliation, [ReconciledBalance])]) -> AccountBalances {
    AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: counts.map(\.0), balances: counts.flatMap(\.1), accounts: [card, cash],
      tree: categories.tree, now: at("2026-09-30", hour: 23), calendar: calendar)
  }

  func byId(_ counts: [(Reconciliation, [ReconciledBalance])]) -> [UUID: Reconciliation] {
    Dictionary(uniqueKeysWithValues: counts.map { ($0.0.id, $0.0) })
  }

  @Test func aPreOneTwoZeroOpeningIsNoCount() {
    let opening = count(10, on: "2026-09-20", kind: .opening, [(key(id(1)), 0), (key(id(2)), 0)])
    let sheet = count(20, on: "2026-09-26", compared: true, [(key(id(1)), 120_000)])
    let all = [opening, sheet]
    #expect(ZeroOpenings.isPreOneTwoZero(opening.1[0], of: opening.0))
    let book = balances(all)
    #expect(
      ZeroOpenings.rests(key(id(1)), before: id(2000), balances: book, reconciliations: byId(all)))
    // A new count of the sheet: every anchor of the key is such a row.
    #expect(ZeroOpenings.rests(key(id(2)), before: nil, balances: book, reconciliations: byId(all)))
    #expect(
      ZeroOpenings.frozenCounts(balances: book, reconciliations: all.map(\.0), kept: [])
        == [id(2000)])
  }

  @Test func aTypedZeroOfOneTwoIsACount() {
    for origin in [ReconciliationOrigin.setup, .account] {
      let opening = count(10, on: "2026-09-20", kind: .opening, origin: origin, [(key(id(1)), 0)])
      let sheet = count(20, on: "2026-09-26", compared: true, [(key(id(1)), 5_000)])
      let all = [opening, sheet]
      let book = balances(all)
      #expect(!ZeroOpenings.isPreOneTwoZero(opening.1[0], of: opening.0))
      #expect(
        !ZeroOpenings.rests(
          key(id(1)), before: id(2000), balances: book, reconciliations: byId(all)))
      #expect(
        ZeroOpenings.frozenCounts(balances: book, reconciliations: all.map(\.0), kept: []).isEmpty)
    }
  }

  @Test func aMergeZeroIsACount() {
    let opening = count(10, on: "2026-09-20", kind: .opening, origin: .merge, [(key(id(1)), 0)])
    let sheet = count(20, on: "2026-09-26", compared: true, [(key(id(1)), 5_000)])
    let all = [opening, sheet]
    #expect(!ZeroOpenings.isPreOneTwoZero(opening.1[0], of: opening.0))
    #expect(
      !ZeroOpenings.rests(
        key(id(1)), before: id(2000), balances: balances(all), reconciliations: byId(all)))
  }

  @Test func aNonZeroOpeningIsACount() {
    let opening = count(10, on: "2026-09-20", kind: .opening, [(key(id(1)), 3_000)])
    let sheet = count(20, on: "2026-09-26", compared: true, [(key(id(1)), 5_000)])
    let all = [opening, sheet]
    let book = balances(all)
    #expect(!ZeroOpenings.isPreOneTwoZero(opening.1[0], of: opening.0))
    #expect(
      !ZeroOpenings.rests(key(id(1)), before: id(2000), balances: book, reconciliations: byId(all)))
    #expect(
      !ZeroOpenings.rests(key(id(1)), before: nil, balances: book, reconciliations: byId(all)))
    // A zero counted by a sheet is a count as well: only an opening can be an empty field.
    let zeroSheet = count(30, on: "2026-09-21", [(key(id(2)), 0)])
    let later = count(40, on: "2026-09-27", compared: true, [(key(id(2)), 700)])
    let other = [zeroSheet, later]
    #expect(!ZeroOpenings.isPreOneTwoZero(zeroSheet.1[0], of: zeroSheet.0))
    #expect(
      !ZeroOpenings.rests(
        key(id(2)), before: id(4000), balances: balances(other), reconciliations: byId(other)))
  }

  /// Once the first real count exists, the one after it compares with it: it rests on a count.
  @Test func aCountAfterAKeptCountDoesNotRest() {
    let opening = count(10, on: "2026-09-20", kind: .opening, [(key(id(1)), 0)])
    let first = count(20, on: "2026-09-26", compared: true, [(key(id(1)), 120_000)])
    let second = count(30, on: "2026-09-28", compared: true, [(key(id(1)), 119_000)])
    let all = [opening, first, second]
    let book = balances(all)
    #expect(
      ZeroOpenings.rests(key(id(1)), before: id(2000), balances: book, reconciliations: byId(all)))
    #expect(
      !ZeroOpenings.rests(key(id(1)), before: id(3000), balances: book, reconciliations: byId(all)))
    #expect(
      !ZeroOpenings.rests(key(id(1)), before: nil, balances: book, reconciliations: byId(all)))
    // The first anchor of a key has nothing before it; a count the key does not have is unknown.
    #expect(
      !ZeroOpenings.rests(key(id(1)), before: id(1000), balances: book, reconciliations: byId(all)))
    #expect(
      !ZeroOpenings.rests(key(id(1)), before: id(9999), balances: book, reconciliations: byId(all)))
    // A key never counted rests on nothing.
    #expect(
      !ZeroOpenings.rests(key(id(2)), before: nil, balances: book, reconciliations: byId(all)))
    #expect(
      ZeroOpenings.frozenCounts(balances: book, reconciliations: all.map(\.0), kept: [])
        == [id(2000)])
  }

  @Test func keptCountsAreNotFrozen() {
    let opening = count(10, on: "2026-09-20", kind: .opening, [(key(id(1)), 0), (key(id(2)), 0)])
    let sheet = count(
      20, on: "2026-09-26", compared: true, [(key(id(1)), 120_000), (key(id(2)), 3_000)])
    // An opening compared after «Позже» is not a sheet: it is never a candidate.
    let compared = count(
      30, on: "2026-09-27", kind: .opening, compared: true, [(key(id(1)), 121_000)])
    let all = [opening, sheet, compared]
    let book = balances(all)
    #expect(
      ZeroOpenings.frozenCounts(balances: book, reconciliations: all.map(\.0), kept: [])
        == [id(2000), id(2001)])
    #expect(
      ZeroOpenings.frozenCounts(balances: book, reconciliations: all.map(\.0), kept: [id(2001)])
        == [id(2000)])
    #expect(
      ZeroOpenings.frozenCounts(
        balances: book, reconciliations: all.map(\.0), kept: [id(2000), id(2001)]
      ).isEmpty)
  }
}
