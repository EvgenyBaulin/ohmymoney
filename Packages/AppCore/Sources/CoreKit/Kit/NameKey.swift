import Foundation

/// A name as names are compared: the case, «ё» against «е» and the spaces around it do not
/// count, the spaces inside it do. «Отпуск» and « отпуск », «Ёлка» and «Елка» are one name —
/// the rule the entry line reads names by, so a name that would be taken for another one is
/// found before it is written.
public enum NameKey {
  /// `name` without the spaces around it, in lower case, every «ё» as «е».
  public static func fold(_ name: String) -> String {
    String(name.trimmingCharacters(in: .whitespaces).lowercased().map { $0 == "ё" ? "е" : $0 })
  }
}
