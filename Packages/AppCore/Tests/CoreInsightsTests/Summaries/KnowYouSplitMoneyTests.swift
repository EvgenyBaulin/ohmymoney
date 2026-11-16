import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("Know you: categories and quality of split purchases")
struct KnowYouSplitMoneyTests {
  private let first = CoreKit.Category(kind: .expense, name: "Synthetic first")
  private let second = CoreKit.Category(kind: .expense, name: "Synthetic second")
  private let end = DateOnly(year: 2026, month: 11, day: 15)

  private func ledger(reverseParts: Bool = false) -> Ledger {
    let entries = (0..<56).map { back in
      let recent = back < 28
      let id = UUID()
      let secondAmount = AmountE4(whole: recent ? 300 : 100)
      let firstAmount = AmountE4(whole: 100)
      var parts = [
        TransactionPart(
          transactionId: id, categoryId: first.id, quality: .neutral, amountE4: firstAmount),
        TransactionPart(
          transactionId: id, categoryId: second.id, quality: .bad, amountE4: secondAmount),
      ]
      if reverseParts { parts.reverse() }
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense,
          occurredAt: CalendarContext.utc.moment(end.adding(days: -back), hour: 18, minute: 0),
          amountE4: firstAmount + secondAmount),
        parts: parts)
    }
    return Ledger(dataset: Dataset(entries: entries, categories: [first, second]), calendar: .utc)
  }

  @Test func growthBelongsToTheCategoryOfTheGrowingPart() throws {
    for reverse in [false, true] {
      let fact = try #require(
        KnowYouFacts.check(.categoryGrew, ledger: ledger(reverseParts: reverse), through: end))
      #expect(fact.args.first == .category(second.id))
      #expect(fact.differenceBP == 20_000)
    }
  }

  @Test func qualitySharesUseEachPartsAmountAndAreIndependentOfPartOrder() throws {
    for reverse in [false, true] {
      let fact = try #require(
        KnowYouFacts.check(.badShareGrew, ledger: ledger(reverseParts: reverse), through: end))
      // Bad spending is 100/200 before and 300/400 now: 75%, a relative rise of 50%.
      #expect(fact.args.first == .percent(75))
      #expect(fact.differenceBP == 5_000)
    }
  }

  @Test func splittingACheckDoesNotDoubleItsPurchaseCount() {
    #expect(KnowYouFacts.check(.purchasesMore, ledger: ledger(), through: end) == nil)
    #expect(KnowYouFacts.check(.checkGrew, ledger: ledger(), through: end)?.differenceBP == 10_000)
  }
}
