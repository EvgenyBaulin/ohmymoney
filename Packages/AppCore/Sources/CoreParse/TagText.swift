import CoreKit
import Foundation

/// A line with its tags taken out.
public struct TaggedText: Hashable, Sendable {
  /// The line without the tag words, the spaces closed up.
  public var text: String
  /// The tags in the order written, each once (two spellings of one name are one tag), as
  /// first typed and without the «#».
  public var tags: [String]

  public init(text: String, tags: [String]) {
    self.text = text
    self.tags = tags
  }
}

/// Reads «#отпуск #турция» out of a line: a word that starts with «#», has letters, digits, «-»
/// or «_» only and at least one letter. «#1» and «a#b» are not tags and stay in the text. A
/// comma or a full stop at the end of the word is punctuation, not part of the tag.
public enum TagText {
  private static let trailing: Set<Character> = [",", ".", ";", ":", "!", "?", ")"]

  public static func extract(from line: String) -> TaggedText {
    var kept: [Substring] = []
    var tags: [String] = []
    var seen: Set<String> = []
    for word in line.split(whereSeparator: \.isWhitespace) {
      if word.hasPrefix("#"), let name = tagName(of: word) {
        if seen.insert(TagName.key(name)).inserted { tags.append(name) }
      } else {
        kept.append(word)
      }
    }
    return TaggedText(text: kept.joined(separator: " "), tags: tags)
  }

  private static func tagName(of word: Substring) -> String? {
    var body = word
    while let last = body.last, trailing.contains(last) { body.removeLast() }
    return TagName.normalized(String(body))
  }
}
