import CoreAccounting
import CoreKit
import Foundation

// MARK: - Leaks

/// What the small purchases are counted by.
public enum LeakGrouping: String, CaseIterable, Hashable, Sendable {
  /// By place; purchases without a place are not seen (the default).
  case place
  /// By top-level category.
  case category
}

/// «Утечки»: small purchases that happen often, found against the owner's own history rather
/// than by a fixed sum.
///
/// * Over the last 90 days, small is any purchase in the lower quarter of the purchase sums
///   (the 25th percentile of all of them, linear between the closest ranks).
/// * Often is more often than the usual: more small purchases than the median group has.
///   A group also needs `minimumCount` of them to be named.
/// * «Кофе до 300 ₽ 22 раза — 5 900 ₽ в месяц»: the group, its largest small purchase, the
///   count, and the cost scaled to 30 days.
/// * Operations marked one-off are not leaks and are left out. With fewer than
///   `minimumPurchases` purchases there is no history to judge by and nothing is named.
public struct SpendingLeaks: Hashable, Sendable {
  public static let window = 90
  public static let minimumPurchases = 20
  public static let minimumCount = 3

  public struct Leak: Hashable, Sendable {
    public var key: ReportKey
    public var count: Int
    /// What the small purchases cost in the 90 days.
    public var total: AmountE4
    /// The same, scaled to a month of 30 days.
    public var perMonth: AmountE4
    /// The largest of the small purchases: the «до …» of the sentence.
    public var largest: AmountE4
  }

  public var grouping: LeakGrouping
  public var range: DayRange
  /// The lower-quarter sum; `nil` without enough history.
  public var threshold: AmountE4?
  /// The usual number of small purchases per group (the median); `nil` without enough history.
  public var usualCount: Int?
  /// Costliest per month first.
  public var leaks: [Leak]

  public init(
    ledger: Ledger, today: DateOnly, grouping: LeakGrouping = .place,
    oneOff: OneOffMarks = .none
  ) {
    self.grouping = grouping
    let range = DayRange(today.adding(days: -(Self.window - 1)), today)
    self.range = range

    // One purchase is one operation; its sum is what its counted parts add up to.
    struct Purchase {
      var key: ReportKey?
      var amount: AmountE4
    }
    var purchases: [UUID: Purchase] = [:]
    for row in SpendingRows.rows(in: range, of: ledger)
    where row.kind == .expense && !oneOff.contains(row.transactionId) {
      let key: ReportKey? =
        switch grouping {
        case .place: row.placeId.map(ReportKey.place)
        case .category: ReportGrouping.category.outerKey(of: row)
        }
      var purchase = purchases[row.transactionId] ?? Purchase(key: key, amount: .zero)
      purchase.amount += row.contribution
      purchases[row.transactionId] = purchase
    }
    let sums = purchases.values.filter { $0.amount.raw > 0 }
    guard sums.count >= Self.minimumPurchases,
      let quarter = Quantile.value(sums.map(\.amount.decimal), Decimal(string: "0.25")!)
    else {
      threshold = nil
      usualCount = nil
      leaks = []
      return
    }
    let limit = AmountE4.rounded(quarter)
    threshold = limit

    var groups: [ReportKey: (count: Int, total: AmountE4, largest: AmountE4)] = [:]
    for purchase in sums where purchase.amount <= limit {
      guard let key = purchase.key else { continue }
      var group = groups[key] ?? (0, .zero, .zero)
      group.count += 1
      group.total += purchase.amount
      group.largest = max(group.largest, purchase.amount)
      groups[key] = group
    }
    let counts = groups.values.map { Decimal($0.count) }
    let usual = Quantile.value(counts, Decimal(string: "0.5")!).map {
      NSDecimalNumber(decimal: DecimalMath.round($0, scale: 0)).intValue
    }
    usualCount = usual
    leaks = groups.compactMap { key, group -> Leak? in
      guard let usual, group.count > usual, group.count >= Self.minimumCount else { return nil }
      return Leak(
        key: key, count: group.count, total: group.total,
        perMonth: AmountE4.rounded(group.total.decimal * 30 / Decimal(Self.window)),
        largest: group.largest)
    }.sorted {
      $0.perMonth != $1.perMonth
        ? $0.perMonth > $1.perMonth : $0.key.description < $1.key.description
    }
  }
}

// MARK: - What ate the limit

/// «Что съело лимит»: the three largest purchases of a category in a month, and one line for
/// the others — «и 14 покупок до 480 ₽ — 3 900 ₽».
///
/// * The category counts with its subcategories; a purchase is one operation, net of its
///   refunds (the ledger's rule), and a reconciliation's difference is no purchase.
/// * «The others» are all the other purchases of the category, so
///   `largest + others + returns == spent`. `returns` is the money that came back through
///   refunds of purchases from other months — below zero or zero.
public struct LimitConsumption: Hashable, Sendable {
  public static let largestCount = 3

  public struct Purchase: Hashable, Sendable {
    public var transactionId: UUID
    public var amount: AmountE4
  }

  public var categoryId: UUID
  public var month: MonthKey
  /// What the category spent in the month.
  public var spent: AmountE4
  /// Up to three, largest first.
  public var largest: [Purchase]
  /// The purchases that are not among the largest: how many, what they add up to, the largest
  /// of them («до …»); `nil` when there are none.
  public var othersCount: Int
  public var othersTotal: AmountE4
  public var othersLargest: AmountE4?
  /// Refunds in the month that took back purchases of earlier months, as a negative sum.
  public var returns: AmountE4

