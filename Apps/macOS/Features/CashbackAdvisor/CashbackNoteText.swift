import AppCore
import Foundation

/// The words of a line of «Стоит посмотреть» about cashback (`CashbackNote`): the month's
/// choice to make, a place where another card pays more, the cashback trap. Each line says its
/// figures in words and a symbol, never in colour alone.
enum CashbackNoteText {
  static let table = "SyncHistory"

  /// Every key the lines use, so a test finds each in both languages.
  static let keys = [
    "cashback.note.choose", "cashback.note.payHere", "cashback.note.payHereCategory",
    "cashback.note.trap", "cashback.note.action.choose", "cashback.note.someCard",
  ]

  /// `accounts` names accounts and cards by id, `labels` places and categories.
  @MainActor
  static func text(
    _ note: CashbackNote, accounts: [UUID: String], labels: [UUID: String],
    _ environment: AppEnvironment
  ) -> String {
    func f(_ key: String, _ arguments: CVarArg...) -> String {
      String(
        format: environment.language(key, table: table), locale: environment.language.locale,
        arguments: arguments)
    }
    let money = environment.money
    switch note {
    case .choose(let due):
      return f(
        "cashback.note.choose", accounts[due.accountId] ?? "—",
        environment.dates.monthTitle(due.month))
    case .payHere(let hint):
      let card = holderName(hint.best, accounts: accounts, environment)
      let percents = [
        money.percent(hint.bestPercent), money.percent(hint.usualPercent),
        money.rounded(hint.gainRub, currency: .rub),
      ]
      if let place = hint.placeId.flatMap({ labels[$0] }) {
        return f("cashback.note.payHere", place, card, percents[0], percents[1], percents[2])
      }
      return f(
        "cashback.note.payHereCategory", hint.categoryId.flatMap { labels[$0] } ?? "—", card,
        percents[0], percents[1], percents[2])
    case .trap(let trap):
      return f(
        "cashback.note.trap", money.rounded(trap.spentRub, currency: .rub),
        money.rounded(trap.cashbackRub, currency: .rub), labels[trap.categoryId] ?? "—",
        money.rounded(trap.usualRub, currency: .rub))
    }
  }

  @MainActor
  static func holderName(
    _ candidate: CashbackCandidate, accounts: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    switch candidate.holder {
    case .card(let id), .account(let id):
      return accounts[id] ?? environment.language("cashback.note.someCard", table: table)
    }
  }

  static func symbol(_ note: CashbackNote) -> String {
    switch note {
    case .choose: "checklist"
    case .payHere: "creditcard"
    case .trap: "exclamationmark.triangle"
    }
  }
}
