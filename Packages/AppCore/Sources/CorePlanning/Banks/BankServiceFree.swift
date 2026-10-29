import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// How far an account is from free service this month: the spending on its cards, or the balance
/// it keeps, whichever the bank asks for. The conditions are the owner's words; the figures
/// are a hint and the bank has the last word.
public struct BankServiceProgress: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  public var currency: CurrencyCode
  /// The spending of the month that makes the service free; `nil`: not a condition.
  public var spendTargetE4: AmountE4?
  public var spentE4: AmountE4
  /// The balance that makes the service free; `nil`: not a condition.
  public var balanceTargetE4: AmountE4?
  public var balanceE4: AmountE4?
  /// The last day of the month: the day the spending counts through.
  public var through: DateOnly

  public var id: UUID { accountId }

  public var spendMet: Bool { spendTargetE4.map { spentE4 >= $0 } ?? false }
  public var balanceMet: Bool {
    guard let target = balanceTargetE4, let balance = balanceE4 else { return false }
    return balance >= target
  }
  /// One of the conditions is met, so the service is free.
  public var isFree: Bool { spendMet || balanceMet }
  /// What is left to spend; `nil` without a spending condition, zero once it is met.
  public var spendLeftE4: AmountE4? {
    spendTargetE4.map { spentE4 >= $0 ? .zero : $0 - spentE4 }
  }
  /// What the balance lacks; `nil` without a balance condition or a known balance.
  public var balanceShortE4: AmountE4? {
    guard let target = balanceTargetE4, let balance = balanceE4 else { return nil }
    return balance >= target ? .zero : target - balance
  }

  public init(
    accountId: UUID, currency: CurrencyCode, spendTargetE4: AmountE4?, spentE4: AmountE4,
    balanceTargetE4: AmountE4?, balanceE4: AmountE4?, through: DateOnly
  ) {
    self.accountId = accountId
    self.currency = currency
    self.spendTargetE4 = spendTargetE4
    self.spentE4 = spentE4
    self.balanceTargetE4 = balanceTargetE4
    self.balanceE4 = balanceE4
    self.through = through
  }
}

public enum BankServiceFree {
  /// The purchases on the cards of `accountId` in `month`, in the currency of the conditions:
  /// live expenses paid with a card of the account, without what the app wrote to keep the books
  /// right, payments of debts, cash taken out and goal contributions.
  public static func spending(
    accountId: UUID, currency: CurrencyCode, month: MonthKey, ledger: Ledger
  ) -> AmountE4 {
    let dataset = ledger.dataset
    let cashTags = Set(
      dataset.tagBook.tags.filter { BankLimitTags.kind(ofTag: $0.name) != nil }.map(\.id))
    var total = AmountE4.zero
    for entry in dataset.entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        transaction.paymentMethodId == accountId, transaction.cardId != nil,
        transaction.debtId == nil, transaction.creditDebtId == nil,
        transaction.movedMoney.currency == currency
      else { continue }
      if let link = OperationLink(externalId: transaction.externalId) {
        if link.isBookkeeping { continue }
        if case .transferFee = link { continue }
      }
      let day = ledger.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      guard day.monthKey == month else { continue }
      let tagged = entry.parts.contains { part in
        dataset.tagBook.tagIds(of: part.id).contains { cashTags.contains($0) }
      }
      if tagged || entry.parts.allSatisfy({ $0.goalId != nil }) { continue }
      total += transaction.movedMoney.amount
    }
    return total
  }

  /// The progress of every account that states a condition of free service; the card rows
  /// state the same for one card and are read with the account's.
  public static func progress(
    ledger: Ledger, data: BankData, accounts: AccountsSnapshot, today: DateOnly
  ) -> [BankServiceProgress] {
    let month = today.monthKey
    let live = Set(ledger.dataset.paymentMethods.filter { !$0.archived }.map(\.id))
    var result: [BankServiceProgress] = []
    for conditions in data.conditions where conditions.cardId == nil {
      guard live.contains(conditions.accountId),
        conditions.serviceFreeSpendE4 != nil || conditions.serviceFreeBalanceE4 != nil
      else { continue }
      let balance = accounts.line(of: conditions.accountId)?.keys
        .first { $0.key.currency == conditions.currency }?.balance
      result.append(
        BankServiceProgress(
          accountId: conditions.accountId, currency: conditions.currency,
          spendTargetE4: conditions.serviceFreeSpendE4,
          spentE4: spending(
            accountId: conditions.accountId, currency: conditions.currency, month: month,
            ledger: ledger),
          balanceTargetE4: conditions.serviceFreeBalanceE4, balanceE4: balance,
          through: month.lastDay))
    }
    return result
  }
}

/// The balance an account is asked to keep, checked before an operation is written.
public struct MinBalanceWarning: Hashable, Sendable {
  public var minimumE4: AmountE4
  public var afterE4: AmountE4
  public var currency: CurrencyCode

  public init(minimumE4: AmountE4, afterE4: AmountE4, currency: CurrencyCode) {
    self.minimumE4 = minimumE4
    self.afterE4 = afterE4
    self.currency = currency
  }
}

public enum BankMinBalance {
  /// The warning for spending `spendE4` from an account that holds `balanceE4` when the bank asks
  /// to keep `minimumE4`: given when the balance stands at or above the minimum now and would
  /// fall below it. An account already below is not nagged at every record; its card says so.
  public static func warning(
    balanceE4: AmountE4, spendE4: AmountE4, minimumE4: AmountE4, currency: CurrencyCode
  ) -> MinBalanceWarning? {
    guard spendE4.raw > 0, balanceE4 >= minimumE4 else { return nil }
    let after = balanceE4 - spendE4
    guard after < minimumE4 else { return nil }
    return MinBalanceWarning(minimumE4: minimumE4, afterE4: after, currency: currency)
  }

  /// The account's balance now below its minimum, or `nil`.
  public static func shortfall(
    balanceE4: AmountE4?, minimumE4: AmountE4?
  ) -> AmountE4? {
    guard let balanceE4, let minimumE4, balanceE4 < minimumE4 else { return nil }
    return minimumE4 - balanceE4
  }
}
