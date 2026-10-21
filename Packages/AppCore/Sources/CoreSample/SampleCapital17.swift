import CoreKit
import Foundation

extension SampleDataSet {
  /// The capital and the safety cushion, after the education loan and the savings account:
  ///
  /// * a car (`vehicle`) valued three times — a few days after the first day, halfway and ten
  ///   days before the last day —, each valuation below the one before, the way a car loses
  ///   worth;
  /// * a brokerage account (`investment`) valued at the end of every month of the history, its
  ///   worth drifting a few percent up or down each month;
  /// * the savings account the loan layer opened kept as the safety cushion;
  /// * the spending the owner cannot stop marked essential — groceries, utilities, the phone and
  ///   the home internet, transport and health —, with sport under health marked not essential,
  ///   the way the owner overrides a parent;
  /// * a cushion goal of six months, unless the set already says another.
  ///
  /// Nothing here moves money or adds an operation, so every count, known answer and money at
  /// the end stays as it was. The layer draws from streams of its own; a history shorter than
  /// two months gets no car and no brokerage account, there being no time for them to change.
  func withCapitalLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: 0x0017_CA91_7A15_0017, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    var set = self

    // The cushion: the account that earns interest — the savings account of the loan layer.
    for index in set.paymentMethods.indices
    where set.paymentMethods[index].interest != nil && !set.paymentMethods[index].archived {
      set.paymentMethods[index].cushion = true
    }

    // The spending that cannot stop, and one subcategory the owner says is not.
    let starters = StarterCategories(categories)
    let marks: [(String, Bool)] =
      Self.essentialStarters.map { ($0, true) } + [("Sport", false)]
    for (english, essential) in marks {
      guard let id = starters.id(english),
        let index = set.categories.firstIndex(where: { $0.id == id })
      else { continue }
      set.categories[index].essential = essential
    }

    if set.settings[CapitalSettings.targetMonthsKey] == nil {
      set.settings[CapitalSettings.targetMonthsKey] = String(Self.cushionGoalMonths)
    }

    guard Self.days(from: firstDay, to: lastDay, calendar: calendar) >= Self.capitalMinimumDays
    else { return set }

    // The car: bought before the history, worth less at every valuation.
    var carStream = layer.stream("car")
    let car = Asset(
      id: carStream.nextUUID(), name: layer.word("Car", "Машина"), kind: .vehicle,
      currency: .rub, sort: 1)
    let span = Self.days(from: firstDay, to: lastDay, calendar: calendar)
    let carDays = [
      calendar.adding(days: 3, to: firstDay),
      calendar.adding(days: span / 2, to: firstDay),
      calendar.adding(days: -10, to: lastDay),
    ]
    var carWorth = Int64(carStream.int(in: 160...240)) * 10_000
    var carValuations: [AssetValuation] = []
    for day in carDays {
      var rng = layer.stream("car valuation", on: day)
      if !carValuations.isEmpty {
        let lost = Int64(rng.int(in: 5...12))
        carWorth = (carWorth * (100 - lost) / 100) / 10_000 * 10_000
      }
      carValuations.append(
        AssetValuation(
          id: rng.nextUUID(), assetId: car.id, day: day, valueE4: AmountE4(whole: carWorth)))
    }

    // The brokerage account: valued at the end of every month the history has.
    var brokerageStream = layer.stream("brokerage account")
    let brokerage = Asset(
      id: brokerageStream.nextUUID(), name: layer.word("Brokerage account", "Брокерский счёт"),
      kind: .investment, currency: .rub, sort: 2)
    var brokerageWorth = Int64(brokerageStream.int(in: 25...40)) * 10_000
    var brokerageValuations: [AssetValuation] = []
    var month = firstDay.monthKey
    while month <= lastDay.monthKey {
      let end = DateOnly(year: month.year, month: month.month, day: calendar.daysInMonth(month))
      month = month.next
      guard end >= firstDay, end <= lastDay else { continue }
      var rng = layer.stream("brokerage valuation", on: end)
      if !brokerageValuations.isEmpty {
        let change = Int64(rng.int(in: -4...6))
        brokerageWorth = (brokerageWorth * (100 + change) / 100) / 100 * 100
      }
      brokerageValuations.append(
        AssetValuation(
          id: rng.nextUUID(), assetId: brokerage.id, day: end,
          valueE4: AmountE4(whole: brokerageWorth)))
    }

    set.assets += [car, brokerage]
    set.assetValuations += carValuations + brokerageValuations
    return set
  }

  /// The starter categories the sample marks essential, by their English seed names.
  static let essentialStarters = [
    "Groceries", "Utilities", "Mobile", "Home internet", "Transport", "Health",
  ]
  /// The months of obligatory spending the sample's cushion goal asks for.
  static let cushionGoalMonths = 6
  /// The shortest history that gets the car and the brokerage account.
  static let capitalMinimumDays = 60

  static func days(from start: DateOnly, to end: DateOnly, calendar: CalendarContext) -> Int {
    let seconds = calendar.startOfDay(end).timeIntervalSince(calendar.startOfDay(start))
    return Int((seconds / 86_400).rounded())
  }
}