  public init(ledger: Ledger, categoryId: UUID, month: MonthKey) {
    self.categoryId = categoryId
    self.month = month
    let tree = ledger.tree
    func isUnder(_ id: UUID?) -> Bool {
      var current = id
      var depth = 0
      while let id = current, depth < 8 {
        if id == categoryId { return true }
        current = tree.parent(of: id)?.id
        depth += 1
      }
      return false
    }
    var byOperation: [UUID: AmountE4] = [:]
    for row in SpendingRows.rows(in: DayRange(month.firstDay, month.lastDay), of: ledger)
    where isUnder(row.categoryId) {
      byOperation[row.transactionId, default: .zero] += row.contribution
    }
    let purchases = byOperation.compactMap { id, amount -> Purchase? in
      amount.raw > 0 ? Purchase(transactionId: id, amount: amount) : nil
    }.sorted {
      $0.amount != $1.amount
        ? $0.amount > $1.amount : $0.transactionId.uuidString < $1.transactionId.uuidString
    }
    largest = Array(purchases.prefix(Self.largestCount))
    let others = purchases.dropFirst(Self.largestCount)
    othersCount = others.count
    othersTotal = AmountE4.sum(others.map(\.amount))
    othersLargest = others.first?.amount
    returns = AmountE4.sum(byOperation.values.filter { $0.raw <= 0 })
    spent = AmountE4.sum(byOperation.values)
  }
}

// MARK: - Price in hours of work

/// The settings of the price in hours; off until the owner turns it on.
public struct WorkHoursSettings: Hashable, Sendable {
  public static let enabledKey = "spending.workHours.enabled"
  public static let hoursPerMonthKey = "spending.workHours.perMonth"
  public static let defaultHoursPerMonth = 168

  public var isEnabled: Bool
  public var hoursPerMonth: Int

  public init(isEnabled: Bool = false, hoursPerMonth: Int = defaultHoursPerMonth) {
    self.isEnabled = isEnabled
    self.hoursPerMonth = hoursPerMonth
  }

  public static let storageKeys = [enabledKey, hoursPerMonthKey]

  /// The settings the rows give; a value that does not read keeps its default.
  public init(storedValues values: [String: String]) {
    let hours = values[Self.hoursPerMonthKey].flatMap {
      Int($0.trimmingCharacters(in: .whitespaces))
    }
    self.init(
      isEnabled: values[Self.enabledKey]?.trimmingCharacters(in: .whitespaces) == "1",
      hoursPerMonth: hours.flatMap { (1...744).contains($0) ? $0 : nil }
        ?? Self.defaultHoursPerMonth)
  }

  /// The rows to write; a setting at its default deletes its key (`nil`).
  public var storedValues: [String: String?] {
    [
      Self.enabledKey: isEnabled ? "1" : nil,
      Self.hoursPerMonthKey: hoursPerMonth == Self.defaultHoursPerMonth
        ? nil : String(hoursPerMonth),
    ]
  }
}

/// «Кроссовки 14 000 — 18 часов вашей работы»: the price divided by what an hour of work
/// brings. The rate is the average monthly earnings over the last three whole months — what
/// came to the accounts, as typed — divided by the hours of work in a month the owner gave.
///
/// A month before the first operation is not a month with no earnings: it is not counted. No
/// earnings, switched off, or no hours — no rate, and no price in hours anywhere.
public struct WorkRate: Hashable, Sendable {
  public static let months = 3

  /// The average earnings of a month, in rubles.
  public var monthlyEarnings: AmountE4
  /// How many months the average is over (up to three).
  public var monthsCounted: Int
  public var hoursPerMonth: Int

  /// What one hour of work brings, in rubles.
  public var hourly: AmountE4 {
    AmountE4.rounded(monthlyEarnings.decimal / Decimal(hoursPerMonth))
  }

  public init?(
    ledger: Ledger, today: DateOnly, settings: WorkHoursSettings,
    earningsCategoryId: UUID? = nil
  ) {
    guard settings.isEnabled, settings.hoursPerMonth > 0, let first = ledger.firstDay else {
      return nil
    }
    let last = today.monthKey.adding(months: -1)
    let wanted = MonthKey.range(last.adding(months: -(Self.months - 1)), through: last)
      .filter { $0 >= first.monthKey }
    guard !wanted.isEmpty else { return nil }
    let tree = ledger.tree
    let earnings = AmountE4.sum(
      ledger.rows(attributedTo: wanted).lazy
        .filter { row in
          guard row.kind == .income else { return false }
          guard let earningsCategoryId else { return true }
          return row.categoryId == earningsCategoryId
            || tree.root(of: row.categoryId)?.id == earningsCategoryId
        }
        .map(\.amountRubE4))
    guard earnings.raw > 0 else { return nil }
    monthlyEarnings = AmountE4.rounded(earnings.decimal / Decimal(wanted.count))
    monthsCounted = wanted.count
    hoursPerMonth = settings.hoursPerMonth
  }

  /// How many hours of work a price is, to one decimal place.
  public func hours(for price: AmountE4) -> Decimal {
    DecimalMath.round(price.decimal * Decimal(hoursPerMonth) / monthlyEarnings.decimal, scale: 1)
  }

  /// The same in whole hours, rounded half away from zero.
  public func wholeHours(for price: AmountE4) -> Int {
    NSDecimalNumber(
      decimal: DecimalMath.round(
        price.decimal * Decimal(hoursPerMonth) / monthlyEarnings.decimal, scale: 0)
    ).intValue
  }
}
