import AppCore
import Foundation

extension AccountCardChoices {
  /// The choices of a picker that offers accounts alone — a transfer, a count, a move of a
  /// selection to another account — named as every list of accounts names them
  /// (`AccountLabels`): a bank with one live account is called by the bank, a bank with several
  /// names each «Банк › Счёт», an account with no bank by itself. No card is offered.
  ///
  /// `accounts` are the choices in the order to show them; `every` is every account there is
  /// when `accounts` leaves some out, so a bank counts as many accounts as it has live ones.
  static func accountItems(
    accounts: [PaymentMethod], banks: [Bank], among every: [PaymentMethod]? = nil,
    locale: Locale
  ) -> [Item] {
    AccountLabels(accounts: every ?? accounts, cards: [], banks: banks)
      .entries(offering: accounts, withCards: false, locale: locale)
      .map { Item(id: $0.id, name: $0.name, isCard: false) }
  }
}
