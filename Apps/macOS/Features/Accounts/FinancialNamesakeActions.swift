import AppCore
import AppDatabase
import Foundation

extension PlanningActions {
  /// The explicit rename changes only the chosen spelling, never the archive state or links.
  func renameFinancialNamesake(_ record: NamesakeRecord, to name: String, spelling: String?) -> Bool
  {
    let accounts = AccountActions(environment: environment, store: store)
    guard
      let change = Self.renamingArchivedFinancialRecord(
        record, to: name, spelling: spelling,
        accounts: accounts.all, cards: accounts.cards, banks: accounts.banks)
    else { return false }
    guard apply(change) else { return false }
    environment.refreshVocabulary()
    return true
  }

  static func renamingArchivedFinancialRecord(
    _ record: NamesakeRecord, to name: String, spelling: String? = nil,
    accounts: [PaymentMethod], cards: [PaymentCard], banks: [Bank]
  ) -> PlanningChange? {
    let name = trimmed(name)
    guard !name.isEmpty else { return nil }
    var rows = PlanningRows.empty
    switch record.kind {
    case .account:
      guard var account = accounts.first(where: { $0.id == record.id }), account.archived else {
        return nil
      }
      if let spelling {
        guard let index = account.aliases.firstIndex(of: spelling) else { return nil }
        account.aliases[index] = name
      } else {
        account.name = name
      }
      rows.paymentMethods = [account]
    case .card:
      guard var card = cards.first(where: { $0.id == record.id }),
        card.archived || accounts.contains(where: { $0.id == card.accountId && $0.archived })
      else { return nil }
      if let spelling {
        guard let index = card.aliases.firstIndex(of: spelling) else { return nil }
        card.aliases[index] = name
      } else {
        card.name = name
      }
      rows.cards = [card]
    case .bank:
      guard var bank = banks.first(where: { $0.id == record.id }), bank.archived else { return nil }
      bank.name = name
      rows.banks = [bank]
    default: return nil
    }
    return PlanningChange(upsert: rows)
  }

  func restoreFinancialCard(_ id: UUID) -> Bool {
    let accounts = AccountActions(environment: environment, store: store)
    guard let card = accounts.cards.first(where: { $0.id == id }) else { return false }
    if accounts.all.contains(where: { $0.id == card.accountId && $0.archived }) {
      return accounts.restore(card.accountId, includingCard: id) == .done
    }
    return CardActions(environment: environment, store: store).restore(id) == .done
  }
}
