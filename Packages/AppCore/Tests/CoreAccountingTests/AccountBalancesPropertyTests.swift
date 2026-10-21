import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A random history of money on three accounts. Next to every operation, transfer and count it
/// writes down what that record should do to the balances, by a plain model of the rules — the
/// code under test is never asked:
///
/// * a purchase takes its amount off (account, its currency), or its charge off (account, main
///   currency) when the account does not hold the currency and a charge is stored; income, a
///   refund and money back put theirs on; no account means the main one;
/// * a deleted operation, a line of the books, a purchase on credit and money put into a goal or
///   taken out of it move nothing; a purchase part of which goes to a goal moves the rest;
/// * a transfer takes the amount sent off one key and puts the amount received on another; its
///   fee is an ordinary purchase;
/// * a balance is the latest count of accounts made by then plus every move after its moment
///   and up to then; a count of one total counts nothing.
private struct MoneyHistory {
  struct Move: Hashable {
    var key: BalanceKey
    var at: Date
    var amount: AmountE4
    var source: AccountMovement.Source
    /// A journal line that knows only its day: of a count made that day nothing can be said.
    var dayOnly: DateOnly? = nil
    /// A journal line with no date at all: it never counts.
    var undated = false
  }

  /// A purchase part a refund can still take back from.
  struct Refundable {
    var partId: UUID
    var currency: CurrencyCode
    var left: AmountE4
    var account: UUID
    var at: Date
  }

  static let kzt = CurrencyCode("KZT")
  static let eur = CurrencyCode("EUR")
  static let main = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  static let freedom = PaymentMethod(
    id: id(2), name: "Freedom", currency: kzt, otherCurrencies: [.rub, .usd])
  static let dollars = PaymentMethod(id: id(3), name: "Dollars", kind: .cash, currency: .usd)
  static let accounts = [main, freedom, dollars]
  static let loan = Debt(id: id(200), direction: .iOwe, type: .loan, name: "Loan")
  static let laptop = Debt(
    id: id(201), direction: .iOwe, type: .installment, name: "Laptop",
    paymentsAreExpenses: false, origin: .purchase)
  static let lent = Debt(
    id: id(202), direction: .owedToMe, type: .personal, name: "Lent", personId: id(300))
  static let friend = Debt(
    id: id(203), direction: .iOwe, type: .personal, name: "From a friend", currency: .usd)
  static let creditCard = Debt(
    id: id(204), direction: .iOwe, type: .creditCard, name: "Credit card")
  static let debts = Dictionary(
    uniqueKeysWithValues: [loan, laptop, lent, friend, creditCard].map { ($0.id, $0) })

  let categories = StartingCategories()
  let start = moment("2026-03-01")
  /// Sixty days in; about a sixth of the history is still ahead of it.
  let now = moment("2026-04-30").addingTimeInterval(23 * 3600)
  var entries: [TransactionEntry] = []
  var transfers: [Transfer] = []
  var moves: [Move] = []
  var reconciliations: [Reconciliation] = []
  var counted: [ReconciledBalance] = []
  var refundable: [Refundable] = []
  var journal: [DebtEntry] = []
  var dice: MoneyDice
  private var nextNumber = 1000

  init(seed: UInt64, operations: Int = 140, counts: Int = 6) {
    dice = MoneyDice(seed: seed)
    for _ in 0..<operations { step() }
    addCounts(counts)
  }

  var liveKeys: [BalanceKey] {
    Self.accounts.flatMap { account in
      account.currencies.map { BalanceKey(accountId: account.id, currency: $0) }
    }
  }

  // MARK: Building blocks

  mutating func number() -> Int {
    nextNumber += 1
    return nextNumber
  }

  /// A moment within seventy days of the start, to the minute.
  mutating func someMoment() -> Date {
    start.addingTimeInterval(TimeInterval(dice.below(70 * 1440) * 60))
  }

  mutating func someAccount() -> PaymentMethod { dice.pick(Self.accounts) }

  mutating func held(by account: PaymentMethod) -> CurrencyCode { dice.pick(account.currencies) }

  mutating func notHeld(by account: PaymentMethod) -> CurrencyCode {
    dice.pick([CurrencyCode.rub, .usd, Self.kzt, Self.eur].filter { !account.holds($0) })
  }

