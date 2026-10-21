import CoreKit
import Foundation

/// One account merged into another, worked out before anything is written.
public enum AccountMerge {
  /// The merge of `source` into `target` at `at`. A merge is no count: the merged account
  /// behaves as if the two had always been one, so every balance it writes is dated at a real
  /// count that already was, never at the merge, and an operation dated after that count —
  /// entered before the merge or after it — moves money.
  ///
  /// * the target holds its own currencies, in its order, then those of the source it lacks;
  /// * it is the main account when either of the two was;
  /// * the transfers between the two in one currency go — they would move money from the
  ///   account to itself; an exchange between them stays, inside the merged account;
  /// * in each currency, with T the target's latest count and S the source's:
  ///   - both counted: the target is counted at T's moment at T plus what the source held
  ///     then — its balance then when S was made by then, else S less what moved on the
  ///     source between T and S;
  ///   - only the source counted, the target never moved: the target is counted at S's
  ///     moment with S's money;
  ///   - only the target ever moved or was counted: nothing is written, the target keeps its
  ///     own counts;
  ///   - one counted, the other moved but never counted: the key goes into `needsBalance`,
  ///     which the merge dialog asks for (`AccountMergePlan.count(_:typed:)`). Left empty, a
  ///     counted target is counted again at its own latest count with that count's money, so
  ///     what the other account moved before it is history; a counted source leaves the
  ///     target uncounted;
  ///   - neither counted: nothing is written and nothing asked — the merged key stays
  ///     uncounted;
  /// * the source is counted at zero right after its own latest count in every currency it
  ///   was counted in: its money now lives in the target, and bringing the source back from
  ///   the archive must not count it twice.
  public static func plan(
    source: PaymentMethod, target: PaymentMethod, transfers: [Transfer],
    balances: AccountBalances, at: Date
  ) -> (plan: AccountMergePlan, needsBalance: [BalanceKey]) {
    var merged = target
    var others = Array(target.currencies.dropFirst())
    for currency in source.currencies where !target.holds(currency) && !others.contains(currency) {
      others.append(currency)
    }
    merged.otherCurrencies = others
    merged.isDefault = target.isDefault || source.isDefault
    merged.archived = false

    let pair: Set<UUID> = [source.id, target.id]
    let deleted =
      transfers.filter {
        !$0.isExchange && pair.contains($0.fromAccountId) && pair.contains($0.toAccountId)
          && $0.fromAccountId != $0.toAccountId
      }.map(\.id)

    var sourceCurrencies = source.currencies
    for key in balances.keys where key.accountId == source.id {
      if !sourceCurrencies.contains(key.currency) { sourceCurrencies.append(key.currency) }
    }
    var currencies = merged.currencies
    for currency in sourceCurrencies where !currencies.contains(currency) {
      currencies.append(currency)
    }

    var opening: [BalanceKey: AmountE4] = [:]
    var moments: [BalanceKey: Date] = [:]
    var needsBalance: [BalanceKey] = []
    var sourceZero: [BalanceKey] = []
    for currency in currencies {
      let into = BalanceKey(accountId: target.id, currency: currency)
      let from = BalanceKey(accountId: source.id, currency: currency)
      let intoCount = balances.latestAnchor(into)
      let fromCount = balances.latestAnchor(from)
      if let fromCount {
        sourceZero.append(from)
        moments[from] = fromCount.at
      }
      switch (intoCount, fromCount) {
      case (let intoCount?, let fromCount?):
        let sourceThen: AmountE4
        if fromCount.at <= intoCount.at {
          sourceThen = balances.balance(from, at: intoCount.at) ?? fromCount.balance.actualE4
        } else {
          sourceThen =
            fromCount.balance.actualE4
            - balances.moved(from, after: intoCount.at, through: fromCount.at)
        }
        opening[into] = intoCount.balance.actualE4 + sourceThen
        moments[into] = intoCount.at
      case (let intoCount?, nil):
        guard balances.hasHistory(from) else { continue }
        needsBalance.append(into)
        opening[into] = intoCount.balance.actualE4
        moments[into] = intoCount.at
      case (nil, let fromCount?):
        if balances.hasHistory(into) {
          needsBalance.append(into)
        } else {
          opening[into] = fromCount.balance.actualE4
          moments[into] = fromCount.at
        }
      case (nil, nil):
        continue
      }
    }
    let plan = AccountMergePlan(
      sourceId: source.id, target: merged, deletedTransferIds: deleted, opening: opening, at: at,
      sourceZero: sourceZero.sorted(), moments: moments)
    return (plan, needsBalance.sorted())
  }

  /// What the merged account holds now in each currency once `plan` is written, from the
  /// balances before it: the count it will rest on plus what moved on either account after
  /// that count. A currency it will not know is left out. What the merge dialog shows.
  public static func balancesAfter(
    _ plan: AccountMergePlan, source: UUID, balances: AccountBalances
  ) -> [BalanceKey: AmountE4] {
    var keys = Set(plan.opening.keys)
    for currency in plan.target.currencies {
      keys.insert(BalanceKey(accountId: plan.target.id, currency: currency))
    }
    var result: [BalanceKey: AmountE4] = [:]
    for into in keys {
      let anchor: (amount: AmountE4, at: Date)
      if let amount = plan.opening[into] {
        anchor = (amount, plan.moments[into] ?? plan.at)
      } else if let count = balances.latestAnchor(into) {
        anchor = (count.balance.actualE4, count.at)
      } else {
        continue
      }
      let from = BalanceKey(accountId: source, currency: into.currency)
      let through = max(balances.now, anchor.at)
      result[into] =
        anchor.amount + balances.moved(into, after: anchor.at, through: through)
        + balances.moved(from, after: anchor.at, through: through)
    }
    return result
  }
}
