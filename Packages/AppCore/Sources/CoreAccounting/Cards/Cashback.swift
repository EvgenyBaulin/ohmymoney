import CoreKit
import Foundation

/// Whose cashback rules price an operation: a card, or an account paid from without a card.
public enum CashbackHolder: Hashable, Sendable {
  case card(UUID)
  case account(UUID)
}

/// Which holder's rules apply.
///
/// The rules of the bank belong to the account, and its cards follow them: a card may keep rules
/// of its own, which are only the places where it differs (`CashbackRuleBook`). So an operation
/// that names no card is priced by its account — a second card, a card put in the archive or
/// two accounts merged never change what the purchases of the past would have earned.
public enum CashbackHolders {
  /// The card the operation names — live or archived: its past purchases keep their rules —;
  /// else its account. An operation that names no account is the main account's.
  public static func holder(
    accountId: UUID?, cardId: UUID?, mainAccountId: UUID?
  ) -> CashbackHolder? {
    if let cardId { return .card(cardId) }
    guard let account = accountId ?? mainAccountId else { return nil }
    return .account(account)
  }

  /// Where the rules of an account are edited: the account itself, then each of its live cards,
  /// whose own rules are what differs from the account's.
  public static func editableHolders(of accountId: UUID, cards: [PaymentCard]) -> [CashbackHolder] {
    let live = CardRules.ordered(cards, of: accountId, locale: Locale(identifier: "en_US_POSIX"))
    return [.account(accountId)] + live.map { .card($0.id) }
  }

  /// The account a holder belongs to.
  public static func account(of holder: CashbackHolder, cards: [PaymentCard]) -> UUID? {
    switch holder {
    case .account(let id): id
    case .card(let id): cards.first { $0.id == id }?.accountId
    }
  }
}

extension CashbackRule {
  /// The card of the rule, or its account when it has none.
  public var holder: CashbackHolder {
    cardId.map(CashbackHolder.card) ?? .account(accountId)
  }
}

/// Every rule of every holder, indexed once, and the order they are chosen in.
///
/// A card prices a purchase with its own rules and the rules of its account together: the card's
/// own rule wins where both have one for the same month and category, and the account's rules
/// cover everything else. The book also knows how each account rounds, as the account says.
public struct CashbackRuleBook: Sendable {
  private struct Key: Hashable {
    var holder: CashbackHolder
    var month: MonthKey?
    var categoryId: UUID?
  }

  private let byKey: [Key: CashbackRule]
  private let byHolder: [CashbackHolder: [CashbackRule]]
  private let tree: CategoryTree
  private let accountOfCard: [UUID: UUID]
  private let roundingOfAccount: [UUID: CashbackRounding]

  /// `cards` tell which account a card follows, `accounts` how each rounds; a card or account
  /// that is not given has no account above it, and rounds as `CashbackRounding.standard`.
  public init(
    rules: [CashbackRule], tree: CategoryTree, cards: [PaymentCard] = [],
    accounts: [PaymentMethod] = []
  ) {
    var byKey: [Key: CashbackRule] = [:]
    var byHolder: [CashbackHolder: [CashbackRule]] = [:]
    for rule in rules {
      let key = Key(holder: rule.holder, month: rule.month, categoryId: rule.categoryId)
      // The database keeps one rule per key; of two a hand edit left, the first stays.
      guard byKey[key] == nil else { continue }
      byKey[key] = rule
      byHolder[rule.holder, default: []].append(rule)
    }
    self.byKey = byKey
    self.byHolder = byHolder
    self.tree = tree
    self.accountOfCard = Dictionary(
      cards.map { ($0.id, $0.accountId) }, uniquingKeysWith: { first, _ in first })
    self.roundingOfAccount = Dictionary(
      accounts.map { ($0.id, $0.cashbackRounding) }, uniquingKeysWith: { first, _ in first })
  }

  public var isEmpty: Bool { byKey.isEmpty }

