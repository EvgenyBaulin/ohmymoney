import CoreKit
import Foundation

/// A template with a blank for the amount: «Такси до работы — ? ₽». The chip fills the line
/// with everything but the amount and waits for the number; the amount is the only thing that
/// changes from one time to the next.
public enum TemplateBlank {
  /// The blank in the template text. It stands alone between spaces, or glued to a currency
  /// sign («?₽»).
  public static let marker = "?"

  private static let dashes: Set<String> = ["—", "–", "-", ":"]

  /// The words before and after the blank, a dash right before it dropped:
  /// «Такси до работы — ? ₽» gives «Такси до работы» and «₽».
  public static func parts(of text: String) -> (before: String, after: String)? {
    let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let index = tokens.firstIndex(where: isBlank(token:)) else { return nil }
    var before = Array(tokens[..<index])
    while let last = before.last, dashes.contains(last) { before.removeLast() }
    var after = Array(tokens[(index + 1)...])
    let glued = String(tokens[index].dropFirst())
    if !glued.isEmpty { after.insert(glued, at: 0) }
    return (before.joined(separator: " "), after.joined(separator: " "))
  }

  public static func isBlank(_ text: String) -> Bool {
    parts(of: text) != nil
  }

  public static func isBlank(_ template: Template) -> Bool {
    isBlank(template.text)
  }

  /// The line the chip puts in the field once the amount is known: «Такси до работы 350 ₽».
  /// Nil for a template without a blank. `amount` is what the owner typed, as typed.
  public static func filled(_ text: String, amount: String) -> String? {
    guard let (before, after) = parts(of: text) else { return nil }
    let typed = amount.trimmingCharacters(in: .whitespaces)
    guard !typed.isEmpty else { return nil }
    return [before, typed, after].filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// The line the chip puts in the field before the amount: the text up to the blank, with a
  /// space for the owner to type the number after.
  public static func prefix(of text: String) -> String? {
    guard let (before, _) = parts(of: text) else { return nil }
    return before.isEmpty ? "" : before + " "
  }

  private static func isBlank(token: String) -> Bool {
    guard token.hasPrefix(marker) else { return false }
    let rest = token.dropFirst()
    return rest.isEmpty || rest.allSatisfy { "₽$€£₸₾₺₴".contains($0) }
  }
}
