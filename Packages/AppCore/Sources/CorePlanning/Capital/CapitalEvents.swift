import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// An event supported by a dated purchase, sale or movement of a loan journal.
public struct CapitalEvent: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case purchase, sale, loanOpened, loanClosed
  }

  public var id: String
  public var kind: Kind
  public var day: DateOnly
  public var name: String
  /// The recorded amount in its original currency; absent when a sale has no operation.
  public var amountE4: AmountE4?
  public var currency: CurrencyCode
  public var accountIds: Set<UUID>

  public init(
    id: String, kind: Kind, day: DateOnly, name: String, amountE4: AmountE4?,
    currency: CurrencyCode, accountIds: Set<UUID> = []
  ) {
    self.id = id
    self.kind = kind
    self.day = day
    self.name = name
    self.amountE4 = amountE4
    self.currency = currency
    self.accountIds = accountIds
  }
}

public enum CapitalEvents {
  /// Evaluations and opening balances are observations, never evidence of a purchase or
  /// origination. Only things included in capital and loans with recorded movements qualify.
  public static func build(
    ledger: Ledger, journal: [DebtEntry], today: DateOnly
  ) -> [CapitalEvent] {
    let dataset = ledger.dataset
    let entries = Dictionary(ledger.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let valuedItems = Set(dataset.thingValuations.filter { $0.owner == .ownedItem }.map(\.ownerId))
    var events: [CapitalEvent] = []
    for item in dataset.ownedItems where !item.archived && valuedItems.contains(item.id) {
      if let day = item.boughtOn, day <= today {
        events.append(
          CapitalEvent(
            id: "item.\(item.id).purchase", kind: .purchase, day: day, name: item.name,
            amountE4: item.priceE4, currency: item.currency))
      }
      if let day = item.soldOn, day <= today {
        let sale = item.saleTransactionId.flatMap { entries[$0]?.transaction }
        let income = sale.flatMap { $0.kind == .income ? $0 : nil }
        events.append(
          CapitalEvent(
            id: "item.\(item.id).sale", kind: .sale, day: day, name: item.name,
            amountE4: income?.amountE4, currency: income?.currency ?? item.currency,
            accountIds: Set(income?.paymentMethodId.map { [$0] } ?? [])))
      }
    }

    let byDebt = Dictionary(grouping: journal, by: \.debtId)
    for debt in dataset.debts where !debt.isDeleted && debt.direction == .iOwe && debt.type == .loan
    {
      let all = byDebt[debt.id] ?? []
      let dated = all.compactMap { line -> (line: DebtEntry, day: DateOnly)? in
        guard let day = line.date ?? line.occurredAt.map(ledger.calendar.day(of:)), day <= today
        else { return nil }
        return (line, day)
      }.sorted {
        if $0.day != $1.day { return $0.day < $1.day }
        return $0.line.id.uuidString < $1.line.id.uuidString
      }
      func accounts(_ line: DebtEntry) -> Set<UUID> {
        Set(
          [
            line.paymentMethodId,
            line.transactionId.flatMap { entries[$0]?.transaction.paymentMethodId },
          ].compactMap { $0 })
      }
      // An undated balance makes the start ambiguous. A dated balance without a movement
      // likewise says when it was entered, rather than when the bank issued the loan.
      let hasUndated = all.contains { $0.date == nil && $0.occurredAt == nil }
      if !hasUndated, let first = dated.first,
        first.line.kind == .borrowed, !first.line.tranche, first.line.amountE4 > .zero,
        first.line.occurredAt != nil || first.line.transactionId.flatMap({ entries[$0] }) != nil
      {
        events.append(
          CapitalEvent(
            id: "debt.\(debt.id).opened", kind: .loanOpened, day: first.day, name: debt.name,
            amountE4: first.line.amountE4, currency: debt.currency,
            accountIds: accounts(first.line)))
      }
      // A closed flag has no date. A final payment that clears principal and accrued
      // interest supplies one; adjustments and write-offs must not become payoff events.
      let latestDay = all.compactMap { $0.date ?? $0.occurredAt.map(ledger.calendar.day(of:)) }
        .max()
      if debt.closed, !hasUndated, let lastDay = dated.last?.day, lastDay == latestDay {
        let payments = dated.filter {
          $0.day == lastDay && $0.line.kind == .payment && $0.line.amountE4 < .zero
        }
        let owed = DebtBalanceAt.owed(
          of: debt, journal: all, through: lastDay, calendar: ledger.calendar)
        let before = DebtBalanceAt.owed(
          of: debt, journal: all, through: ledger.calendar.adding(days: -1, to: lastDay),
          calendar: ledger.calendar)
        let hasWriteOff = dated.contains {
          $0.day == lastDay && $0.line.kind != .payment && $0.line.amountE4 < .zero
        }
        if !payments.isEmpty, !hasWriteOff, before.balance + before.accruedE4 > .zero,
          owed.balance + owed.accruedE4 <= .zero
        {
          events.append(
            CapitalEvent(
              id: "debt.\(debt.id).closed", kind: .loanClosed, day: lastDay, name: debt.name,
              amountE4: -AmountE4.sum(payments.map { $0.line.amountE4 }), currency: debt.currency,
              accountIds: payments.reduce(into: Set<UUID>()) { $0.formUnion(accounts($1.line)) }))
        }
      }
    }
    return events.sorted {
      if $0.day != $1.day { return $0.day < $1.day }
      return $0.id < $1.id
    }
  }
}
