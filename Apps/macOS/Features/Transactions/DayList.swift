import AppCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// Operations by day, newest first: the days of Overview. Each day is one list by time — income,
/// spending, refunds, money back and the transfers between the owner's accounts side by side —
/// and the kinds are told apart by the symbol of each row, which VoiceOver speaks too; the
/// header of the day says what it comes to, transfers counted in no total. The Transactions
/// window shows the whole history in a table of its own (`TransactionsTable`).
///
/// Selection is the list's own: click, ⌘-click and ⇧-click are native, ⌘A is the system
/// «Select All», Esc clears it. A double click and the context menu go through
/// `contextMenu(forSelectionType:)`, because a tap gesture on a row fights the selection.
/// Only operations and transfers can be selected: whatever `header` puts on top carries no
/// tag.
///
/// The list owns no sheets and no dialogs. Rows are redrawn on every change of the data,
/// and a sheet hung on a row goes away with it — so everything the menu opens hangs on the
/// root of the screen instead.
struct DayList<Header: View, MenuItems: View>: View {
  @Dependency(\.environment) private var environment

  let groups: [TransactionsStore.DayGroup]
  @Binding var selection: Set<UUID>
  /// The ledger of the data: a row without a description is named by its category, and a
  /// row shows the quality the rules give its parts, as the table of Transactions does.
  var ledger: Ledger?
  /// Shown as a row under `header` when there is nothing to list.
  var emptyText: String?
  /// The list has no data yet: the state of the step that brings it is shown instead of the
  /// days.
  var waiting: ListWaiting?
  @ViewBuilder var header: () -> Header
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  /// ⌫ on the selection. `nil` leaves the key alone.
  var deleteAction: ((Set<UUID>) -> Void)?
  /// A row can be dragged out of the list (to another day of the calendar).
  var dragsRows = false

  var body: some View {
    List(selection: $selection) { rows }
      .listStyle(.inset)
      .contextMenu(forSelectionType: UUID.self, menu: menu, primaryAction: primaryAction)
      // ↓ in the entry line walks the list from its newest row; Esc clears the selection and
      // hands the keyboard back to the line.
      .walkedFromTheEntryLine(
        firstRow: OperationsWalk.firstRow(of: groups.map(\.items)), selection: $selection
      )
      .onExitCommand {
        selection = []
        NotificationCenter.default.post(name: .returnToEntryLine, object: nil)
      }
      // ⌘A is the system «Select All», and a focused list answers it by itself. This is the
      // way back when it does not reach the list: the same thing, done by hand.
      .macSelectAll {
        selection = Set(groups.flatMap(\.selectableIds))
      }
      .onDeleteCommand {
        guard let deleteAction, !selection.isEmpty else { return }
        deleteAction(selection)
      }
  }

  @ViewBuilder
  private var rows: some View {
    // Once for the whole list, not for every transfer row.
    let names = accountNames
    header()
    if let waiting {
      ComputedBlock(waiting: waiting.state, retry: waiting.retry)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    } else if groups.isEmpty, let emptyText {
      emptyRow(emptyText)
    }
    ForEach(groups) { group in
      Section {
        ForEach(group.items) { item in
          switch item {
          case .operation(let entry):
            row(entry)
          case .transfer(let transfer):
            TransferRow(transfer: transfer, accounts: names)
              .tag(transfer.id)
          }
        }
      } header: {
        DayHeader(day: group.day, totals: group.totals)
      }
    }
  }

  private func row(_ entry: TransactionEntry) -> some View {
    TransactionRow(
      entry: entry, names: ledger?.tree ?? CategoryTree(),
      quality: TransactionListing.quality(of: entry, ledger: ledger),
      refund: ledger.flatMap { RefundMark.of(entry, ledger: $0) },
      payingFor: PayingForLabel.text(of: entry, people: peopleNames, language: environment.language)
    )
    .tag(entry.id)
    .modifier(OperationDragModifier(enabled: dragsRows, id: entry.id))
  }

