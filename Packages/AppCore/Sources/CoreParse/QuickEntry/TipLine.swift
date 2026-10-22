import CoreKit
import Foundation

/// «кафе 2000 чай 200» — a tip, or a service charge, written in the line:
/// it becomes a part of its own in the subcategory «Чаевые», so the cafe and the tip are two
/// parts of one operation and the analytics sees them on its own.
public struct TipReading: Hashable, Sendable {
  public enum Amount: Hashable, Sendable {
    case fixed(Decimal)
    /// Percent of the rest of the line: «чаевые 10%».
    case percent(Decimal)
  }

  public enum Kind: Hashable, Sendable {
    case tip
    case serviceCharge
  }

  /// The line without the tip words: «кафе 2000».
  public var baseLine: String
  public var amount: Amount
  public var kind: Kind
  /// The words that named the tip, as typed.
  public var phrase: String

  /// The name of the subcategory both kinds go to; the app creates it under the category of
  /// the operation's other part when it is missing.
  public static let subcategoryName = "Чаевые"

  /// The tip in money and the rest, for a base of `base`: they are two parts and the operation
  /// is their sum — a tip is paid on top of the bill, not out of it. A percent is taken of the
  /// base and rounded half away from zero to a kopek.
  public func parts(base: AmountE4) -> (base: AmountE4, tip: AmountE4)? {
    let tip: AmountE4
    switch amount {
    case .fixed(let value):
      guard let money = try? AmountE4(decimal: value) else { return nil }
      tip = money
    case .percent(let percent):
      let exact = base.decimal * percent / 100
      guard let money = try? AmountE4(decimal: DecimalMath.round(exact, scale: 2)) else {
        return nil
      }
      tip = money
    }
    guard base > .zero, tip > .zero else { return nil }
    return (base, tip)
  }
}

public enum TipLine {
  private struct Phrase {
    var words: [String]
    var kind: TipReading.Kind
  }

  /// Longest first, so «на чай» is read before «чай».
  private static let phrases: [Phrase] = [
    Phrase(words: ["сервисный", "сбор"], kind: .serviceCharge),
    Phrase(words: ["service", "charge"], kind: .serviceCharge),
    Phrase(words: ["service", "fee"], kind: .serviceCharge),
    Phrase(words: ["на", "чай"], kind: .tip),
    Phrase(words: ["чаевые"], kind: .tip),
    Phrase(words: ["чаевых"], kind: .tip),
    Phrase(words: ["tips"], kind: .tip),
    Phrase(words: ["tip"], kind: .tip),
    Phrase(words: ["gratuity"], kind: .tip),
    Phrase(words: ["обслуживание"], kind: .serviceCharge),
    Phrase(words: ["сервис"], kind: .serviceCharge),
    Phrase(words: ["чай"], kind: .tip),
  ]

  /// The tip a line says, or nil. A tip is read only when the rest of the line still has an
  /// amount of its own — «кафе 2000 чай 200» is a cafe and a tip, «чай 200» is a tea and
  /// «чаевые 200» a tip alone, both ordinary operations.
  public static func read(
    _ text: String, parser: InputLineParser, today: DateOnly
  ) -> TipReading? {
    let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let keys = words.map {
      NameKey.fold($0.trimmingCharacters(in: CharacterSet(charactersIn: ",.:;")))
    }
    var index = words.count - 1
    // The last tip phrase of the line wins: the amount of a bill comes before it.
    while index >= 0 {
      for phrase in phrases {
        let end = index + phrase.words.count
        guard end <= words.count, Array(keys[index..<end]) == phrase.words else { continue }
        // «на чай» is read at its own first word, not as a «чай» with a stray «на» before it.
        if phrase.words == ["чай"], index > 0, keys[index - 1] == "на" { continue }
        guard let (amount, used) = amount(in: words, from: end) else { continue }
        var rest = Array(words[..<index])
        rest += Array(words[(end + used)...])
        let baseLine = rest.joined(separator: " ")
        guard !baseLine.isEmpty else { continue }
        let parsed = parser.parse(baseLine, today: today)
        guard parsed.amount != nil, parsed.isSaveable, parsed.kind == .expense else { continue }
        return TipReading(
          baseLine: baseLine, amount: amount, kind: phrase.kind,
          phrase: words[index..<(end + used)].joined(separator: " "))
      }
      index -= 1
    }
    return nil
  }

  /// «200», «200р», «10%», «10 %», «10 процентов»: the amount after the phrase and how many
  /// words it took.
  private static func amount(in words: [String], from start: Int) -> (TipReading.Amount, Int)? {
    guard start < words.count else { return nil }
    let scan = BankScan(words[start])
    guard let (value, end) = scan.number(at: 0), value > 0 else { return nil }
    let rest = String(scan.chars[end...])
    if rest == "%" { return (.percent(value), 1) }
    if rest.isEmpty {
      if start + 1 < words.count {
        let next = NameKey.fold(words[start + 1])
        if next == "%" || ["процент", "процента", "процентов", "percent"].contains(next) {
          return (.percent(value), 2)
        }
      }
      return (.fixed(value), 1)
    }
    // A currency glued to the number: «200р», «200₽».
    if let (_, currencyEnd) = scan.currency(at: end), currencyEnd == scan.count {
      return (.fixed(value), 1)
    }
    return nil
  }
}
