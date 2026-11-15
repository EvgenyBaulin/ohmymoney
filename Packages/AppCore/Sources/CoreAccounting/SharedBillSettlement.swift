import CoreKit
import Foundation

/// One side of a shared bill: the owner or one of the people of the books.
public enum SettlementParty: Hashable, Sendable {
  case me
  case person(UUID)

  /// A fixed order for ties, so the same bills always settle the same way.
  fileprivate var sortKey: String {
    switch self {
    case .me: "0"
    case .person(let id): "1" + id.uuidString
    }
  }
}

/// A bill one of the people paid and several shared equally — a dinner, a taxi, a flat of a trip.
public struct SharedBill: Hashable, Sendable {
  public var paidBy: SettlementParty
  public var total: AmountE4
  /// Everyone whose share the bill is, the payer too when they ate as well. The payer need not
  /// be among them (paying for others only). The first in the list takes the extra units when
  /// the bill does not split evenly.
  public var sharedBy: [SettlementParty]

  public init(paidBy: SettlementParty, total: AmountE4, sharedBy: [SettlementParty]) {
    self.paidBy = paidBy
    self.total = total
    self.sharedBy = sharedBy
  }
}

/// «X gives Y this much» — one payment that closes part of the settlement.
public struct SettlementTransfer: Hashable, Sendable {
  public var from: SettlementParty
  public var to: SettlementParty
  public var amount: AmountE4

  public init(from: SettlementParty, to: SettlementParty, amount: AmountE4) {
    self.from = from
    self.to = to
    self.amount = amount
  }
}

/// Who owes whom after a set of shared bills.
public struct SharedBillSettlement: Hashable, Sendable {
  /// Per party: what they paid less their shares. Positive — is owed money, negative — owes.
  /// Together the balances add up to exactly zero.
  public var balances: [SettlementParty: AmountE4]
  /// The fewest payments that settle everybody, largest first.
  public var transfers: [SettlementTransfer]

  public func balance(of party: SettlementParty) -> AmountE4 { balances[party] ?? .zero }

  /// What the owner is owed (positive) or owes (negative) by each person, from the transfers.
  public func owedToMe(by person: UUID) -> AmountE4 {
    transfers.reduce(.zero) { sum, transfer in
      if transfer.to == .me, transfer.from == .person(person) { return sum + transfer.amount }
      if transfer.from == .me, transfer.to == .person(person) { return sum - transfer.amount }
      return sum
    }
  }

  /// Equal shares, the units that do not divide going to the first in each bill's list
  /// (`AmountE4.split`), so the shares of a bill always add up to its total. A bill nobody
  /// shared, or of nothing, is left out.
  public static func settle(_ bills: [SharedBill]) -> SharedBillSettlement {
    var balances: [SettlementParty: AmountE4] = [:]
    for bill in bills where bill.total > .zero && !bill.sharedBy.isEmpty {
      balances[bill.paidBy, default: .zero] += bill.total
      let shares = bill.total.split(into: bill.sharedBy.count)
      for (party, share) in zip(bill.sharedBy, shares) {
        balances[party] = (balances[party] ?? .zero) - share
      }
    }
    balances = balances.filter { !$0.value.isZero }
    return SharedBillSettlement(balances: balances, transfers: transfers(for: balances))
  }

  /// Greedy: the biggest debtor pays the biggest creditor as much as either can, until all are
  /// even. Never more payments than people less one.
  private static func transfers(for balances: [SettlementParty: AmountE4]) -> [SettlementTransfer]
  {
    func ordered(_ items: [(SettlementParty, AmountE4)]) -> [(SettlementParty, AmountE4)] {
      items.sorted { left, right in
        left.1 != right.1 ? left.1 > right.1 : left.0.sortKey < right.0.sortKey
      }
    }
    var creditors = ordered(balances.filter { $0.value > .zero }.map { ($0.key, $0.value) })
    var debtors = ordered(balances.filter { $0.value < .zero }.map { ($0.key, -$0.value) })
    var result: [SettlementTransfer] = []
    while let creditor = creditors.first, let debtor = debtors.first {
      let amount = min(creditor.1, debtor.1)
      result.append(SettlementTransfer(from: debtor.0, to: creditor.0, amount: amount))
      creditors[0].1 = creditors[0].1 - amount
      debtors[0].1 = debtors[0].1 - amount
      if creditors[0].1.isZero { creditors.removeFirst() }
      if debtors[0].1.isZero { debtors.removeFirst() }
      creditors = ordered(creditors)
      debtors = ordered(debtors)
    }
    return result
  }
}
