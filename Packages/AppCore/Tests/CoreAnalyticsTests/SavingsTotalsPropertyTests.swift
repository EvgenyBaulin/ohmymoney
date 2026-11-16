import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// Random transfers between ordinary and saving accounts (a cushion, an account with interest,
/// a piggy bank): moving money between saving places saves nothing, and the above-100-percent
/// flag is exactly a rate over 100 %.
@Suite("Savings totals: transfers between saving accounts, random books")
struct SavingsTotalsPropertyTests {
  static let seeds: [UInt64] = Array(1...30)

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "5A700000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  let main = PaymentMethod(id: id(1), name: "Main")
  let wallet = PaymentMethod(id: id(2), name: "Wallet")
  let cushion = PaymentMethod(id: id(3), name: "Cushion", cushion: true)
  let deposit = PaymentMethod(
    id: id(4), name: "Deposit", interest: DepositTerms(rate: 10, period: .monthly))
  let piggy = PaymentMethod(id: id(5), name: "Piggy", piggy: true)

  var ordinary: [PaymentMethod] { [main, wallet] }
  var savers: [PaymentMethod] { [cushion, deposit, piggy] }
  let span = Period.month(MonthKey(year: 2026, month: 9)).range

  func transfer(
    _ from: PaymentMethod, _ to: PaymentMethod, _ units: Int, day: Int
  ) -> Transfer {
    let when = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: day))
      .addingTimeInterval(12 * 3600)
    let amount = AmountE4(whole: Int64(units))
    return Transfer(
      occurredAt: when, fromAccountId: from.id, fromCurrency: .rub, fromAmountE4: amount,
      toAccountId: to.id, toCurrency: .rub, toAmountE4: amount)
  }

  func totals(_ transfers: [Transfer], income: AmountE4) -> SavingsTotals {
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: ordinary + savers, transfers: transfers),
      calendar: .utc)
    return SavingsTotals(ledger: ledger, in: span, income: income)
  }

  @Test(arguments: seeds)
  func transfersBetweenSavingAccountsNeverChangeWhatIsSaved(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    var across: [Transfer] = []
    for _ in 0..<random.int(in: 0...8) {
      let saver = random.choice(from: savers)
      let plain = random.choice(from: ordinary)
      let units = random.int(in: 100...50_000)
      across.append(
        random.chance(1, outOf: 2)
          ? transfer(plain, saver, units, day: random.int(in: 1...28))
          : transfer(saver, plain, units, day: random.int(in: 1...28)))
    }
    var inside: [Transfer] = []
    for _ in 0..<random.int(in: 1...10) {
      let from = random.choice(from: savers)
      let to = random.choice(from: savers)
      inside.append(transfer(from, to, random.int(in: 100...80_000), day: random.int(in: 1...28)))
    }
    for _ in 0..<random.int(in: 0...3) {
      let plain = random.choice(from: ordinary)
      inside.append(transfer(plain, random.choice(from: ordinary), 500, day: 9))
    }
    let income = AmountE4(whole: Int64(random.int(in: 0...200_000)))
    let before = totals(across, income: income)
    let after = totals(across + inside, income: income)
    #expect(after.accounts == before.accounts, "seed \(seed)")
    #expect(after.saved == before.saved, "seed \(seed)")
    #expect(after.basisPoints == before.basisPoints, "seed \(seed)")
    #expect(after.isAbove100Percent == before.isAbove100Percent, "seed \(seed)")
    // The order of the transfers does not matter either.
    var shuffled = random
    let reordered = (across + inside).shuffled(using: &shuffled)
    #expect(totals(reordered, income: income).saved == before.saved, "seed \(seed)")
  }

  @Test(arguments: seeds)
  func theAboveHundredFlagIsExactlyARateOverHundredPercent(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &+ 500)
    for _ in 0..<40 {
      let income = AmountE4(raw: Int64(random.int(in: -2...300)) * 10_000_000)
      let units = random.int(in: 0...400_000)
      let into = random.chance(2, outOf: 3)
      let move =
        into
        ? transfer(random.choice(from: ordinary), random.choice(from: savers), units, day: 5)
        : transfer(random.choice(from: savers), random.choice(from: ordinary), units, day: 5)
      let result = totals([move], income: income)
      let label = "seed \(seed): saved \(result.saved.raw), income \(income.raw)"
      if income.raw <= 0 {
        #expect(result.basisPoints == nil && !result.isAbove100Percent, "\(label)")
        continue
      }
      let rate = result.basisPoints ?? Int.min
      #expect(result.isAbove100Percent == (rate > 10_000), "\(label)")
      // Well over the income is flagged, at or under it never.
      if result.saved <= income { #expect(!result.isAbove100Percent, "\(label)") }
      if Decimal(result.saved.raw) > Decimal(income.raw) * Decimal(string: "1.0001")! {
        #expect(result.isAbove100Percent, "\(label)")
      }
    }
  }
}
