import AppCore
import Foundation

/// The words of the screens of the purchases, apart from the views so a test reads each in both
/// languages. A line says what it is about in words; a symbol and a colour only back it up.
@MainActor
enum PurchasesText {
  static let table = "Purchases"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  static func count(_ key: String, _ environment: AppEnvironment, _ count: Int) -> String {
    environment.language.format(key, table: table, counts: count)
  }

  /// «+1 200 ₽» / «−1 200 ₽» with the sign of U+2212, so a change is never told by colour alone.
  static func signed(
    _ amount: AmountE4, currency: CurrencyCode = .rub, _ environment: AppEnvironment
  )
    -> String
  {
    let body = environment.money.rounded(amount.magnitude, currency: currency)
    if amount.raw > 0 { return "+" + body }
    if amount.raw < 0 { return "\u{2212}" + body }
    return body
  }

  static func percent(_ value: Int, _ environment: AppEnvironment) -> String {
    String(value) + (environment.language.resolvedCode == "ru" ? "\u{00A0}%" : "%")
  }

  // MARK: Pages

  /// The pages of the screen, in the order of the switch.
  enum Page: String, CaseIterable, Identifiable, Sendable {
    case wishes, shopping, things, waiting, savings

    var id: String { rawValue }

    var titleKey: String {
      switch self {
      case .wishes: "purchases.page.wishes"
      case .shopping: "purchases.page.shopping"
      case .things: "purchases.page.things"
      case .waiting: "purchases.page.waiting"
      case .savings: "purchases.page.savings"
      }
    }

    var symbol: String {
      switch self {
      case .wishes: "heart"
      case .shopping: "checklist"
      case .things: "shippingbox"
      case .waiting: "hourglass"
      case .savings: "tag"
      }
    }
  }

  // MARK: Wishes

  static func price(of wish: Wish, _ environment: AppEnvironment) -> String {
    guard let price = wish.priceE4 else { return t("purchases.wish.noPrice", environment) }
    return environment.money.rounded(price, currency: wish.currency)
  }

  static func priority(_ value: Int, _ environment: AppEnvironment) -> String {
    value == 0 ? t("purchases.priority.none", environment) : "\(value)"
  }

  /// «Через 4 мес., если откладывать 25 000 ₽ в месяц», «Хватает уже сейчас», or why no wait can be
  /// told.
  static func afford(_ line: WishLine, _ environment: AppEnvironment) -> String? {
    if line.rateMissing { return t("purchases.afford.noRate", environment) }
    switch line.afford.outcome {
    case .noPrice:
      return nil
    case .affordableNow:
      return t("purchases.afford.now", environment)
    case .noSavingPace:
      return t("purchases.afford.noPace", environment)
    case .months(let months):
      let pace = line.afford.monthlySavingE4.map { environment.money.rounded($0) } ?? ""
      return count("purchases.afford.months", environment, months) + ", "
        + f("purchases.afford.pace", environment, pace)
    }
  }

  /// Why it is time to buy, in words.
  static func reason(_ reason: WishPriceTracking.Reason, _ environment: AppEnvironment) -> String {
    switch reason {
    case .belowExpected: t("purchases.timeToBuy.expected", environment)
    case .fellFromHighest(let value):
      f("purchases.timeToBuy.fell", environment, percent(value, environment))
    }
  }

  /// «Цена: −1 000 ₽ к прошлой отметке», `nil` while there are fewer than two prices.
  static func change(_ line: WishLine, _ environment: AppEnvironment) -> String? {
    guard let change = line.tracking.lastChangeE4, !change.isZero else { return nil }
    return f(
      "purchases.price.change", environment,
      signed(change, currency: line.wish.currency, environment))
  }

  /// «Думал 32 000 ₽ — вышло 29 900 ₽», with the difference told by its sign.
  static func outcome(
    _ outcome: WishOutcome, currency: CurrencyCode, _ environment: AppEnvironment
  ) -> String {
    let base = f(
      "purchases.outcome", environment,
      environment.money.rounded(outcome.expectedE4, currency: currency),
      environment.money.rounded(outcome.paidE4, currency: currency))
    let difference = outcome.differenceE4
    if difference.isZero { return base }
    return base + " (" + signed(difference, currency: currency, environment) + ")"
  }

  static func refusal(_ refusal: PurchaseRefusal, _ environment: AppEnvironment) -> String {
    switch refusal {
    case .emptyName: t("purchases.refusal.name", environment)
    case .badPrice: t("purchases.refusal.price", environment)
    case .badLink: t("purchases.refusal.link", environment)
    case .notFound: t("purchases.refusal.notFound", environment)
    }
  }

  // MARK: Things

  /// «2 340 ₽ в месяц · всего 28 080 ₽ за 12 мес.»
  static func ownership(_ cost: OwnershipCost, _ environment: AppEnvironment) -> String {
    let money = environment.money
    return f(
      "purchases.thing.cost", environment, money.rounded(cost.perMonthRubE4),
      money.rounded(cost.totalRubE4), count("purchases.thing.months", environment, cost.months))
  }

  /// «Гарантия до 12 марта» / «Гарантия кончилась», `nil` without a warranty.
  static func warranty(_ cost: OwnershipCost, _ environment: AppEnvironment) -> String? {
    guard let until = cost.warrantyUntil, let left = cost.warrantyDaysLeft else { return nil }
    return left >= 0
      ? f("purchases.thing.warranty", environment, environment.dates.longDay(until))
      : t("purchases.thing.warrantyOver", environment)
  }

  /// «Топливо 48 000 ₽ · 8,1 л/100 км · 11 ₽/км».
  static func vehicle(_ vehicle: VehicleCost, _ environment: AppEnvironment) -> String? {
    var parts: [String] = []
    let money = environment.money
    if !vehicle.fuelRubE4.isZero {
      parts.append(f("purchases.vehicle.fuel", environment, money.rounded(vehicle.fuelRubE4)))
    }
    if let average = vehicle.fuelAverageLitersPer100Km {
      parts.append(
        f(
          "purchases.vehicle.average", environment,
          NumberText.decimal(average, fractionDigits: 1...1)))
    }
    if let perKm = vehicle.perKmRubE4 {
      parts.append(f("purchases.vehicle.perKm", environment, money.exact(perKm)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: Waiting

  /// «до 12 марта» / «просрочен на 3 дня».
  static func expected(
    _ refund: WaitingRefund, today: DateOnly, _ environment: AppEnvironment
  )
    -> String
  {
    if refund.isLate(today: today) {
      return count("purchases.waiting.late", environment, -refund.daysLeft(today: today))
    }
    return f("purchases.waiting.until", environment, environment.dates.longDay(refund.expectedBy))
  }

  // MARK: Savings

  static func savings(_ savings: DiscountSavings, _ environment: AppEnvironment) -> String {
    environment.money.rounded(savings.totalRubE4)
  }
}