  /// The rules of one holder, in the order they were given: a card's own, an account's own.
  public func rules(of holder: CashbackHolder) -> [CashbackRule] { byHolder[holder] ?? [] }

  /// The rules that price a holder: its own, and for a card the rules of its account that the
  /// card has no rule of its own for (the same month and category).
  public func effectiveRules(of holder: CashbackHolder) -> [CashbackRule] {
    let own = rules(of: holder)
    guard case .card(let id) = holder, let account = accountOfCard[id] else { return own }
    let taken = Set(
      own.map { Key(holder: .account(account), month: $0.month, categoryId: $0.categoryId) })
    return own
      + rules(of: .account(account)).filter {
        !taken.contains(Key(holder: .account(account), month: $0.month, categoryId: $0.categoryId))
      }
  }

  /// The account a holder follows, when the book knows it.
  public func account(of holder: CashbackHolder) -> UUID? {
    switch holder {
    case .account(let id): id
    case .card(let id): accountOfCard[id]
    }
  }

  /// How the bank of the holder's account rounds the cashback of one purchase.
  public func rounding(for holder: CashbackHolder?) -> CashbackRounding {
    holder.flatMap { account(of: $0) }.flatMap { roundingOfAccount[$0] } ?? .standard
  }

  /// The rule that prices a purchase of `categoryId` in `month`, the first found of: the month's
  /// rule of the subcategory, the month's of its category, the «always» of the subcategory, the
  /// «always» of the category, the month's «everything else», the «always» «everything else».
  /// The bank's categories of the month win over a standing rate on the same purchase, and
  /// «everything else» is the last word of both. Where a card and its account both have the rule
  /// of a step, the card's is taken.
  public func rule(
    for holder: CashbackHolder, categoryId: UUID?, month: MonthKey
  ) -> CashbackRule? {
    var holders = [holder]
    if case .card(let id) = holder, let account = accountOfCard[id] {
      holders.append(.account(account))
    }
    guard holders.contains(where: { byHolder[$0] != nil }) else { return nil }
    let path = categoryPath(categoryId)
    for scope in [month, nil] as [MonthKey?] {
      for category in path {
        for held in holders {
          if let rule = byKey[Key(holder: held, month: scope, categoryId: category)] {
            return rule
          }
        }
      }
    }
    for scope in [month, nil] as [MonthKey?] {
      for held in holders {
        if let rule = byKey[Key(holder: held, month: scope, categoryId: nil)] { return rule }
      }
    }
    return nil
  }

  /// The category and the categories above it, nearest first; empty without a category.
  private func categoryPath(_ categoryId: UUID?) -> [UUID] {
    guard let categoryId else { return [] }
    var path = [categoryId]
    var current = categoryId
    while let parent = tree.parent(of: current), !path.contains(parent.id), path.count < 8 {
      path.append(parent.id)
      current = parent.id
    }
    return path
  }
}

/// What the owner typed in the field «Кэшбэк»: an amount («45») or a percent («5%»).
public enum CashbackInput: Hashable, Sendable {
  /// In the currency that moves on the account; read like every typed amount (`TypedNumber`).
  case amount(AmountE4)
  /// Read like a rate (`DecimalMath.parse`): a lone comma is the decimal one, «1,5%» is 1.5 %.
  case percent(CashbackPercent)
  case unreadable(Problem)

  public enum Problem: Hashable, Sendable {
    case malformed
    case negative
    case percentAboveHundred
    case percentTooPrecise
    case tooLarge
  }

  /// `nil` for an empty field.
  public static func read(_ text: String) -> CashbackInput? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let last = trimmed.last, last == "%" || last == "％" {
      let number = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
      guard let value = DecimalMath.parse(number) else { return .unreadable(.malformed) }
      if value < 0 { return .unreadable(.negative) }
      if value > 100 { return .unreadable(.percentAboveHundred) }
      guard let percent = CashbackPercent(decimal: value) else {
        return .unreadable(.percentTooPrecise)
      }
      return .percent(percent)
    }
    guard let reading = TypedNumber.read(trimmed) else {
      return .unreadable(TypedNumber.isTooLarge(trimmed) ? .tooLarge : .malformed)
    }
    if reading.value < 0 { return .unreadable(.negative) }
    guard let amount = try? AmountE4(decimal: reading.value), amount <= AmountE4.inputLimit else {
      return .unreadable(.tooLarge)
    }
    return .amount(amount)
  }
}

