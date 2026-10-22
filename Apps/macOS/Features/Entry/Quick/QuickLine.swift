import AppCore
import Foundation

/// What the text in the entry line is, before it is read as one ordinary operation: a word of
/// regret and an amount («ой 350»), several operations in one line («кофе 250; метро 62»), a
/// bill with a tip («кафе 2000 чай 200»), or the request to write yesterday again. Pure, so a
/// test reads every case without a window.
enum QuickLine {
  enum Kind: Equatable {
    case ordinary
    /// «ой 350»: the last operation had another amount.
    case correction(AmountCorrection)
    /// «кофе 250; метро 62»: each part is an operation of its own.
    case several(parts: [String], truncated: Bool)
    /// «кафе 2000 чай 200»: the bill and the tip are two parts of one operation.
    case tip(TipReading)
    /// «повторить вчера».
    case repeatYesterday
  }

  /// The phrases that ask for yesterday again, folded like names are.
  static let repeatPhrases: Set<String> = Set(
    [
      "повторить вчера", "повтори вчера", "как вчера", "то же что вчера", "то же, что вчера",
      "repeat yesterday", "same as yesterday",
    ].map { NameKey.fold($0) })

  static func classify(_ text: String, parser: InputLineParser, today: DateOnly) -> Kind {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .ordinary }
    if repeatPhrases.contains(NameKey.fold(trimmed)) { return .repeatYesterday }
    if let correction = CorrectionLine.read(trimmed, parser: parser, today: today) {
      return .correction(correction)
    }
    if MultiEntryLine.containsSeparator(trimmed) {
      let parts = MultiEntryLine.split(trimmed)
      // «кофе 250;» is one operation with a stray separator: it reads as typed.
      if parts.count > 1 {
        return .several(
          parts: Array(parts.prefix(MultiEntryLine.maxParts)),
          truncated: parts.count > MultiEntryLine.maxParts)
      }
    }
    if let tip = TipLine.read(trimmed, parser: parser, today: today) { return .tip(tip) }
    return .ordinary
  }
}

/// What a paste into the line is. The answers of the owner: a text of a bank fills the line
/// with what it says and offers the rest; a list of them is shown with ticks; any other text
/// goes in as it was pasted.
enum QuickPaste {
  enum Decision: Equatable {
    case plain
    case message(BankMessage)
    case list([BankListItem])
  }

  /// The smallest chunk that can be a text of a bank: a keystroke or a word is never one.
  static let smallestPaste = 14

  /// The chunk `new` has over `old`, when `new` is `old` with a block inserted at the end, the
  /// start, or in the middle; `nil` when it is not a paste (a keystroke, a deletion).
  static func inserted(old: String, new: String) -> String? {
    guard new.count >= old.count + smallestPaste else { return nil }
    if old.isEmpty { return new }
    if new.hasPrefix(old) { return String(new.dropFirst(old.count)) }
    if new.hasSuffix(old) { return String(new.dropLast(old.count)) }
    // In the middle: the common start and the common end are the old text.
    let head = zip(old, new).prefix { $0 == $1 }.count
    let tailLimit = old.count - head
    let tail = zip(old.reversed(), new.reversed()).prefix(tailLimit).prefix { $0 == $1 }.count
    guard head + tail == old.count else { return nil }
    let start = new.index(new.startIndex, offsetBy: head)
    let end = new.index(new.endIndex, offsetBy: -tail)
    return String(new[start..<end])
  }

  static func decide(chunk: String, today: DateOnly) -> Decision {
    switch BankTextParser().reading(of: chunk, today: today) {
    case .plain: .plain
    case .message(let message): .message(message)
    case .list(let items): .list(items)
    }
  }
}

/// What the app has to ask about the card a text of a bank names.
enum QuickCardQuestion: Equatable {
  /// No card in the text, or the card is known: nothing to ask.
  case none
  /// The digits are not any card's yet: asked once, and the answer is kept on the card.
  case unknown(last4: String)
  /// Two cards end the same way.
  case ambiguous([CardDigits])

  static func of(_ lookup: CardDigitsIndex.Lookup) -> QuickCardQuestion {
    switch lookup {
    case .none, .card: .none
    case .unknown(let last4): .unknown(last4: last4)
    case .ambiguous(let cards): .ambiguous(cards)
    }
  }
}
