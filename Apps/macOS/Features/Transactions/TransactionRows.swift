import AppCore
import Foundation

/// What a row of the Transactions table stands for: an operation, one part of a split under
/// it, or a transfer between the owner's accounts. Operations and transfers are selected and
/// deleted; a part is shown so the split can be read, and is changed through its operation.
enum RowID: Hashable, Sendable {
  case transaction(UUID)
  case part(UUID)
  case transfer(UUID)
}

/// «Category › Subcategory» as the dictionary names them, root first. `archived` is set when
/// either of the two has been retired: the cell says «(archived)» after the path.
struct CategoryPath: Hashable, Sendable {
  var names: [String]
  var archived: Bool

  init(names: [String], archived: Bool = false) {
    self.names = names
    self.archived = archived
  }

  /// `nil` for a part without a category, and for an id the dictionary no longer has.
  init?(_ id: UUID?, tree: CategoryTree) {
    guard let category = tree.category(id) else { return nil }
    if let parent = tree.parent(of: category.id) {
      self.init(
        names: [parent.name, category.name], archived: parent.archived || category.archived)
    } else {
      self.init(names: [category.name], archived: category.archived)
    }
  }

  var text: String { names.joined(separator: " › ") }
}

/// What names an operation in a list. Its description when it has one; otherwise its
/// category, so a row typed as «250» with a category picked in the panel still says what
/// it is (first live run, 18 September: such rows read «—»); otherwise its kind. Only the
/// description is the owner's own words — the other two are shown in the secondary style.
enum RowTitle: Hashable, Sendable {
  case note(String)
  case category(CategoryPath)
  case kind(TransactionKind)

  static func resolve(note: String?, category: CategoryPath?, kind: TransactionKind) -> RowTitle {
    if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
      return .note(oneLine(note))
    }
    if let category { return .category(category) }
    return .kind(kind)
  }

  /// A description of several lines reads as one in a row: the lines joined by spaces.
  static func oneLine(_ note: String) -> String {
    note.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// A split names itself by the category of its first part that has one: that is the part
  /// the entry line and the panel fill first.
  static func of(_ entry: TransactionEntry, tree: CategoryTree) -> RowTitle {
    let category = entry.parts.lazy.compactMap { CategoryPath($0.categoryId, tree: tree) }.first
    return resolve(note: entry.transaction.note, category: category, kind: entry.transaction.kind)
  }

  /// Whether the title is the owner's own description.
  var isNote: Bool {
    if case .note = self { return true }
    return false
  }

  /// The words of the title, as `RowTitleText` shows them.
  @MainActor
  func text(language: AppLanguage) -> String {
    switch self {
    case .note(let note): note
    case .category(let path): CategoryPathText.text(path, language: language)
    case .kind(let kind): language("kind.\(kind.rawValue)")
    }
  }
}

/// A refund taken back from a purchase, as the rows of both say it. The refund counts in the
/// purchase — its day, its month, its category — so the purchase says what came back, and the
/// refund says which purchase it belongs to: two rows that read as one story.
enum RefundMark: Hashable, Sendable {
  /// On a purchase, or a part of one: what its refunds took back, in its own currency.
  case refunded(AmountE4, CurrencyCode)
  /// On a refund: the purchase it takes back from — what names it, the day it was made — so
  /// the row leads to it. `withYear` when the purchase is of another year than the refund: a
  /// purchase refunded through «Показать раньше» may be more than a year old, and «1 сентября»
  /// alone would not say which.
  case refundOf(purchaseId: UUID, title: RowTitle, day: DateOnly, withYear: Bool = false)

  /// The mark of an operation of the ledger: what its refunds took back, when it is a purchase
  /// with any; the purchase, when it is a refund taken back from one; nothing otherwise — a
  /// refund whose purchase is gone counts on its own, as refunds always did.
  static func of(_ entry: TransactionEntry, ledger: Ledger) -> RefundMark? {
    let index = ledger.refundIndex
    guard !index.isEmpty else { return nil }
    switch entry.transaction.kind {
    case .expense:
      return refunded(AmountE4.sum(entry.parts.map { index.refunded(part: $0.id) }), entry)
    case .refund:
      for part in entry.parts {
        guard let purchasePart = index.purchasePart(ofRefundPart: part.id),
          let mark = refundOf(purchasePart, by: entry, ledger: ledger)
        else { continue }
        return mark
      }
      return nil
    case .income, .reimbursement:
      return nil
    }
  }

