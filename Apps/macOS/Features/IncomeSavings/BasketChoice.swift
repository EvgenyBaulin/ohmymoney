import AppCore
import Foundation

/// The basket menu of a category in Settings → Категории: leave it to the rules (essential
/// spending is «needs», goals are «savings», the rest «wants», a subcategory follows its parent)
/// or move it to a basket of the owner's choosing.
enum BasketChoice: Hashable, CaseIterable {
  case automatic
  case needs
  case wants
  case savings

  init(_ basket: BudgetBasket?) {
    switch basket {
    case nil: self = .automatic
    case .needs: self = .needs
    case .wants: self = .wants
    case .savings: self = .savings
    }
  }

  var basket: BudgetBasket? {
    switch self {
    case .automatic: nil
    case .needs: .needs
    case .wants: .wants
    case .savings: .savings
    }
  }

  /// Only an expense category of the owner's has a basket: income categories and the system
  /// ones (their place is fixed by what they are) have none to choose.
  static func isFixed(_ category: CoreKit.Category, in tree: CategoryTree) -> Bool {
    category.kind != .expense || tree.systemRole(of: category.id) != nil
  }

  @MainActor
  static func name(_ choice: BasketChoice, _ environment: AppEnvironment) -> String {
    switch choice {
    case .automatic: IncomeSavingsText.t("income.basket.automatic", environment)
    case .needs: IncomeSavingsText.basketName(.needs, environment)
    case .wants: IncomeSavingsText.basketName(.wants, environment)
    case .savings: IncomeSavingsText.basketName(.savings, environment)
    }
  }
}
