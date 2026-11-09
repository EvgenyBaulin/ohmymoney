import AppCore
import Foundation

/// The app's side of `BankTextMemory`: where it is kept (`statement.learned` in the `settings`
/// table), the scope of an account, and the three moments it learns or is used outside the
/// loading of statements — the owner's edit of an operation a pair filled, a text of a bank that
/// stands for an operation typed by hand, and the shop a text of a bank is offered under.
@MainActor
enum BankTextLearning {
  static func memory(_ environment: AppEnvironment) -> BankTextMemory {
    BankTextMemory.decoded((try? environment.settings?.string(BankTextMemory.settingsKey)) ?? nil)
  }

  /// The account and its bank. An account without a bank is a bank of its own (`bankId` nil):
  /// what it learned is used for it alone.
  nonisolated static func scope(
    account: UUID, accounts: [PaymentMethod]
  ) -> BankTextMemory.Scope {
    BankTextMemory.Scope(
      accountId: account, bankId: accounts.first { $0.id == account }?.bankId)
  }

  /// Writes the memory outside of ⌘Z — the way the shops' names of auto entry are kept: it is a
  /// habit the app picks up, not a change of the books.
  @discardableResult
  static func save(_ memory: BankTextMemory, environment: AppEnvironment) -> Bool {
    guard let text = memory.encoded() else { return false }
    return AppEnvironment.attempt("statement.learned", on: environment.settings) {
      try $0.set(BankTextMemory.settingsKey, to: text)
    }
  }

  /// The owner saved an edit of an operation: if a learned pair filled it, or was learned from
  /// it, what he wrote now is what the bank's text means from now on. Says whether it taught.
  @discardableResult
  static func edited(_ entry: TransactionEntry, environment: AppEnvironment) -> Bool {
    var memory = memory(environment)
    guard memory.remembers(operation: entry.id),
      memory.relearn(operation: entry.id, fill: BankTextFill(entry: entry)),
      save(memory, environment: environment)
    else { return false }
    AppLog.info("statement.relearned", .db, "an edit taught a text of a bank anew")
    return true
  }

  /// A text of a bank came for an operation the owner had typed by hand already: the shop as
  /// the bank spells it is learned as what he wrote. Says whether it taught.
  @discardableResult
  static func matched(
    message: BankMessage, account: UUID, entry: TransactionEntry, accounts: [PaymentMethod],
    environment: AppEnvironment
  ) -> Bool {
    var memory = memory(environment)
    guard
      AutoEntryMemory.learn(
        &memory, message: message, entry: entry,
        scope: scope(account: account, accounts: accounts)),
      save(memory, environment: environment)
    else { return false }
    AppLog.info("autoEntry.learnedPair", .db, "a text of a bank was matched with a typed operation")
    return true
  }

  /// The name of the place the owner wrote the shop of this text as, on this account or another
  /// of its bank; `nil` when nothing was learned or the place is gone.
  nonisolated static func placeName(
    for message: BankMessage, account: UUID?, accounts: [PaymentMethod],
    places: [ParserVocabulary.Entry], memory: BankTextMemory
  ) -> String? {
    guard let account,
      let fill = AutoEntryMemory.fill(
        memory, message: message, scope: scope(account: account, accounts: accounts)),
      let place = fill.placeId
    else { return nil }
    return places.first { $0.id == place }?.name
  }
}
