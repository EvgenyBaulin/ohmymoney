import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Random books of accounts, assets and debts in both directions: «с долгами мне» and «без
/// них» differ by exactly the debts owed to me, at every point of the capital and in its lines.
@Suite("Net worth with and without the debts owed to me: random books")
struct NetWorthOwedToMePropertyTests {
  typealias Fx = CapitalFx

  static let seeds: [UInt64] = Array(1...25)
  static let today = Fx.day("2026-10-11")

  func dataset(seed: UInt64) -> Dataset {
    var random = SeededRandom(seed: seed)
    let main = Fx.id(1)
    let (count, rows) = Fx.count(
      1, "2026-05-10", [(main, .rub, String(random.int(in: 0...900_000)))])
    var debts: [Debt] = []
    var journal: [DebtEntry] = []
    for index in 0..<random.int(in: 0...6) {
      let iOwe = random.chance(1, outOf: 2)
      let debt = Debt(
        id: Fx.id(100 + index), direction: iOwe ? .iOwe : .owedToMe,
        type: random.chance(1, outOf: 3) ? .loan : .personal, name: "Debt \(index)",
        closed: random.chance(1, outOf: 8))
      debts.append(debt)
      var number = 0
      let first = Fx.day("2026-05-20").adding(days: random.int(in: 0...60))
      journal.append(
        DebtEntry(
          id: Fx.id(1_000 + index * 20), debtId: debt.id, date: first,
          amountE4: Fx.rub(String(random.int(in: 1_000...500_000))), kind: .borrowed))
      for _ in 0..<random.int(in: 0...4) {
        number += 1
        journal.append(
          DebtEntry(
            id: Fx.id(1_000 + index * 20 + number), debtId: debt.id,
            date: first.adding(days: random.int(in: 1...120)),
            amountE4: Fx.rub(String(random.int(in: 100...300_000))),
            kind: random.chance(1, outOf: 4) ? .borrowed : .payment))
      }
    }
    let assets = random.chance(1, outOf: 2)
      ? [Asset(name: "Flat", kind: .realty, purchasedOn: Fx.day("2026-05-01"),
          purchasePriceE4: Fx.rub(String(random.int(in: 100_000...3_000_000))))]
      : []
    return Dataset(
      paymentMethods: [PaymentMethod(id: main, name: "Main", isDefault: true)],
      debts: debts,
      planning: PlanningBook(
        reconciliations: [count], debtEntries: journal, reconciledBalances: rows),
      assets: assets)
  }

  @Test(arguments: seeds)
  func theTwoFiguresDifferByTheDebtsOwedToMeAtEveryPoint(_ seed: UInt64) {
    let capital = Fx.capital(dataset(seed: seed), today: Self.today, months: nil)
    #expect(!capital.points.isEmpty)
    for point in capital.points {
      #expect(point.netRub - point.netWithoutOwedToMeRub == point.owedToMeRub, "seed \(seed)")
      #expect(point.netWithoutOwedToMeRub == point.haveRub - point.owedToMeRub - point.iOweRub)
      #expect(point.hasOwedToMe == !point.owedToMeRub.isZero)
      #expect(point.owedToMeRub.raw >= 0 && point.iOweRub.raw >= 0, "seed \(seed)")
      if !point.hasOwedToMe { #expect(point.netRub == point.netWithoutOwedToMeRub) }
    }
  }

  @Test(arguments: seeds)
  func theOwedLinesOfNowAddUpToTheFigure(_ seed: UInt64) {
    let capital = Fx.capital(dataset(seed: seed), today: Self.today, months: nil)
    let owedLines = capital.breakdown.have.filter { $0.group == .owedToMe }
    let sum = owedLines.reduce(AmountE4.zero) { $0 + ($1.amountRub ?? .zero) }
    #expect(capital.now.owedToMeRub == sum, "seed \(seed)")
    let oweLines = capital.breakdown.owe.reduce(AmountE4.zero) { $0 + ($1.amountRub ?? .zero) }
    #expect(capital.now.iOweRub == oweLines, "seed \(seed)")
    #expect(capital.now.netRub - capital.now.netWithoutOwedToMeRub == sum, "seed \(seed)")
  }
}