  func piece(
    _ amount: AmountE4, category: UUID? = nil, goal: UUID? = nil, reimbursable: Bool = false,
    status: ReimbursementStatus? = nil, refunding: UUID? = nil, forWhom: ForWhom = .me,
    event: UUID? = nil
  ) -> TransactionPart {
    TransactionPart(
      transactionId: id(0), categoryId: category, amountE4: amount, forWhom: forWhom,
      reimbursable: reimbursable, debtorPersonId: reimbursable ? id(300) : nil,
      reimbursementStatus: reimbursable ? (status ?? .expected) : nil, eventId: event,
      goalId: goal, refundOfPartId: refunding)
  }

  /// Writes an operation; its parts get the ids `number * 10 + index`.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, at: Date, currency: CurrencyCode, account: UUID?,
    parts: [TransactionPart], leg: (CurrencyCode, AmountE4)? = nil, externalId: String? = nil,
    debtId: UUID? = nil, creditDebtId: UUID? = nil, placeId: UUID? = nil, deleted: Bool = false
  ) -> TransactionEntry {
    let number = number()
    var fixed = parts
    for index in fixed.indices {
      fixed[index].id = id(number * 10 + index)
      fixed[index].transactionId = id(number)
    }
    let transaction = Transaction(
      id: id(number), kind: kind, occurredAt: at, currency: currency,
      amountE4: AmountE4.sum(fixed.map(\.amountE4)), placeId: placeId, paymentMethodId: account,
      accountCurrency: leg?.0, accountAmountE4: leg?.1, debtId: debtId,
      creditDebtId: creditDebtId, externalId: externalId, createdAt: at, updatedAt: at,
      deletedAt: deleted ? at : nil)
    let entry = TransactionEntry(transaction: transaction, parts: fixed)
    entries.append(entry)
    return entry
  }

  mutating func expect(
    _ account: UUID?, _ currency: CurrencyCode, _ signed: AmountE4, at: Date, from entry: UUID
  ) {
    moves.append(
      Move(
        key: BalanceKey(accountId: account ?? Self.main.id, currency: currency), at: at,
        amount: signed, source: .operation(entry)))
  }

  // MARK: One random record

  mutating func step() {
    let at = someMoment()
    switch dice.below(19) {
    case 0, 1, 2: purchase(at: at)
    case 3: foreignPurchase(at: at)
    case 4: income(at: at)
    case 5: partlyForAGoal(at: at)
    case 6: onlyForAGoal(at: at)
    case 7: onCredit(at: at)
    case 8: lineOfTheBooks(at: at)
    case 9, 10: transfer(at: at)
    case 11: exchange(at: at)
    case 12, 13: refund()
    case 14: moneyBack(at: at)
    case 15: paidForSomebodyOrOnADebt(at: at)
    case 16, 17: journalLine(at: at)
    default: deletedOrLegacy(at: at)
    }
  }

  /// A purchase in a currency the account holds, sometimes split, sometimes with no account.
  mutating func purchase(at: Date) {
    let account = someAccount()
    let currency = held(by: account)
    let named: UUID? = dice.chance(15) ? nil : account.id
    let split = dice.chance(30)
    let parts =
      split
      ? [
        piece(dice.amount(upTo: 3000), category: categories.groceries),
        piece(dice.amount(upTo: 3000), category: categories.fuel),
      ] : [piece(dice.amount(upTo: 8000), category: categories.groceries)]
    let entry = add(.expense, at: at, currency: currency, account: named, parts: parts)
    expect(named, currency, -entry.transaction.amountE4, at: at, from: entry.id)
    for part in entry.parts {
      refundable.append(
        Refundable(
          partId: part.id, currency: currency, left: part.amountE4,
          account: named ?? Self.main.id, at: at))
    }
  }

  /// A purchase in a currency the account does not hold: the account's main currency moves by
  /// the charge — or, for a row of the time before charges, its own currency moves.
  mutating func foreignPurchase(at: Date) {
    let account = someAccount()
    let currency = notHeld(by: account)
    let amount = dice.amount(upTo: 500)
    if dice.chance(15) {
      let entry = add(
        .expense, at: at, currency: currency, account: account.id,
        parts: [piece(amount, category: categories.groceries)])
      expect(account.id, currency, -amount, at: at, from: entry.id)
      return
    }
    let charge = dice.amount(upTo: 50_000)
    let entry = add(
      .expense, at: at, currency: currency, account: account.id,
      parts: [piece(amount, category: categories.groceries)],
      leg: (account.mainCurrency, charge))
    expect(account.id, account.mainCurrency, -charge, at: at, from: entry.id)
    refundable.append(
      Refundable(
        partId: entry.parts[0].id, currency: currency, left: amount, account: account.id, at: at
      ))
  }

  /// Income, sometimes carrying what income stored before it lost those fields: a place, an
  /// event, a person, «за другого», credit. It comes in all the same.
  mutating func income(at: Date) {
    let account = someAccount()
    let legacy = dice.chance(40)
    let amount = dice.amount(upTo: 90_000)
    var part = piece(
      amount, category: categories.salary, reimbursable: legacy && dice.chance(50),
      forWhom: legacy ? .partner : .me, event: legacy ? id(400) : nil)
    if legacy { part.forPersonId = id(301) }
    if dice.chance(25) {
      let currency = notHeld(by: account)
      let charge = dice.amount(upTo: 90_000)
      let entry = add(
        .income, at: at, currency: currency, account: account.id, parts: [part],
        leg: (account.mainCurrency, charge), creditDebtId: legacy ? Self.loan.id : nil,
        placeId: legacy ? id(500) : nil)
      expect(account.id, account.mainCurrency, charge, at: at, from: entry.id)
    } else {
      let currency = held(by: account)
      let entry = add(
        .income, at: at, currency: currency, account: account.id, parts: [part],
        creditDebtId: legacy ? Self.loan.id : nil, placeId: legacy ? id(500) : nil)
      expect(account.id, currency, amount, at: at, from: entry.id)
    }
  }

  /// A purchase and a contribution to a goal in one operation: only the purchase leaves. In a
  /// currency the account does not hold, the account is charged in its main currency, and only
  /// the purchase's share of that charge leaves — the share the parts' amounts give it.
  mutating func partlyForAGoal(at: Date) {
    let account = someAccount()
    let foreign = dice.chance(40)
    let currency = foreign ? notHeld(by: account) : held(by: account)
    let bought = dice.amount(upTo: 4000)
    let saved = dice.amount(upTo: 4000)
    let goalFirst = dice.chance(50)
    let byGoalId = dice.chance(50)
    let goal =
      byGoalId
      ? piece(saved, category: categories.goals, goal: id(600))
      : piece(saved, category: categories.goalsTrip)
    let spent = piece(bought, category: categories.groceries)
    let parts = goalFirst ? [goal, spent] : [spent, goal]
    let charge: AmountE4? = foreign ? dice.amount(upTo: 90_000) : nil
    let entry = add(
      dice.chance(20) ? .refund : .expense, at: at, currency: currency, account: account.id,
      parts: parts, leg: charge.map { (account.mainCurrency, $0) })
    let leaves: AmountE4
    if let charge {
      let shares = charge.allocated(
        proportionallyTo: parts.map(\.amountE4), outOf: bought + saved)
      leaves = shares[goalFirst ? 1 : 0]
    } else {
      leaves = bought
    }
    let sign: AmountE4 = entry.transaction.kind == .expense ? -leaves : leaves
    expect(
      account.id, charge == nil ? currency : account.mainCurrency, sign, at: at, from: entry.id)
  }

  /// Money put into a goal, or taken back out of it: it stays on the accounts.
  mutating func onlyForAGoal(at: Date) {
    let account = someAccount()
    let parts = [
      piece(dice.amount(upTo: 20_000), category: categories.goalsTrip),
      piece(dice.amount(upTo: 20_000), category: categories.goals, goal: id(601)),
    ]
    add(
      dice.chance(30) ? .refund : .expense, at: at, currency: held(by: account),
      account: account.id, parts: Array(parts.prefix(dice.int(1...2))))
  }

  /// A purchase on credit: the debt grew, no money left.
  mutating func onCredit(at: Date) {
    add(
      .expense, at: at, currency: .rub, account: Self.main.id,
      parts: [piece(dice.amount(upTo: 90_000), category: categories.groceries)],
      creditDebtId: dice.chance(50) ? Self.laptop.id : Self.loan.id)
  }

  /// What the app writes to keep the books right moves no money.
  mutating func lineOfTheBooks(at: Date) {
    let some = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB") ?? UUID()
    let text = some.uuidString.lowercased()
    let keys = [
      ("reimb:\(text):surplus", TransactionKind.income),
      ("reimb:\(text):shortfall:\(text)", .expense),
      ("reconcile:\(text)", .expense),
      ("reconcile:\(text):\(text)", .income),
      ("writeoff:\(text):\(text)", .expense),
    ]
    let (key, kind) = dice.pick(keys)
    let account = someAccount()
    add(
      kind, at: at, currency: held(by: account), account: account.id,
      parts: [piece(dice.amount(upTo: 5000), category: categories.other)], externalId: key)
  }

  /// Money from one account and currency to another; sometimes with a fee the bank took.
  mutating func transfer(at: Date) {
    let keys = liveKeys
    let from = dice.pick(keys)
    let to = dice.pick(keys.filter { $0 != from })
    let sent = dice.amount(upTo: 30_000)
    let received = from.currency == to.currency ? sent : dice.amount(upTo: 300_000)
    let transferId = id(600_000 + number())
    transfers.append(
      Transfer(
        id: transferId, occurredAt: at, fromAccountId: from.accountId,
        fromCurrency: from.currency, fromAmountE4: sent, toAccountId: to.accountId,
        toCurrency: to.currency, toAmountE4: received))
    moves.append(Move(key: from, at: at, amount: -sent, source: .transferOut(transferId)))
    moves.append(Move(key: to, at: at, amount: received, source: .transferIn(transferId)))
    if dice.chance(40) {
      let fee = dice.amount(upTo: 300)
      let entry = add(
        .expense, at: at, currency: from.currency, account: from.accountId,
        parts: [piece(fee, category: categories.fees)],
        externalId: TransferRules.feeKey(of: transferId))
      expect(from.accountId, from.currency, -fee, at: at, from: entry.id)
    }
  }

  /// An exchange inside one account: rubles into tenge on Freedom.
  mutating func exchange(at: Date) {
    let sent = dice.amount(upTo: 50_000)
    let received = dice.amount(upTo: 300_000)
    let transferId = id(600_000 + number())
    let from = BalanceKey(accountId: Self.freedom.id, currency: .rub)
    let to = BalanceKey(accountId: Self.freedom.id, currency: Self.kzt)
    transfers.append(
      Transfer(
        id: transferId, occurredAt: at, fromAccountId: from.accountId, fromCurrency: .rub,
        fromAmountE4: sent, toAccountId: to.accountId, toCurrency: Self.kzt,
        toAmountE4: received))
    moves.append(Move(key: from, at: at, amount: -sent, source: .transferOut(transferId)))
    moves.append(Move(key: to, at: at, amount: received, source: .transferIn(transferId)))
  }

  /// A refund of an earlier purchase, whole or part of what is left of it, onto the purchase's
  /// account or another; at its own moment, by what came onto the account.
  mutating func refund() {
    let open = refundable.indices.filter { refundable[$0].left.raw > 0 }
    guard !open.isEmpty else {
      purchase(at: someMoment())
      return
    }
    let index = dice.pick(open)
    let bought = refundable[index]
    let at = bought.at.addingTimeInterval(TimeInterval(dice.int(1...30 * 24) * 3600))
    let amount =
      dice.chance(50) ? bought.left : AmountE4(raw: Int64(dice.int(1...Int(bought.left.raw))))
    refundable[index].left = bought.left - amount
    let account =
      dice.chance(60)
      ? (Self.accounts.first { $0.id == bought.account } ?? Self.main) : someAccount()
    let part = piece(amount, category: categories.groceries, refunding: bought.partId)
    if account.holds(bought.currency) {
      let entry = add(
        .refund, at: at, currency: bought.currency, account: account.id, parts: [part])
      expect(account.id, bought.currency, amount, at: at, from: entry.id)
    } else {
      let charge = dice.amount(upTo: 50_000)
      let entry = add(
        .refund, at: at, currency: bought.currency, account: account.id, parts: [part],
        leg: (account.mainCurrency, charge))
      expect(account.id, account.mainCurrency, charge, at: at, from: entry.id)
    }
  }

  /// Money a person gave back, or a repayment of money lent: it comes onto the account.
  mutating func moneyBack(at: Date) {
    let account = someAccount()
    let currency = held(by: account)
    let amount = dice.amount(upTo: 5000)
    var part = piece(amount)
    part.forPersonId = id(300)
    let entry = add(
      .reimbursement, at: at, currency: currency, account: account.id, parts: [part],
      debtId: dice.chance(30) ? Self.lent.id : nil)
    expect(account.id, currency, amount, at: at, from: entry.id)
  }

  /// A part paid for somebody else, whatever became of it, a payment on a debt, money lent:
  /// all of it left the account.
  mutating func paidForSomebodyOrOnADebt(at: Date) {
    let account = someAccount()
    let currency = held(by: account)
    let amount = dice.amount(upTo: 6000)
    let entry: TransactionEntry
    switch dice.below(3) {
    case 0:
      entry = add(
        .expense, at: at, currency: currency, account: account.id,
        parts: [
          piece(
            amount, category: categories.groceries, reimbursable: true,
            status: dice.pick(ReimbursementStatus.allCases), forWhom: .friends)
        ])
    case 1:
      entry = add(
        .expense, at: at, currency: currency, account: account.id,
        parts: [piece(amount, category: categories.loansCar)],
        debtId: dice.pick([Self.loan.id, Self.laptop.id]))
    default:
      entry = add(
        .expense, at: at, currency: currency, account: account.id, parts: [piece(amount)],
        debtId: Self.lent.id)
    }
    expect(account.id, currency, -amount, at: at, from: entry.id)
  }

  /// A line of a debt journal. Money borrowed through the journal alone comes onto its account
  /// — the main one when it names none —, money lent that way leaves it, by the figure the
  /// account moved when it does not hold the debt's currency; the line knows its moment, or its
  /// day only, or nothing. A line with an operation, a line of another kind, a line of a debt
  /// of a purchase, and the opening line a purchase on credit wrote move nothing.
  mutating func journalLine(at: Date) {
    let lineId = id(900_000 + number())
    let day = CalendarContext.utc.day(of: at)
    switch dice.below(6) {
    case 0, 1, 2:
      let debt = dice.chance(60) ? Self.friend : Self.lent
      let account = dice.chance(20) ? nil : someAccount()
      let holder = account ?? Self.main
      let amount = dice.amount(upTo: 3000)
      let leg: (CurrencyCode, AmountE4)? =
        holder.holds(debt.currency) ? nil : (holder.mainCurrency, dice.amount(upTo: 90_000))
      let timing = dice.below(10)
      journal.append(
        DebtEntry(
          id: lineId, debtId: debt.id, date: timing >= 6 && timing < 9 ? day : nil,
          amountE4: debt.direction == .owedToMe && dice.chance(50) ? -amount : amount,
          kind: .borrowed, paymentMethodId: account?.id, occurredAt: timing < 6 ? at : nil,
          accountCurrency: leg?.0, accountAmountE4: leg?.1))
      let magnitude = leg?.1 ?? amount
      moves.append(
        Move(
          key: BalanceKey(accountId: holder.id, currency: leg?.0 ?? debt.currency),
          at: timing < 6 ? at : CalendarContext.utc.startOfDay(day),
          amount: debt.direction == .owedToMe ? -magnitude : magnitude, source: .journal(lineId),
          dayOnly: timing >= 6 && timing < 9 ? day : nil, undated: timing >= 9))
    case 3:
      let kind = dice.pick([DebtEntryKind.payment, .adjustment])
      journal.append(
        DebtEntry(
          id: lineId, debtId: Self.friend.id, amountE4: -dice.amount(upTo: 500), kind: kind,
          occurredAt: at))
      journal.append(
        DebtEntry(
          id: id(900_000 + number()), debtId: Self.friend.id, amountE4: dice.amount(upTo: 500),
          kind: .borrowed, transactionId: id(1), occurredAt: at))
    case 4:
      journal.append(
        DebtEntry(
          id: lineId, debtId: Self.laptop.id, date: day, amountE4: dice.amount(upTo: 90_000),
          kind: .borrowed, occurredAt: at))
    default:
      // A purchase put on the credit card writes an opening line of the same day and amount.
      let amount = dice.amount(upTo: 20_000)
      add(
        .expense, at: at, currency: .rub, account: Self.main.id,
        parts: [piece(amount, category: categories.groceries)], creditDebtId: Self.creditCard.id,
        deleted: dice.chance(15))
      journal.append(
        DebtEntry(
          id: lineId, debtId: Self.creditCard.id, date: day, amountE4: amount, kind: .borrowed))
    }
  }

  /// A deleted operation of any kind moves nothing.
  mutating func deletedOrLegacy(at: Date) {
    let account = someAccount()
    add(
      dice.pick(TransactionKind.allCases), at: at, currency: held(by: account),
      account: account.id, parts: [piece(dice.amount(upTo: 9000), category: categories.groceries)],
      deleted: true)
  }

  // MARK: Counts

  /// Counts made at moments up to now, in the order of the book: most count accounts, some
  /// open them, a few are totals of the time before accounts — with rows that anchor nothing.
  mutating func addCounts(_ count: Int) {
    let moments = (0..<count).map { _ in
      start.addingTimeInterval(TimeInterval(dice.below(60 * 1440) * 60))
    }.sorted()
    let outside = BalanceKey(accountId: Self.dollars.id, currency: .rub)
    for at in moments {
      let kind = dice.pick([
        ReconciliationKind.accounts, .accounts, .accounts, .opening, .total,
      ])
      let recNumber = number()
      reconciliations.append(
        Reconciliation(
          id: id(700_000 + recNumber), date: CalendarContext.utc.day(of: at), reconciledAt: at,
          actualTotalRubE4: .zero, kind: kind))
      for key in liveKeys + [outside] where dice.chance(55) {
        counted.append(
          ReconciledBalance(
            id: id(800_000 + number()), reconciliationId: id(700_000 + recNumber),
            accountId: key.accountId, currency: key.currency,
            actualE4: dice.chance(10) ? .zero : dice.amount(upTo: 400_000)))
      }
    }
  }

  // MARK: The model's answers

  /// Every count of the key that anchors a balance, in the order of the book, with its moment.
  func anchors(of key: BalanceKey) -> [(balance: ReconciledBalance, at: Date)] {
    let byId = Dictionary(uniqueKeysWithValues: reconciliations.map { ($0.id, $0) })
    return counted.compactMap { balance in
      guard balance.key == key, let reconciliation = byId[balance.reconciliationId],
        reconciliation.kind != .total, let at = reconciliation.reconciledAt
      else { return nil }
      return (balance, at)
    }
  }

  /// The latest count of the key made by `instant`, and the moves after it and up to then.
  func expected(
    _ key: BalanceKey, at instant: Date
  ) -> (
    anchor: ReconciledBalance?, moves: [Move]
  ) {
    let found = anchors(of: key).last { $0.at <= instant }
    let anchorDay = found.map { CalendarContext.utc.day(of: $0.at) }
    let after = moves.filter { move in
      guard move.key == key, !move.undated else { return false }
      if let day = move.dayOnly, day == anchorDay { return false }
      return move.at <= instant && (found.map { move.at > $0.at } ?? true)
    }
    return (found?.balance, after)
  }

  /// The journal lines of the key left out of its balance now: those of the day of its latest
  /// count, and those with no date.
  func leftOut(_ key: BalanceKey) -> (onAnchorDay: Int, undated: Int) {
    let anchorDay = anchors(of: key).last.map { CalendarContext.utc.day(of: $0.at) }
    let lines = moves.filter { $0.key == key }
    return (
      lines.filter { $0.dayOnly != nil && $0.dayOnly == anchorDay }.count,
      lines.filter(\.undated).count
    )
  }

  func expectedAmount(_ key: BalanceKey, at instant: Date) -> AmountE4? {
    let (anchor, after) = expected(key, at: instant)
    return anchor.map { $0.actualE4 + AmountE4.sum(after.map(\.amount)) }
  }

  var expectedKeys: [BalanceKey] {
    var keys = Set(liveKeys)
    keys.formUnion(moves.map(\.key))
    for balance in counted {
      guard
        let reconciliation = reconciliations.first(where: { $0.id == balance.reconciliationId }),
        reconciliation.kind != .total
      else { continue }
      keys.insert(balance.key)
    }
    return keys.sorted()
  }

  // MARK: The code under test

  func build(
    entries: [TransactionEntry]? = nil, transfers: [Transfer]? = nil,
    journal: [DebtEntry]? = nil, now: Date? = nil,
    reconciliations: [Reconciliation]? = nil, counted: [ReconciledBalance]? = nil
  ) -> AccountBalances {
    AccountBalances.build(
      entries: entries ?? self.entries, transfers: transfers ?? self.transfers,
      debtEntries: journal ?? self.journal,
      debts: Self.debts, reconciliations: reconciliations ?? self.reconciliations,
      balances: counted ?? self.counted, accounts: Self.accounts, tree: categories.tree,
      now: now ?? self.now, calendar: .utc)
  }
}

