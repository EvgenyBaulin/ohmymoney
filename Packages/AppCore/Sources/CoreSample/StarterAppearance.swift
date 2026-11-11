import CoreKit
import Foundation

/// The symbol and colour a starter category is made with. They are keyed by the English seed
/// name and the kind, so all thirty languages get them with the names; only top-level categories
/// have one, a subcategory is drawn like its parent until the owner picks another
/// (`CategoryTree.appearance(of:)`). A category the table does not name — a system one made
/// later, the owner's own — has none, and its row keeps the mark of its kind.
enum StarterAppearance {
  static func of(_ seed: CategorySeed) -> CategoryAppearance {
    guard seed.parentEnglish == nil,
      let found = table["\(seed.kind.rawValue)/\(seed.english)"]
    else { return .none }
    return CategoryAppearance(icon: found.icon, color: found.tone.key)
  }

  private static let table: [String: (icon: String, tone: CategoryTone)] = [
    "expense/Groceries": ("cart", .tone1),
    "expense/Food out": ("fork.knife", .tone2),
    "expense/Transport": ("bus", .tone3),
    "expense/Car": ("car", .tone4),
    "expense/Home": ("house", .tone5),
    "expense/Subscriptions & services": ("cloud", .accent),
    "expense/Health": ("cross.case", .tone2),
    "expense/Beauty": ("scissors", .tone5),
    "expense/Clothing": ("tshirt", .tone3),
    "expense/Electronics": ("laptopcomputer", .tone4),
    "expense/Entertainment": ("film", .tone5),
    "expense/Gifts": ("gift", .tone2),
    "expense/Travel": ("airplane", .tone1),
    "expense/Education": ("graduationcap", .tone3),
    "expense/Other": ("ellipsis.circle", .neutral),
    "expense/Goals": ("target", .tone4),
    "expense/Loans": ("building.columns", .neutral),
    "expense/Unknown": ("ellipsis.circle", .neutral),
    "expense/Taxes & fees": ("percent", .neutral),
    "expense/Kids": ("figure.2.and.child.holdinghands", .tone2),
    "income/Work": ("briefcase", .tone1),
    "income/Family": ("heart", .tone5),
    "income/Passive": ("banknote", .tone4),
    "income/Gifts": ("gift", .tone2),
    "income/Sales": ("creditcard", .tone3),
    "income/Other": ("ellipsis.circle", .neutral),
    "income/Surcharges": ("percent", .neutral),
    "income/Unknown": ("ellipsis.circle", .neutral),
    "income/Child benefit": ("figure.2.and.child.holdinghands", .tone2),
  ]
}
