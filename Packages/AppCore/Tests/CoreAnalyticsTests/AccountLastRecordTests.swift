import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The moment the owner last wrote an operation down on an account: the latest `createdAt` of
/// its live operations, as «Последняя запись» of Overview reads the moment of writing — without
/// the lines the app writes to keep the books right, and without transfers and their fees.
@Suite("The last operation written on each account")
struct AccountLastRecordTests {
  let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
  let card = PaymentMethod(name: "Card", currency: .rub)
  let cash = PaymentMethod(name: "Cash", currency: .rub)

  let base = Date(timeIntervalSince1970: 1_790_000_000)

  func at(_ minutes: Int) -> Date { base.addingTimeInterval(TimeInterval(minutes * 60)) }

  func operation(
    on account: UUID?, written minutes: Int, happened: Int = 0, externalId: String? = nil,
    deleted: Bool = false
  ) -> TransactionEntry {
    let id = UUID()
    let amount = AmountE4(whole: 100)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: at(happened), amountE4: amount,
        paymentMethodId: account, externalId: externalId, createdAt: at(minutes),
        updatedAt: at(minutes), deletedAt: deleted ? at(minutes + 1) : nil),
      parts: [TransactionPart(transactionId: id, amountE4: amount)])
  }

  @Test func eachAccountHasTheMomentOfItsLatestWriting() {
    let dataset = Dataset(
      entries: [
        operation(on: card.id, written: 10),
        // Written later about an earlier day: written now.
        operation(on: card.id, written: 30, happened: -600),
        operation(on: main.id, written: 20),
        // An operation that names no account is on the main one.
        operation(on: nil, written: 25),
      ],
      paymentMethods: [main, card, cash])
    let moments = AccountLastRecord.byAccount(dataset)
    #expect(moments[card.id] == at(30))
    #expect(moments[main.id] == at(25))
    #expect(moments[cash.id] == nil)
    #expect(AccountLastRecord.latest(of: [card.id, cash.id], in: moments) == at(30))
    #expect(AccountLastRecord.latest(of: [cash.id], in: moments) == nil)
  }

  @Test func whatTheAppWritesAndWhatIsDeletedDoNotCount() {
    let transferId = UUID()
    let dataset = Dataset(
      entries: [
        operation(on: card.id, written: 10),
        operation(on: card.id, written: 40, deleted: true),
        operation(on: card.id, written: 50, externalId: "reimb:1:surplus"),
        operation(
          on: card.id, written: 60,
          externalId: "reconcile:\(UUID().uuidString.lowercased())"),
        operation(
          on: card.id, written: 90,
          externalId: "transfer:\(transferId.uuidString.lowercased()):fee"),
      ],
      paymentMethods: [main, card, cash])
    // The fee goes with its transfer, which is no operation of the account.
    #expect(AccountLastRecord.byAccount(dataset)[card.id] == at(10))
  }
}
