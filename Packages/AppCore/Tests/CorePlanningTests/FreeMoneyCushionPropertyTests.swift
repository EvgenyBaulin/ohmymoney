import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The free sum and the cushion on random books: with «не считать подушку в свободной сумме»
/// off nothing changes — not a figure, not a line —, and on, «можно тратить сейчас» loses
/// exactly the cushion money on accounts in the summary; a cushion in a group left out of the
/// summary was never in the free sum.
@Suite("The free sum without the cushion on random books")
struct FreeMoneyCushionPropertyTests {
  typealias Book = NetWorthNowEqualsAccountsSnapshotPropertyTest.Book
  static let seeds: [UInt64] = Array(1...40)

  let today = DateOnly(year: 2026, month: 10, day: 11)

  func snapshot(_ dataset: Dataset, rates: [CurrencyCode: Decimal]) -> PlanningSnapshot {
    PlanningSnapshot.build(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today,
      now: CalendarContext.utc.noon(of: today), rubPerUnit: rates)
  }

  func withCushion(_ dataset: Dataset, flagged: Bool, outOfFreeMoney: Bool) -> Dataset {
    var copy = dataset
    if !flagged {
      copy.paymentMethods = copy.paymentMethods.map { account in
        var plain = account
        plain.cushion = false
        return plain
      }
    }
    copy.capitalSettings = CapitalSettings(outOfFreeMoney: outOfFreeMoney)
    return copy
  }

  @Test(arguments: seeds)
  func offChangesNothing(_ seed: UInt64) {
    let book = Book(seed: seed)
    let plain = snapshot(
      withCushion(book.dataset, flagged: false, outOfFreeMoney: false), rates: book.rates)
    let flagged = snapshot(
      withCushion(book.dataset, flagged: true, outOfFreeMoney: false), rates: book.rates)
    #expect(flagged.freeMoney == plain.freeMoney, "seed \(seed)")
    #expect(flagged.freeMoney.cushion == .zero, "seed \(seed)")
    #expect(flagged.freeMoney.cushionLine == nil, "seed \(seed)")
    let later = today.monthKey.adding(months: 3).lastDay
    let ledger = Ledger(
      dataset: withCushion(book.dataset, flagged: true, outOfFreeMoney: false), calendar: .utc)
    let plainLedger = Ledger(
      dataset: withCushion(book.dataset, flagged: false, outOfFreeMoney: false), calendar: .utc)
    #expect(
      flagged.freeMoney(until: later, ledger: ledger)
        == plain.freeMoney(until: later, ledger: plainLedger), "seed \(seed)")
  }

  @Test(arguments: seeds)
  func onTakesOffTheCushionInTheSummaryOnly(_ seed: UInt64) {
    let book = Book(seed: seed)
    let off = snapshot(
      withCushion(book.dataset, flagged: true, outOfFreeMoney: false), rates: book.rates)
    let on = snapshot(
      withCushion(book.dataset, flagged: true, outOfFreeMoney: true), rates: book.rates)

    var inSummary = AmountE4.zero
    for section in on.accounts.sections where section.inSummary {
      for line in section.accounts where line.account.cushion {
        inSummary += line.totalRub ?? .zero
      }
    }
    #expect(on.cushion.inSummaryRub == inSummary, "seed \(seed)")
    #expect(on.freeMoney.cushion == inSummary, "seed \(seed)")
    #expect(on.freeMoney.moneyNow == off.freeMoney.moneyNow, "seed \(seed)")
    #expect(on.freeMoney.main == off.freeMoney.main.map { $0 - inSummary }, "seed \(seed)")
    #expect(on.freeMoney.grey == off.freeMoney.grey.map { $0 - inSummary }, "seed \(seed)")
    #expect(on.freeMoney.lines == off.freeMoney.lines, "seed \(seed)")
    #expect(on.freeMoney.excluded == off.freeMoney.excluded, "seed \(seed)")
    #expect(
      on.freeMoney.cushionLine
        == (inSummary.isZero
          ? nil : FreeToSpendLine(key: FreeMoney.Key.cushion, sign: .minus, amount: inSummary)),
      "seed \(seed)")
    // The rest of the cushion lies in groups left out of the summary.
    let outside = on.cushion.moneyRub - on.cushion.inSummaryRub
    var leftOut = AmountE4.zero
    for section in on.accounts.sections where !section.inSummary {
      for line in section.accounts where line.account.cushion {
        leftOut += line.totalRub ?? .zero
      }
    }
    #expect(outside == leftOut, "seed \(seed)")
  }
}
