import AppCore
import Foundation

/// A wish with what the rules of the purchases say about it: how long it takes to collect the
/// price at the pace of «can save», and whether the prices noted by hand say it is time to buy.
struct WishLine: Identifiable, Hashable, Sendable {
  var wish: Wish
  var tracking: WishPriceTracking
  var afford: TimeToAfford
  /// The price in rubles; `nil` without a price or without a rate of its currency.
  var priceRubE4: AmountE4?
  /// The price is in a currency that has no rate: no wait can be told, and none is guessed.
  var rateMissing: Bool
  var id: UUID { wish.id }
}

/// A wish that was bought: what the owner thought it would cost against what came out.
struct BoughtWishLine: Identifiable, Hashable, Sendable {
  var wish: Wish
  /// `nil` when the operation is gone or the wish never had a price.
  var outcome: WishOutcome?
  var id: UUID { wish.id }
}

/// A thing the owner keeps: an asset of the capital (not an investment) or a thing noted apart.
struct OwnedLine: Identifiable, Hashable, Sendable {
  enum Origin: Hashable, Sendable {
    case asset(Asset)
    case item(OwnedItem)
  }

  var origin: Origin
  var subject: OwnershipSubject
  var cost: OwnershipCost
  /// Fuel and kilometres, for a car or any thing with fill-ups under its tag.
  var vehicle: VehicleCost?
  var id: String { subject.id }

  var name: String { subject.name }
  var isSold: Bool { cost.isSold }
}

/// What the screens of the purchases show, counted once from one dataset. Pure: a test reads
/// each rule without a window.
struct PurchasesPage: Sendable {
  var wishes: [WishLine]
  var bought: [BoughtWishLine]
  var shopping: [ShoppingItem]
  var things: [OwnedLine]
  var soldThings: [OwnedLine]
  var waiting: WaitingRefunds
  var savingsYear: DiscountSavings
  var savingsMonth: DiscountSavings

  /// Operations shown as candidates of a purchase: the last two months.
  static let candidateDays = 60
  /// How far an operation may be from the price of the wish to be offered, in percent.
  static let candidateTolerancePercent = 25

  static func build(
    dataset: Dataset, canSave: CanSave?, rubPerUnit: [CurrencyCode: Decimal], today: DateOnly,
    calendar: CalendarContext, waiting: WaitingRefunds
  ) -> PurchasesPage {
    func rate(_ currency: CurrencyCode) -> Decimal? {
      currency == .rub ? 1 : rubPerUnit[currency]
    }
    let entries = dataset.entries
    var lines: [WishLine] = []
    var bought: [BoughtWishLine] = []
    for wish in dataset.wishes where !wish.archived {
      if let transactionId = wish.boughtTransactionId {
        let paid = entries.first { $0.id == transactionId }.flatMap {
          paidAmount(of: $0, inCurrencyOf: wish, rubPerUnit: rubPerUnit)
        }
        bought.append(
          BoughtWishLine(
            wish: wish, outcome: paid.flatMap { WishOutcome.compare(wish: wish, paidE4: $0) }))
        continue
      }
      let tracking = WishPriceTracking.track(
        wish: wish, prices: dataset.wishPrices, today: today)
      let factor = rate(wish.currency)
      let missing = wish.priceE4 != nil && factor == nil
      let priceRub: AmountE4? = wish.priceE4.flatMap { price in
        factor.map {
          wish.currency == .rub ? price : (try? AmountE4(decimal: price.decimal * $0)) ?? .zero
        }
      }
      let afford: TimeToAfford
      if let canSave, let factor {
        afford = TimeToAfford.estimate(
          wish: wish, rateToRub: factor, canSave: canSave, today: today)
      } else {
        // No month to take the pace from: the price is known, the pace is not («нечего
        // откладывать»); without a rate there is no price in rubles at all.
        afford = TimeToAfford.estimate(
          priceRubE4: priceRub, monthlySavingE4: nil, today: today)
      }
      lines.append(
        WishLine(
          wish: wish, tracking: tracking, afford: afford, priceRubE4: priceRub,
          rateMissing: missing))
    }
    lines.sort { Self.wishOrder($0.wish, $1.wish) }

    var things: [OwnedLine] = []
    var sold: [OwnedLine] = []
    func place(_ line: OwnedLine) {
      if line.isSold { sold.append(line) } else { things.append(line) }
    }
    let tagBook = dataset.tagBook
    func tagId(named name: String) -> UUID? {
      tagBook.tag(named: name).flatMap { $0.archived ? nil : $0.id }
    }
    for asset in dataset.assets where asset.kind != .investment {
      // An asset has no tag and no sale of its own: the tag of its name stands for its running
      // costs, and the income noted with its name on the day it was disposed of for its sale.
      let subject = OwnershipSubject(
        asset: asset, valuations: dataset.assetValuations, rateToRub: rate(asset.currency) ?? 1,
        tagId: tagId(named: asset.name),
        saleTransactionId: asset.disposedOn.flatMap {
          saleOf(asset.name, on: $0, entries: entries, calendar: calendar)
        })
      place(
        line(
          .asset(asset), subject, entries: entries, tagBook: tagBook, today: today,
          calendar: calendar, isVehicle: asset.kind == .vehicle))
    }
    for item in dataset.ownedItems where !item.archived {
      var subject = OwnershipSubject(item: item, rateToRub: rate(item.currency) ?? 1)
      if subject.tagId == nil { subject.tagId = tagId(named: item.name) }
      place(
        line(
          .item(item), subject, entries: entries, tagBook: tagBook, today: today,
          calendar: calendar, isVehicle: false))
    }
    things.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    sold.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    let yearStart = DateOnly(year: today.year, month: 1, day: 1)
    return PurchasesPage(
      wishes: lines, bought: bought,
      shopping: dataset.shoppingItems.sorted { left, right in
        if left.done != right.done { return !left.done }
        return (left.sort, left.createdOn) < (right.sort, right.createdOn)
      },
      things: things, soldThings: sold, waiting: waiting,
      savingsYear: DiscountSavings.summarize(
        entries: entries, range: DayRange(yearStart, today), calendar: calendar),
      savingsMonth: DiscountSavings.summarize(
        entries: entries, range: DayRange(today.monthKey.firstDay, today), calendar: calendar))
  }

