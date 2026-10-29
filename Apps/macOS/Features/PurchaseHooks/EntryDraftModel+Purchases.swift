import AppCore
import Foundation

extension EntryDraftModel {
  /// The rubles of the purchase that count for the pause: the parts that are mine (not paid for
  /// somebody else), in rubles at the rate the draft holds or the last known one. `nil` for a
  /// currency without a rate.
  static func pauseAmount(
    of draft: TransactionDraft, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    let mine = AmountE4.sum(draft.parts.filter { !$0.reimbursable }.map(\.amount))
    guard draft.currency != .rub else { return mine }
    guard let rate = draft.rate ?? rubPerUnit[draft.currency] else { return nil }
    return try? AmountE4(decimal: mine.decimal * rate)
  }

  /// «Подождать?»: asked once before a purchase above the owner's share of the free sum is
  /// written, and only with the pause switched on. A saved purchase being edited is asked about
  /// only when the edit makes it big: one that was above the share as saved asks nothing.
  func pauseQuestion(money: EntrySaveQuestions.Money) -> PauseQuestion? {
    guard !pauseAnswered, draft.kind == .expense, !isReconcileDifference,
      !KindFields.isGoalOnly(draft, tree: categoryTree),
      let amount = Self.pauseAmount(of: draft, rubPerUnit: money.rubPerUnit)
    else { return nil }
    let verdict = PurchasePause.check(
      amountRubE4: amount, freeRubE4: money.freeRubE4, settings: money.purchase)
    guard case .wait(let share) = verdict else { return nil }
    if editsSavedOperation {
      guard let saved = savedOperation else { return nil }
      if let before = Self.pauseAmount(of: saved, rubPerUnit: money.rubPerUnit),
        PurchasePause.check(
          amountRubE4: before, freeRubE4: money.freeRubE4, settings: money.purchase
        ).shouldAsk
      {
        return nil
      }
    }
    return PauseQuestion(amountRubE4: amount, sharePercent: share)
  }

  /// «Сколько проехали с прошлой заправки?»: asked once for a fill-up (the note names litres)
  /// that carries no mileage, with the setting on. A saved purchase being edited is asked about
  /// only when the edit makes it a fill-up.
  func mileageQuestion(money: EntrySaveQuestions.Money) -> MileageQuestion? {
    guard !mileageAnswered, draft.kind == .expense, draft.odometerKm == nil else { return nil }
    let probe = Transaction(
      kind: .expense, occurredAt: draft.occurredAt, amountE4: draft.amount, note: draft.note,
      odometerKm: draft.odometerKm)
    guard FuelEconomy.shouldAskMileage(probe, settings: money.purchase) else { return nil }
    if editsSavedOperation {
      guard let saved = savedOperation, FuelEconomy.liters(inNote: saved.note) == nil else {
        return nil
      }
    }
    return MileageQuestion(previous: money.lastFill)
  }

  /// The answer to the mileage question: the kilometres driven since the fill-up before make the
  /// mileage now; without one before, the number is the mileage itself. `nil` is «Не помню».
  func answerMileage(_ km: Int?, previous: FuelFill?) {
    mileageAnswered = true
    guard let km, km > 0 else { return }
    draft.odometerKm =
      previous == nil ? km : FuelEconomy.odometer(afterDriving: km, since: previous)
  }
}
