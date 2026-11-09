import CoreKit
import Foundation

/// A text a bank sent on its own (an SMS, a push) uses and teaches the same memory as the
/// statements (`BankTextMemory`): the shop as the bank spells it is the text, the card's account
/// is the scope. A statement's «SAMPLE CAFE» and an SMS's «SAMPLE CAFE» of the same card are one
/// pair, whichever came first.
public enum AutoEntryMemory {
  /// What the owner made of the message's shop on this account (or another of its bank).
  public static func fill(
    _ memory: BankTextMemory, message: BankMessage, scope: BankTextMemory.Scope
  ) -> BankTextFill? {
    guard let merchant = message.merchant else { return nil }
    return memory.fill(scope: scope, kind: message.kind, text: merchant)
  }

  /// The message stands for `entry`, typed by hand: remember what the owner made of the shop.
  @discardableResult
  public static func learn(
    _ memory: inout BankTextMemory, message: BankMessage, entry: TransactionEntry,
    scope: BankTextMemory.Scope
  ) -> Bool {
    guard let merchant = message.merchant else { return false }
    return memory.learn(
      scope: scope, kind: message.kind, text: merchant, fill: BankTextFill(entry: entry),
      operation: entry.id)
  }

  /// The operation typed by hand that the message is about: of the card's account, of the day,
  /// kind, amount and currency the text says — and only when one such operation exists, since a
  /// guess would teach the wrong pair. Lines that came from a statement or a screenshot are the
  /// bank's own and are passed over. `dayOf` reads an operation's day in the zone it was
  /// recorded in.
  public static func handTyped(
    for message: BankMessage, account: UUID, on day: DateOnly, entries: [TransactionEntry],
    dayOf: (Transaction) -> DateOnly
  ) -> TransactionEntry? {
    let found = entries.filter { entry in
      let transaction = entry.transaction
      return !transaction.isDeleted && transaction.paymentMethodId == account
        && transaction.kind == message.kind && transaction.currency == message.money.currency
        && transaction.amountE4 == message.money.amount
        && transaction.source != "statement" && transaction.source != "screenshot"
        && dayOf(transaction) == day
    }
    return found.count == 1 ? found[0] : nil
  }
}
