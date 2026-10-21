import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Платежи и подписки» of an account's screen: the payments paid from the account or any of
/// its cards, and on the main account those that name no account.
@Suite("The payments of an account")
struct AccountPaymentsTests {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  let tBank = Self.id(1)
  let sber = Self.id(2)

  func status(
    _ number: Int, _ name: String, account: UUID?, card: UUID? = nil, next: String,
    active: Bool = true
  ) -> ScheduledStatus {
    let day = DateOnly(iso: next)!
    return ScheduledStatus(
      payment: ScheduledPayment(
        id: Self.id(number), name: name, amountE4: AmountE4(whole: 100), paymentMethodId: account,
        nextDate: day, active: active, cardId: card),
      dueDates: [day], nextDue: day, isOverdue: false, amountNext: AmountE4(whole: 100),
      monthly: AmountE4(whole: 100), yearly: AmountE4(whole: 1200),
      myShareRubNext: AmountE4(whole: 100), expectedReturnRubNext: nil, lastCharge: nil,
      chargedDifferently: false)
  }

  @Test func listsPaymentsOfTheAccountAndItsCards() {
    let statuses = [
      status(10, "Music", account: tBank, card: Self.id(11), next: "2026-09-20"),
      status(11, "Rent", account: tBank, next: "2026-10-01"),
      status(12, "Gym", account: sber, next: "2026-09-15"),
    ]
    #expect(
      AccountPayments.on(tBank, statuses: statuses, mainAccountId: sber).map(\.id) == [
        Self.id(10), Self.id(11),
      ])
  }

  @Test func noAccountMeansTheMainAccount() {
    let statuses = [
      status(10, "Water", account: nil, next: "2026-09-20"),
      status(11, "Gym", account: sber, next: "2026-09-15"),
    ]
    #expect(
      AccountPayments.on(sber, statuses: statuses, mainAccountId: sber).map(\.id) == [
        Self.id(11), Self.id(10),
      ])
    #expect(AccountPayments.on(tBank, statuses: statuses, mainAccountId: sber).isEmpty)
  }

  @Test func otherAccountsPaymentsAreNotListed() {
    let statuses = [
      status(10, "Gym", account: sber, next: "2026-09-15"),
      status(11, "Paused", account: tBank, next: "2026-09-15", active: false),
    ]
    #expect(AccountPayments.on(tBank, statuses: statuses, mainAccountId: sber).isEmpty)
  }

  @Test func sortedByNextUnpaidThenName() {
    let statuses = [
      status(10, "b", account: tBank, next: "2026-09-20"),
      status(11, "A", account: tBank, next: "2026-09-20"),
      status(12, "z", account: tBank, next: "2026-09-10"),
    ]
    #expect(
      AccountPayments.on(tBank, statuses: statuses, mainAccountId: sber).map(\.id) == [
        Self.id(12), Self.id(11), Self.id(10),
      ])
  }
}