/// The cashback one operation is expected to earn.
public struct CashbackExpectation: Hashable, Sendable {
  public enum Source: Hashable, Sendable {
    /// The rules that priced it, each once, in the order of the parts.
    case rules([UUID])
    /// The figure the owner typed for the operation.
    case override
  }

  /// In the currency that moved on the account, to the kopeck; below zero for a refund of no
  /// purchase, which takes cashback back.
  public var money: Money
  /// The same in rubles, at the operation's own rate.
  public var rubles: AmountE4
  public var holder: CashbackHolder?
  public var source: Source

  public init(money: Money, rubles: AmountE4, holder: CashbackHolder?, source: Source) {
    self.money = money
    self.rubles = rubles
    self.holder = holder
    self.source = source
  }
}

/// How much cashback to expect. An expectation only: received cashback is income in the
/// cashback category, and nothing here ever becomes income.
public enum CashbackMath {
  /// Whether an operation can earn cashback at all: a purchase, or a refund of no purchase
  /// (it takes back what its money had earned). Not income, not money back, not a contribution
  /// to a goal, not a payment on a debt — the bank pays nothing for those —, not a purchase on
  /// credit — the lender paid —, not what the app writes to keep the books, not the fee of a
  /// transfer.
  public static func earns(_ entry: TransactionEntry, tree: CategoryTree) -> Bool {
    let transaction = entry.transaction
    switch transaction.kind {
    case .expense: break
    case .refund:
      guard !entry.parts.contains(where: { $0.refundOfPartId != nil }) else { return false }
    case .income, .reimbursement: return false
    }
    guard transaction.creditDebtId == nil, !KindFields.isGoalOnly(entry, tree: tree),
      !entry.parts.allSatisfy({ tree.isLoanCategory($0.categoryId) })
    else { return false }
    switch OperationLink(externalId: transaction.externalId) {
    case .some(.transferFee): return false
    case .some(let link) where link.isBookkeeping: return false
    default: return true
    }
  }

  /// The cashback a saved operation is expected to earn, or `nil` when it earns none or its
  /// holder has no rule for any of its parts.
  ///
  /// The base is the money that moved on the account, the whole receipt with the parts paid for
  /// others: the bank pays on what the card was charged. It is spread over the parts in their
  /// proportions; what refunds took back from a part (`refunded`, in the operation's currency)
  /// makes that part cheaper. Each part takes the rule of its own category — a part that pays a
  /// debt takes none —; the sum is rounded once, the way the account's bank rounds
  /// (`CashbackRounding`), half away from zero by default. A figure the owner typed wins over
  /// the rules and shrinks with the refunds the same way, to the kopeck.
  public static func expected(
    _ entry: TransactionEntry, holder: CashbackHolder?, book: CashbackRuleBook,
    tree: CategoryTree, calendar: CalendarContext, refunded: (UUID) -> AmountE4
  ) -> CashbackExpectation? {
    guard earns(entry, tree: tree) else { return nil }
    let transaction = entry.transaction
    let moved = transaction.movedMoney
    let total = transaction.amountE4
    let sign: Decimal = transaction.kind == .refund ? -1 : 1
    let weights = entry.parts.map(\.amountE4)
    let bases = moved.amount.allocated(proportionallyTo: weights, outOf: total)

    if let typed = transaction.keptCashback {
      let refundedTotal = AmountE4.sum(entry.parts.map { refunded($0.id) })
      let kept = total.isZero ? 1 : max(0, (total - refundedTotal).decimal / total.decimal)
      return expectation(
        sign * typed.amount.decimal * kept, of: transaction, holder: holder, source: .override,
        rounding: CashbackRounding(precision: .cents))
    }
    guard let holder else { return nil }
    // The month of the rule is the month of the day the purchase was made on, in the zone it was
    // recorded in (0491): a dinner at 02:00 on the 1st in Bali is October's, whatever the Mac says.
    let month = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      .monthKey
    var value = Decimal(0)
    var used: [UUID] = []
    for (part, base) in zip(entry.parts, bases) {
      guard !tree.isLoanCategory(part.categoryId),
        let rule = book.rule(for: holder, categoryId: part.categoryId, month: month)
      else { continue }
      if !used.contains(rule.id) { used.append(rule.id) }
      let amount = part.amountE4.decimal
      let left =
        amount.isZero ? Decimal(0) : max(0, (amount - refunded(part.id).decimal) / amount)
      value += base.decimal * left * rule.percent.fraction
    }
    guard !used.isEmpty else { return nil }
    return expectation(
      sign * value, of: transaction, holder: holder, source: .rules(used),
      rounding: book.rounding(for: holder))
  }

