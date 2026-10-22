import AppCore
import Foundation

/// The words of quick entry: the strip above the line, its sheets, the note of a day, the move
/// to another day and the card's digits. Table «QuickEntry», both languages.
@MainActor
enum QuickText {
  static let table = "QuickEntry"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// A string with a count in it (plural forms in the catalog).
  static func counted(_ key: String, _ environment: AppEnvironment, _ count: Int) -> String {
    environment.language.counted(key, table: table, [count])
  }

  /// «Кофе: 250 ₽ → 350 ₽. Исправить?», or the longer question for an operation written more
  /// than an hour ago.
  static func correction(_ offer: QuickCorrection.Offer, _ environment: AppEnvironment) -> String {
    let old = offer.before.transaction
    let new = offer.after.transaction
    let name = old.note.flatMap { $0.isEmpty ? nil : $0 } ?? t("quick.operation", environment)
    let before = environment.money.exact(old.amountE4, currency: old.currency)
    let after = environment.money.exact(new.amountE4, currency: new.currency)
    return f(
      offer.isStale ? "quick.correction.stale" : "quick.correction.ask", environment, name, before,
      after)
  }

  /// «Пятёрочка · 1,250 ₽ · карта •••• 3230».
  static func bank(_ offer: BankOffer, _ environment: AppEnvironment) -> String {
    var words: [String] = []
    if let merchant = offer.message.merchant, !merchant.isEmpty { words.append(merchant) }
    words.append(
      environment.money.exact(offer.message.money.amount, currency: offer.message.money.currency))
    if let digits = offer.message.cardLast4 {
      words.append(f("quick.bank.card", environment, "•••• " + digits))
    }
    return f("quick.bank.read", environment, words.joined(separator: " · "))
  }

  static func balance(_ offer: BankOffer, _ environment: AppEnvironment) -> String? {
    guard let balance = offer.message.balance else { return nil }
    return f(
      "quick.bank.reconcile", environment,
      environment.money.exact(balance.amount, currency: balance.currency))
  }

  /// «Пятёрочка, обычно ~1 200 ₽».
  static func suggestion(_ suggestion: PlaceSuggestion, _ environment: AppEnvironment) -> String {
    guard let usual = suggestion.usual else { return suggestion.name }
    return f(
      "quick.suggest.usual", environment, suggestion.name,
      environment.money.rounded(usual.amount, currency: usual.currency))
  }

  /// The words for a failure or a notice, by key.
  static func line(_ key: String, _ environment: AppEnvironment) -> String { t(key, environment) }

  /// Every key of the table, so a test finds each in both languages.
  static let keys: [String] = [
    "quick.operation", "quick.correction.ask", "quick.correction.stale", "quick.correction.apply",
    "quick.correction.none", "quick.correction.failed", "quick.correction.done",
    "quick.correction.refused.amount", "quick.correction.refused.currency",
    "quick.correction.refused.rate", "quick.correction.refused.account",
    "quick.correction.refused.debt", "quick.correction.refused.moneyBack",
    "quick.correction.refused.parts",
    "quick.bank.read", "quick.bank.card", "quick.bank.reconcile", "quick.bank.askCard",
    "quick.cardAsk.title", "quick.cardAsk.message", "quick.cardAsk.none",
    "quick.suggest.usual", "quick.suggest.label",
    "quick.queue.waiting", "quick.queue.cancel",
    "quick.draft.later", "quick.draft.kept", "quick.draft.failed", "quick.draft.list",
    "quick.drafts.title", "quick.drafts.empty", "quick.drafts.finish", "quick.drafts.delete",
    "quick.drafts.hint", "quick.drafts.reminder", "quick.drafts.reminder.action",
    "quick.repeat.title", "quick.repeat.subtitle", "quick.repeat.write", "quick.repeat.none",
    "quick.repeat.written", "quick.repeat.left",
    "quick.bills.title", "quick.bills.subtitle", "quick.bills.duplicate", "quick.bills.skipped",
    "quick.bills.write", "quick.bills.written", "quick.bills.categoryNote",
    "quick.note.add", "quick.note.edit", "quick.note.placeholder", "quick.note.save",
    "quick.note.delete", "quick.note.title", "quick.note.failed", "quick.note.mark",
    "quick.move.menu", "quick.move.title", "quick.move.pick", "quick.move.confirm",
    "quick.move.done", "quick.move.failed", "quick.move.same", "quick.move.ahead.title",
    "quick.move.ahead.message", "quick.move.ahead.record", "quick.move.month",
    "quick.move.rate", "quick.move.drop",
    "quick.card.last4", "quick.card.last4.hint", "quick.card.last4.bad", "quick.card.details",
    "quick.card.details.hint", "quick.card.masked",
    "quick.split.title", "quick.split.hint", "quick.split.exact", "quick.split.first",
    "quick.split.second", "quick.split.step",
  ]
}
