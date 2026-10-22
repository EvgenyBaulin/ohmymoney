import CoreKit
import Foundation

/// «ой, 350» — the last operation had a wrong amount. The line starts
/// with a word of regret and says nothing but the new amount.
public struct AmountCorrection: Hashable, Sendable {
  public var amount: Decimal
  /// The currency when the line names one («ой 12 usd»); nil keeps the operation's own.
  public var currency: CurrencyCode?
  /// The formula as typed, when the amount was one.
  public var expression: String?
}

public enum CorrectionLine {
  private static let triggers: Set<String> = [
    "ой", "ай", "упс", "исправь", "исправить", "поправь", "поправить", "ошибся", "ошиблась",
    "oops", "fix", "correct", "whoops",
  ]
  private static let fillers: Set<String> = ["на", "to", "—", "-", "это", "is"]

  /// The correction a line says, or nil when it is not one: it must start with a word of
  /// regret, and what follows must be an amount and nothing else — «ой 350», «ой, 350 р»,
  /// «исправь на 1 200», «oops 12.5 usd». «ой кофе 350» is a new operation, not a correction.
  public static func read(
    _ text: String, parser: InputLineParser, today: DateOnly
  ) -> AmountCorrection? {
    var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = words.first else { return nil }
    let head = NameKey.fold(first.trimmingCharacters(in: CharacterSet(charactersIn: ",.!:;")))
    guard triggers.contains(head) else { return nil }
    words.removeFirst()
    while let next = words.first, fillers.contains(next.lowercased()) { words.removeFirst() }
    guard !words.isEmpty else { return nil }
    let parsed = parser.parse(words.joined(separator: " "), today: today)
    guard let amount = parsed.amount, parsed.isSaveable, parsed.note.isEmpty,
      parsed.date == nil, parsed.kind == .expense, parsed.placeId == nil,
      parsed.paymentMethodId == nil, parsed.cardId == nil, parsed.eventId == nil
    else { return nil }
    return AmountCorrection(
      amount: amount, currency: parsed.currency, expression: parsed.amountExpression)
  }
}