  /// The mark of one part of a split: what the refunds took back from that part.
  static func of(
    part: TransactionPart, in entry: TransactionEntry, ledger: Ledger
  ) -> RefundMark? {
    switch entry.transaction.kind {
    case .expense:
      return refunded(ledger.refundIndex.refunded(part: part.id), entry)
    case .refund:
      return ledger.refundIndex.purchasePart(ofRefundPart: part.id).flatMap {
        refundOf($0, by: entry, ledger: ledger)
      }
    case .income, .reimbursement:
      return nil
    }
  }

  private static func refunded(_ amount: AmountE4, _ entry: TransactionEntry) -> RefundMark? {
    amount.raw > 0 ? .refunded(amount, entry.transaction.currency) : nil
  }

  /// The purchase a refund takes back from, named as its row names it — by the part's own note
  /// when the part has one, a part of a split being what was taken back.
  private static func refundOf(
    _ purchasePart: UUID, by refund: TransactionEntry, ledger: Ledger
  ) -> RefundMark? {
    guard let row = ledger.row(ofPart: purchasePart),
      let purchase = ledger.entry(row.transactionId),
      let part = purchase.parts.first(where: { $0.id == purchasePart })
    else { return nil }
    let title =
      purchase.isSplit
      ? RowTitle.resolve(
        note: part.note ?? purchase.transaction.note,
        category: CategoryPath(part.categoryId, tree: ledger.tree), kind: .expense)
      : RowTitle.of(purchase, tree: ledger.tree)
    let day = ledger.calendar.day(of: purchase.transaction.occurredAt)
    return .refundOf(
      purchaseId: purchase.id, title: title, day: day,
      withYear: day.year != ledger.calendar.day(of: refund.transaction.occurredAt).year)
  }
}

/// The words and the symbol of a refund on the rows: «вернули 500 ₽» on the purchase, «к
/// покупке «Кроссовки», 12 сентября» on the refund — «12 сентября 2025 г.» for a purchase of
/// another year. The symbol of a refund of a purchase with the words, never a colour alone.
@MainActor
enum RefundMarkText {
  static let symbol = "arrow.uturn.left.circle"

  static func text(_ mark: RefundMark, environment: AppEnvironment) -> String {
    let language = environment.language
    switch mark {
    case .refunded(let amount, let currency):
      return language.format(
        "transactions.refunded", table: table, environment.money.exact(amount, currency: currency))
    case .refundOf(_, let title, let day, let withYear):
      return language.format(
        "transactions.refundOf", table: table, title.text(language: language),
        withYear ? environment.dates.longDay(day) : environment.dates.dayAndMonth(day))
    }
  }

  private static let table = "Transactions"
}

/// A cell of an operation that may differ between its parts: nothing, one value, or
/// «several» when the parts of a split disagree.
enum RowCell<Value: Hashable & Sendable>: Hashable, Sendable {
  case none
  case one(Value)
  case several

  /// One value when every part has the same, «several» otherwise; `none` when there are no
  /// values at all or all of them are missing.
  static func of(_ values: [Value?]) -> RowCell {
    guard let first = values.first else { return .none }
    guard values.allSatisfy({ $0 == first }) else { return .several }
    return first.map(RowCell.one) ?? .none
  }
}

/// «For whom» of a part: a value, a person it was for, or — for a part of a purchase paid
/// for somebody else — who owes it and what became of the money.
enum ForWhomValue: Hashable, Sendable {
  case value(ForWhom)
  case person(String)
  case owed(by: String?, ReimbursementStatus)

  /// The words of a `person` cell in a row of `kind`. Money back names the person it came
  /// from — «от: Аня» — so it is not read as money spent on them; any other row names the
  /// person as they are. The colon keeps the name as it is stored: «от» would want it
  /// declined, and no rule declines every name right.
  @MainActor
  static func personText(_ name: String, kind: TransactionKind, language: AppLanguage) -> String {
    guard kind == .reimbursement else { return name }
    return language.format("transactions.moneyBackFrom", table: "Transactions", name)
  }
}

