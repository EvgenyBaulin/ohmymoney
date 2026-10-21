import Foundation

/// The check behind the privacy rule of the journal: the journal is run through a filter, and
/// the test fails if an amount, a title or a name got into a line.
///
/// It is given what must never appear — the amounts, people, categories, places, events and
/// notes of whatever data the journal was gathered on — and says which of them did.
public enum LogPrivacy {
  /// Anything shorter than this is not evidence: a two-letter name or a one-digit amount
  /// would match half the alphabet and every line with a number in it.
  public static let shortestMeaningful = 3

  public static func offences(in text: String, forbidding values: [String]) -> [String] {
    let lowered = text.lowercased()
    let tightened = String(lowered.filter { !$0.isWhitespace })
    let numbersOfText = numbers(in: text)
    var found: [String] = []
    for value in values {
      let needle = value.lowercased()
      guard needle.count >= shortestMeaningful else { continue }
      if lowered.contains(needle) {
        found.append(value)
        continue
      }
      // «Кофе с молоком» in the log as «Кофесмолоком» is the same leak.
      let tight = String(needle.filter { !$0.isWhitespace })
      if tight.count >= shortestMeaningful, tightened.contains(tight) {
        found.append(value)
        continue
      }
      // An amount survives losing its separators: 12 345,67 → 1234567. Looked for inside
      // each number of the text, never across two: `upserted=15 removed=0` is not «1500».
      let digits = String(value.filter(\.isNumber))
      if digits.count >= 4, numbersOfText.contains(where: { $0.contains(digits) }) {
        found.append(value)
      }
    }
    return found
  }

  /// What may stand between the digits of one formatted amount: a space of any width, a comma,
  /// a point, an apostrophe.
  static let separators: Set<Character> = [
    " ", "\u{00A0}", "\u{202F}", "\u{2009}", ",", ".", "'", "\u{2019}",
  ]

  /// The numbers of a text, each as its digits alone: a digit, and the digits that follow it
  /// through one separator at a time. The stamps of the journal's lines are left out first —
  /// a time is never an amount, and its seconds and thousandths would read as one number.
  static func numbers(in text: String) -> [String] {
    let characters = Array(withoutStamps(text))
    var numbers: [String] = []
    var current = ""
    for (index, character) in characters.enumerated() {
      if character.isNumber {
        current.append(character)
      } else if !current.isEmpty, separators.contains(character), index + 1 < characters.count,
        characters[index + 1].isNumber
      {
        continue
      } else if !current.isEmpty {
        numbers.append(current)
        current = ""
      }
    }
    if !current.isEmpty { numbers.append(current) }
    return numbers
  }

  /// The shape of `LogLine.stamp`: `2026-09-20T09:28:43.456+03:00`; `0` is any digit, `+` a
  /// sign.
  private static let stampShape = Array("0000-00-00T00:00:00.000+00:00")

  static func withoutStamps(_ text: String) -> String {
    let characters = Array(text)
    var kept: [Character] = []
    var index = 0
    while index < characters.count {
      if isStamp(characters, at: index) {
        kept.append(" ")
        index += stampShape.count
      } else {
        kept.append(characters[index])
        index += 1
      }
    }
    return String(kept)
  }

  private static func isStamp(_ characters: [Character], at start: Int) -> Bool {
    guard start + stampShape.count <= characters.count else { return false }
    for (offset, shape) in stampShape.enumerated() {
      let character = characters[start + offset]
      switch shape {
      case "0": guard character.isASCII, character.isNumber else { return false }
      case "+": guard character == "+" || character == "-" else { return false }
      default: guard character == shape else { return false }
      }
    }
    return true
  }

  /// Every line of a journal, checked at once.
  public static func offences(inLines lines: [String], forbidding values: [String]) -> [String] {
    var found: [String] = []
    for line in lines {
      for value in offences(in: line, forbidding: values) where !found.contains(value) {
        found.append(value)
      }
    }
    return found
  }
}
