import AppCore
import Foundation

/// The words of the trips, from the table `Travel`: the line of the trip that is on, the day's
/// allowance, the card of the return, the summary and the cards abroad.
@MainActor
enum TravelText {
  static let table = "Travel"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// «Поездка: Бали до 15 октября · валюта IDR · бюджет 100 000 ₽».
  static func modeLine(_ mode: TripBannerModel.Mode, _ environment: AppEnvironment) -> String {
    var parts = [
      format(
        "travel.mode.title", environment, mode.event.name,
        PlanningBlockText.dayText(mode.event.endDate, environment))
    ]
    if let currency = mode.event.tripCurrency {
      parts.append(format("travel.mode.currency", environment, currency.code))
    }
    if let budget = mode.budgetRub {
      parts.append(format("travel.mode.budget", environment, environment.money.rounded(budget)))
    }
    return parts.joined(separator: " · ")
  }

  /// «Сегодня потрачено 5 000 ₽ · осталось на день 5 000 ₽»; over the day's share and with the
  /// budget gone it says so in words as well as in the sign.
  static func dayLine(_ allowance: TripAllowance, _ environment: AppEnvironment) -> String {
    let money = environment.money
    if allowance.exhausted {
      return format(
        "travel.day.exhausted", environment, money.rounded(allowance.spentToday))
    }
    if allowance.leftToday.isNegative {
      return format(
        "travel.day.over", environment, money.rounded(allowance.spentToday),
        money.rounded(allowance.leftToday.magnitude))
    }
    return format(
      "travel.day.left", environment, money.rounded(allowance.spentToday),
      money.rounded(allowance.leftToday))
  }
}
