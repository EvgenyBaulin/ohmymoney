import Foundation

/// A polite reminder to somebody who owes me, made from a template with fields: `{имя}` /
/// `{name}`, `{сумма}` / `{amount}`, `{за что}` / `{for}`, `{дата}` / `{date}`. The owner's edit
/// of the text becomes the template of the next one.
public enum NudgeText {
  /// The values a template is filled with, as the owner sees them.
  public struct Values: Hashable, Sendable {
    public var name: String
    public var amount: String
    public var reason: String?
    public var day: String?

    public init(name: String, amount: String, reason: String? = nil, day: String? = nil) {
      self.name = name
      self.amount = amount
      self.reason = reason
      self.day = day
    }
  }

  /// The fields, Russian and English spelling, in the order of `Values`.
  static let fields: [(ru: String, en: String)] = [
    ("{имя}", "{name}"), ("{сумма}", "{amount}"), ("{за что}", "{for}"), ("{дата}", "{date}"),
  ]

  /// The text of `template` with its fields filled; a field without a value leaves its phrase.
  /// A phrase is a part of the template in square brackets — «[ за {за что}]» —: it is kept,
  /// without its brackets, only when every field in it has a value. A field without a value
  /// outside brackets is left out, and the spaces it leaves are closed.
  public static func make(
    template: String, name: String, amount: String, reason: String?, day: String?
  ) -> String {
    let values = [name, amount, reason ?? "", day ?? ""].map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func fill(_ text: String) -> (text: String, missing: Bool) {
      var result = text
      var missing = false
      for (index, field) in fields.enumerated() {
        for token in [field.ru, field.en] where result.contains(token) {
          if values[index].isEmpty { missing = true }
          result = result.replacingOccurrences(of: token, with: values[index])
        }
      }
      return (result, missing)
    }
    var output = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "[") {
      output += fill(String(rest[..<open])).text
      guard let close = rest[open...].firstIndex(of: "]") else {
        rest = rest[open...]
        break
      }
      let phrase = fill(String(rest[rest.index(after: open)..<close]))
      if !phrase.missing { output += phrase.text }
      rest = rest[rest.index(after: close)...]
    }
    output += fill(String(rest)).text
    return tidy(output)
  }

  /// The owner's edit of a filled text turned back into a template: each value found word for
  /// word becomes its field again — the longest value first, so a name inside a reason stays in
  /// the reason. The fields are spelled in Russian when the text is.
  public static func template(fromEdited text: String, values: Values) -> String {
    let russian = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    let pairs = [values.name, values.amount, values.reason ?? "", values.day ?? ""]
      .enumerated()
      .map { ($0.element.trimmingCharacters(in: .whitespacesAndNewlines), $0.offset) }
      .filter { !$0.0.isEmpty }
      .sorted { $0.0.count > $1.0.count }
    // Swap in placeholders first, so a field put back is never matched by a shorter value.
    var result = text
    var placed: [(String, String)] = []
    for (value, index) in pairs where result.contains(value) {
      let mark = "\u{1}\(index)\u{1}"
      result = result.replacingOccurrences(of: value, with: mark)
      placed.append((mark, russian ? fields[index].ru : fields[index].en))
    }
    for (mark, field) in placed { result = result.replacingOccurrences(of: mark, with: field) }
    return result
  }

  /// Spaces closed after a field left out: no double spaces, none before a punctuation mark.
  static func tidy(_ text: String) -> String {
    var result = text
    while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
    for mark in [",", ".", "!", "?", ":", ";", ")"] {
      result = result.replacingOccurrences(of: " " + mark, with: mark)
    }
    return result.trimmingCharacters(in: .whitespaces)
  }
}