  /// The names of the people, archived ones too: «за Машу», «пополам с Машей».
  private var peopleNames: [UUID: String] {
    Dictionary(
      (ledger?.dataset.people ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
  }

  /// The names of the accounts, archived ones too: a transfer made from one retired since still
  /// says where the money came from.
  private var accountNames: [UUID: String] {
    Dictionary(
      (ledger?.dataset.paymentMethods ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
  }

  private func emptyRow(_ text: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "list.bullet.rectangle")
        .appFont(.title)
        .foregroundStyle(.secondary)
      Text(verbatim: text)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .listRowSeparator(.hidden)
    .selectionDisabled()
  }
}

/// A list that has no data yet: what the step that brings it is doing, and how to run it
/// again when it failed.
struct ListWaiting {
  let state: BlockState<Never>
  let retry: () -> Void
}

/// The title of a day and what it comes to. A section of the Transactions table names its
/// side of the day too: «Сегодня · Доходы».
struct DayHeader: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let day: DateOnly
  var sideKey: String?
  let totals: RowTotals

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: title)
        .appFont(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(Color(theme.palette.accentContent))
        .accessibilityAddTraits(.isHeader)
      Spacer()
      RowTotalsLine(totals: totals)
    }
  }

  private var title: String {
    let day = environment.dates.dayTitle(
      day,
      today: environment.today,
      language: AppLanguageStrings(
        today: environment.language("common.today"),
        yesterday: environment.language("common.yesterday")))
    guard let sideKey else { return day }
    return "\(day) · \(environment.language(sideKey, table: "Transactions"))"
  }
}

/// The groups of `RowTotals` that are not empty, each with its caption, rounded to whole
/// rubles: the header of a day, the selection bar and the delete confirmation say it the
/// same way.
struct RowTotalsLine: View {
  @Dependency(\.environment) private var environment
  let totals: RowTotals

  var body: some View {
    HStack(spacing: 12) {
      ForEach(totals.nonEmptyGroups, id: \.self) { group in
        HStack(spacing: 4) {
          Text(verbatim: RowTotalsText.caption(group, language: environment.language))
            .foregroundStyle(.secondary)
          Text(verbatim: environment.money.rounded(totals[group]))
            .monospacedDigit()
        }
      }
    }
    .appFont(.subheadline)
  }
}

/// The same line as plain text, for places that take a string — the text of a dialog.
@MainActor
enum RowTotalsText {
  static func caption(_ group: RowTotals.Group, language: AppLanguage) -> String {
    language("totals.\(group.rawValue)", table: "Transactions")
  }

  static func line(_ totals: RowTotals, environment: AppEnvironment) -> String {
    totals.nonEmptyGroups
      .map {
        "\(caption($0, language: environment.language)) \(environment.money.rounded(totals[$0]))"
      }
      .joined(separator: " · ")
  }
}

