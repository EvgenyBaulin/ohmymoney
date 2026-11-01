import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// Spotlight gets the description and the place of an operation and nothing else; nothing at
/// all while it is off, and never an operation of a hidden account.
@Suite("What Spotlight may know")
struct SpotlightPlanTests {
  let open = UUID()
  let secret = UUID()
  let shop = Place(name: "Пятёрочка")

  func entry(
    _ note: String?, place: UUID? = nil, account: UUID? = nil, amount: Int64 = 98_765,
    deleted: Bool = false
  ) -> TransactionEntry {
    let transaction = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_793_000_000),
      amountE4: AmountE4(whole: amount), note: note, placeId: place, paymentMethodId: account,
      deletedAt: deleted ? Date() : nil)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: UUID(), amountE4: AmountE4(whole: amount))
      ])
  }

  func items(_ entries: [TransactionEntry], enabled: Bool = true) -> [SpotlightPlan.Item] {
    SpotlightPlan.items(
      entries, enabled: enabled, hiddenAccounts: [secret],
      placeName: { [shop] in $0 == shop.id ? shop.name : nil })
  }

  @Test func onlyTheDescriptionAndThePlace() {
    let coffee = entry("Кофе", place: shop.id, account: open)
    let made = items([coffee, entry(nil, place: shop.id), entry("Taxi")])
    #expect(made.map(\.title) == ["Кофе", "Пятёрочка", "Taxi"])
    #expect(made.map(\.place) == ["Пятёрочка", nil, nil])
    #expect(made.first?.id == coffee.id.uuidString.lowercased())
    #expect(SpotlightPlan.operationId(of: made[0].id) == coffee.id)
  }

  /// No amount reaches the index: not the amount, not its digits.
  @Test func noAmountIsIndexed() {
    let made = items([entry("Обед", place: shop.id, amount: 98_765)])
    for item in made {
      let text = [item.title, item.place ?? ""].joined(separator: " ")
      #expect(!text.contains("98765"))
      #expect(!text.contains("98,765"))
      #expect(!text.contains("₽"))
    }
  }

  @Test func offIndexesNothing() {
    #expect(items([entry("Кофе")], enabled: false).isEmpty)
  }

  @Test func hiddenAccountsAreNeverIndexed() {
    let made = items([entry("Подарок", account: secret), entry("Кофе", account: open)])
    #expect(made.map(\.title) == ["Кофе"])
  }

  @Test func deletedAndEmptyOperationsAreLeftOut() {
    let made = items([entry("Удалено", deleted: true), entry(nil), entry("  \n ")])
    #expect(made.isEmpty)
  }

  @Test func aDescriptionOfSeveralLinesIsOneLine() {
    #expect(items([entry(" Кофе\nс собой ")]).map(\.title) == ["Кофе с собой"])
  }
}
