import AppCore
import SwiftUI

/// What the second line of an operation says on a narrow screen: «Кафе · Т-Банк» — the category
/// and the account —, and for a transfer the two accounts. Pure, so both languages are checked
/// without a view.
enum OperationRowCaption {
  static func text(
    category: String?, account: String?, transfer: String?
  ) -> String? {
    let parts = [transfer ?? category, transfer == nil ? account : nil]
      .compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
  }
}

/// «Операции» as a phone or a narrow tablet draws it: a card for each day — the day and what it
/// comes to above it —, in it a row per operation with the round mark of its kind, the
/// description, «category · account» and the signed amount. The same arguments as the Mac's
/// table, so a platform picks one of them and `OperationsScreen` is written once.
///
/// Selection, the context menu, a tap that edits and ⌫ work as on every list of the window. A
/// split is one row with the number of its parts; its parts are in the editor.
struct OperationDayCards<MenuItems: View>: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces

  let deps: AppDependencies
  let listing: TransactionListing
  @Binding var selection: Set<UUID>
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  var deleteAction: (Set<UUID>) -> Void

  var body: some View {
    List(selection: $selection) {
      ForEach(listing.days) { day in
        Section {
          ForEach(day.rows) { item in
            row(item)
              .tag(item.transactionId)
              .listRowBackground(surfaces.card)
          }
        } header: {
          DayCardHeader(day: day.day, totals: day.totals)
            .appDependencies(deps)
        }
      }
    }
    #if os(iOS)
      .listStyle(.insetGrouped)
    #endif
    .scrollContentBackground(.hidden)
    .contextMenu(forSelectionType: UUID.self, menu: menu, primaryAction: primaryAction)
  }

  private func caption(of item: TransactionRowItem) -> String? {
    var category: String?
    if case .one(let path) = item.category {
      category = CategoryPathText.text(path, language: environment.language)
    }
    // A row titled by its category says it once: the second line keeps only the account.
    if case .category = item.title { category = nil }
    return OperationRowCaption.text(
      category: category, account: item.paymentMethod, transfer: item.transfer?.accounts)
  }

  /// The title in the primary colour whatever it is made of — the description, the category
  /// of a row without one, or its kind.
  private func titleText(of item: TransactionRowItem) -> String {
    switch item.title {
    case .note(let note): note
    case .category(let path): CategoryPathText.text(path, language: environment.language)
    case .kind(let kind):
      item.isTransfer
        ? environment.language("operations.row.transfer", table: "Transactions")
        : environment.language("kind.\(kind.rawValue)")
    }
  }

  private func row(_ item: TransactionRowItem) -> some View {
    HStack(spacing: 12) {
      OperationBadge(kind: OperationBadgeKind(item))
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: titleText(of: item))
            .appFont(.body.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
          if item.partCount > 1 {
            Label {
              Text(verbatim: "\(item.partCount)")
            } icon: {
              Image(systemName: "square.split.2x1")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
        if let caption = caption(of: item) {
          Text(verbatim: caption)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      Text(
        verbatim: OperationAmountSign.prefix(
          kind: item.kind, isTransfer: item.isTransfer, isPart: false)
          + environment.money.exact(item.amount, currency: item.currency)
      )
      .appFont(.body.monospacedDigit())
      .fontWeight(.semibold)
      .foregroundStyle(
        item.kind == .income && !item.isTransfer
          ? AnyShapeStyle(surfaces.positive) : AnyShapeStyle(.primary))
    }
    .accessibilityElement(children: .combine)
  }
}

/// The head of a day card: the day in small capitals of the secondary colour, and what the day
/// came to — «Расходы 2 650 ₽» — on the right, in the same colour. A label, not an accent:
/// the amounts of the rows are what the eye should land on.
struct DayCardHeader: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let day: DateOnly
  let totals: RowTotals

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: title)
        .appFont(.caption.weight(.semibold))
        .textCase(.uppercase)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      RowTotalsLine(totals: totals)
        .appFont(.caption)
    }
    .foregroundStyle(Color(theme.palette.contentSecondary))
  }

  private var title: String {
    environment.dates.dayTitle(
      day,
      today: environment.today,
      language: AppLanguageStrings(
        today: environment.language("common.today"),
        yesterday: environment.language("common.yesterday")))
  }
}
