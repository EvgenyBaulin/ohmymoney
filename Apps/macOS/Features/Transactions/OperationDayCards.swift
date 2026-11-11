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

/// «Операции» on a phone or a tablet. A phone (and a tablet too narrow for columns) draws the
/// frame 5:7984: a card for each day — the day and its figure above it —, in it a row per
/// operation with the round mark of its kind, the description, «category · account» and the
/// signed amount. A tablet wide enough draws the frame 5:76375: one card with the names of the
/// columns, the days and a row per operation in the Mac's columns — description, category,
/// account, time, amount. The same arguments as the Mac's table, so a platform picks one of them
/// and `OperationsScreen` is written once.
///
/// Selection, the context menu, a tap that edits and ⌫ work as on every list of the window. A
/// split is one row with the number of its parts; its parts are in the editor.
struct OperationDayCards<MenuItems: View>: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var idiom

  let deps: AppDependencies
  let listing: TransactionListing
  @Binding var selection: Set<UUID>
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  var deleteAction: (Set<UUID>) -> Void
  @State private var width: CGFloat = 0

  /// The narrowest a tablet's list is drawn in columns: the five columns of the frame and room
  /// for a description.
  static var widthForColumns: CGFloat { 720 }

  /// Whether the list is drawn in columns: a tablet (or the Mac), wide enough.
  static func showsColumns(width: CGFloat, idiom: LayoutIdiom) -> Bool {
    idiom != .phone && width >= widthForColumns
  }

  var body: some View {
    let columns = Self.showsColumns(width: width, idiom: LayoutIdiom.resolved(idiom))
    Group {
      if columns {
        VStack(spacing: 0) {
          OperationColumnsHeader()
          list(columns: true)
        }
        .padding(.top, OperationsMetrics.cardVertical)
        .operationsCard()
        .padding(.horizontal, OperationsMetrics.padPageSide)
      } else {
        list(columns: false)
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  @ViewBuilder
  private func list(columns: Bool) -> some View {
    let list = plainList(columns: columns)
      .environment(\.defaultMinListRowHeight, 1)
      // The head of a day is as tall as its words and margins, not the system's header.
      .environment(\.defaultMinListHeaderHeight, 1)
      .scrollContentBackground(.hidden)
      .contextMenu(forSelectionType: UUID.self, menu: menu, primaryAction: primaryAction)
    #if os(iOS)
      if columns {
        // The days follow one another in the card with nothing between them but the hairline.
        list.listStyle(.plain)
          .listSectionSpacing(0)
          .contentMargins(.top, 0, for: .scrollContent)
      } else {
        // The cards of the days, 10 apart, 16 from the sides of the page.
        list.listStyle(.insetGrouped)
          .listSectionSpacing(OperationsMetrics.phoneStackGap)
          .contentMargins(.horizontal, OperationsMetrics.phonePageSide, for: .scrollContent)
      }
    #else
      list
    #endif
  }

  private func plainList(columns: Bool) -> some View {
    List(selection: $selection) {
      ForEach(listing.days) { day in
        Section {
          ForEach(day.rows) { item in
            Group {
              if columns { columnRow(item) } else { row(item) }
            }
            .tag(item.transactionId)
            .listRowInsets(rowInsets(columns: columns))
            .listRowBackground(theme.surfaceCard)
            .listRowSeparatorTint(theme.borderHairline)
            // The last row of a day keeps its hairline too, above the next day's head.
            .listSectionSeparator(columns ? .visible : .hidden, edges: .bottom)
            .listSectionSeparatorTint(theme.borderHairline)
            // The hairline runs across the whole card, edge to edge, as the frames draw it: the
            // row's own margin is given back on both sides.
            .alignmentGuide(.listRowSeparatorLeading) { _ in -Self.rowSide(columns: columns) }
            .alignmentGuide(.listRowSeparatorTrailing) { row in
              row.width + Self.rowSide(columns: columns)
            }
          }
        } header: {
          OperationDayHead(day: day.day, totals: day.totals)
            .padding(.horizontal, columns ? 0 : OperationsMetrics.phoneDayInset)
            .padding(.top, columns ? OperationsMetrics.padDayTop : OperationsMetrics.phoneDayInset)
            .padding(
              .bottom, columns ? OperationsMetrics.padDayBottom : OperationsMetrics.phoneDayGap
            )
            .listRowInsets(
              EdgeInsets(
                top: 0, leading: columns ? OperationsMetrics.rowHorizontal : 0, bottom: 0,
                trailing: columns ? OperationsMetrics.rowHorizontal : 0)
            )
            .appDependencies(deps)
        }
      }
    }
  }

  /// The margin of a row at its sides: 18 in the tablet's columns, 14 in a phone's card.
  static func rowSide(columns: Bool) -> CGFloat {
    columns ? OperationsMetrics.rowHorizontal : OperationsMetrics.phoneRowHorizontal
  }

  private func rowInsets(columns: Bool) -> EdgeInsets {
    columns
      ? EdgeInsets(
        top: OperationsMetrics.padRowVertical, leading: OperationsMetrics.rowHorizontal,
        bottom: OperationsMetrics.padRowVertical, trailing: OperationsMetrics.rowHorizontal)
      : EdgeInsets(
        top: OperationsMetrics.phoneRowVertical, leading: OperationsMetrics.phoneRowHorizontal,
        bottom: OperationsMetrics.phoneRowVertical, trailing: OperationsMetrics.phoneRowHorizontal)
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

  private func amountText(of item: TransactionRowItem) -> String {
    OperationAmountSign.prefix(kind: item.kind, isTransfer: item.isTransfer, isPart: false)
      + environment.money.exact(item.amount, currency: item.currency)
  }

  private func title(of item: TransactionRowItem, font: AppFont) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: titleText(of: item))
        .appFont(font)
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(1)
      if item.partCount > 1 {
        Label {
          Text(verbatim: "\(item.partCount)")
        } icon: {
          Image(systemName: "square.split.2x1")
        }
        .appFont(.caption)
        .foregroundStyle(theme.contentSecondary)
      }
    }
  }

  /// A row of the phone (5:8015): the mark 36, the description 16 medium over «Кафе · Т-Банк»
  /// 12, and the amount 16 semibold — income too in the primary colour: its «+» and its mark
  /// say what it is.
  private func row(_ item: TransactionRowItem) -> some View {
    HStack(spacing: OperationsMetrics.badgeGap) {
      OperationBadge(
        kind: OperationBadgeKind(item), category: item.categoryMark,
        side: OperationsMetrics.phoneBadge,
        symbolSide: OperationsMetrics.phoneBadgeSymbol)
      VStack(alignment: .leading, spacing: OperationsMetrics.phoneLineGap) {
        title(of: item, font: OperationsType.phoneTitle)
        if let caption = caption(of: item) {
          HStack(spacing: 5) {
            if let accent = item.accountAccent {
              AccountAccentDot(accent: accent, diameter: 7)
            }
            Text(verbatim: caption)
              .appFont(OperationsType.phoneCaption)
              .foregroundStyle(theme.contentSecondary)
              .lineLimit(1)
          }
        }
      }
      Spacer(minLength: 8)
      Text(verbatim: amountText(of: item))
        .appFont(OperationsType.phoneAmount)
        .foregroundStyle(theme.contentPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  /// A row of the tablet (5:76390): the mark 32 and the description 15 medium, the category, the
  /// account and the time 14 in the secondary colour, the amount 15 semibold, 12 between them.
  private func columnRow(_ item: TransactionRowItem) -> some View {
    HStack(spacing: OperationsMetrics.columnGap) {
      HStack(spacing: OperationsMetrics.badgeGap) {
        OperationBadge(kind: OperationBadgeKind(item), category: item.categoryMark)
        title(of: item, font: OperationsType.rowTitle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Group {
        Text(verbatim: categoryText(of: item))
          .frame(width: OperationColumnsHeader.categoryWidth, alignment: .leading)
        Text(verbatim: item.transfer?.accounts ?? item.paymentMethod ?? "")
          .frame(width: OperationColumnsHeader.accountWidth, alignment: .leading)
        Text(verbatim: environment.dates.time(item.occurredAt))
          .monospacedDigit()
          .frame(width: OperationColumnsHeader.timeWidth, alignment: .leading)
      }
      .appFont(OperationsType.rowCell)
      .foregroundStyle(theme.contentSecondary)
      .lineLimit(1)
      Text(verbatim: amountText(of: item))
        .appFont(OperationsType.rowAmount)
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(1)
        .frame(width: OperationColumnsHeader.amountWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
  }

  private func categoryText(of item: TransactionRowItem) -> String {
    switch item.category {
    case .one(let path): CategoryPathText.text(path, language: environment.language)
    case .several: environment.language("transactions.several", table: "Transactions")
    case .none: ""
    }
  }
}

/// The names of the columns at the top of the tablet's card (5:76376): 11 semibold capitals in
/// the secondary colour, 18 at the sides and 8 above and below, the widths of the frame.
struct OperationColumnsHeader: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme

  static let categoryWidth: CGFloat = 137
  static let accountWidth: CGFloat = 121
  static let timeWidth: CGFloat = 57
  static let amountWidth: CGFloat = 97

  var body: some View {
    HStack(spacing: OperationsMetrics.columnGap) {
      name(.description).frame(maxWidth: .infinity, alignment: .leading)
      name(.category).frame(width: Self.categoryWidth, alignment: .leading)
      name(.account).frame(width: Self.accountWidth, alignment: .leading)
      name(.time).frame(width: Self.timeWidth, alignment: .leading)
      name(.amount).frame(width: Self.amountWidth, alignment: .trailing)
    }
    .appFont(AppFont.system(size: 11, weight: .semibold))
    .foregroundStyle(theme.contentSecondary)
    .lineLimit(1)
    .padding(.horizontal, OperationsMetrics.rowHorizontal)
    .padding(.vertical, 8)
    .accessibilityHidden(true)
  }

  private func name(_ column: OperationColumn) -> Text {
    Text(verbatim: column.headerTitle(language: environment.language))
  }
}

/// The head of a day in «Операции» (Mac 5:35478, tablet 5:76387, phone 5:8011): the day in
/// capitals, 12 semibold — in the accent's content colour on the Mac and the tablet, in the
/// secondary one on a phone — and at the right what the day did to the money in one signed
/// figure, 12 medium in the secondary colour (`RowTotals.net`): «−2 650 ₽», «+118 581 ₽». A day
/// of transfers only says no figure.
struct OperationDayHead: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var idiom
  let day: DateOnly
  let totals: RowTotals
  /// The totals hold operations of a covered hidden account that the day does not list.
  var partHidden = false

  /// The colour of the day's name on each design: the accent's words on the Mac and a tablet,
  /// the secondary ink on a phone.
  static func nameInk(in theme: AppThemeColors, idiom: LayoutIdiom = .mac) -> Color {
    idiom == .phone ? theme.contentSecondary : theme.accentContent
  }

  /// The figure of a day, or `nil` for a day that moved money only between the owner's
  /// accounts.
  @MainActor
  static func figure(_ totals: RowTotals, money: MoneyFormatter) -> String? {
    totals.isEmpty ? nil : money.signedRounded(totals.net)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: title)
        .appFont(OperationsType.dayName)
        .textCase(.uppercase)
        .foregroundStyle(Self.nameInk(in: theme, idiom: LayoutIdiom.resolved(idiom)))
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      if partHidden { PartHiddenNote() }
      if let figure = Self.figure(totals, money: environment.money) {
        Text(verbatim: figure)
          .appFont(OperationsType.dayFigure)
          .foregroundStyle(theme.contentSecondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("operations.day")
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