/// The balance engine against the model of `MoneyHistory`, on forty random histories each.
@Suite("Balances against a model of the money")
struct AccountBalancesPropertyTests {
  static let seeds: [UInt64] = Array(1...40)

  /// Every key: the latest count, plus every move after it and up to now — the sum, the moves
  /// themselves and their order; never counted, no balance but the moves still listed.
  @Test(arguments: seeds)
  func everyBalanceIsItsLatestCountPlusWhatMovedAfterIt(seed: UInt64) {
    let history = MoneyHistory(seed: seed)
    check(history.build(), against: history, seed: seed)
  }

  private func check(_ balances: AccountBalances, against history: MoneyHistory, seed: UInt64) {
    #expect(balances.keys == history.expectedKeys, "seed \(seed)")
    #expect(balances.unassignedOperations == 0, "seed \(seed)")
    for key in history.expectedKeys {
      let (anchor, moves) = history.expected(key, at: history.now)
      let balance = balances[key]
      #expect(balance?.anchor?.id == anchor?.id, "seed \(seed), \(key)")
      #expect(
        balance?.movedSinceAnchor == AmountE4.sum(moves.map(\.amount)), "seed \(seed), \(key)")
      #expect(
        balance?.amountE4 == history.expectedAmount(key, at: history.now), "seed \(seed), \(key)")
      #expect(
        Set(balance?.movements.map(\.source) ?? []) == Set(moves.map(\.source)),
        "seed \(seed), \(key)")
      let times = balance?.movements.map(\.at) ?? []
      #expect(times == times.sorted(), "seed \(seed), \(key): moves are oldest first")
      let left = history.leftOut(key)
      #expect(balance?.journalLinesOnAnchorDay == left.onAnchorDay, "seed \(seed), \(key)")
      #expect(balance?.undatedJournalLines == left.undated, "seed \(seed), \(key)")
    }
  }

  /// The balance at any moment — before the first count, between counts, on the moment of a
  /// move, ahead of now — follows the same rule.
  @Test(arguments: seeds)
  func theBalanceAtAnyMomentFollowsTheSameRule(seed: UInt64) {
    var history = MoneyHistory(seed: seed)
    let balances = history.build()
    var instants = history.moves.prefix(10).map(\.at)
    instants += history.reconciliations.compactMap(\.reconciledAt)
    for _ in 0..<12 {
      instants.append(
        history.start.addingTimeInterval(TimeInterval(history.dice.below(80 * 1440) * 60)))
    }
    for instant in instants {
      for key in history.expectedKeys {
        #expect(
          balances.balance(key, at: instant) == history.expectedAmount(key, at: instant),
          "seed \(seed), \(key), \(instant)")
      }
    }
  }

  /// The order operations and transfers are handed over in changes nothing.
  @Test(arguments: seeds)
  func theOrderOfTheRecordsChangesNothing(seed: UInt64) {
    var history = MoneyHistory(seed: seed)
    let first = history.build()
    let entries = history.dice.shuffled(history.entries)
    let transfers = history.dice.shuffled(history.transfers)
    #expect(history.build(entries: entries, transfers: transfers) == first, "seed \(seed)")
  }

  /// Deleting operations takes exactly their moves out; bringing them back (⌘Z) gives the very
  /// balances of before.
  @Test(arguments: seeds)
  func deletingAndBringingBackIsExact(seed: UInt64) {
    var history = MoneyHistory(seed: seed)
    let before = history.build()
    var gone: Set<UUID> = []
    var deleted = history.entries
    for index in deleted.indices
    where !deleted[index].transaction.isDeleted && history.dice.chance(25) {
      gone.insert(deleted[index].id)
      deleted[index].transaction.deletedAt = history.now
    }
    var trimmed = history
    trimmed.entries = deleted
    trimmed.moves = history.moves.filter { move in
      guard case .operation(let id) = move.source else { return true }
      return !gone.contains(id)
    }
    check(trimmed.build(), against: trimmed, seed: seed)
    var restored = deleted
    for index in restored.indices where gone.contains(restored[index].id) {
      restored[index].transaction.deletedAt = nil
    }
    #expect(history.build(entries: restored) == before, "seed \(seed)")
  }

  /// Right after a count of every key the balances are the count exactly, whatever moved before.
  @Test(arguments: seeds)
  func rightAfterACountTheBalancesAreTheCount(seed: UInt64) {
    var history = MoneyHistory(seed: seed)
    let at = history.now
    let count = Reconciliation(
      id: id(999_999), date: CalendarContext.utc.day(of: at), reconciledAt: at,
      actualTotalRubE4: .zero, kind: .accounts)
    var rows: [ReconciledBalance] = []
    for (index, key) in history.expectedKeys.enumerated() {
      rows.append(
        ReconciledBalance(
          id: id(990_000 + index), reconciliationId: count.id, accountId: key.accountId,
          currency: key.currency, actualE4: history.dice.amount(upTo: 100_000)))
    }
    let balances = history.build(
      reconciliations: history.reconciliations + [count], counted: history.counted + rows)
    for row in rows {
      #expect(balances[row.key]?.amountE4 == row.actualE4, "seed \(seed), \(row.key)")
      #expect(balances[row.key]?.movements.isEmpty == true, "seed \(seed), \(row.key)")
    }
  }

  /// Money moved between the owner's own keys in one currency is neither made nor lost: without
  /// operations, the balances of a currency add up to what was counted of it.
  @Test(arguments: seeds)
  func transfersInOneCurrencyNeitherMakeNorLoseMoney(seed: UInt64) {
    let history = MoneyHistory(seed: seed)
    let sameCurrency = history.transfers.filter { !$0.isExchange }
    let balances = history.build(
      entries: [], transfers: sameCurrency, journal: [], reconciliations: [], counted: [])
    var byCurrency: [CurrencyCode: AmountE4] = [:]
    for key in balances.keys {
      byCurrency[key.currency, default: .zero] += balances[key]?.movedSinceAnchor ?? .zero
    }
    for (currency, total) in byCurrency {
      #expect(total == .zero, "seed \(seed), \(currency)")
    }
  }
}

