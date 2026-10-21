import AppCore
import AppKit
import SwiftUI

/// The table of «Операции»: a section for each day, newest day first, with what the day comes
/// to in its header — income, spending and transfers together in one list by time, told apart
/// by the symbol of each row; a split is one row with a disclosure triangle and its parts
/// under it. The ⇄ rows of the transfers between the owner's accounts add up to nothing.
///
/// Selection is the table's own — click, ⌘-click, ⇧-click, ⌘A — and holds operations and
/// transfers only: parts cannot be selected (`selectionDisabled`), since a part is changed and
/// deleted with its operation. Esc clears the selection, ⌫ deletes it after asking. A double click and
/// the context menu go through `contextMenu(forSelectionType:)`; on a part they act on its
/// operation.
///
/// The columns, their order and their widths are `layout` (`OperationColumnLayout`), which
/// «Настроить столбцы…» edits: a setting of this Mac, never in the database or an archive. The
/// table is built again when the layout changes, so a width chosen there is the one it lays out.
/// The description and the amount cannot be hidden.
struct TransactionsTable<MenuItems: View>: View {
  @Dependency(\.environment) private var environment

  /// Handed to every cell and every day header by hand. A `Table` on macOS shows each of
  /// them in a hosting view of its own, and such a host does not always get the environment
  /// of the column above it: in the window at 900 pt, with the sidebar folded
  /// away for the inspector, the cells of DayList and of this file were drawn with the
  /// stand-in and the red badge named them (23.09; `testADoubleClickThatAlsoSelectsTheRow
  /// InANarrowWindowSettles` under the whole suite).
  let deps: AppDependencies
  let listing: TransactionListing
  @Binding var selection: Set<UUID>
  var layout: OperationColumnLayout = .standard
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  var deleteAction: (Set<UUID>) -> Void

  /// The layout the table now on screen was made for, once it has appeared. Until then it is
  /// made with no rows (`filled`).
  @State private var madeFor: OperationColumnLayout?

  /// Whether the table on screen has its rows. A table is always made empty and filled on the
  /// next update: made with rows, SwiftUI expands its sections while it builds the
  /// `NSOutlineView`, and AppKit, measuring the rows from inside that expansion, measures
  /// them again from inside its own measuring — «reentrant operation in its NSTableView
  /// delegate», which AppKit promises to turn into an assert. Rows that come into a table
  /// already on screen take the ordinary way of an update.
  private var filled: Bool { madeFor == layout }

  var body: some View {
    let rows = filled ? listing : .empty
    return Table(of: TransactionRowItem.self, selection: rowSelection(rows)) {
      TableColumnForEach(layout.visible) { column in
        TableColumn(title(column)) { item in
          // A refund leads to its purchase: the click opens the purchase as a double click
          // would.
          OperationCell(column: column, item: item, openPurchase: { primaryAction([$0]) })
            .appDependencies(deps)
        }
        .width(
          min: CGFloat(column.minimumWidth), ideal: CGFloat(layout.width(of: column)),
          max: CGFloat(column.maximumWidth)
        )
        .alignment(column.isNumeric ? .trailing : .leading)
      }
    } rows: {
      allRows(rows)
    }
    // Inside the identity of the table: a table made again for another layout appears again,
    // empty, and is filled again.
    .onAppear { madeFor = layout }
    // The widths are the ideal ones of the columns, which a table reads when it is made.
    .id(layout)
    .contextMenu(forSelectionType: RowID.self) { rows in
      menu(listing.owners(of: rows))
    } primaryAction: { rows in
      primaryAction(listing.owners(of: rows))
    }
    // ⌘A is the system «Select All», and a focused table answers it by itself. This is the
    // way back when it does not reach the table: every operation listed, no part.
    .onCommand(#selector(NSResponder.selectAll(_:))) { selection = listing.visibleIds }
    .onDeleteCommand {
      guard !selection.isEmpty else { return }
      deleteAction(selection)
    }
  }

  /// The table selects rows; the window keeps operations and transfers. A part never gets
  /// in: it cannot be selected anyway, and the selection bar, the menu and ⌘A count
  /// operations and transfers.
  ///
  /// The empty table, before it is filled, selects nothing and changes nothing: the window's
  /// selection waits for the rows it names.
  private func rowSelection(_ rows: TransactionListing) -> Binding<Set<RowID>> {
    guard filled else { return .constant([]) }
    return Binding(
      get: { Set(selection.map(rows.row(of:))) },
      set: { selection = TransactionListing.operations(in: $0) })
  }

  // MARK: Rows

  @TableRowBuilder<TransactionRowItem>
  private func allRows(_ rows: TransactionListing) -> some TableRowContent<TransactionRowItem> {
    ForEach(rows.days) { section in
      Section {
        OutlineGroup(section.rows, children: \.parts) { item in
          TableRow(item)
            .selectionDisabled(item.isPart)
        }
      } header: {
        DayHeader(day: section.day, totals: section.totals)
          .appDependencies(deps)
      }
    }
  }

  private func title(_ column: OperationColumn) -> Text {
    Text(verbatim: environment.language(column.titleKey, table: "Transactions"))
  }
}

/// The cell of one column of a row.
private struct OperationCell: View {
  @Dependency(\.environment) private var environment
  let column: OperationColumn
  let item: TransactionRowItem
  var openPurchase: ((UUID) -> Void)? = nil

