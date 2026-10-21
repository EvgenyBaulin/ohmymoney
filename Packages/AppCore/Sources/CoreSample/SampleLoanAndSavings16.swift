import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// An education loan and a savings account, after the later count:
  ///
  /// * «Образовательный кредит» under the state programme: 3 %, the bank charging interest day
  ///   by day, the grace payments of the programme (a share of the interest — 40 % in the first
  ///   year), the main schedule from the first day of the month two years ahead, repaid over 180
  ///   months. Two tranches, each an expense in «Образование» on the loan the way a purchase on
  ///   credit is — spending once, no money moved — with the line of the journal that grows the
  ///   debt naming it (`DebtRules.tranche`). Every grace due up to the last day is paid, exactly
  ///   what it asks for: the first from the savings account, the second from the main one. A
  ///   grace payment is all interest, so beside each the app's interest operation is written —
  ///   an expense of all of it in the loan's subcategory of «Кредиты», on the loan as a purchase
  ///   on credit is, keyed `debtinterest:<payment>:<itself>` — and the payment itself is no
  ///   spending, since the loan's payments are not expenses.
  /// * «Накопительный счёт», 16 % paid monthly on the day it was opened and kept on it
  ///   (capitalised): its first count when it was opened, the first month's interest recorded as
  ///   income in the category of interest (remembered under `accounts.interestCategory`), and a
  ///   top-up from the main account a few days before the last day.
  ///
  /// Every row that moves money on an account counted before is dated after that account's last
  /// count, so the counts still find what they found. The layer draws from streams of its own;
  /// a history too short for the loan's first tranche gets nothing from it.
  func withLoanAndSavingsLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: 0x0016_10A2_5A7E_0016, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    guard let main = mainAccount, let education = starter("Education"),
      let loans = starter("Loans")?.category, let interest = starter("Interest", .income),
      let dates = LoanAndSavingsDates(lastDay: lastDay, calendar: calendar),
      dates.firstTranche > firstDay, let toppedUpOn = layer.daysBeforeEnd(3)
    else { return self }
    var set = self

    // The savings account, opened with what the bank said was on it.
    var accountStream = layer.stream("savings account")
    let savings = PaymentMethod(
      id: accountStream.nextUUID(), name: layer.word("Savings account", "Накопительный счёт"),
      kind: .account, currency: .rub, groupId: main.groupId,
      sort: (paymentMethods.map(\.sort).max() ?? 0) + 1, bankId: main.bankId,
      interest: DepositTerms(
        rate: Self.savingsRate, period: .monthly, openedOn: dates.savingsOpened))
    set.paymentMethods.append(savings)
    let savingsKey = BalanceKey(accountId: savings.id, currency: .rub)
    var openingStream = layer.stream("savings opened", on: dates.savingsOpened)
    let deposited = AmountE4(whole: Int64(openingStream.int(in: 15...25)) * 10_000)
    let opening = Reconciliation(
      id: openingStream.nextUUID(), date: dates.savingsOpened,
      reconciledAt: layer.moment(dates.savingsOpened, hour: 10, minute: 0),
      actualTotalRubE4: .zero, kind: .opening, origin: .account)
    set.reconciliations.append(opening)
    set.reconciledBalances.append(
      ReconciledBalance(
        id: openingStream.nextUUID(), reconciliationId: opening.id, accountId: savings.id,
        currency: .rub, actualE4: deposited))
    set.accountExpectations[savingsKey] = deposited
    if set.settings[AccountSettings.interestCategoryKey] == nil {
      set.settings[AccountSettings.interestCategoryKey] = interest.category.id.uuidString
    }

    // The loan, filed under «Кредиты» the way the app files a loan.
    var loanStream = layer.stream("education loan")
    let name = layer.word("Education loan", "Образовательный кредит")
    let subcategory = CoreKit.Category(
      id: loanStream.nextUUID(), parentId: loans.id, kind: .expense, name: name,
      sort: categories.filter { $0.parentId == loans.id }.count)
    set.categories.append(subcategory)
    let loan = Debt(
      id: loanStream.nextUUID(), direction: .iOwe, type: .loan, name: name,
      interestRate: Self.educationLoanRate, paymentDay: dates.payday, paymentsAreExpenses: false,
      origin: .existing, loansSubcategoryId: subcategory.id, accruesInterest: true,
      grace: DebtGrace(mainFrom: dates.mainFrom, payment: .programme),
      repayMonths: Self.educationLoanMonths)
    set.debts.append(loan)

    // The tranches: a term of tuition each, the expense of the day it was drawn.
    var drawn: [(from: DateOnly, amount: AmountE4)] = []
    var total = AmountE4.zero
    for day in [dates.firstTranche, dates.secondTranche] {
      var rng = layer.stream("tranche", on: day)
      let amount = AmountE4(whole: Int64(rng.int(in: 30...44)) * 5_000)
      let operation = layer.purchase(
        amount, of: education.category, parent: education.parent,
        at: layer.clamped(calendar.startOfDay(day).addingTimeInterval(12 * 3_600)),
        account: main.id, note: name, rng: &rng)
      var entry = operation
      entry.transaction.creditDebtId = loan.id
      entry.parts[0].categorySource = .system
      guard
        let line = try? DebtRules.tranche(
          on: loan, amount: amount, date: day, transactionId: entry.id, entryId: rng.nextUUID())
      else { continue }
      set.debtEntries.append(line)
      set.addOnCredit(entry, calendar: calendar)
      total += amount
      drawn.append((day, total))
    }

    // The grace dues up to the last day, each paid exactly, with its interest beside it.
    let share = GracePayment.programme.interestShare(inLoanYear: 1) ?? 1
    var paidFromSavings = AmountE4.zero
    for (due, previous, account) in [
      (dates.firstDue, dates.dueBefore, savings.id), (dates.secondDue, dates.firstDue, main.id),
    ] {
      let accrued = InterestMath.accrue(
        segments: drawn, percent: Self.educationLoanRate, after: previous, through: due)
      let amount = InterestMath.cents(accrued * share)
      guard amount.raw > 0 else { continue }
      var rng = layer.stream("grace payment", on: due)
      let at = layer.moment(due, hour: 11, minute: rng.int(in: 0...59))
      let payment = set.loanPayment(
        amount, on: loan, category: subcategory, root: loans, at: at, account: account,
        note: layer.word("Education loan payment", "Платёж по образовательному кредиту"),
        rng: &rng)
      guard
        let line = try? DebtRules.payment(
          on: loan, amountE4: amount, date: due, transactionId: payment.id,
          entryId: rng.nextUUID()
        ).entry
      else { continue }
      set.debtEntries.append(line)
      set.addMoving(payment, calendar: calendar)
      let interestId = rng.nextUUID()
      var charged = set.loanPayment(
        amount, on: loan, category: subcategory, root: loans, at: at, account: account,
        note: layer.word("Interest on «\(name)»", "Проценты по «\(name)»"), id: interestId,
        rng: &rng)
      charged.transaction.debtId = nil
      charged.transaction.creditDebtId = loan.id
      charged.transaction.externalId = Self.interestKey(ofPayment: payment.id, interest: interestId)
      set.addOnCredit(charged, calendar: calendar)
      if account == savings.id { paidFromSavings += amount }
    }

    // The first month's interest of the savings account, recorded on its pay date and kept on it.
    var balance: [(from: DateOnly, amount: AmountE4)] = [(dates.savingsOpened, deposited)]
    if !paidFromSavings.isZero {
      balance.append((dates.firstDue, deposited - paidFromSavings))
    }
    let earned = InterestMath.cents(
      InterestMath.accrue(
        segments: balance, percent: Self.savingsRate, after: dates.savingsOpened,
        through: dates.savingsPaid))
    if earned.raw > 0 {
      var rng = layer.stream("savings interest", on: dates.savingsPaid)
      let at = layer.moment(dates.savingsPaid, hour: 7, minute: rng.int(in: 0...59))
      let id = rng.nextUUID()
      set.addIncome(
        TransactionEntry(
          transaction: Transaction(
            id: id, kind: .income, occurredAt: at, amountE4: earned, amountRubE4: earned,
            note: layer.word("Savings interest", "Проценты по накопительному счёту"),
            paymentMethodId: savings.id, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: rng.nextUUID(), transactionId: id, categoryId: interest.category.id,
              amountE4: earned, amountRubE4: earned)
          ]),
        calendar: calendar)
    }

    // A top-up from the main account, after its count.
    var transferStream = layer.stream("savings topped up", on: toppedUpOn)
    let toppedUpAt = layer.moment(toppedUpOn, hour: 12, minute: 0)
    let topUp = AmountE4(whole: Int64(transferStream.int(in: 2...4)) * 10_000)
    set.transfers.append(
      Transfer(
        id: transferStream.nextUUID(), occurredAt: toppedUpAt, fromAccountId: main.id,
        fromCurrency: .rub, fromAmountE4: topUp, toAccountId: savings.id, toCurrency: .rub,
        toAmountE4: topUp, note: layer.word("To savings", "На накопительный счёт"),
        createdAt: toppedUpAt, updatedAt: toppedUpAt))
    set.transfers.sort { left, right in
      left.occurredAt != right.occurredAt
        ? left.occurredAt < right.occurredAt : left.id.uuidString < right.id.uuidString
    }
    let mainKey = BalanceKey(accountId: main.id, currency: .rub)
    set.accountExpectations[mainKey] = (set.accountExpectations[mainKey] ?? .zero) - topUp
    set.accountExpectations[savingsKey] = (set.accountExpectations[savingsKey] ?? .zero) + topUp
    return set
  }

  /// The rate of the education loan of the state programme, its term after the grace period, and
  /// the rate of the savings account, in percent a year.
  static let educationLoanRate = Decimal(3)
  static let educationLoanMonths = 180
  static let savingsRate = Decimal(16)

  /// The key of the interest operation `interest` of the loan payment `payment` — the app's
  /// `debtinterest:<payment>:<interest>`.
  static func interestKey(ofPayment payment: UUID, interest: UUID) -> String {
    "debtinterest:" + payment.uuidString.lowercased() + ":" + interest.uuidString.lowercased()
  }

  /// An expense of `amount` in the loan's subcategory of «Кредиты», the category the app files
  /// both a loan payment and its interest in (`system`).
  fileprivate func loanPayment(
    _ amount: AmountE4, on loan: Debt, category: CoreKit.Category, root: CoreKit.Category,
    at moment: Date, account: UUID, note: String, id: UUID? = nil, rng: inout SeededRandom
  ) -> TransactionEntry {
    let id = id ?? rng.nextUUID()
    let part = TransactionPart(
      id: rng.nextUUID(), transactionId: id, categoryId: category.id, categorySource: .system,
      quality: category.quality ?? root.quality ?? .neutral, qualitySource: .category,
      amountE4: amount, amountRubE4: amount)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: amount, amountRubE4: amount,
        note: note, paymentMethodId: account, debtId: loan.id, createdAt: moment,
        updatedAt: moment),
      parts: [part])
  }

  /// An operation joins the set in time order after what it already has at its moment.
  fileprivate mutating func insert(_ entry: TransactionEntry) {
    let index =
      entries.firstIndex { $0.transaction.occurredAt > entry.transaction.occurredAt }
      ?? entries.endIndex
    entries.insert(entry, at: index)
  }

  /// An expense on a loan, the way a purchase on credit is: my spending of its month, and no
  /// money moved on its account.
  fileprivate mutating func addOnCredit(_ entry: TransactionEntry, calendar: CalendarContext) {
    insert(entry)
    let month = calendar.day(of: entry.transaction.occurredAt).monthKey
    let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for part in entry.parts {
      let category = part.categoryId.flatMap { byId[$0] }
      expectations.spend(
        part.amountRubE4, in: month, root: category.map { $0.parentId ?? $0.id },
        quality: part.quality ?? .neutral)
    }
  }

  /// A payment of a loan whose payments are not expenses: money gone from its account, and no
  /// spending.
  fileprivate mutating func addMoving(_ entry: TransactionEntry, calendar: CalendarContext) {
    insert(entry)
    guard let account = entry.transaction.paymentMethodId else { return }
    let key = BalanceKey(accountId: account, currency: entry.transaction.currency)
    accountExpectations[key] = (accountExpectations[key] ?? .zero) - entry.transaction.amountE4
  }

  /// Income: of the month of its day, and money come to its account.
  fileprivate mutating func addIncome(_ entry: TransactionEntry, calendar: CalendarContext) {
    insert(entry)
    expectations.receive(
      entry.transaction.amountRubE4, for: calendar.day(of: entry.transaction.occurredAt).monthKey)
    guard let account = entry.transaction.paymentMethodId else { return }
    let key = BalanceKey(accountId: account, currency: entry.transaction.currency)
    accountExpectations[key] = (accountExpectations[key] ?? .zero) + entry.transaction.amountE4
  }
}