/// What an operation part of which goes to a goal moves, on random splits and charges.
@Suite("The share of a charge that leaves for a purchase")
struct GoalShareOfAChargeTests {
  let categories = StartingCategories()

  /// Only the parts that are not money for a goal leave the account: their share of the charge,
  /// within a unit of rounding per part of the exact share; no goal part — the whole charge;
  /// only goal parts — nothing at all. A refund put back the same share.
  @Test(arguments: Array(1...60) as [UInt64])
  func onlyTheShareOfThePurchaseLeaves(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let count = dice.int(2...4)
    var parts: [TransactionPart] = []
    var goal: [Bool] = []
    for index in 0..<count {
      let isGoal = dice.chance(45)
      goal.append(isGoal)
      parts.append(
        TransactionPart(
          id: id(10 + index), transactionId: id(1),
          categoryId: isGoal ? categories.goalsTrip : categories.groceries,
          amountE4: dice.fineAmount(upTo: 900)))
    }
    let total = AmountE4.sum(parts.map(\.amountE4))
    let charge = dice.fineAmount(upTo: 90_000)
    let kind: TransactionKind = dice.chance(25) ? .refund : .expense
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id(1), kind: kind, occurredAt: moment("2026-03-02"), currency: .usd,
        amountE4: total, paymentMethodId: id(1), accountCurrency: .rub, accountAmountE4: charge),
      parts: parts)
    let moved = AccountBalances.movement(of: entry, mainId: id(1), tree: categories.tree)
    let spent = AmountE4.sum(zip(parts, goal).filter { !$0.1 }.map(\.0.amountE4))
    guard !spent.isZero else {
      #expect(moved == nil, "seed \(seed)")
      return
    }
    guard let moved else {
      Issue.record("seed \(seed): a purchase part moved nothing")
      return
    }
    let magnitude = kind == .expense ? -moved.amountE4 : moved.amountE4
    #expect(moved.key == BalanceKey(accountId: id(1), currency: .rub), "seed \(seed)")
    if spent == total {
      #expect(magnitude == charge, "seed \(seed)")
    } else {
      let exact = charge.decimal * spent.decimal / total.decimal
      let difference = abs((magnitude.decimal - exact) * 10_000)
      #expect(difference <= Decimal(count), "seed \(seed): \(magnitude.decimal) vs \(exact)")
      #expect(magnitude.raw >= 0 && magnitude <= charge, "seed \(seed)")
    }
  }
}