struct TransactionRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  let entry: TransactionEntry
  let names: CategoryTree
  /// The quality of its parts; «several» when they disagree (`TransactionListing.quality`).
  let quality: RowCell<Quality>
  /// «вернули 500 ₽» on a purchase, the purchase on its refund (`RefundMark`).
  var refund: RefundMark? = nil
  /// The card that paid, where the list tells cards apart: on the screen of an account with
  /// more than one.
  var cardName: String? = nil
  /// «за Машу», «пополам с Машей», «поровну на 3» (`PayingForLabel`).
  var payingFor: String? = nil

  var body: some View {
    HStack(spacing: 12) {
      // Nothing in the day heads a kind: the symbol says it, in words for VoiceOver and on
      // hover.
      let kind = Self.kindWords(entry.transaction.kind, language: environment.language)
      Image(systemName: Palette.kindSymbol(entry.transaction.kind))
        .foregroundStyle(entry.transaction.kind == .income ? .green : .secondary)
        .help(Text(verbatim: kind))
        .accessibilityLabel(Text(verbatim: kind))
      VStack(alignment: .leading, spacing: 2) {
        // A row typed without a description is named by its category, in the secondary
        // style, rather than by a dash nobody can tell apart (first live run, 18 September).
        RowTitleText(title: RowTitle.of(entry, tree: names))
        HStack(spacing: 8) {
          Text(verbatim: environment.dates.time(entry.transaction.occurredAt))
          if let cardName {
            Label {
              Text(verbatim: cardName)
            } icon: {
              Image(systemName: "creditcard")
            }
            .lineLimit(1)
          }
          // A formula kept from before is shown with its numbers written the way the app
          // writes them, like every other number.
          if let expression = entry.transaction.amountExpr {
            Text(verbatim: ExpressionEvaluator.canonical(expression) ?? expression)
          }
          if entry.transaction.kind == .reimbursement {
            // Money came in, but it is not income: it closes what I paid for somebody else.
            Text(
              verbatim: environment.language(
                "transactions.moneyBackNotIncome", table: "Transactions"))
          }
          if let payingFor {
            Label {
              Text(verbatim: payingFor)
            } icon: {
              Image(systemName: "person.2")
            }
            .lineLimit(1)
          } else if entry.isSplit {
            Label {
              Text(verbatim: "\(entry.parts.count)")
            } icon: {
              Image(systemName: "square.split.2x1")
            }
          }
          if let refund {
            RefundMarkLabel(mark: refund)
          }
          if let status = TransactionListing.owedMark(of: entry) {
            let words = [
              environment.language("entry.paidForSomeone", table: "Entry"),
              environment.language(Palette.reimbursementKey(status)),
            ]
            .joined(separator: " · ")
            Image(systemName: Palette.reimbursementSymbol(status))
              .help(Text(verbatim: words))
              .accessibilityLabel(Text(verbatim: words))
          }
          switch quality {
          case .none:
            EmptyView()
          case .several:
            Text(verbatim: environment.language("transactions.several", table: "Transactions"))
          case .one(let quality):
            QualityTag(
              quality: quality,
              title: environment.language(Palette.qualityKey(quality)))
          }
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 1) {
        Text(
          verbatim: environment.money.exact(
            entry.transaction.amountE4, currency: entry.transaction.currency)
        )
        .appFont(.body.monospacedDigit())
        if let approximate = ApproximateText.of(
          entry.transaction, environment: environment, compute: compute)
        {
          Text(verbatim: approximate)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("operation.approximate")
        }
      }
    }
    .padding(.vertical, 2)
    .contentShape(.rect)
    // One element for VoiceOver, which also hears where the money is filed: a row with a
    // description does not show its category. The UI test reads the same value.
    .accessibilityElement(children: .combine)
    .accessibilityValue(Text(verbatim: categories))
    .accessibilityIdentifier("operation.\(entry.transaction.kind.rawValue)")
  }

  /// The kind of an operation in words — «Доход», «Расход», «Возврат покупки», «Возврат
  /// денег» — what its symbol says.
  static func kindWords(_ kind: TransactionKind, language: AppLanguage) -> String {
    language("kind.\(kind.rawValue)")
  }

  /// The categories of the parts, each once: «Food out › Cafes; Groceries».
  private var categories: String {
    var seen: [String] = []
    for part in entry.parts {
      guard let path = CategoryPath(part.categoryId, tree: names)?.text, !seen.contains(path)
      else { continue }
      seen.append(path)
    }
    return seen.joined(separator: "; ")
  }
}

/// A transfer between the owner's accounts in a list of days: ⇄, «Перевод: Сбер → Kaspi»,
/// the time and the note, and the amount sent — with what arrived when it was an exchange.
/// Neither income nor spending: no colour, no sign, the symbol and the words say what it is.
struct TransferRow: View {
  @Dependency(\.environment) private var environment
  let transfer: Transfer
  /// The names of the accounts by id.
  let accounts: [UUID: String]