/// One row of the table: an operation, or a part of a split under it. Everything a cell
/// shows is resolved here, off the main thread, from the data of the pipeline; the words
/// that depend on the language — kinds, «several», «(archived)», the status of money owed —
/// are put in by the cells.
struct TransactionRowItem: Identifiable, Hashable, Sendable {
  let id: RowID
  /// The operation of the row: itself, or the one the part belongs to.
  let transactionId: UUID
  let kind: TransactionKind
  let occurredAt: Date
  /// The description of an operation, the note of a part.
  let note: String?
  /// What names the row when it has no description of its own.
  let title: RowTitle
  let expression: String?
  /// The position of a part inside its operation, from 1; `nil` for an operation.
  let partNumber: Int?
  let place: String?
  let category: RowCell<CategoryPath>
  let forWhom: RowCell<ForWhomValue>
  let event: RowCell<String>
  let paymentMethod: String?
  let quality: RowCell<Quality>
  let amount: AmountE4
  let currency: CurrencyCode
  let amountRub: AmountE4
  /// How many parts the operation has; 1 for a part and for an operation that is not split.
  let partCount: Int
  /// The mark of an operation with parts paid for somebody else: waiting while any of them
  /// waits, then returned, then written off. Purchases only.
  let owedMark: ReimbursementStatus?
  /// The parts of a split, shown under it; `nil` for everything else, so no disclosure
  /// triangle is drawn.
  var parts: [TransactionRowItem]?
  /// What a refund taken back from a purchase says here: on the purchase, what came back; on
  /// the refund, the purchase. `nil` for everything else.
  var refund: RefundMark? = nil
  /// A transfer between the owner's accounts: where the money went from and to. `nil` for an
  /// operation and its parts.
  var transfer: TransferRowText? = nil
  /// The cashback the owner wrote for the operation, in the currency it came in; `nil` for a
  /// part, a transfer and an operation without one.
  var cashback: Money? = nil

  var isPart: Bool {
    if case .part = id { return true }
    return false
  }

  var isTransfer: Bool { transfer != nil }
}

/// What a row of a transfer says: the two accounts, and what arrived when it is another
/// currency than what was sent — an exchange. The words around it are put in by the cells.
struct TransferRowText: Hashable, Sendable {
  let from: String
  let to: String
  /// The currencies, for an exchange inside one account: «Freedom: RUB → KZT».
  let fromCurrency: CurrencyCode
  let toCurrency: CurrencyCode
  let received: AmountE4
  let note: String?
  /// An exchange between two currencies of one account.
  let withinOneAccount: Bool

  var isExchange: Bool { fromCurrency != toCurrency }

  /// The accounts, for the account column: «Сбер → Kaspi», or just «Freedom» for an exchange
  /// inside it.
  var accounts: String { withinOneAccount ? from : "\(from) → \(to)" }

  init(_ transfer: Transfer, names: [UUID: String]) {
    from = names[transfer.fromAccountId] ?? ""
    to = names[transfer.toAccountId] ?? ""
    fromCurrency = transfer.fromCurrency
    toCurrency = transfer.toCurrency
    received = transfer.toAmountE4
    note = transfer.note
    withinOneAccount = transfer.fromAccountId == transfer.toAccountId
  }

  /// «Перевод: Сбер → Kaspi», or «Обмен в Freedom: RUB → KZT» inside one account.
  @MainActor
  func title(language: AppLanguage) -> String {
    withinOneAccount
      ? language.format(
        "transactions.transfer.exchange", table: "Transactions", from, fromCurrency.code,
        toCurrency.code)
      : language.format("transactions.transfer.title", table: "Transactions", from, to)
  }
}

/// What deleting a selection takes besides its operations: the transfers among it, and the
/// rubles of their fees, which go with them.
struct TransferDeletion: Hashable, Sendable {
  var count = 0
  var fees: AmountE4 = .zero
  /// Why each transfer of the selection the rules keep stays: one of its accounts is in the
  /// archive, or something came back for its fee (`TransferActions.deletionRefusals`).
  var kept: [TransferRefusal] = []

  static let none = TransferDeletion()
}

/// The words the question before a deletion says about transfers: a transfer is not an
/// operation, so it is counted apart, and the fee that goes with it is named.
@MainActor
enum TransferDeletionText {
  /// «Удалить 2 перевода?» when nothing but transfers goes; `nil` when operations go too — the
  /// operations' question is asked then, and `lines` add the transfers.
  static func title(
    operations: Int, _ transfers: TransferDeletion, language: AppLanguage
  ) -> String? {
    guard operations == 0, transfers.count > 0 else { return nil }
    return language.format(
      "transactions.transfers.confirmDelete", table: table, counts: transfers.count)
  }

