import CoreAccounting
import CoreKit
import Foundation

/// A line of the cashback figures: an account, and one of its cards or the account's own line.
public struct CashbackHolderKey: Hashable, Sendable {
  /// `nil`: operations that name no account.
  public var accountId: UUID?
  /// `nil`: the account's own line — operations that name no card.
  public var cardId: UUID?

  public init(accountId: UUID?, cardId: UUID? = nil) {
    self.accountId = accountId
    self.cardId = cardId
  }
}

/// Expected and received cashback by account, card and month.
///
/// Expected: what the rules of the account and its card (or the figure typed for an operation)
/// promise for the purchases of the period, by the day of the purchase — a refund taken back
/// from a purchase makes the purchase cheaper, on the purchase's day and card —, in the money
/// that moved on the account and in rubles at the operation's own rate. An expectation, never
/// income. What the rules gave, with no figure typed, is the part nobody has confirmed
/// (`Cell.unconfirmedRub`); it needs no confirming and counts all the same.
///
/// Received: income in the cashback category and its subcategories, by the month it is for,
/// on the card it names, else on the account — and the points an account's cashback comes as
/// are the cashback of that account (`CashbackPoints`).
///
/// The turnover and my spending of each line are counted as in «Оборот и кэшбэк»
/// (`PaymentMethodsReport`), so the lines of an account add up to its row there.
public struct CashbackReport: Sendable {
  public struct Cell: Hashable, Sendable {
    public var holder: CashbackHolderKey
    public var month: MonthKey
    /// Rubles.
    public var mySpending: AmountE4
    /// Rubles: whole receipts minus refunds, as `PaymentMethodsReport` counts it.
    public var turnover: AmountE4
    public var expected: [CurrencyCode: AmountE4]
    public var expectedRub: AmountE4
    /// The part of `expectedRub` the rules gave, where no figure was typed for the operation.
    public var unconfirmedRub: AmountE4
    public var received: [CurrencyCode: AmountE4]
    public var receivedRub: AmountE4

    public init(holder: CashbackHolderKey, month: MonthKey) {
      self.holder = holder
      self.month = month
      mySpending = .zero
      turnover = .zero
      expected = [:]
      expectedRub = .zero
      unconfirmedRub = .zero
      received = [:]
      receivedRub = .zero
    }

    var isEmpty: Bool {
      mySpending.isZero && turnover.isZero && expected.isEmpty && received.isEmpty
    }

    mutating func record(
      spending: AmountE4, turnover: AmountE4?, expectation: CashbackExpectation?
    ) {
      mySpending += spending
      if let turnover { self.turnover += turnover }
      if let expectation {
        expected[expectation.money.currency, default: .zero] += expectation.money.amount
        expectedRub += expectation.rubles
        if case .rules = expectation.source { unconfirmedRub += expectation.rubles }
      }
    }

    mutating func receive(_ row: LedgerRow) {
      received[row.currency, default: .zero] += row.amountE4
      receivedRub += row.amountRubE4
    }

    mutating func add(_ other: Cell) {
      mySpending += other.mySpending
      turnover += other.turnover
      expectedRub += other.expectedRub
      unconfirmedRub += other.unconfirmedRub
      receivedRub += other.receivedRub
      for (currency, amount) in other.expected { expected[currency, default: .zero] += amount }
      for (currency, amount) in other.received { received[currency, default: .zero] += amount }
    }
  }

  /// One cell per line and month with anything in it, lines in the order of the lists.
  public let cells: [Cell]
  /// Some card or account has a rule.
  public let hasRules: Bool

