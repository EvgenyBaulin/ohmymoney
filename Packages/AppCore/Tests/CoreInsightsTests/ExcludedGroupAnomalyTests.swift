import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// A group of accounts left out of the summary hides its money only: what is spent on its
/// accounts is looked at by the anomaly rules like any other spending, and a transfer between
/// accounts is no spending the rules could find.
@Suite("Anomalies see the spending of accounts left out of the summary")
struct ExcludedGroupAnomalyTests {
  let today = DateOnly(year: 2026, month: 6, day: 20)
  let groceries = UUID(uuidString: "00000000-0000-0000-0000-00000000B010") ?? UUID()
  let cafe = UUID(uuidString: "00000000-0000-0000-0000-00000000B011") ?? UUID()

  func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: cafe, kind: .expense, name: "Cafe", quality: .bad),
    ]
  }

  /// A seeded SplitMix64, for a reproducible history.
  struct Dice {
    var state: UInt64
    mutating func below(_ bound: Int) -> Int {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((mixed ^ (mixed >> 31)) % UInt64(max(1, bound)))
    }
  }

  /// Half a year of purchases on a ruble card and on a tenge account of the Kazakh group — now
  /// and then a large one, a twin, a bad week —, and transfers between the two.
  func dataset(seed: UInt64, inSummary: Bool, transfers: Bool) -> Dataset {
    var dice = Dice(state: seed)
    let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
    let kaspi = PaymentMethod(
      id: id(2), name: "Kaspi", currency: CurrencyCode("KZT"), groupId: id(90))
    let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 1, day: 1))
    var entries: [TransactionEntry] = []
    for number in 1...(120 + dice.below(80)) {
      let at = start.addingTimeInterval(TimeInterval(dice.below(170) * 86_400 + 36_000))
      let onKaspi = dice.below(2) == 0
      let large = dice.below(25) == 0
      let rub = AmountE4(
        whole: Int64(large ? 20_000 + dice.below(60_000) : 100 + dice.below(3_000)))
      let amount = onKaspi ? AmountE4(raw: rub.raw * 5) : rub
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(1000 + number), kind: .expense, occurredAt: at,
            currency: onKaspi ? CurrencyCode("KZT") : .rub, amountE4: amount,
            rate: onKaspi ? Decimal(2) / 10 : nil, amountRubE4: rub,
            paymentMethodId: onKaspi ? kaspi.id : card.id, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: id(10_000 + number), transactionId: id(1000 + number),
              categoryId: dice.below(3) == 0 ? cafe : groceries, amountE4: amount, amountRubE4: rub)
          ]))
    }
    let moved: [Transfer] =
      transfers
      ? (1...8).map { number in
        let at = start.addingTimeInterval(TimeInterval(dice.below(170) * 86_400))
        return Transfer(
          id: id(5000 + number), occurredAt: at, fromAccountId: id(1), fromCurrency: .rub,
          fromAmountE4: AmountE4(whole: 50_000), toAccountId: id(2),
          toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(whole: 250_000),
          createdAt: at, updatedAt: at)
      } : []
    return Dataset(
      entries: entries, categories: categories, paymentMethods: [card, kaspi], transfers: moved,
      accountGroups: [AccountGroup(id: id(90), name: "Kazakhstan", inSummary: inSummary)])
  }

  func anomalies(_ dataset: Dataset) -> AnomalyReport {
    AnomalyRules.build(ledger: Ledger(dataset: dataset, calendar: .utc), today: today)
  }

  /// The anomalies are the same whether the Kazakh group is in the summary or not, with or
  /// without transfers between the accounts.
  @Test(arguments: Array(1...15) as [UInt64])
  func theSummaryAndTransfersChangeNoAnomaly(seed: UInt64) {
    let apart = anomalies(dataset(seed: seed, inSummary: false, transfers: true))
    #expect(
      apart == anomalies(dataset(seed: seed, inSummary: true, transfers: true)), "seed \(seed)")
    #expect(
      apart == anomalies(dataset(seed: seed, inSummary: false, transfers: false)), "seed \(seed)")
  }

  /// A large purchase on the tenge account of the group apart is a «Крупная трата» like one on
  /// the card: the rules see its rubles, not where the money lives.
  @Test func aLargePurchaseApartIsFound() {
    var data = dataset(seed: 7, inSummary: false, transfers: true)
    let at = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 6, day: 18))
      .addingTimeInterval(36_000)
    data.entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(9999), kind: .expense, occurredAt: at, currency: CurrencyCode("KZT"),
          amountE4: AmountE4(whole: 2_500_000), rate: Decimal(2) / 10,
          amountRubE4: AmountE4(whole: 500_000), paymentMethodId: id(2), createdAt: at,
          updatedAt: at),
        parts: [
          TransactionPart(
            id: id(99_990), transactionId: id(9999), categoryId: groceries,
            amountE4: AmountE4(whole: 2_500_000), amountRubE4: AmountE4(whole: 500_000))
        ]))
    let found = anomalies(data).all
    #expect(found.contains { $0.rule == .largeExpense && $0.transactionId == id(9999) })
  }
}