  /// The same for the ↓ panel, before anything is saved: nothing refunded yet, the typed
  /// figure taken from the draft.
  public static func expected(
    _ draft: TransactionDraft, holder: CashbackHolder?, book: CashbackRuleBook,
    tree: CategoryTree, calendar: CalendarContext
  ) -> CashbackExpectation? {
    guard let entry = entry(of: draft) else { return nil }
    return expected(
      entry, holder: holder, book: book, tree: tree, calendar: calendar, refunded: { _ in .zero })
  }

  /// A typed percent of the draft's base — the money that moves on the account —, rounded the
  /// way the account's bank rounds.
  public static func amount(
    of percent: CashbackPercent, on draft: TransactionDraft,
    rounding: CashbackRounding = .standard
  ) -> Money? {
    let moved = movedMoney(of: draft)
    let value = rounding.apply(moved.amount.decimal.magnitude * percent.fraction)
    guard let amount = try? AmountE4(decimal: value) else { return nil }
    return Money(amount: amount, currency: moved.currency)
  }

  /// What moves on the account for a draft: its «Списано со счёта», else its own amount.
  public static func movedMoney(of draft: TransactionDraft) -> Money {
    if let currency = draft.accountCurrency, let amount = draft.accountAmount {
      return Money(amount: amount, currency: currency)
    }
    return Money(amount: draft.amount, currency: draft.currency)
  }

  private static func entry(of draft: TransactionDraft) -> TransactionEntry? {
    var draft = draft
    if draft.parts.isEmpty { draft.normalizeSinglePart() }
    let rate = draft.currency == .rub ? Decimal(1) : draft.rate
    return try? draft.materialize(
      id: UUID(), now: Date(timeIntervalSince1970: 0),
      rublesConverter: { amount in
        guard let rate else { return amount }
        return try AmountE4(decimal: amount.decimal * rate)
      })
  }

  private static func expectation(
    _ value: Decimal, of transaction: Transaction, holder: CashbackHolder?,
    source: CashbackExpectation.Source, rounding: CashbackRounding
  ) -> CashbackExpectation? {
    let moved = transaction.movedMoney
    let rounded = rounding.apply(value)
    guard let amount = try? AmountE4(decimal: rounded) else { return nil }
    let rubles: AmountE4
    if moved.currency == .rub {
      rubles = amount
    } else if moved.amount.isZero {
      rubles = .zero
    } else {
      let exact =
        rounded * transaction.amountRubE4.decimal / moved.amount.decimal
      rubles = (try? AmountE4(decimal: DecimalMath.round(exact, scale: 2))) ?? .zero
    }
    return CashbackExpectation(
      money: Money(amount: amount, currency: moved.currency), rubles: rubles, holder: holder,
      source: source)
  }
}