  /// «И 1 перевод.» after the operations, and «Их комиссии, 15.00 ₽, удаляются вместе с ними.»
  /// A transfer the rules keep is said to stay, with the words its own sheet refuses it in:
  /// «1 перевод останется как есть. Один из счетов в архиве.»
  static func lines(
    operations: Int, _ transfers: TransferDeletion, environment: AppEnvironment
  ) -> [String] {
    var lines: [String] = []
    if transfers.count > 0, operations > 0 {
      lines.append(
        environment.language.format(
          "transactions.transfers.alsoDeleted", table: table, counts: transfers.count))
    }
    if transfers.count > 0, !transfers.fees.isZero {
      lines.append(
        environment.language.format(
          "transactions.transfers.feesDeleted", table: table,
          environment.money.exact(transfers.fees, currency: .rub)))
    }
    if !transfers.kept.isEmpty {
      // Each reason once, in the order the transfers come.
      var reasons: [String] = []
      for refusal in transfers.kept {
        let words = TransferText.message(refusal, environment)
        if !reasons.contains(words) { reasons.append(words) }
      }
      let stays = environment.language.format(
        "transactions.transfers.kept", table: table, counts: transfers.kept.count)
      lines.append(([stays] + reasons).joined(separator: " "))
    }
    return lines
  }

  private static let table = "Transactions"
}

/// One side of one day: its income — with the money people gave back — or its spending.
struct TransactionSection: Identifiable, Sendable {
  enum Side: String, Sendable {
    case income
    case expenses
    /// Money moved between the owner's own accounts: in no total.
    case transfers

    /// Money given back is listed among the income because money came in; it is never
    /// added to the income (`RowTotals` keeps it apart).
    static func of(_ kind: TransactionKind) -> Side {
      TransactionsStore.DayGroup.isListedWithIncome(kind) ? .income : .expenses
    }

    /// The words of the header of the side: «Сегодня · Переводы».
    var titleKey: String {
      switch self {
      case .income: "transactions.income"
      case .expenses: "transactions.expenses"
      case .transfers: "transactions.transfers"
      }
    }
  }

  let day: DateOnly
  let side: Side
  let rows: [TransactionRowItem]
  /// What this side of the day comes to, from `RowTotals`: the same function as the day of
  /// Overview, the selection bar and the delete confirmation.
  let totals: RowTotals

  var id: String { "\(day.iso).\(side.rawValue)" }
}

/// One day of the table: everything of the day in one list, newest first — income, spending,
/// refunds, money back and transfers side by side, the kinds told apart by their symbols — and
/// what the day comes to. The table divides the history by days and nothing else.
struct TransactionDaySection: Identifiable, Sendable {
  let day: DateOnly
  let rows: [TransactionRowItem]
  let totals: RowTotals

  var id: String { day.iso }
}

/// What the table shows for one filtering: sections newest day first, income before
/// spending within a day, operations newest first within a side.
struct TransactionListing: Sendable {
  let sections: [TransactionSection]
  /// The operations and transfers listed: the selection never reaches beyond them.
  let visibleIds: Set<UUID>
  /// The operation each listed part belongs to.
  let partOwners: [UUID: UUID]
  /// The transfers among `visibleIds`: their rows are addressed as transfers, not operations.
  let transferIds: Set<UUID>
  /// The sections put by day (`byDay`), made once: the table reads them on every change.
  let days: [TransactionDaySection]

  init(
    sections: [TransactionSection], visibleIds: Set<UUID>, partOwners: [UUID: UUID],
    transferIds: Set<UUID> = []
  ) {
    self.sections = sections
    self.visibleIds = visibleIds
    self.partOwners = partOwners
    self.transferIds = transferIds
    self.days = Self.byDay(sections)
  }

  static let empty = TransactionListing(sections: [], visibleIds: [], partOwners: [:])

  var isEmpty: Bool { sections.isEmpty }

  /// The sections of the listing put by day: the sides of a day merged into one list by time,
  /// newest first (a stable order for rows of the same moment), totals added up.
  private static func byDay(_ sections: [TransactionSection]) -> [TransactionDaySection] {
    var days: [TransactionDaySection] = []
    var index: [String: Int] = [:]
    for section in sections {
      if let at = index[section.day.iso] {
        let kept = days[at]
        days[at] = TransactionDaySection(
          day: kept.day, rows: kept.rows + section.rows, totals: kept.totals + section.totals)
      } else {
        index[section.day.iso] = days.count
        days.append(
          TransactionDaySection(day: section.day, rows: section.rows, totals: section.totals))
      }
    }
    return days.map { day in
      let ordered = day.rows.enumerated().sorted {
        $0.element.occurredAt != $1.element.occurredAt
          ? $0.element.occurredAt > $1.element.occurredAt : $0.offset < $1.offset
      }.map(\.element)
      return TransactionDaySection(day: day.day, rows: ordered, totals: day.totals)
    }
  }
  /// The operations listed — «N earlier operations» counts these; a transfer is not one.
  var operationCount: Int { visibleIds.count - transferIds.count }

