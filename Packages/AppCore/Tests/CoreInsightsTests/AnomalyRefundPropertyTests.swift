import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// Random months of groceries with refunds taken back from some purchases — the same week,
/// weeks later, in full or in part — and the rules that read my spending: a refund is never an
/// anomaly of its own, a purchase refunded in full is none, and what an anomaly says a purchase
/// cost is what is left of it.
@Suite("Anomalies on random books with refunds")
struct AnomalyRefundPropertyTests {
  static let today = DateOnly(year: 2026, month: 9, day: 19)
  static let groceries = UUID(uuidString: "00000000-0000-0000-0000-00000000B001") ?? UUID()

  /// SplitMix64: the same seed gives the same book everywhere.
  struct Dice {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return mixed ^ (mixed >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
  }

  static func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  /// Two hundred days of purchases, a few very large; a third of them partly or fully
  /// refunded up to five weeks later.
  static func ledger(seed: UInt64) -> (ledger: Ledger, refunds: Set<UUID>, full: Set<UUID>) {
    var dice = Dice(state: seed)
    var entries: [TransactionEntry] = []
    var refunds: Set<UUID> = []
    var full: Set<UUID> = []
    let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 3, day: 1))
    for number in 1...(60 + dice.below(80)) {
      let when = start.addingTimeInterval(
        TimeInterval(dice.below(200) * 86_400 + 3_600 * (8 + dice.below(12)) + 60 * dice.below(60)))
      let large = dice.chance(6)
      let amount = AmountE4(
        raw: Int64(large ? 20_000 + dice.below(40_000) : 500 + dice.below(2_500)) * 10_000)
      let purchase = uuid(number)
      let part = uuid(100_000 + number)
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: purchase, kind: .expense, occurredAt: when, amountE4: amount),
          parts: [
            TransactionPart(
              id: part, transactionId: purchase, categoryId: groceries, quality: .neutral,
              qualitySource: .category, amountE4: amount)
          ]))
      guard dice.chance(33) else { continue }
      let whole = dice.chance(40)
      let taken = whole ? amount : AmountE4(raw: max(10_000, amount.raw / 2 / 10_000 * 10_000))
      let refund = uuid(200_000 + number)
      refunds.insert(refund)
      if whole { full.insert(purchase) }
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: refund, kind: .refund,
            occurredAt: when.addingTimeInterval(TimeInterval(dice.below(36) * 86_400)),
            amountE4: taken),
          parts: [
            TransactionPart(
              id: uuid(300_000 + number), transactionId: refund, categoryId: groceries,
              amountE4: taken, refundOfPartId: part)
          ]))
    }
    let dataset = Dataset(
      entries: entries,
      categories: [
        CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral)
      ])
    return (Ledger(dataset: dataset, calendar: .utc), refunds, full)
  }

  @Test(arguments: Array(1...25) as [UInt64])
  func aRefundIsNeverAnAnomalyOfItsOwn(seed: UInt64) {
    let (ledger, refunds, full) = Self.ledger(seed: seed)
    let options = AnomalyOptions.standard(.high)
    let report = AnomalyRules.build(ledger: ledger, today: Self.today, options: options)
    for anomaly in report.all {
      guard let transaction = anomaly.transactionId else { continue }
      #expect(!refunds.contains(transaction), "seed \(seed): \(anomaly.rule) on a refund")
      #expect(!full.contains(transaction), "seed \(seed): \(anomaly.rule) on a refunded purchase")
      if anomaly.rule == .largeExpense, let part = anomaly.partId {
        #expect(
          anomaly.amount == ledger.row(ofPart: part)?.contribution,
          "seed \(seed): a large payment says what it cost before its refunds")
      }
    }
  }

  /// The books above do make large payments, and some of them after a refund: the check above
  /// is not true only because there is nothing to check.
  @Test func theBooksDoMakeLargePayments() {
    var large = 0
    var afterARefund = 0
    for seed in 1...25 as ClosedRange<UInt64> {
      let (ledger, _, _) = Self.ledger(seed: seed)
      let report = AnomalyRules.build(
        ledger: ledger, today: Self.today, options: AnomalyOptions.standard(.high))
      for anomaly in report.all where anomaly.rule == .largeExpense {
        large += 1
        if let part = anomaly.partId, (ledger.row(ofPart: part)?.refundedE4.raw ?? 0) > 0 {
          afterARefund += 1
        }
      }
    }
    #expect(large > 0)
    #expect(afterARefund > 0)
  }
}