  var body: some View {
    switch column {
    case .time:
      if !item.isPart {
        Text(verbatim: environment.dates.time(item.occurredAt))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    case .description:
      DescriptionCell(item: item, openPurchase: openPurchase)
    case .amount:
      AmountCell(item: item)
    case .category:
      CategoryCell(item: item)
    case .account:
      Text(verbatim: item.paymentMethod ?? "").lineLimit(1)
    case .place:
      Text(verbatim: item.place ?? "").lineLimit(1)
    case .forWhom:
      ForWhomCell(cell: item.forWhom, kind: item.kind)
    case .quality:
      QualityCell(cell: item.quality)
    case .cashback:
      if let cashback = item.cashback {
        Text(verbatim: environment.money.exact(cashback.amount, currency: cashback.currency))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    case .note:
      // The comment on one line; the whole of it is in the editor and in the tooltip.
      if let note = item.note, !note.isEmpty {
        Text(verbatim: note.replacingOccurrences(of: "\n", with: " "))
          .lineLimit(1)
          .truncationMode(.tail)
          .help(Text(verbatim: note))
      }
    case .event:
      NameCell(cell: item.event)
    }
  }
}

/// The widths the table cannot go below (`TransactionsTable`): the ones a fixed text needs.
enum TransactionColumnWidths {
  /// The time column: «00:00» in the monospaced digits of the body font, after the room the
  /// first column keeps in every row for the disclosure triangle of a split and the insets of
  /// the cell — `timeInset`, measured on macOS 26 with a few points to spare. At 48 pt the
  /// time read «1…» (the live run of 19 September).
  static let time: CGFloat = 64
  static let timeInset: CGFloat = 26
  /// The amount column: «1,234,567.89 ₽» in the monospaced digits of the body font and the
  /// insets of the cell.
  static let amount: CGFloat = 104
  static let amountInset: CGFloat = 4
}

// MARK: - Cells

/// The description, or what names the row without one; the marks of the operation beside
/// it — the parts of a split, money owed, money back that is not income — and the amount
/// as it was typed under it.
private struct DescriptionCell: View {
  @Dependency(\.environment) private var environment
  let item: TransactionRowItem
  /// Opens the purchase a refund takes money back from.
  var openPurchase: ((UUID) -> Void)? = nil

  /// What kind of row this is, so a UI test can double-click a plain operation, a split and
  /// a part of one without reading their descriptions.
  private var identifier: String {
    if item.isTransfer { return "transactions.row.transfer" }
    if item.isPart { return "transactions.row.part" }
    return item.partCount > 1 ? "transactions.row.split" : "transactions.row.single"
  }

  var body: some View {
    if let transfer = item.transfer {
      transferBody(transfer)
    } else {
      operationBody
    }
  }

  /// «⇄ Перевод: Сбер → Kaspi», the note under it: money moved between the owner's own
  /// accounts, the symbol and the words saying so, never a colour.
  private func transferBody(_ transfer: TransferRowText) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Label {
        Text(verbatim: transfer.title(language: environment.language))
          .lineLimit(1)
      } icon: {
        Image(systemName: TransferSymbol.name)
          .foregroundStyle(.secondary)
      }
      if let note = transfer.note, !note.isEmpty {
        Text(verbatim: note)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
  }

  private var operationBody: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        title
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
        if let mark = item.owedMark {
          let words = [
            environment.language("entry.paidForSomeone", table: "Entry"),
            environment.language(Palette.reimbursementKey(mark)),
          ]
          .joined(separator: " · ")
          Image(systemName: Palette.reimbursementSymbol(mark))
            .foregroundStyle(.secondary)
            .help(Text(verbatim: words))
            .accessibilityLabel(Text(verbatim: words))
        }
        if item.kind == .reimbursement, !item.isPart {
          // Listed among the income because money came in, but it is not income: it
          // closes what I paid for somebody else.
          Text(
            verbatim: environment.language(
              "transactions.moneyBackNotIncome", table: "Transactions")
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      if let expression = item.expression {
        Text(verbatim: expression)
          .appFont(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      // «вернули 500 ₽» on a purchase, «к покупке «Кроссовки», 12 сентября» on its refund.
      if let refund = item.refund {
        RefundMarkLabel(mark: refund, open: openPurchase)
      }
    }
    .accessibilityIdentifier(identifier)
  }

  /// A part says «part 2» when it has no note of its own: its category is in the next
  /// column already.
  @ViewBuilder
  private var title: some View {
    if let number = item.partNumber, !item.title.isNote {
      Text(
        verbatim: environment.language.format(
          "transactions.part", table: "Transactions", counts: number)
      )
      .foregroundStyle(.secondary)
    } else {
      RowTitleText(title: item.title)
    }
  }
}

private struct CategoryCell: View {
  @Dependency(\.environment) private var environment
  let item: TransactionRowItem

  var body: some View {
    switch item.category {
    case .one(let path):
      Text(verbatim: CategoryPathText.text(path, language: environment.language))
    case .several:
      SeveralText()
    case .none:
      // Money given back and a transfer have no category; anything else without one says so.
      if item.kind != .reimbursement, !item.isTransfer {
        Text(verbatim: environment.language("category.uncategorized"))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// «For whom»: the value or the person; a part paid for somebody else carries the symbol of
/// its status and its words — «за Аню · ждёт» — never the colour alone.
private struct ForWhomCell: View {
  @Dependency(\.environment) private var environment
  let cell: RowCell<ForWhomValue>
  /// Money back keeps its payer in the same column, so the kind decides whether the name is
  /// who the money was spent on or who gave it back.
  let kind: TransactionKind

  var body: some View {
    switch cell {
    case .none:
      EmptyView()
    case .several:
      SeveralText()
    case .one(.value(let value)):
      Text(verbatim: environment.label(for: value))
        .foregroundStyle(value == .me ? .secondary : .primary)
    case .one(.person(let name)):
      Text(verbatim: ForWhomValue.personText(name, kind: kind, language: environment.language))
    case .one(.owed(let name, let status)):
      let words = ForWhomText.owed(by: name, status, language: environment.language)
      Label {
        Text(verbatim: words)
      } icon: {
        Image(systemName: Palette.reimbursementSymbol(status))
      }
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text(verbatim: words))
    }
  }
}

/// The words of a part paid for somebody else: «за Аню · ждёт».
@MainActor
enum ForWhomText {
  static func owed(
    by name: String?, _ status: ReimbursementStatus, language: AppLanguage
  )
    -> String
  {
    let who =
      name.map { language.format("transactions.paidFor", table: "Transactions", $0) }
      ?? language("entry.paidForSomeone", table: "Entry")
    return "\(who) · \(language(Palette.reimbursementKey(status)))"
  }
}

private struct NameCell: View {
  let cell: RowCell<String>

  var body: some View {
    switch cell {
    case .none: EmptyView()
    case .several: SeveralText()
    case .one(let name): Text(verbatim: name)
    }
  }
}

private struct QualityCell: View {
  @Dependency(\.environment) private var environment
  let cell: RowCell<Quality>

  var body: some View {
    switch cell {
    case .none:
      EmptyView()
    case .several:
      SeveralText()
    case .one(let quality):
      QualityTag(
        quality: quality, title: environment.language(Palette.qualityKey(quality)), font: .body)
    }
  }
}

/// The exact amount in the currency of the operation; a foreign one says what it came to in
/// rubles under it.
private struct AmountCell: View {
  @Dependency(\.environment) private var environment
  let item: TransactionRowItem

  var body: some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(verbatim: environment.money.exact(item.amount, currency: item.currency))
        .monospacedDigit()
        .foregroundStyle(item.isPart ? .secondary : .primary)
      if let transfer = item.transfer {
        // An exchange says what arrived; a transfer in one currency arrives as it was sent.
        if transfer.isExchange {
          let received = environment.money.exact(transfer.received, currency: transfer.toCurrency)
          Text(verbatim: "→ \(received)")
            .appFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      } else if item.currency != .rub {
        Text(verbatim: "≈ \(environment.money.rounded(item.amountRub))")
          .appFont(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// «Several»: the parts of a split disagree on this cell.
private struct SeveralText: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    Text(verbatim: environment.language("transactions.several", table: "Transactions"))
      .foregroundStyle(.secondary)
  }
}
