import CoreKit
import Foundation

/// Evaluates the small arithmetic a person can type instead of an amount:
/// `120+80.5+45`, `(1000+600)/2`, `3000÷4`, `1500×3−2000`.
///
/// Everything is computed exactly — as fractions while their terms fit 128 bits, in `Decimal`
/// beyond that — and the result is rounded once, half away from zero, to the four fraction
/// digits the schema stores in its `*_e4` columns, so an expression can never carry more
/// precision than the amount it produces.
public enum ExpressionEvaluator: Sendable {
  /// Fraction digits kept in the result — the scale of the `*_e4` money columns.
  public static let fractionDigits = 4

  /// Largest result one amount may have: `AmountE4.inputLimit`, a trillion whole units.
  /// Decimal arithmetic does not trap on overflow — it quietly returns a NaN — so a formula
  /// that runs past it is rejected here instead of travelling on as a number. The limit sits
  /// far below `Int64.max` stored units on purpose: two amounts that each fit the column
  /// must still fit it together, in the total of a day or of a split.
  static let maxMagnitude = AmountE4.inputLimit.decimal

  /// How large a number or an intermediate result of a formula may be on the way. A `Decimal`
  /// keeps 38 significant digits; beyond 10^33 fewer than five of them are left after the
  /// point, so the four digits of an amount are no longer exact — two forty-digit numbers that
  /// differ by one came to 0, not 1, and with 250 added to a plausible, wrong 250. No formula
  /// of an amount needs a figure that large, so it is refused as too large on the spot,
  /// whatever the formula would come to in the end.
  static let maxIntermediate = Decimal(sign: .plus, exponent: 33, significand: 1)

  /// - Throws: `CoreError.emptyInput` for blank text, `CoreError.divisionByZero`,
  ///   `CoreError.amountOutOfRange` when the result overflows or is larger than one amount
  ///   may be, or a figure on the way is too large to keep exact (`maxIntermediate`),
  ///   `CoreError.malformedExpression(position:)` with the offset of the offending
  ///   character (the length of the text when the formula ends too early).
  public static func evaluate(_ text: String) throws -> Decimal {
    try worked(text, numbers: .amount, fractionDigits: fractionDigits)
  }

  /// The formula worked out with its numbers read by `rule` and the result rounded once, half
  /// away from zero, to `scale` fraction digits — four for an amount, more for a rate
  /// (`RateText`). The limits of an amount hold for both.
  static func worked(
    _ text: String, numbers rule: ExpressionLexer.NumberRule, fractionDigits scale: Int
  ) throws -> Decimal {
    let characters = Array(text)
    guard characters.contains(where: { !ExpressionLexer.isSpace($0) }) else {
      throw CoreError.emptyInput
    }
    let tokens = try ExpressionLexer.tokenize(characters, numbers: rule)
    guard !tokens.isEmpty else { throw CoreError.emptyInput }
    var parser = ExpressionParser(tokens: tokens, endPosition: characters.count)
    let value = try parser.parseExpression()
    try parser.expectEnd()
    let rounded: Decimal
    if let exact = value.exact, let units = exact.units(scale: scale) {
      // Rounded on the exact value: a tie behind a quotient that never ends goes away from
      // zero, as it would on paper.
      rounded = DecimalMath.round(
        Decimal(
          sign: units < 0 ? .minus : .plus, exponent: -scale,
          significand: Decimal(units.magnitude)),
        scale: scale)
    } else if value.exact != nil, scale == fractionDigits {
      // An amount whose units do not fit is too large for any amount.
      throw CoreError.amountOutOfRange
    } else {
      guard !value.decimal.isNaN else { throw CoreError.amountOutOfRange }
      rounded = DecimalMath.round(value.decimal, scale: scale)
    }
    guard rounded.magnitude <= maxMagnitude else { throw CoreError.amountOutOfRange }
    return rounded
  }

  /// The text with every number in it written the way the app writes numbers, and everything
  /// else — signs, brackets, spaces, the `k` of thousands — as typed: «1500,5+2,50» becomes
  /// «1,500.5+2.50», «(1 000+600)/2» becomes «(1,000+600)/2», «2,5k» becomes «2.5k». It comes
  /// to the same value as the text. Nil for text that is not made of numbers and signs.
  public static func canonical(_ text: String) -> String? {
    let characters = Array(text)
    guard let tokens = try? ExpressionLexer.tokenize(characters) else { return nil }
    var result = ""
    var cursor = 0
    for token in tokens {
      guard case .number = token.kind else { continue }
      result += String(characters[cursor..<token.position]) + token.canonical
      cursor = token.end
    }
    return result + String(characters[cursor...])
  }

  /// True when the text is a formula rather than a plain number, so the entry keeps it in
  /// `amount_expr`. A single leading sign does not make a formula: `+50000` marks income. An
  /// `x`/`х` glued to digits on both sides does: «250x2».
  public static func isFormula(_ text: String) -> Bool {
    var characters = Array(text.trimmingCharacters(in: .whitespaces))
    if let first = characters.first, first == "+" || ExpressionLexer.operatorKind(first) == .minus {
      characters.removeFirst()
    }
    return characters.contains { ExpressionLexer.operatorKind($0) != nil }
      || characters.indices.contains { ExpressionLexer.isGluedTimes(characters, at: $0) }
  }
}

/// A figure of a formula on the way: what `Decimal` makes of it, and the same figure as an
/// exact fraction for as long as one holds it.
struct FormulaFigure {
  var decimal: Decimal
  var exact: ExactFraction?

