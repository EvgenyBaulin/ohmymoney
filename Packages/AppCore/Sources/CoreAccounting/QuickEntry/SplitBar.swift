import CoreKit
import Foundation

/// The bar of an operation's amount the owner drags a border along to split it into parts:
/// a check of 2 340, the border between «Продукты» and «Бытовая химия». A border
/// stops at every 10 ₽; the exact amount is typed. Parts are always above zero and always add up
/// to the total, to the unit.
public struct SplitBar: Hashable, Sendable {
  public let total: AmountE4
  /// The stop of the drag.
  public let step: AmountE4

  /// A drag stops at every ten.
  public static let preferredStep = AmountE4(whole: 10)

  /// Nil when the amount cannot be split at all: it is not above a kopek.
  ///
  /// A bar of ten rubles or less has no stop of ten inside it, so its stop is one ruble, and
  /// one of a ruble or less, a kopek: the bar is never left without a border to move.
  public init?(total: AmountE4) {
    let candidates = [Self.preferredStep, AmountE4(whole: 1), AmountE4(raw: 100)]
    guard let step = candidates.first(where: { total > $0 }) else { return nil }
    self.total = total
    self.step = step
  }

  /// The largest border the bar has: the last stop before the end.
  private var lastStop: AmountE4 {
    let stops = (total.raw - 1) / step.raw
    return AmountE4(raw: stops * step.raw)
  }

  /// The nearest stop to a typed or dragged first part, half away from zero, kept inside the bar
  /// with at least a step on each side.
  public func snapped(first: AmountE4) -> AmountE4 {
    let units = DecimalMath.round(Decimal(first.raw) / Decimal(step.raw), scale: 0)
    let raw = ((try? DecimalMath.int64(rounding: units)) ?? 0) * step.raw
    return AmountE4(raw: min(max(raw, step.raw), lastStop.raw))
  }

  /// The border at `fraction` of the bar (0 at the left end, 1 at the right), as the two parts
  /// it makes.
  public func parts(atFraction fraction: Decimal) -> (first: AmountE4, second: AmountE4) {
    let clamped = min(max(fraction, 0), 1)
    let exact = (try? DecimalMath.int64(rounding: Decimal(total.raw) * clamped)) ?? 0
    let first = snapped(first: AmountE4(raw: exact))
    return (first, total - first)
  }

  /// A first part typed by the owner, to the unit: nil unless both parts stay above zero.
  public func parts(exactFirst first: AmountE4) -> (first: AmountE4, second: AmountE4)? {
    guard first > .zero, first < total else { return nil }
    return (first, total - first)
  }

  /// A bar with several borders, each at a fraction of the bar: the parts they make. Borders
  /// stop at the steps, are put in order, and are moved apart by a step where two meet; the last
  /// part takes what is left, so the parts add up to the total. Nil when there is no room for that
  /// many parts.
  public func parts(atFractions fractions: [Decimal]) -> [AmountE4]? {
    guard !fractions.isEmpty else { return [total] }
    let count = fractions.count + 1
    guard Decimal(count) * step.decimal <= total.decimal else { return nil }
    var borders = fractions.map { parts(atFraction: $0).first.raw }.sorted()
    for index in borders.indices.dropFirst() {
      borders[index] = max(borders[index], borders[index - 1] + step.raw)
    }
    // The borders pushed forward may have run into the end: move them back.
    let end = lastStop.raw
    var limit = end
    for index in borders.indices.reversed() {
      borders[index] = min(borders[index], limit)
      limit = borders[index] - step.raw
    }
    guard borders.first.map({ $0 >= step.raw }) == true else { return nil }
    var result: [AmountE4] = []
    var previous: Int64 = 0
    for border in borders {
      result.append(AmountE4(raw: border - previous))
      previous = border
    }
    result.append(AmountE4(raw: total.raw - previous))
    return result
  }
}
