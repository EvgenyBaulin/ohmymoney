import AppCore
import Foundation

/// What the strip over the window says about the trips, worked out from the snapshot of the data
/// without a word of text: the line of the trip that is on, with the day's allowance, and the
/// card «С возвращением!» of the trip that has just ended. Nothing here writes.
struct TripBannerModel: Equatable {
  /// A trip that is on.
  struct Mode: Equatable {
    var event: Event
    /// In rubles, the ledger's currency; `nil` — no budget, or a currency without a rate.
    var budgetRub: AmountE4?
    /// `nil` without a budget.
    var allowance: TripAllowance?
    /// What the trip has cost so far, whatever the dates of its operations.
    var spentRub: AmountE4
  }

  /// A trip that has ended and has not been welcomed back.
  struct Welcome: Equatable {
    var event: Event
    var totalRub: AmountE4
  }

  var mode: Mode?
  var welcome: Welcome?

  var isEmpty: Bool { mode == nil && welcome == nil }

  /// The strip for `today`. The settings are brought up to the day first (`afterDayChange`), so
  /// a trip whose last day was yesterday is already a card here, before the app has written that
  /// down.
  static func make(
    dataset: Dataset, ledger: Ledger, rates: DayRates, today: DateOnly
  ) -> TripBannerModel {
    let settings = TripMode.afterDayChange(
      settings: dataset.tripSettings, events: dataset.events, today: today)
    var model = TripBannerModel()
    if case .on(let event) = TripMode.state(
      settings: settings, events: dataset.events, today: today)
    {
      let budget = TripBudget.inRubles(event, rates: rates, on: today)
      let summary = TripSummary(event: event, ledger: ledger, budgetRub: budget)
      model.mode = Mode(
        event: event, budgetRub: budget, allowance: summary.allowance(event: event, today: today),
        spentRub: summary.total)
    }
    if let event = TripMode.welcomeBack(settings: settings, events: dataset.events, today: today) {
      let summary = TripSummary(event: event, ledger: ledger, budgetRub: nil)
      model.welcome = Welcome(event: event, totalRub: summary.total)
    }
    return model
  }
}