  var body: some View {
    let text = TransferRowText(transfer, names: accounts)
    HStack(spacing: 12) {
      Image(systemName: TransferSymbol.name)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: text.title(language: environment.language))
        HStack(spacing: 8) {
          Text(verbatim: environment.dates.time(transfer.occurredAt))
          if let note = transfer.note, !note.isEmpty {
            Text(verbatim: note)
              .lineLimit(1)
          }
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 1) {
        Text(
          verbatim: environment.money.exact(transfer.fromAmountE4, currency: transfer.fromCurrency)
        )
        .appFont(.body.monospacedDigit())
        if transfer.isExchange {
          let received = environment.money.exact(
            transfer.toAmountE4, currency: transfer.toCurrency)
          Text(verbatim: "→ \(received)")
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("operation.transfer")
  }
}

/// What a row says about whom it was paid for, when its parts are laid out one of the ways of
/// «За кого» (`PayingForRules.reading`): «за Машу», «за Машу · подарок», «пополам с Машей»,
/// «поровну на 3». Nothing for an expense of mine alone or one split by categories. The name is
/// not declined (the rule of every name in the app).
@MainActor
enum PayingForLabel {
  static func text(
    of entry: TransactionEntry, people: [UUID: String], language: AppLanguage
  ) -> String? {
    guard entry.transaction.kind == .expense else { return nil }
    var draft = TransactionDraft(
      kind: .expense, occurredAt: entry.transaction.occurredAt, amount: entry.transaction.amountE4)
    draft.parts = entry.parts.map { part in
      PartDraft(
        id: part.id, categoryId: part.categoryId, amount: part.amountE4, forWhom: part.forWhom,
        forPersonId: part.forPersonId, reimbursable: part.reimbursable,
        debtorPersonId: part.debtorPersonId)
    }
    func name(_ id: UUID) -> String { people[id] ?? "—" }
    switch PayingForRules.reading(of: draft) {
    case .none, .me?: return nil
    case .somebody(let person, let paysBack)?:
      let words = language.format("payingFor.row.for", table: "Transactions", name(person))
      return paysBack
        ? words : words + " · " + language("payingFor.row.gift", table: "Transactions")
    case .half(let person)?:
      return language.format("payingFor.row.half", table: "Transactions", name(person))
    case .evenly(let people)?:
      return language.format("payingFor.row.evenly", table: "Transactions", "\(people.count + 1)")
    }
  }
}

/// The grey line under an amount in another currency (`ApproximateAmount`): «≈ 1,240 ₽», «≈ 1,240 ₽
/// · курс от 05.10», or «= 1,240 ₽» once the rate is the owner's or the account was charged in
/// the default currency. Only shown; nothing is stored.
@MainActor
enum ApproximateText {
  static func of(
    _ transaction: CoreKit.Transaction, environment: AppEnvironment, compute: ComputeStore
  ) -> String? {
    let target = environment.defaultCurrency
    guard
      let approximate = ApproximateAmount.of(
        transaction, day: environment.calendar.day(of: transaction.occurredAt),
        defaultCurrency: target,
        rubPerUnitOfDefault: compute.snapshot?.context.rubPerUnit[target])
    else { return nil }
    switch approximate {
    case .exact(let amount, let currency):
      return "= " + environment.money.exact(amount, currency: currency)
    case .approximate(let amount, let currency, let rateDay):
      let text = "≈ " + environment.money.exact(amount, currency: currency)
      guard let rateDay else { return text }
      return text + " · "
        + environment.language.format(
          "approximate.rateOf", table: "Transactions", environment.dates.dayAndMonth(rateDay))
    }
  }

  /// The same for an amount not written yet — the entry line and the ↓ panel: at the last rate the
  /// bank gave, with its day when it is not today's.
  static func of(
    amount: AmountE4, currency: CurrencyCode, environment: AppEnvironment, compute: ComputeStore
  ) -> String? {
    let target = environment.defaultCurrency
    guard currency != target, amount.raw > 0, let context = compute.snapshot?.context,
      let perUnit = currency == .rub ? 1 : context.rubPerUnit[currency]
    else { return nil }
    let rubles = amount.decimal * perUnit
    let value: Decimal
    if target == .rub {
      value = rubles
    } else {
      guard let targetPerUnit = context.rubPerUnit[target], targetPerUnit > 0 else { return nil }
      value = rubles / targetPerUnit
    }
    guard let converted = try? AmountE4(decimal: DecimalMath.round(value, scale: 2)) else {
      return nil
    }
    let text = "≈ " + environment.money.exact(converted, currency: target)
    guard let day = context.rateDays[currency], day != environment.today else { return text }
    return text + " · "
      + environment.language.format(
        "approximate.rateOf", table: "Transactions", environment.dates.dayAndMonth(day))
  }
}

extension View {
  /// ⌘A when the list does not answer the system «Select All» by itself. Only a Mac has the
  /// responder chain that command travels.
  @ViewBuilder
  func macSelectAll(_ action: @escaping () -> Void) -> some View {
    #if os(macOS)
      onCommand(#selector(NSResponder.selectAll(_:)), perform: action)
    #else
      self
    #endif
  }
}
