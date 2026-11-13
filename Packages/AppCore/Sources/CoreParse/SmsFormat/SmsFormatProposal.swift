import CoreKit
import Foundation

/// A new format drawn from a text the owner has corrected: the amount, the shop, the balance and
/// the card the owner confirmed become groups, every other digit a run of digits, every word
/// stays. The example it keeps is the text with its figures and its shop made up, never the
/// text the bank sent.
public enum SmsFormatProposal {
  /// The sample the shop is replaced by in the kept example.
  static let sampleShop = "SAMPLE SHOP"

  public static func propose(
    text: String, message: BankMessage, id: String
  ) -> SmsFormat? {
    let source = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !source.isEmpty, source.count <= SmsFormatLibrary.longestText else { return nil }

    struct Piece {
      var range: Range<Int>
      var column: SmsColumn
    }
    var pieces: [Piece] = []
    func overlaps(_ range: Range<Int>) -> Bool {
      pieces.contains { $0.range.overlaps(range) }
    }

    // The shop first: it is the part that may contain digits.
    if let merchant = message.merchant, !merchant.isEmpty,
      let range = find(Array(merchant), in: source)
    {
      pieces.append(Piece(range: range, column: .payee))
    }
    // Numbers, left to right: the first that is the amount, the first that is the balance.
    var wanted: [(AmountE4, SmsColumn)] = [
      (message.money.amount, message.operation.kind == .expense ? .outcome : .income)
    ]
    if let balance = message.balance { wanted.append((balance.amount, .balance)) }
    var cursor = 0
    var usedAmount = false
    var usedBalance = false
    while cursor < source.count {
      guard source[cursor].isNumber, !overlaps(cursor..<(cursor + 1)) else {
        cursor += 1
        continue
      }
      var end = cursor
      while end < source.count,
        source[end].isNumber || ".,".contains(source[end])
          || (source[end].isWhitespace && end + 1 < source.count && source[end + 1].isNumber
            && end > cursor && source[end - 1].isNumber)
      {
        end += 1
      }
      while end > cursor, !source[end - 1].isNumber { end -= 1 }
      let token = String(source[cursor..<end])
      let range = cursor..<end
      if !overlaps(range), let value = SmsFormatNumbers.amount(token) {
        if !usedAmount, value == wanted[0].0 {
          pieces.append(Piece(range: range, column: wanted[0].1))
          usedAmount = true
        } else if !usedBalance, wanted.count > 1, value == wanted[1].0 {
          pieces.append(Piece(range: range, column: .balance))
          usedBalance = true
        }
      }
      cursor = max(end, cursor + 1)
    }
    guard usedAmount else { return nil }
    if let digits = message.cardLast4 {
      var from = 0
      while from + 4 <= source.count {
        let range = from..<(from + 4)
        if String(source[range]) == digits, !overlaps(range),
          from == 0 || !source[from - 1].isNumber,
          from + 4 == source.count || !source[from + 4].isNumber
        {
          pieces.append(
            Piece(range: range, column: message.isAccountDigits ? .account : .card))
          break
        }
        from += 1
      }
    }
    if message.time != nil {
      for index in 0..<max(source.count - 4, 0)
      where source[index].isNumber && !overlaps(index..<(index + 5)) {
        let candidate = String(source[index..<min(index + 5, source.count)])
        if candidate.count == 5, candidate.dropFirst(2).first == ":",
          SmsFormatNumbers.clock(candidate) != nil
        {
          pieces.append(Piece(range: index..<(index + 5), column: .time))
          break
        }
      }
    }
    pieces.sort { $0.range.lowerBound < $1.range.lowerBound }

    var pattern = "^"
    var example = ""
    var columns: [SmsColumn] = []
    var index = 0
    func literal(_ range: Range<Int>) {
      var position = range.lowerBound
      while position < range.upperBound {
        let character = source[position]
        if character.isNumber {
          while position < range.upperBound, source[position].isNumber { position += 1 }
          pattern += #"\d+"#
          example += "1"
        } else if character.isWhitespace {
          while position < range.upperBound, source[position].isWhitespace { position += 1 }
          pattern += #"\s+"#
          example += " "
        } else {
          pattern += NSRegularExpression.escapedPattern(for: String(character))
          example.append(character)
          position += 1
        }
      }
    }
    for piece in pieces {
      literal(index..<piece.range.lowerBound)
      switch piece.column {
      case .payee:
        pattern += "(.+?)"
        example += sampleShop
      case .card, .account:
        pattern += #"(\d{4})"#
        example += "1111"
      case .time:
        pattern += #"(\d{1,2}:\d{2})"#
        example += "11:11"
      default:
        pattern += #"(\d[\d\s]*(?:[.,]\d+)?)"#
        example += piece.column == .balance ? "1000" : "100"
      }
      columns.append(piece.column)
      index = piece.range.upperBound
    }
    literal(index..<source.count)
    pattern += "$"

    var format = SmsFormat(
      id: id, bank: message.bank, pattern: pattern, columns: columns,
      operation: message.operation, examples: [example])
    // A tidy example may start or end with spaces the text did not have.
    format.examples = format.examples.map { $0.trimmingCharacters(in: .whitespaces) }
    guard SmsFormatValidator.problems(of: format).isEmpty else { return nil }
    return format
  }

  private static func find(_ needle: [Character], in haystack: [Character]) -> Range<Int>? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    let lowered = needle.map { Character($0.lowercased()) }
    for start in 0...(haystack.count - needle.count) {
      var matches = true
      for offset in 0..<needle.count
      where Character(haystack[start + offset].lowercased()) != lowered[offset] {
        matches = false
        break
      }
      if matches { return start..<(start + needle.count) }
    }
    return nil
  }
}
