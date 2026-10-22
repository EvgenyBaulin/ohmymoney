import AppCore
import SwiftUI

/// The Mac's `Table` of operations is AppKit; on iPhone and iPad the same listing is the day
/// cards: a card per day with its total, a round line-symbol badge per row, «category · account»
/// beneath the description. Same arguments as the Mac's table, so `OperationsScreen` is written
/// once.
struct TransactionsTable<MenuItems: View>: View {
  let deps: AppDependencies
  let listing: TransactionListing
  @Binding var selection: Set<UUID>
  var layout: OperationColumnLayout = .standard
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  var deleteAction: (Set<UUID>) -> Void

  var body: some View {
    OperationDayCards(
      deps: deps, listing: listing, selection: $selection, menu: menu,
      primaryAction: primaryAction, deleteAction: deleteAction)
  }
}