/// The days of the education loan and the savings account, counted back from the last day so
/// that every grace due up to it is paid and nothing that moves money on the main account comes
/// before its count two weeks before the last day.
struct LoanAndSavingsDates: Hashable {
  /// The day of the month the loan is paid on — never after the 28th, so every month has it.
  let payday: Int
  /// The payday before the first due, the first due and the second; the second is five to
  /// eight days before the last day.
  let dueBefore: DateOnly
  let firstDue: DateOnly
  let secondDue: DateOnly
  /// Twenty days before the first due, and ten after it.
  let firstTranche: DateOnly
  let secondTranche: DateOnly
  /// The first day of the main schedule: the 1st of the month two years after the last day's.
  let mainFrom: DateOnly
  /// A week to ten days before the first due — on a day every month has —, and a month later,
  /// the first payout of its interest.
  let savingsOpened: DateOnly
  let savingsPaid: DateOnly

  init?(lastDay: DateOnly, calendar: CalendarContext) {
    let fiveBefore = calendar.adding(days: -5, to: lastDay)
    let payday = min(fiveBefore.day, 28)
    let thisMonth = DateOnly(year: lastDay.year, month: lastDay.month, day: payday)
    let second = thisMonth <= fiveBefore ? lastDay.monthKey : lastDay.monthKey.previous
    let first = second.previous
    let before = first.previous
    self.payday = payday
    self.secondDue = DateOnly(year: second.year, month: second.month, day: payday)
    self.firstDue = DateOnly(year: first.year, month: first.month, day: payday)
    self.dueBefore = DateOnly(year: before.year, month: before.month, day: payday)
    self.firstTranche = calendar.adding(days: -20, to: firstDue)
    self.secondTranche = calendar.adding(days: 10, to: firstDue)
    self.mainFrom = DateOnly(year: lastDay.year + 2, month: lastDay.month, day: 1)
    var opened = calendar.adding(days: -7, to: firstDue)
    while opened.day > 28 { opened = calendar.adding(days: -1, to: opened) }
    self.savingsOpened = opened
    let paid = opened.monthKey.next
    self.savingsPaid = DateOnly(year: paid.year, month: paid.month, day: opened.day)
    guard savingsPaid > firstDue, secondTranche < secondDue else { return nil }
  }
}
