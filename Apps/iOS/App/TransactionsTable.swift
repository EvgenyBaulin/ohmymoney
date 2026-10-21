import AppCore
import SwiftUI

/// The Mac's `Table` of operations is AppKit; on iPhone the same listing is a plain list by day.
/// Same arguments, so `OperationsScreen` is written once.
struct TransactionsTable<MenuItems: View>: View {
  @Dependency(\.environment) private var environment

  let deps: AppDependencies
  let listing: TransactionListing
  @Binding var selection: Set<UUID>
  var layout: OperationColumnLayout = .standard
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  var deleteAction: (Set<UUID>) -> Void

  var body: some View {
    List(selection: $selection) {
      ForEach(listing.days) { day in
        Section {
          ForEach(day.rows) { item in
            HStack {
              Text(verbatim: item.note ?? "")
                .appFont(.body)
                .lineLimit(1)
              Spacer()
              Text(verbatim: environment.money.exact(item.amount, currency: item.currency))
                .appFont(.body)
                .monospacedDigit()
            }
            .tag(item.transactionId)
          }
        } header: {
          Text(verbatim: day.day.iso)
        }
      }
    }
    .contextMenu(forSelectionType: UUID.self, menu: menu, primaryAction: primaryAction)
  }
}