  static func + (left: FormulaFigure, right: FormulaFigure) -> FormulaFigure {
    FormulaFigure(
      decimal: left.decimal + right.decimal,
      exact: left.exact.flatMap { a in right.exact.flatMap(a.adding) })
  }

  static func - (left: FormulaFigure, right: FormulaFigure) -> FormulaFigure {
    FormulaFigure(
      decimal: left.decimal - right.decimal,
      exact: left.exact.flatMap { a in right.exact.flatMap(a.subtracting) })
  }

  static func * (left: FormulaFigure, right: FormulaFigure) -> FormulaFigure {
    FormulaFigure(
      decimal: left.decimal * right.decimal,
      exact: left.exact.flatMap { a in right.exact.flatMap(a.multiplied(by:)) })
  }

  static func / (left: FormulaFigure, right: FormulaFigure) -> FormulaFigure {
    FormulaFigure(
      decimal: left.decimal / right.decimal,
      exact: left.exact.flatMap { a in right.exact.flatMap(a.divided(by:)) })
  }

  static prefix func - (figure: FormulaFigure) -> FormulaFigure {
    FormulaFigure(decimal: -figure.decimal, exact: figure.exact?.negated())
  }

  /// Zero exactly when the exact fraction says so; the decimal decides only where there is
  /// no fraction, since a quotient cut at 38 digits may leave a hair above zero.
  var isZero: Bool {
    exact.map(\.isZero) ?? (decimal == Decimal.zero)
  }
}

/// Recursive descent over the token list: `+ -` bind loosest, then `* /`, then unary signs,
/// then numbers and parentheses.
struct ExpressionParser {
  /// How far brackets and signs may nest. Both nest by recursion, so without a ceiling a
  /// line pasted with a few hundred opening brackets runs the stack out and kills the
  /// process instead of raising an error. A formula a person types never comes close.
  static let maxDepth = 32

  private let tokens: [ExpressionToken]
  private let endPosition: Int
  private var index = 0
  private var depth = 0

  init(tokens: [ExpressionToken], endPosition: Int) {
    self.tokens = tokens
    self.endPosition = endPosition
  }

  private func peek() -> ExpressionToken? {
    index < tokens.count ? tokens[index] : nil
  }

  private mutating func advance() {
    index += 1
  }

  mutating func expectEnd() throws {
    if let token = peek() {
      throw CoreError.malformedExpression(position: token.position)
    }
  }

  mutating func parseExpression() throws -> FormulaFigure {
    var value = try parseTerm()
    while let token = peek() {
      switch token.kind {
      case .plus:
        advance()
        let right = try parseTerm()
        value = try kept(value + right)
      case .minus:
        advance()
        let right = try parseTerm()
        value = try kept(value - right)
      default:
        return value
      }
    }
    return value
  }

  private mutating func parseTerm() throws -> FormulaFigure {
    var value = try parseUnary()
    while let token = peek() {
      switch token.kind {
      case .times:
        advance()
        let right = try parseUnary()
        value = try kept(value * right)
      case .divide:
        advance()
        let right = try parseUnary()
        guard !right.isZero else { throw CoreError.divisionByZero }
        value = try kept(value / right)
      default:
        return value
      }
    }
    return value
  }

  private mutating func parseUnary() throws -> FormulaFigure {
    guard let token = peek() else {
      throw CoreError.malformedExpression(position: endPosition)
    }
    switch token.kind {
    case .plus, .minus:
      advance()
      try descend(from: token.position)
      defer { depth -= 1 }
      let value = try parseUnary()
      return token.kind == .minus ? -value : value
    default:
      return try parsePrimary()
    }
  }

  /// A number or an intermediate result small enough to keep every digit an amount needs, or
  /// a refusal: too large, or no number at all — what `Decimal` gives when it overflows. Told
  /// by the exact fraction while there is one.
  private func kept(_ value: FormulaFigure) throws -> FormulaFigure {
    if let exact = value.exact {
      guard exact.isBelow(ExpressionParser.maxIntermediate) else {
        throw CoreError.amountOutOfRange
      }
      return value
    }
    guard !value.decimal.isNaN, value.decimal.magnitude < ExpressionEvaluator.maxIntermediate
    else { throw CoreError.amountOutOfRange }
    return value
  }

  /// `ExpressionEvaluator.maxIntermediate` as a whole number of 128 bits.
  static let maxIntermediate: Int128 = {
    var value: Int128 = 1
    for _ in 0..<33 { value *= 10 }
    return value
  }()

  /// Enters one more level of nesting, or refuses to.
  private mutating func descend(from position: Int) throws {
    depth += 1
    guard depth <= ExpressionParser.maxDepth else {
      throw CoreError.malformedExpression(position: position)
    }
  }

  private mutating func parsePrimary() throws -> FormulaFigure {
    guard let token = peek() else {
      throw CoreError.malformedExpression(position: endPosition)
    }
    switch token.kind {
    case .number(let value, let exact):
      advance()
      return try kept(FormulaFigure(decimal: value, exact: exact))
    case .openParen:
      advance()
      try descend(from: token.position)
      defer { depth -= 1 }
      let value = try parseExpression()
      guard let closing = peek(), closing.kind == .closeParen else {
        throw CoreError.malformedExpression(position: peek()?.position ?? endPosition)
      }
      advance()
      return value
    default:
      throw CoreError.malformedExpression(position: token.position)
    }
  }
}
