import AppCore
import Foundation

/// What «За кого» of the ↓ panel comes to, in plain words under its fields: «Вы заплатили
/// 1,200 ₽ за другого. Маша должен(а) вам 1,200 ₽.», «Ваша часть — 600 ₽, Маша должен(а) вам
/// 600 ₽.», or a gift that nobody owes. Nothing for «Себе» or without an amount.
@MainActor
enum PayingForSentence {
  static func text(of model: EntryDraftModel, environment: AppEnvironment) -> String? {
    guard model.draft.amount.raw > 0, model.payingFor != .me else { return nil }
    func t(_ key: String) -> String { environment.language(key, table: "Entry") }
    let currency = model.draft.currency
    let outcome = PayingForRules.outcome(of: model.payingFor, total: model.draft.amount)
    func money(_ amount: AmountE4) -> String { environment.money.exact(amount, currency: currency) }
    func name(_ id: UUID) -> String { model.people.first { $0.id == id }?.name ?? "—" }
    let owes = outcome.owed.map {
      String(format: t("entry.payingFor.owes"), name($0.person), money($0.amount))
    }
    if let gift = outcome.giftFor {
      return String(format: t("entry.payingFor.gift"), money(outcome.paid), name(gift))
    }
    if outcome.mine.isZero {
      return String(format: t("entry.payingFor.paid"), money(outcome.paid)) + " "
        + owes.joined(separator: ", ") + "."
    }
    return String(format: t("entry.payingFor.mine"), money(outcome.mine)) + ", "
      + owes.joined(separator: ", ") + "."
  }
}
