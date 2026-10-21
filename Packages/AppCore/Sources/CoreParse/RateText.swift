import CoreKit
import Foundation

/// A rate typed by hand — rubles for one unit of a currency, in the ↓ panel, the money-back sheet
/// or «Провести». A plain number reads exactly as rates always read (`DecimalMath.parse`: a lone
/// separator is the decimal one, «83,125» is 83.125); a formula is worked out the way the field
/// of an amount works one out — «95,5/1,02», «1/0.0105», «(90+92)/2» —, its numbers read by the
/// same rule of rates, without the `k` of thousands. The result keeps `fractionDigits` digits:
/// the rate of a weak currency has more of them than money has.
public enum RateText {
  /// Fraction digits a rate worked out from a formula keeps: enough for a bank rate of a unit
  /// quoted per ten thousand (eight digits) with room to spare.
  public static let fractionDigits = 10

  /// What `text` says as a number — of any sign —, or nil for nothing typed, a half-typed
  /// formula or text that is no number.
  public static func value(_ text: String) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let plain = DecimalMath.parse(trimmed) { return plain }
    guard isFormula(trimmed) else { return nil }
    return try? ExpressionEvaluator.worked(
      trimmed, numbers: .rate, fractionDigits: fractionDigits)
  }

  /// The rate `text` says when it is one: a number above zero. A rate at or below zero, or text
  /// that does not read, is no rate.
  public static func rate(_ text: String) -> Decimal? {
    value(text).flatMap { $0 > 0 ? $0 : nil }
  }

  /// Whether the text is a formula rather than a plain number: a sign of arithmetic past a
  /// leading one, or an `x` glued to digits.
  public static func isFormula(_ text: String) -> Bool {
    ExpressionEvaluator.isFormula(text)
  }
}