  // MARK: Months at a time

  /// How many months the table shows at first, and how many more each «Show more» adds.
  /// SwiftUI's `Table` pays for every section on every change — a click that selects one
  /// row re-reads them all — and «All time» of two dense years is a thousand sections: a
  /// second per click in the measurement of step 7. Three months are under two hundred.
  static let monthsPerPage = 3

  /// The months the listing covers, newest first.
  var months: [MonthKey] {
    var months: [MonthKey] = []
    for section in sections where months.last != section.day.monthKey {
      months.append(section.day.monthKey)
    }
    return months
  }

  /// The newest `count` months of the listing, as the table shows them: the sections of
  /// those months, and only their operations and parts as the ones a selection may hold.
  func latestMonths(_ count: Int) -> TransactionListing {
    let months = self.months
    guard count < months.count else { return self }
    let kept = Set(months.prefix(max(count, 0)))
    let shown = sections.filter { kept.contains($0.day.monthKey) }
    var visible: Set<UUID> = []
    var owners: [UUID: UUID] = [:]
    for row in shown.lazy.flatMap(\.rows) {
      visible.insert(row.transactionId)
      for part in row.parts ?? [] {
        if case .part(let id) = part.id { owners[id] = row.transactionId }
      }
    }
    return TransactionListing(
      sections: shown, visibleIds: visible, partOwners: owners,
      transferIds: transferIds.intersection(visible))
  }

  /// The operations and transfers among rows of the table. Parts are left out: they cannot be
  /// selected, and the selection holds operations and transfers only.
  static func operations(in rows: Set<RowID>) -> Set<UUID> {
    Set(
      rows.compactMap { row in
        switch row {
        case .transaction(let id), .transfer(let id): id
        case .part: nil
        }
      })
  }

  /// The row a selected id is: a transfer when the listing has it as one, an operation
  /// otherwise.
  func row(of id: UUID) -> RowID {
    transferIds.contains(id) ? .transfer(id) : .transaction(id)
  }

  /// The operations rows stand for, a part standing for its operation: what a double click
  /// or the menu of a part of a split acts on. A transfer stands for itself.
  func owners(of rows: Set<RowID>) -> Set<UUID> {
    Set(
      rows.compactMap { row in
        switch row {
        case .transaction(let id), .transfer(let id): id
        case .part(let id): partOwners[id]
        }
      })
  }

  /// What the filters find, operations and transfers: the whole listing of the window.
  static func build(matching filter: EntryFilter, in ledger: Ledger) -> TransactionListing {
    build(
      filter.apply(to: ledger), ledger: ledger, transfers: transfers(matching: filter, in: ledger))
  }

