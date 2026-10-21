import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The credit of the sample, after the capital:
  ///
  /// * every debt of the set marked reviewed (`termsReviewed`): the sample is written by this
  ///   version, so nothing in it is a debt of an older one to ask about;
  /// * the main account's own card made its main card — the account has two —;
  /// * «Кредитка Т-Банка», an account of the bank «Т-Банк» with its terms (limit 150,000, the
  ///   statement on the 5th due in 25 days, 29.9 % on purchases, 49.9 % on cash with no grace
  ///   period, the minimum 8 % and not below 600, the fee for cash 2.9 % + 290): opened with a
  ///   first count at zero twenty days before its latest statement, three purchases in the
  ///   period of that statement, which the main account pays in full before it is due, one
  ///   purchase after it, and cash taken to the cash account with the bank's fee after the
  ///   cash's later count — the card paid off whole from the main account that evening, so it
  ///   ends at zero;
  /// * «Пылесос», 12,000 in four parts every two weeks, the first paid on the day of the
  ///   purchase — the next due is after the last day;
  /// * an early repayment of 50,000 «a shorter term» of the bank loan, and the insurance of that
  ///   loan paid once on the day it began, long before the history;
  /// * «Залог за квартиру», 30,000 owed back to me in four months.
  ///
  /// Every row that moves money on an account counted before is dated after that account's last
  /// count, so the counts still find what they found. The layer draws from streams of its own; a
  /// history shorter than two months gets only the marks.
  func withCreditLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: Self.creditLayerTag, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    var set = self
    for index in set.debts.indices { set.debts[index].termsReviewed = true }
    guard Self.days(from: firstDay, to: lastDay, calendar: calendar) >= Self.creditMinimumDays,
      let main = mainAccount
    else { return set }
    if let index = set.paymentMethods.firstIndex(where: { $0.id == main.id }) {
      let own = CardsMigration.cardId(forAccount: main.id)
      let live = cards.filter { $0.accountId == main.id && !$0.archived }
      if live.count >= 2, live.contains(where: { $0.id == own }) {
        set.paymentMethods[index].mainCardId = own
      }
    }
    set.addTBankCreditCard(layer: layer, main: main)
    set.addInstalmentPlan(layer: layer, main: main)
    set.addEarlyRepayment(layer: layer, main: main)
    set.addPledge(layer: layer)
    return set
  }

  /// «CREDIT19»: the tag of the credit layer's streams.
  static let creditLayerTag: UInt64 = 0x4352_4544_4954_3139
  /// The shortest history that gets the credit card, the plan, the early repayment and the pledge.
  static let creditMinimumDays = 60

  /// The terms of the credit card of «Т-Банк».
  public static let tBankTerms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
    purchaseRate: Decimal(string: "29.9"), cashRate: Decimal(string: "49.9"),
    minPercent: Decimal(8), minFloorE4: AmountE4(whole: 600),
    cashFeePercent: Decimal(string: "2.9"), cashFeeFixedE4: AmountE4(whole: 290),
    cashWithoutGrace: true)
  /// The price of the vacuum cleaner and its parts.
  static let instalmentPrice = AmountE4(whole: 12_000)
  static let instalmentParts = 4
  static let instalmentEveryDays = 14
  /// The early repayment of the bank loan, and the pledge.
  static let earlyRepayment = AmountE4(whole: 50_000)
  static let pledgeAmount = AmountE4(whole: 30_000)
  /// The cash taken from the credit card.
  public static let cashTaken = AmountE4(whole: 5_000)

  /// The latest statement day of the credit card before the last day: the 5th of the last day's
  /// month when that is over, else of the month before.
  public static func latestStatement(before lastDay: DateOnly) -> DateOnly {
    let month = lastDay.day > 5 ? lastDay.monthKey : lastDay.monthKey.previous
    return DateOnly(year: month.year, month: month.month, day: 5)
  }

  /// The bank «Т-Банк» of the sample: the one already there, else a new one.
  mutating func tBank(layer: SampleLayer) -> Bank {
    let name = layer.word("T-Bank", "Т-Банк")
    if let bank = banks.first(where: { $0.name == name }) { return bank }
    var rng = layer.stream("t-bank")
    let bank = Bank(id: rng.nextUUID(), name: name)
    banks.append(bank)
    return bank
  }

  /// A new account of «Т-Банк» with a card named like it and a first count at zero at 09:00 of
  /// `openedOn`.
  mutating func openTBankAccount(
    _ name: String, credit: CreditCardTerms?, openedOn: DateOnly, main: PaymentMethod,
    layer: SampleLayer, stream feature: String
  ) -> PaymentMethod {
    let bank = tBank(layer: layer)
    var rng = layer.stream(feature)
    let account = PaymentMethod(
      id: rng.nextUUID(), name: name, kind: .card, currency: .rub, groupId: main.groupId,
      sort: (paymentMethods.map(\.sort).max() ?? 0) + 1, bankId: bank.id, credit: credit)
    paymentMethods.append(account)
    cards.append(
      PaymentCard(
        id: CardsMigration.cardId(forAccount: account.id), accountId: account.id,
        name: account.name))
    let opening = Reconciliation(
      id: rng.nextUUID(), date: openedOn, reconciledAt: layer.moment(openedOn, hour: 9, minute: 0),
      actualTotalRubE4: .zero, kind: .opening, origin: .account)
    reconciliations.append(opening)
    reconciledBalances.append(
      ReconciledBalance(
        id: rng.nextUUID(), reconciliationId: opening.id, accountId: account.id, currency: .rub,
        actualE4: .zero))
    accountExpectations[BalanceKey(accountId: account.id, currency: .rub)] = .zero
    return account
  }

  /// A transfer joins the set in time order, and the money of both accounts moves with it.
  mutating func addTransfer(_ transfer: Transfer) {
    transfers.append(transfer)
    transfers.sort { left, right in
      left.occurredAt != right.occurredAt
        ? left.occurredAt < right.occurredAt : left.id.uuidString < right.id.uuidString
    }
    let from = BalanceKey(accountId: transfer.fromAccountId, currency: transfer.fromCurrency)
    let to = BalanceKey(accountId: transfer.toAccountId, currency: transfer.toCurrency)
    accountExpectations[from] = (accountExpectations[from] ?? .zero) - transfer.fromAmountE4
    accountExpectations[to] = (accountExpectations[to] ?? .zero) + transfer.toAmountE4
  }

  // MARK: The credit card

  private mutating func addTBankCreditCard(layer: SampleLayer, main: PaymentMethod) {
    let calendar = layer.calendar
    let statement = Self.latestStatement(before: lastDay)
    let openedOn = calendar.adding(days: -20, to: statement)
    guard openedOn > firstDay,
      let cash = paymentMethods.first(where: { $0.kind == .cash && !$0.isDefault && !$0.archived }),
      let fees = starter("Fees")
    else { return }
    let card = openTBankAccount(
      layer.word("T-Bank credit card", "Кредитка Т-Банка"), credit: Self.tBankTerms,
      openedOn: openedOn, main: main, layer: layer, stream: "t-bank credit card")

    // The purchases of the period of the latest statement, and one after it.
    let buys: [(day: DateOnly, english: String, note: (String, String), range: ClosedRange<Int>)] =
      [
        (calendar.adding(days: 3, to: openedOn), "Groceries", ("Groceries", "Продукты"), 25...45),
        (
          calendar.adding(days: 9, to: openedOn), "Electronics", ("Headphones", "Наушники"), 40...90
        ),
        (calendar.adding(days: -2, to: statement), "Restaurants", ("Dinner out", "Ужин"), 15...35),
        (
          min(calendar.adding(days: 3, to: statement), lastDay), "Coffee shops", ("Coffee", "Кофе"),
          3...6
        ),
      ]
    var owed = AmountE4.zero
    for buy in buys {
      guard let category = starter(buy.english) else { continue }
      var rng = layer.stream("t-bank purchase", on: buy.day)
      let amount = AmountE4(whole: Int64(rng.int(in: buy.range)) * 100)
      let entry = layer.purchase(
        amount, of: category.category, parent: category.parent,
        at: layer.moment(on: buy.day, rng: &rng), account: card.id,
        note: layer.word(buy.note.0, buy.note.1), rng: &rng)
      add(entry, calendar: calendar)
      if buy.day <= statement { owed += amount }
    }

    // The statement paid in full from the main account, after its count and before it is due.
    let paidOn = min(
      max(calendar.adding(days: 2, to: statement), layer.daysBeforeEnd(13) ?? lastDay), lastDay)
    var paidStream = layer.stream("t-bank statement paid", on: paidOn)
    let paidAt = layer.moment(paidOn, hour: 9, minute: 15)
    addTransfer(
      Transfer(
        id: paidStream.nextUUID(), occurredAt: paidAt, fromAccountId: main.id, fromCurrency: .rub,
        fromAmountE4: owed, toAccountId: card.id, toCurrency: .rub, toAmountE4: owed,
        note: layer.word("Credit card statement", "Погашение выписки"), createdAt: paidAt,
        updatedAt: paidAt))

    // Cash from the credit card, after the cash's later count, with the bank's fee.
    let takenOn = max(calendar.adding(days: 1, to: statement), layer.daysBeforeEnd(2) ?? lastDay)
    var cashStream = layer.stream("t-bank cash", on: takenOn)
    let takenAt = layer.moment(takenOn, hour: 12, minute: 30)
    let transfer = Transfer(
      id: cashStream.nextUUID(), occurredAt: takenAt, fromAccountId: card.id, fromCurrency: .rub,
      fromAmountE4: Self.cashTaken, toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: Self.cashTaken, note: layer.word("Cash", "Снятие наличных"), createdAt: takenAt,
      updatedAt: takenAt)
    addTransfer(transfer)
    let fee =
      InterestMath.cents(Self.cashTaken.decimal * (Self.tBankTerms.cashFeePercent ?? 0) / 100)
      + (Self.tBankTerms.cashFeeFixedE4 ?? .zero)
    var charge = layer.purchase(
      fee, of: fees.category, parent: fees.parent, at: takenAt, account: card.id,
      rng: &cashStream)
    charge.parts[0].categorySource = .system
    charge.transaction.externalId = TransferRules.feeKey(of: transfer.id)
    add(charge, calendar: calendar)

    // That evening the whole card is paid off from the main account, ahead of the next
    // statement: it ends at zero, as every account of the sample but the old credit card ends
    // at zero or above. The interest on the cash, charged from its first day, stays an estimate.
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let left = .zero - (accountExpectations[key] ?? .zero)
    guard left.raw > 0 else { return }
    var payOffStream = layer.stream("t-bank paid off", on: takenOn)
    let paidOffAt = max(layer.moment(takenOn, hour: 19, minute: 0), takenAt)
    addTransfer(
      Transfer(
        id: payOffStream.nextUUID(), occurredAt: paidOffAt, fromAccountId: main.id,
        fromCurrency: .rub, fromAmountE4: left, toAccountId: card.id, toCurrency: .rub,
        toAmountE4: left, note: layer.word("Credit card paid off", "Погашение кредитки"),
        createdAt: paidOffAt, updatedAt: paidOffAt))
  }

  // MARK: The instalment plan

  private mutating func addInstalmentPlan(layer: SampleLayer, main: PaymentMethod) {
    let calendar = layer.calendar
    guard let day = layer.daysBeforeEnd(8), let household = starter("Household"),
      let loans = starter("Loans")?.category
    else { return }
    var rng = layer.stream("instalment plan", on: day)
    let name = layer.word("Vacuum cleaner", "Пылесос")
    var purchase = layer.purchase(
      Self.instalmentPrice, of: household.category, parent: household.parent,
      at: layer.moment(day, hour: 13, minute: rng.int(in: 0...59)), account: main.id, note: name,
      rng: &rng)
    let debt = Debt(
      id: rng.nextUUID(), direction: .iOwe, type: .installment, name: name, currency: .rub,
      paymentsAreExpenses: false, origin: .purchase,
      steps: DebtSteps(everyDays: Self.instalmentEveryDays, firstDue: day),
      parts: Self.instalmentParts, termsReviewed: true)
    purchase.transaction.creditDebtId = debt.id
    debts.append(debt)
    debtEntries.append(
      DebtRules.makeEntry(
        id: rng.nextUUID(), debtId: debt.id, kind: .borrowed, amountE4: Self.instalmentPrice,
        date: day, transactionId: purchase.id))
    spendOnCredit(purchase, calendar: calendar)

    // The first part, paid the same day: money gone from the main account, no spending.
    let part = AmountE4(raw: Self.instalmentPrice.raw / Int64(Self.instalmentParts))
    let paidAt = layer.moment(day, hour: 18, minute: rng.int(in: 0...59))
    let payment = debtPayment(
      part, on: debt, category: loans, at: paidAt, account: main.id,
      note: layer.word("Vacuum cleaner instalment", "Платёж за пылесос"), rng: &rng)
    debtEntries.append(
      DebtRules.makeEntry(
        id: rng.nextUUID(), debtId: debt.id, kind: .payment, amountE4: part, date: day,
        transactionId: payment.id))
    payFromAccount(payment)
  }

  // MARK: The bank loan

  private mutating func addEarlyRepayment(layer: SampleLayer, main: PaymentMethod) {
    let calendar = layer.calendar
    guard
      let loan = debts.first(where: {
        $0.direction == .iOwe && $0.type == .loan && $0.paymentsAreExpenses && !$0.accruesInterest
          && $0.loansSubcategoryId != nil
      }),
      let subcategory = categories.first(where: { $0.id == loan.loansSubcategoryId }),
      let began = debtEntries.filter({ $0.debtId == loan.id }).compactMap(\.date).min()
    else { return }

    // The insurance of the loan, paid once on the day it began — long before the history, so
    // no operation of it is here and its days to cancel are long gone.
    var costStream = layer.stream("loan insurance")
    debtCosts.append(
      DebtCost(
        id: costStream.nextUUID(), debtId: loan.id, kind: .insurance,
        amountE4: AmountE4(whole: Int64(costStream.int(in: 8...14)) * 1_000), every: .once,
        day: began))

    guard let day = layer.daysBeforeEnd(10),
      DebtRules.balance(of: loan.id, entries: debtEntries) > Self.earlyRepayment
    else { return }
    var rng = layer.stream("early repayment", on: day)
    let at = layer.moment(day, hour: 12, minute: rng.int(in: 0...59))
    let payment = debtPayment(
      Self.earlyRepayment, on: loan, category: subcategory, at: at, account: main.id,
      note: layer.word("Early repayment", "Досрочное погашение"), rng: &rng)
    var line = DebtRules.makeEntry(
      id: rng.nextUUID(), debtId: loan.id, kind: .payment, amountE4: Self.earlyRepayment,
      date: day, description: payment.transaction.note, transactionId: payment.id)
    line.prepay = .term
    debtEntries.append(line)
    // A loan I had before the app: its payments are my spending in its subcategory.
    add(payment, calendar: calendar)
  }

  // MARK: The pledge

  private mutating func addPledge(layer: SampleLayer) {
    let calendar = layer.calendar
    guard let given = layer.daysBeforeEnd(40) else { return }
    var rng = layer.stream("pledge", on: given)
    let back = given.monthKey.next.next.next.next
    let returnBy = DateOnly(
      year: back.year, month: back.month, day: min(given.day, calendar.daysInMonth(back)))
    let pledge = Debt(
      id: rng.nextUUID(), direction: .owedToMe, type: .personal,
      name: layer.word("Rental deposit", "Залог за квартиру"), paymentsAreExpenses: false,
      origin: .existing, pledge: true, returnBy: returnBy, termsReviewed: true)
    debts.append(pledge)
    // Given when the flat was rented: the debt is set, no money moves inside the history.
    debtEntries.append(
      DebtRules.makeEntry(
        id: rng.nextUUID(), debtId: pledge.id, kind: .adjustment, amountE4: Self.pledgeAmount,
        date: given, description: pledge.name))
  }

  // MARK: Rows

  /// An expense paying `debt` from `account` in `category` — the category the app files the
  /// payment in (`system`).
  func debtPayment(
    _ amount: AmountE4, on debt: Debt, category: CoreKit.Category, at moment: Date,
    account: UUID, note: String, rng: inout SeededRandom
  ) -> TransactionEntry {
    let id = rng.nextUUID()
    let parent = category.parentId.flatMap { parent in categories.first { $0.id == parent } }
    let part = TransactionPart(
      id: rng.nextUUID(), transactionId: id, categoryId: category.id, categorySource: .system,
      quality: category.quality ?? parent?.quality ?? .neutral, qualitySource: .category,
      amountE4: amount, amountRubE4: amount)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: amount, amountRubE4: amount,
        note: note, paymentMethodId: account, debtId: debt.id, createdAt: moment,
        updatedAt: moment),
      parts: [part])
  }

  /// An operation joins the set in time order after what it already has at its moment.
  mutating func insertInTime(_ entry: TransactionEntry) {
    let index =
      entries.firstIndex { $0.transaction.occurredAt > entry.transaction.occurredAt }
      ?? entries.endIndex
    entries.insert(entry, at: index)
  }

  /// A purchase on credit: my spending of its month, and no money moved on its account.
  mutating func spendOnCredit(_ entry: TransactionEntry, calendar: CalendarContext) {
    insertInTime(entry)
    let month = calendar.day(of: entry.transaction.occurredAt).monthKey
    let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for part in entry.parts {
      let category = part.categoryId.flatMap { byId[$0] }
      expectations.spend(
        part.amountRubE4, in: month, root: category.map { $0.parentId ?? $0.id },
        quality: part.quality ?? .neutral)
    }
  }

  /// A payment of a debt whose payments are not expenses: money gone from its account, and no
  /// spending.
  mutating func payFromAccount(_ entry: TransactionEntry) {
    insertInTime(entry)
    guard let account = entry.transaction.paymentMethodId else { return }
    let key = BalanceKey(accountId: account, currency: entry.transaction.currency)
    accountExpectations[key] = (accountExpectations[key] ?? .zero) - entry.transaction.amountE4
  }
}
