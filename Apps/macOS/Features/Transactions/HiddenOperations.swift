import AppCore
import Foundation

/// The operations the lists leave out while the hidden accounts are covered: those of a hidden
/// account, by the account they name or by a card of it. The totals keep their money; a list
/// that loses some of its rows says «часть скрыта» next to its figure instead of saying how much.
///
/// Read from the snapshot the screen draws (`DataSnapshot.hiding`), never from what the shield
/// learned later, so not a frame lists an operation the owner hid. Revealed, it hides nothing.
struct HiddenOperations: Hashable, Sendable {
  let accounts: HiddenAccounts
  let cards: Set<UUID>

  static let none = HiddenOperations(accounts: HiddenAccounts(ids: [UUID]()), cards: [])

  init(accounts: HiddenAccounts, cards: Set<UUID>) {
    self.accounts = accounts
    self.cards = cards
  }

  /// What the snapshot on screen is presented without; nothing for the whole one.
  init(snapshot: DataSnapshot) {
    let accounts = snapshot.hiding
    self.init(accounts: accounts, cards: accounts.cardIds(in: snapshot.ledger.dataset.cards))
  }

  var isEmpty: Bool { accounts.isEmpty && cards.isEmpty }

  func hides(account: UUID?, card: UUID?) -> Bool {
    accounts.isHidden(account) || (card.map(cards.contains) ?? false)
  }

  func hides(_ transaction: Transaction) -> Bool {
    hides(account: transaction.paymentMethodId, card: transaction.cardId)
  }

  func hides(_ entry: TransactionEntry) -> Bool { hides(entry.transaction) }

  func hides(_ row: LedgerRow) -> Bool { hides(account: row.paymentMethodId, card: row.cardId) }

  /// An operation of the ledger by its id; an id the ledger does not know hides nothing.
  func hides(operation id: UUID?, in ledger: Ledger) -> Bool {
    guard !isEmpty, let id, let entry = ledger.entry(id) else { return false }
    return hides(entry)
  }

  /// A transfer between two hidden accounts has nothing to show; one between a hidden and a
  /// visible account is shown with a neutral caption (`HiddenAccounts.caption(for:)`).
  func hides(_ transfer: Transfer) -> Bool {
    accounts.caption(for: transfer) == .betweenHidden
  }

  /// Some operation of a hidden account lies in `range`: a figure of these days holds money the
  /// lists do not show. `kinds` narrows it to what the figure counts; `nil` takes every kind.
  func touches(
    _ range: DayRange, in ledger: Ledger, kinds: Set<TransactionKind>? = nil
  ) -> Bool {
    guard !isEmpty else { return false }
    return ledger.rows(in: range).contains { row in
      (kinds?.contains(row.kind) ?? true) && hides(row)
    }
  }
}
