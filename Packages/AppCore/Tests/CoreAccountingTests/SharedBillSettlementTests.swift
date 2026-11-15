import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Кто кому сколько» for a trip or an event: bills paid by one of the people and shared by some.
/// Synthetic people only.
@Suite("Shared bill settlement")
struct SharedBillSettlementTests {
  private let anya = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private let boris = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  @Test func dinnerOfThreePaidByMeLeavesTwoDebtsToMe() {
    let bill = SharedBill(
      paidBy: .me, total: money(6000), sharedBy: [.me, .person(anya), .person(boris)])
    let result = SharedBillSettlement.settle([bill])
    #expect(result.balance(of: .me) == money(4000))
    #expect(result.balance(of: .person(anya)) == money(-2000))
    #expect(result.balance(of: .person(boris)) == money(-2000))
    #expect(
      Set(result.transfers)
        == [
          SettlementTransfer(from: .person(anya), to: .me, amount: money(2000)),
          SettlementTransfer(from: .person(boris), to: .me, amount: money(2000)),
        ])
  }

  @Test func sharesAddUpToTheBillToTheLastUnit() {
    // 1 of 3 cannot split evenly: 0.3333 + 0.3333 + 0.3334 — every unit is somebody's.
    let bill = SharedBill(
      paidBy: .person(anya), total: AmountE4(raw: 10_000),
      sharedBy: [.me, .person(anya), .person(boris)])
    let result = SharedBillSettlement.settle([bill])
    let sum = result.balances.values.reduce(AmountE4.zero, +)
    #expect(sum == .zero)
    let owed = result.transfers.reduce(AmountE4.zero) { $0 + $1.amount }
    #expect(owed == -(result.balances.values.filter { $0 < .zero }.reduce(AmountE4.zero, +)))
  }

  @Test func debtsThatCrossCancelOut() {
    // I paid 3000 for me and Anya; Anya paid 1000 for me and her: she owes me 1000 net.
    let result = SharedBillSettlement.settle([
      SharedBill(paidBy: .me, total: money(3000), sharedBy: [.me, .person(anya)]),
      SharedBill(paidBy: .person(anya), total: money(1000), sharedBy: [.me, .person(anya)]),
    ])
    #expect(
      result.transfers == [SettlementTransfer(from: .person(anya), to: .me, amount: money(1000))])
  }

  @Test func transfersAreFewerThanPeopleAndSettleEverybody() {
    let result = SharedBillSettlement.settle([
      SharedBill(paidBy: .me, total: money(9000), sharedBy: [.me, .person(anya), .person(boris)]),
      SharedBill(paidBy: .person(anya), total: money(3000), sharedBy: [.person(boris), .me]),
    ])
    var balances = result.balances
    for transfer in result.transfers {
      balances[transfer.from, default: .zero] += transfer.amount
      balances[transfer.to] = (balances[transfer.to] ?? .zero) - transfer.amount
    }
    #expect(balances.values.allSatisfy { $0 == .zero })
    #expect(result.transfers.count <= 2)
  }

  @Test func aBillOnlyItsPayerSharesOwesNothing() {
    let result = SharedBillSettlement.settle([
      SharedBill(paidBy: .me, total: money(500), sharedBy: [.me])
    ])
    #expect(result.transfers.isEmpty)
    #expect(result.balance(of: .me) == .zero)
  }

  @Test func aBillOfNobodyOrZeroIsLeftOut() {
    let result = SharedBillSettlement.settle([
      SharedBill(paidBy: .me, total: money(500), sharedBy: []),
      SharedBill(paidBy: .me, total: .zero, sharedBy: [.me, .person(anya)]),
    ])
    #expect(result.transfers.isEmpty)
  }

  @Test func theSameBillsGiveTheSameTransfersInTheSameOrder() {
    let bills = [
      SharedBill(paidBy: .me, total: money(7000), sharedBy: [.me, .person(anya), .person(boris)]),
      SharedBill(paidBy: .person(boris), total: money(1000), sharedBy: [.me, .person(anya)]),
    ]
    #expect(SharedBillSettlement.settle(bills) == SharedBillSettlement.settle(bills))
  }

  @Test func theDinnerOfTheLedgerIsTheSameBillAsTheEntryLineMakes() {
    // «Поровну» of the entry panel gives my share and one equal share owed by each; this is
    // the same arithmetic.
    let total = AmountE4(raw: 60_001)
    let outcome = PayingForRules.outcome(of: .evenly([anya, boris]), total: total)
    let result = SharedBillSettlement.settle([
      SharedBill(paidBy: .me, total: total, sharedBy: [.me, .person(anya), .person(boris)])
    ])
    for owed in outcome.owed {
      #expect(result.balance(of: .person(owed.person)) == -owed.amount)
    }
    #expect(result.balance(of: .me) == total - outcome.mine)
  }
}