  public init(ledger: Ledger, period: Period) {
    let dataset = ledger.dataset
    let cards = dataset.cards
    let book = CashbackRuleBook(
      rules: dataset.cashbackRules, tree: ledger.tree, cards: cards,
      accounts: dataset.paymentMethods)
    let mainId = dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    let pointsOwners = CashbackPoints.owners(among: dataset.paymentMethods)
    hasRules = !book.isEmpty

    // The line of an operation depends only on its account and card: worked out once each.
    struct Source: Hashable {
      var accountId: UUID?
      var cardId: UUID?
    }
    var lines: [Source: (key: CashbackHolderKey, holder: CashbackHolder?)] = [:]
    func key(_ row: LedgerRow) -> (key: CashbackHolderKey, holder: CashbackHolder?) {
      let source = Source(accountId: row.paymentMethodId, cardId: row.cardId)
      if let known = lines[source] { return known }
      let holder = CashbackHolders.holder(
        accountId: row.paymentMethodId, cardId: row.cardId, mainAccountId: mainId)
      var key = CashbackHolderKey(accountId: row.paymentMethodId)
      if row.paymentMethodId != nil, case .card(let cardId) = holder { key.cardId = cardId }
      lines[source] = (key, holder)
      return (key, holder)
    }

    struct Slot: Hashable {
      var holder: CashbackHolderKey
      var month: MonthKey
    }
    var cells: [Slot: Cell] = [:]

    for row in ledger.rows(in: period.range) {
      let (holderKey, holder) = key(row)
      let month = row.day.monthKey
      let slot = Slot(holder: holderKey, month: month)
      var turnover: AmountE4?
      switch row.kind {
      case .expense: turnover = row.amountRubE4 - row.refundedRubE4
      case .refund where row.refundOfPartId == nil: turnover = -row.amountRubE4
      case .refund, .income, .reimbursement: turnover = nil
      }
      let expectation =
        row.isFirstPart && (row.kind == .expense || row.kind == .refund)
        ? ledger.entry(row.transactionId).flatMap { entry in
          CashbackMath.expected(
            entry, holder: holder, book: book, tree: ledger.tree, calendar: ledger.calendar,
            refunded: { ledger.refunded(forPart: $0) })
        } : nil
      guard !row.contribution.isZero || turnover != nil || expectation != nil else { continue }
      cells[slot, default: Cell(holder: holderKey, month: month)].record(
        spending: row.contribution, turnover: turnover, expectation: expectation)
    }

    if let cashbackId = dataset.settings.cashbackCategoryId {
      let categories = Set([cashbackId] + ledger.tree.children(of: cashbackId).map(\.id))
      for row in ledger.incomeRows(in: period) {
        guard let categoryId = row.categoryId, categories.contains(categoryId) else { continue }
        var holderKey = key(row).key
        // Points that came to a points account are the cashback of the account that earned them.
        if let account = row.paymentMethodId, let owner = pointsOwners[account] {
          holderKey = CashbackHolderKey(accountId: owner)
        }
        let slot = Slot(holder: holderKey, month: row.month)
        cells[slot, default: Cell(holder: holderKey, month: row.month)].receive(row)
      }
    }

    // The order of the lists: accounts as the dataset lists them, the account's own line
    // first, then its cards in their order; operations with no account last.
    var order: [CashbackHolderKey: Int] = [:]
    var position = 0
    for account in dataset.paymentMethods {
      order[CashbackHolderKey(accountId: account.id)] = position
      position += 1
      for card in cards where card.accountId == account.id {
        order[CashbackHolderKey(accountId: account.id, cardId: card.id)] = position
        position += 1
      }
    }
    let rank = { (key: CashbackHolderKey) in order[key] ?? Int.max }
    self.cells = cells.values.filter { !$0.isEmpty }.sorted { left, right in
      let (l, r) = (rank(left.holder), rank(right.holder))
      if l != r { return l < r }
      if left.holder != right.holder {
        return Self.text(left.holder) < Self.text(right.holder)
      }
      return left.month < right.month
    }
  }

  private static func text(_ key: CashbackHolderKey) -> String {
    (key.accountId?.uuidString ?? "") + (key.cardId?.uuidString ?? "")
  }

  /// Each line with its months added up, in the order of the lists; a cell's month is the
  /// first month of its line.
  public func byHolder() -> [Cell] {
    var result: [Cell] = []
    for cell in cells {
      if let last = result.last, last.holder == cell.holder {
        result[result.count - 1].add(cell)
      } else {
        result.append(cell)
      }
    }
    return result
  }

  /// Expected and received in rubles by month: of every line, of one account (its own line and
  /// its cards), or of one card.
  public func byMonth(
    accountId: UUID? = nil, cardId: UUID? = nil
  ) -> [(month: MonthKey, expectedRub: AmountE4, receivedRub: AmountE4)] {
    var months: [MonthKey: (AmountE4, AmountE4)] = [:]
    for cell in cells {
      if let cardId, cell.holder.cardId != cardId { continue }
      if let accountId, cell.holder.accountId != accountId { continue }
      let sums = months[cell.month] ?? (.zero, .zero)
      months[cell.month] = (sums.0 + cell.expectedRub, sums.1 + cell.receivedRub)
    }
    return months.sorted { $0.key < $1.key }.map { month, sums in
      (month: month, expectedRub: sums.0, receivedRub: sums.1)
    }
  }

  /// Expected cashback of an account in rubles, over every line of it.
  public func expectedRub(ofAccount accountId: UUID?) -> AmountE4 {
    AmountE4.sum(cells.filter { $0.holder.accountId == accountId }.map(\.expectedRub))
  }
}

/// The block «Кэшбэк» of an account's screen: the account's own line first — its rules are the
/// ones every card follows —, then each live card that keeps rules of its own, and any other
/// line with cashback that month (a card the purchases named, an archived one).
public enum AccountCashbackSummary {
  public static func month(
    _ month: MonthKey, accountId: UUID, ledger: Ledger
  ) -> [CashbackReport.Cell] {
    let report = CashbackReport(ledger: ledger, period: .month(month))
    let cards = ledger.dataset.cards
    let withOwnRules = Set(ledger.dataset.cashbackRules.compactMap(\.cardId))
    var lines: [CashbackHolderKey] = [CashbackHolderKey(accountId: accountId)]
    for card in CardRules.ordered(cards, of: accountId, locale: Locale(identifier: "en_US_POSIX"))
    where withOwnRules.contains(card.id) {
      lines.append(CashbackHolderKey(accountId: accountId, cardId: card.id))
    }
    let active = report.cells.filter { $0.holder.accountId == accountId }
    for cell in active where !lines.contains(cell.holder) { lines.append(cell.holder) }
    let byKey = Dictionary(active.map { ($0.holder, $0) }, uniquingKeysWith: { first, _ in first })
    // The account's own line first, then the cards in the order of the lists, archived ones
    // after the live.
    let order = cards.filter { $0.accountId == accountId }
      .sorted { left, right in
        if left.archived != right.archived { return !left.archived }
        return CardRules.precedes(left, right, locale: Locale(identifier: "en_US_POSIX"))
      }
      .map(\.id)
    let index = { (key: CashbackHolderKey) in
      key.cardId.flatMap { id in order.firstIndex(of: id) } ?? -1
    }
    let ordered = lines.sorted { index($0) < index($1) }
    return ordered.map { byKey[$0] ?? CashbackReport.Cell(holder: $0, month: month) }
  }
}