  private static func line(
    _ origin: OwnedLine.Origin, _ subject: OwnershipSubject, entries: [TransactionEntry],
    tagBook: TagBook, today: DateOnly, calendar: CalendarContext, isVehicle: Bool
  ) -> OwnedLine {
    let cost = OwnershipCost.compute(
      subject, entries: entries, tagBook: tagBook, today: today, calendar: calendar)
    var vehicle: VehicleCost?
    if subject.tagId != nil {
      let fills = FuelEconomy.fills(
        entries: entries, tagBook: tagBook, tagId: subject.tagId, calendar: calendar)
      if isVehicle || !fills.isEmpty {
        vehicle = VehicleCost.compute(
          subject, entries: entries, tagBook: tagBook, today: today, calendar: calendar)
      }
    }
    return OwnedLine(origin: origin, subject: subject, cost: cost, vehicle: vehicle)
  }

  /// The income that sold a thing named `name` on `day`: a live income of that day with that
  /// description.
  static func saleOf(
    _ name: String, on day: DateOnly, entries: [TransactionEntry], calendar: CalendarContext
  ) -> UUID? {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return entries.first { entry in
      let transaction = entry.transaction
      return !transaction.isDeleted && transaction.kind == .income
        && transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        && calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId) == day
    }?.id
  }

  /// The most wanted first (a priority of 0 is none and goes last), then the owner's order.
  static func wishOrder(_ left: Wish, _ right: Wish) -> Bool {
    let a = left.priority == 0 ? Int.max : left.priority
    let b = right.priority == 0 ? Int.max : right.priority
    if a != b { return a < b }
    if left.sort != right.sort { return left.sort < right.sort }
    if left.createdOn != right.createdOn { return left.createdOn < right.createdOn }
    return left.id.uuidString < right.id.uuidString
  }

  // MARK: The purchase of a wish

  /// What an operation cost in the currency of the wish: its own amount when the currencies
  /// agree, else its rubles at the rate known now. `nil` when the rate is not known.
  static func paidAmount(
    of entry: TransactionEntry, inCurrencyOf wish: Wish, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    let transaction = entry.transaction
    if transaction.currency == wish.currency { return transaction.amountE4 }
    if wish.currency == .rub { return transaction.amountRubE4 }
    guard let rate = rubPerUnit[wish.currency], rate > 0 else { return nil }
    return try? AmountE4(decimal: transaction.amountRubE4.decimal / rate)
  }

  /// The operations the owner may mean by «Купил»: live expenses of the last `candidateDays`
  /// whose rubles are within `candidateTolerancePercent` of the price of the wish, the closest
  /// first. Those that already bought another wish are left out. `[]` without a price or a rate.
  static func candidates(
    for wish: Wish, entries: [TransactionEntry], takenBy others: Set<UUID>,
    rubPerUnit: [CurrencyCode: Decimal], today: DateOnly, calendar: CalendarContext
  ) -> [TransactionEntry] {
    guard let price = wish.priceE4, price.raw > 0 else { return [] }
    let rate: Decimal
    if wish.currency == .rub {
      rate = 1
    } else if let known = rubPerUnit[wish.currency], known > 0 {
      rate = known
    } else {
      return []
    }
    guard let target = try? AmountE4(decimal: price.decimal * rate), target.raw > 0 else {
      return []
    }
    let slack = target.decimal * Decimal(candidateTolerancePercent) / 100
    let low = target.decimal - slack
    let high = target.decimal + slack
    var found: [(entry: TransactionEntry, gap: Decimal)] = []
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense, !others.contains(entry.id),
        transaction.refundWaitingUntil == nil
      else { continue }
      let day = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      guard day <= today, day.days(to: today) <= candidateDays else { continue }
      let rubles = transaction.amountRubE4.decimal
      guard rubles >= low, rubles <= high else { continue }
      found.append((entry, abs(rubles - target.decimal)))
    }
    found.sort { left, right in
      if left.gap != right.gap { return left.gap < right.gap }
      return left.entry.transaction.occurredAt > right.entry.transaction.occurredAt
    }
    return found.map(\.entry)
  }
}