  /// Builds the rows of the operations the filter found, newest first, from the ledger
  /// they were found in, and of the transfers given — each day's after its income and its
  /// spending, in a section of their own that adds up to nothing. Pure, and meant for
  /// `ComputeStore.compute`.
  static func build(
    _ ids: [UUID], ledger: Ledger, transfers: [Transfer] = []
  ) -> TransactionListing {
    let names = Names(ledger.dataset)
    let debts = ledger.debtsById
    var sections: [TransactionSection] = []
    var partOwners: [UUID: UUID] = [:]
    var visible: Set<UUID> = []
    visible.reserveCapacity(ids.count + transfers.count)
    var transferIds: Set<UUID> = []
    let calendar = ledger.calendar
    var transfersByDay = Dictionary(grouping: transfers) { calendar.day(of: $0.occurredAt) }

    /// The transfers of `day` as a section of its own, taken out of those still to list.
    func transferSection(_ day: DateOnly) {
      guard let moved = transfersByDay.removeValue(forKey: day), !moved.isEmpty else { return }
      var rows: [TransactionRowItem] = []
      for transfer in moved.sorted(by: TransactionsStore.newestFirst)
      where visible.insert(transfer.id).inserted {
        transferIds.insert(transfer.id)
        rows.append(row(for: transfer, names: names))
      }
      guard !rows.isEmpty else { return }
      sections.append(TransactionSection(day: day, side: .transfers, rows: rows, totals: .zero))
    }

    /// Days of transfers alone newer than `day`, listed before it.
    func transferDays(after day: DateOnly?) {
      for other in transfersByDay.keys.sorted(by: >) where day.map({ other > $0 }) ?? true {
        transferSection(other)
      }
    }

    var day: DateOnly?
    var income: [TransactionEntry] = []
    var expenses: [TransactionEntry] = []
    func closeDay() {
      guard let day else { return }
      for (side, entries) in [(TransactionSection.Side.income, income), (.expenses, expenses)]
      where !entries.isEmpty {
        sections.append(
          TransactionSection(
            day: day, side: side,
            rows: entries.map { row(for: $0, ledger: ledger, names: names) },
            // A refund taken back from a purchase counts in the purchase, on its day: the
            // same numbers as a day of Overview and the selection.
            totals: RowTotals(entries: entries, debts: debts, refunds: ledger.refundIndex)))
      }
      transferSection(day)
      income.removeAll(keepingCapacity: true)
      expenses.removeAll(keepingCapacity: true)
    }

    for id in ids {
      guard let entry = ledger.entry(id), visible.insert(id).inserted else { continue }
      let entryDay = calendar.day(of: entry.transaction.occurredAt)
      if entryDay != day {
        closeDay()
        transferDays(after: entryDay)
        day = entryDay
      }
      if TransactionSection.Side.of(entry.transaction.kind) == .income {
        income.append(entry)
      } else {
        expenses.append(entry)
      }
      if entry.isSplit {
        for part in entry.parts { partOwners[part.id] = id }
      }
    }
    closeDay()
    transferDays(after: nil)
    return TransactionListing(
      sections: sections, visibleIds: visible, partOwners: partOwners, transferIds: transferIds)
  }

  /// The transfers the filters of the window find, newest first. A transfer is neither income
  /// nor spending and has no category, quality, person, place or event: any of those chosen
  /// leaves transfers out, and so does a card: a transfer moves an account's money, no card
  /// pays it. The period takes the day it was made; the account finds a transfer from it or to
  /// it; the search looks in its note, the names of its accounts and the amounts sent and
  /// received, written as an operation's amount is for its search.
  static func transfers(matching filter: EntryFilter, in ledger: Ledger) -> [Transfer] {
    guard filter.kind == nil, filter.cardId == nil, filter.categoryId == nil,
      filter.subcategoryId == nil, filter.quality == nil, filter.forWhom == nil,
      filter.personId == nil, filter.placeId == nil, filter.eventId == nil,
      filter.reimbursementStatus == nil
    else { return [] }
    let words = NameKey.fold(filter.text).split(whereSeparator: \.isWhitespace).map(String.init)
    let names = Names(ledger.dataset).paymentMethods
    return ledger.dataset.transfers.filter { transfer in
      if let period = filter.period,
        !period.range.contains(ledger.calendar.day(of: transfer.occurredAt))
      {
        return false
      }
      if let account = filter.paymentMethodId, transfer.fromAccountId != account,
        transfer.toAccountId != account
      {
        return false
      }
      guard !words.isEmpty else { return true }
      let fields = [
        transfer.note ?? "", names[transfer.fromAccountId] ?? "",
        names[transfer.toAccountId] ?? "", CSVValue.string(amount: transfer.fromAmountE4),
        CSVValue.string(amount: transfer.toAmountE4),
      ]
      let key = NameKey.fold(fields.joined(separator: "\n"))
      return words.allSatisfy { key.contains($0) }
    }
    .sorted(by: TransactionsStore.newestFirst)
  }

  /// The row of a transfer: the amount sent in its currency, the two accounts in the account
  /// column — one, for an exchange inside an account —, no category, quality or person: it is
  /// neither income nor spending.
  private static func row(for transfer: Transfer, names: Names) -> TransactionRowItem {
    let text = TransferRowText(transfer, names: names.paymentMethods)
    return TransactionRowItem(
      id: .transfer(transfer.id), transactionId: transfer.id, kind: .expense,
      occurredAt: transfer.occurredAt, note: transfer.note, title: .kind(.expense),
      expression: nil, partNumber: nil, place: nil, category: .none, forWhom: .none,
      event: .none, paymentMethod: text.accounts, quality: .none,
      amount: transfer.fromAmountE4, currency: transfer.fromCurrency, amountRub: .zero,
      partCount: 1, owedMark: nil, parts: nil, transfer: text)
  }

