import Foundation

/// Makes the English name of a category from the owner's name, on the device and without the
/// network: the app gives it the system's language model where there is one, else the system's
/// translator; the tests give it a stand-in. The owner's name may be in any language, with a typo
/// or a word of its own: whatever comes back is taken, as long as it is a name.
public protocol CategoryNameTranslating: Sendable {
  /// Whether anything can be translated on this device right now. `false` — no model, no
  /// translator, no language downloaded — leaves every name for a later try.
  func isAvailable() async -> Bool
  /// The English name, `nil` when this one could not be made now.
  func english(for name: String) async -> String?
}

extension CategoryTranslation {
  /// The longest English name kept: a model that answers with a sentence is not giving a name.
  public static let longest = 80

  /// What of a translator's answer is kept as a name: the first line, without the quotes, the
  /// final full stop and the spaces around it; `nil` for nothing left or for something longer
  /// than a name.
  public static func cleaned(_ answer: String) -> String? {
    let firstLine =
      answer
      .split(whereSeparator: \.isNewline)
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map(String.init) ?? ""
    let quotes = CharacterSet(charactersIn: "\"'«»“”„`")
    var name = firstLine.trimmingCharacters(in: .whitespaces.union(quotes))
    while name.hasSuffix(".") { name.removeLast() }
    name = name.trimmingCharacters(in: .whitespaces.union(quotes))
    guard !name.isEmpty, name.count <= longest else { return nil }
    return name
  }
}
