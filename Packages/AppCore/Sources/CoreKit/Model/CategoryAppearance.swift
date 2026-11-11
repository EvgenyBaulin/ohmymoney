import Foundation

/// The mark a category wears in the list of operations: a symbol and a colour, both optional.
/// Stored as plain text (`categories.icon`, `categories.color`) so that a value written by a
/// newer build, which this one does not know, is kept as it is and merely drawn as no mark.
public struct CategoryAppearance: Hashable, Sendable {
  /// A name of `CategoryIcon`, `nil` for none of its own.
  public var icon: String?
  /// A key of `CategoryTone`, `nil` for none of its own.
  public var color: String?

  public init(icon: String? = nil, color: String? = nil) {
    self.icon = icon
    self.color = color
  }

  public static let none = CategoryAppearance()

  /// Whether the category says anything of its own.
  public var isEmpty: Bool { icon == nil && color == nil }
}

/// The short list of symbols a category can take, as SF Symbol names. A name outside it draws
/// nothing in a system image, so the list is also the filter: an unknown name reads as no mark.
public enum CategoryIcon {
  /// Spending, in the order the picker shows them.
  public static let all: [String] = [
    "cart", "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "bus", "car",
    "fuelpump", "parkingsign", "house", "bolt", "wifi", "iphone", "cloud", "heart", "cross.case",
    "pills", "figure.run", "scissors", "tshirt", "laptopcomputer", "gamecontroller", "film",
    "wineglass", "gift", "airplane", "graduationcap", "books.vertical", "pawprint",
    "figure.2.and.child.holdinghands", "creditcard", "building.columns", "banknote", "briefcase",
    "percent", "target", "wrench.and.screwdriver", "shield", "ellipsis.circle",
  ]

  /// `name` when the list has it; `nil` for no name and for one this build does not know.
  public static func known(_ name: String?) -> String? {
    guard let name, all.contains(name) else { return nil }
    return name
  }
}

/// The colours a category can take, by the app's own stable keys. Each key is a slot the theme
/// fills with an ink and a tint of its own, so the mark follows the theme and the contrast
/// theme without the database holding a colour; which theme colour a slot is lives in the
/// interface, not here.
public enum CategoryTone: String, CaseIterable, Sendable {
  case accent
  case tone1
  case tone2
  case tone3
  case tone4
  case tone5
  case neutral

  /// The tone a stored key names; `nil` for no key and for a key this build does not know.
  public init?(key: String?) {
    guard let key, let tone = Self(rawValue: key) else { return nil }
    self = tone
  }

  /// The key as stored.
  public var key: String { rawValue }

  /// The String Catalog key (table `Settings`) of the colour's name, read aloud and shown
  /// next to the swatch: the colour never stands alone.
  public var nameKey: String { "categories.tone.\(rawValue)" }
}