  // MARK: - Rows

  private static func row(
    for entry: TransactionEntry, ledger: Ledger, names: Names
  ) -> TransactionRowItem {
    let transaction = entry.transaction
    let cells = entry.parts.map { PartCells($0, in: transaction, ledger: ledger, names: names) }
    let parts: [TransactionRowItem]? =
      entry.isSplit
      ? zip(entry.parts, cells).enumerated().map { index, pair in
        let (part, cell) = pair
        return TransactionRowItem(
          id: .part(part.id), transactionId: transaction.id, kind: transaction.kind,
          occurredAt: transaction.occurredAt, note: part.note,
          title: RowTitle.resolve(note: part.note, category: cell.category, kind: transaction.kind),
          expression: nil, partNumber: index + 1, place: nil,
          category: cell.category.map(RowCell.one) ?? .none,
          forWhom: cell.forWhom.map(RowCell.one) ?? .none,
          event: cell.event.map(RowCell.one) ?? .none, paymentMethod: nil,
          quality: cell.quality.map(RowCell.one) ?? .none, amount: part.amountE4,
          currency: transaction.currency, amountRub: part.amountRubE4, partCount: 1,
          owedMark: nil, parts: nil,
          refund: RefundMark.of(part: part, in: entry, ledger: ledger))
      } : nil
    let category = RowCell.of(cells.map(\.category))
    return TransactionRowItem(
      id: .transaction(transaction.id), transactionId: transaction.id, kind: transaction.kind,
      occurredAt: transaction.occurredAt, note: transaction.note,
      title: RowTitle.resolve(
        note: transaction.note, category: cells.lazy.compactMap(\.category).first,
        kind: transaction.kind),
      // A formula kept from before, its numbers written the way the app writes them.
      expression: transaction.amountExpr.map { ExpressionEvaluator.canonical($0) ?? $0 },
      partNumber: nil,
      place: transaction.placeId.flatMap { names.places[$0] },
      category: category,
      forWhom: RowCell.of(cells.map(\.forWhom)),
      event: RowCell.of(cells.map(\.event)),
      paymentMethod: names.account(of: transaction),
      quality: RowCell.of(cells.map(\.quality)),
      amount: transaction.amountE4, currency: transaction.currency,
      amountRub: transaction.amountRubE4, partCount: entry.parts.count,
      owedMark: owedMark(of: entry), parts: parts, refund: RefundMark.of(entry, ledger: ledger),
      cashback: transaction.cashback.flatMap { $0.amount.isZero ? nil : $0 })
  }

  /// The quality of an operation as a row of the list of days shows it, the way the table
  /// does: the rules' quality of each part (the one the filter and every figure use, none
  /// for income), one value when the parts agree and «several» when they do not. A part the
  /// ledger does not know yet — the data has not come — shows what it stores.
  static func quality(of entry: TransactionEntry, ledger: Ledger?) -> RowCell<Quality> {
    RowCell.of(
      entry.parts.map { part in ledger?.row(ofPart: part.id).map(\.quality) ?? part.quality })
  }

  /// The mark of a purchase with parts paid for somebody else: waiting while any of them
  /// waits, then returned, then written off. `reimbursable` stays set after the money came
  /// back, so it alone would keep a settled row «waiting» forever. Only a purchase is
  /// waited for: a friend's ticket taken back in a refund carries no mark.
  static func owedMark(of entry: TransactionEntry) -> ReimbursementStatus? {
    guard entry.transaction.kind == .expense else { return nil }
    let statuses = Set(
      entry.parts.filter(\.reimbursable).map { $0.reimbursementStatus ?? .expected })
    return [ReimbursementStatus.expected, .returned, .writtenOff].first(where: statuses.contains)
  }

  /// The cells of one part, as the operation's row compares them across its parts.
  private struct PartCells {
    var category: CategoryPath?
    var forWhom: ForWhomValue?
    var event: String?
    var quality: Quality?

    init(_ part: TransactionPart, in transaction: Transaction, ledger: Ledger, names: Names) {
      category = CategoryPath(part.categoryId, tree: ledger.tree)
      event = part.eventId.flatMap { names.events[$0] }
      // The rules' quality, the one the filter and every figure use; none for income.
      quality = ledger.row(ofPart: part.id)?.quality
      switch transaction.kind {
      case .income:
        forWhom = nil
      case .reimbursement:
        // Who gave the money back.
        forWhom = part.forPersonId.flatMap { names.people[$0] }.map(ForWhomValue.person)
      case .expense where part.reimbursable:
        forWhom = .owed(
          by: (part.debtorPersonId ?? part.forPersonId).flatMap { names.people[$0] },
          part.reimbursementStatus ?? .expected)
      case .expense, .refund:
        forWhom =
          part.forPersonId.flatMap { names.people[$0] }.map(ForWhomValue.person)
          ?? .value(part.forWhom)
      }
    }
  }

