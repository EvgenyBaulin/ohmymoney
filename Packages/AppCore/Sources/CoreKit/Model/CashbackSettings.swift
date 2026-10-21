import Foundation

/// How the bank of an account rounds the cashback of one purchase: to what, and which way. The
/// expectation follows the account's setting, so it comes out as the bank pays it.
///
/// The magnitude is rounded and the sign kept, so a refund of no purchase takes back what the
/// purchase would have given: «down» goes toward zero, «up» away from it.
public struct CashbackRounding: Hashable, Sendable, Codable {
  public enum Precision: String, Codable, Sendable, CaseIterable {
    /// Whole units of the currency.
    case whole
    /// Cents (kopecks).
    case cents
  }

  public enum Direction: String, Codable, Sendable, CaseIterable {
    /// The nearest, a half away from zero.
    case nearest
    case down
    case up
  }

  public var precision: Precision
  public var direction: Direction

  /// Whole units, the nearest: what an account starts with.
  public static let standard = CashbackRounding()

  public init(precision: Precision = .whole, direction: Direction = .nearest) {
    self.precision = precision
    self.direction = direction
  }

  /// `value` rounded the way the account's bank does it.
  public func apply(_ value: Decimal) -> Decimal {
    let scale = precision == .whole ? 0 : 2
    let magnitude = value.magnitude
    let rounded: Decimal
    switch direction {
    case .nearest: rounded = DecimalMath.round(magnitude, scale: scale)
    case .down: rounded = DecimalMath.round(magnitude, scale: scale, mode: .down)
    case .up: rounded = DecimalMath.round(magnitude, scale: scale, mode: .up)
    }
    return value < 0 ? -rounded : rounded
  }
}

/// When the bank of an account pays the cashback out: with the purchase, or by a day of the
/// month after it. An account that has not said (`PaymentMethod.cashbackPayout == nil`) is not
/// guessed for.
public struct CashbackPayout: Hashable, Sendable, Codable {
  public enum Timing: String, Codable, Sendable, CaseIterable {
    /// With the purchase.
    case immediately
    /// By a day of the month after the purchase's.
    case later
  }

  public var timing: Timing
  /// 1…31, only when `later`: the day of the next month by which the bank has paid. A month
  /// without that day ends on its last day, so 31 is «by the end of the month».
  public var day: Int?

  public static let immediately = CashbackPayout(timing: .immediately, day: nil)

  private init(timing: Timing, day: Int?) {
    self.timing = timing
    self.day = day
  }

  /// `nil` outside 1…31.
  public static func later(day: Int) -> CashbackPayout? {
    guard (1...31).contains(day) else { return nil }
    return CashbackPayout(timing: .later, day: day)
  }

  /// A stored pair: a timing, and the day that goes with `later` only. `nil` when they do not
  /// belong together.
  public init?(timing: Timing, storedDay: Int?) {
    switch timing {
    case .immediately:
      guard storedDay == nil else { return nil }
      self = .immediately
    case .later:
      guard let storedDay, let later = Self.later(day: storedDay) else { return nil }
      self = later
    }
  }

  /// The day by which the cashback of the purchases of `month` is paid; `nil` for a bank that
  /// pays with the purchase.
  public func dueDate(forPurchasesOf month: MonthKey, calendar: CalendarContext) -> DateOnly? {
    guard timing == .later, let day else { return nil }
    let next = month.next
    return DateOnly(year: next.year, month: next.month, day: min(day, calendar.daysInMonth(next)))
  }
}