  /// Names of the dictionaries, archived ones included: an operation filed under a retired
  /// place still says where it was.
  private struct Names {
    let people: [UUID: String]
    let places: [UUID: String]
    let events: [UUID: String]
    let paymentMethods: [UUID: String]
    let cards: [UUID: String]
    /// How the lists name an account and a card: the bank, when it has one account and one card.
    let labels: AccountLabels

    init(_ dataset: Dataset) {
      func index<T>(
        _ items: [T], _ id: KeyPath<T, UUID>, _ name: KeyPath<T, String>
      ) -> [UUID:
        String]
      {
        Dictionary(
          items.map { ($0[keyPath: id], $0[keyPath: name]) }, uniquingKeysWith: { a, _ in a })
      }
      people = index(dataset.people, \.id, \.name)
      places = index(dataset.places, \.id, \.name)
      events = index(dataset.events, \.id, \.name)
      paymentMethods = index(dataset.paymentMethods, \.id, \.name)
      cards = index(dataset.cards, \.id, \.name)
      labels = AccountLabels(
        accounts: dataset.paymentMethods, cards: dataset.cards, banks: dataset.banks)
    }

    /// The account column of an operation, as the lists name it: «Т-Банк › Black» when it names
    /// a card of an account with two cards or more, only «Сбер» when its card is called like its
    /// account or its bank, the bank alone for a bank with one account (`AccountLabels`).
    func account(of transaction: Transaction) -> String? {
      guard let id = transaction.paymentMethodId, paymentMethods[id] != nil else { return nil }
      return labels.label(account: id, card: transaction.cardId)
    }
  }
}

/// What the table shows of what the filters found, a few months at a time,
/// kept in step while two things change it at once: a filtering — of a new filter, or of new
/// data — and «Show more». Both cut the page off the main thread and land whenever they are
/// done, in either order, so each landing checks what it was cut for:
///
/// * a filtering cut its page for the months shown when it started; if «Show more» asked
///   for more meanwhile, the new listing is shown at once and cut again for them;
/// * a page «Show more» cut lands only if it was cut from the listing shown now, for the
///   months asked for now. Cut from an older listing, it would bring back operations the
///   data no longer has, and a selection could hold them.
struct TransactionPages {
  /// A page to cut off the main thread: from which listing, how many months, and the stamp
  /// of that listing.
  struct Request: Sendable {
    let listing: TransactionListing
    let months: Int
    fileprivate let serial: Int
  }

  /// What the filters found; `nil` until the first filtering is done.
  private(set) var listing: TransactionListing?
  /// The newest months of it the table shows.
  private(set) var shown: TransactionListing?
  /// How many months the table shows: a new filter starts again from the first page, new
  /// data keeps what was opened.
  private(set) var monthsShown = TransactionListing.monthsPerPage
  /// Moves on with every listing that lands.
  private var serial = 0

  /// Another filter or search starts from the newest months again.
  mutating func startOver() {
    monthsShown = TransactionListing.monthsPerPage
  }

  /// A filtering landed: what it found, and the page cut from it for `months`. The table
  /// shows them at once; when «Show more» asked for another number of months while the
  /// filtering ran, the page still to cut for them is returned.
  mutating func land(
    found: TransactionListing, page: TransactionListing, cutFor months: Int
  ) -> Request? {
    serial += 1
    listing = found
    shown = page
    guard months != monthsShown else { return nil }
    return Request(listing: found, months: monthsShown, serial: serial)
  }

  /// «Show more»: a few more months of the listing shown now.
  mutating func showMore() -> Request? {
    guard let listing else { return nil }
    monthsShown += TransactionListing.monthsPerPage
    return Request(listing: listing, months: monthsShown, serial: serial)
  }

  /// A page cut for `request` landed; returns whether it is shown. Only a page cut from the
  /// listing shown now, for the months asked for now, is — any other is dropped.
  mutating func land(_ page: TransactionListing, for request: Request) -> Bool {
    guard request.serial == serial, request.months == monthsShown else { return false }
    shown = page
    return true
  }
}
