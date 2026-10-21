import AppCore
import AppDatabase
import Foundation

/// The actions of the Debts section. Each asks the debt rules of the core what to write and
/// hands it to the store as one `PlanningChange`: the operation of a payment and its journal
/// line, both lines of a transfer, a closing and its write-off — one write and one step of ⌘Z
/// each. A closed debt takes nothing but «Reopen»: a payment, a line, a transfer or a second
/// close would move a balance no list, total or reminder shows any more.
@MainActor
struct DebtActions {
  let planning: PlanningActions
  var snapshot: DataSnapshot? { planning.snapshot }

  init(_ deps: AppDependencies) {
    planning = PlanningActions(deps)
  }

  /// Through the planning's own write, so a debt made, renamed or closed here is known to
  /// the entry line at once.
  func apply(_ change: PlanningChange) -> Bool { planning.apply(change) }

  /// A new debt, with its Loans subcategory when its payments are expenses («подкатегория
  /// долга создаётся автоматически») and a first line for what is owed now. Owing less than
  /// nothing («100-300» in the field) is refused, not written as a debt at 0.
  ///
  /// Money that changes hands now is a line of cash on an account — `account` while it is
  /// live, else the main one — at `moment`, with what that account was charged when it does
  /// not hold the debt's currency (`charged` when typed, else the prefill).
  ///
  /// A loan written on the day its payment falls due (`DebtTerms.asksAboutThisMonth`) is asked
  /// whether this month's payment is made already: with `termPaid` the first line is followed by
  /// a payment of nothing that closes the due of the day, so the first one owed is next month's.
  ///
  /// `costs` — the fees and insurance of a loan (`debt_costs`) — are written with it: a cost
  /// held back from the loan (`inLoan`) grows the first line by its sum, one paid once apart is
  /// an expense of its own on its day (`costOperations`).
  @discardableResult
  func create(
    _ debt: Debt, balance: AmountE4, on day: DateOnly, moneyMovedNow: Bool,
    account: UUID? = nil, charged: Money? = nil, at moment: Date? = nil, termPaid: Bool = false,
    costs: [DebtCost] = []
  ) -> Bool {
    guard
      let change = createChange(
        debt, balance: balance, on: day, moneyMovedNow: moneyMovedNow, account: account,
        charged: charged, at: moment, termPaid: termPaid, costs: costs),
      apply(change)
    else { return false }
    if !costs.isEmpty {
      AppLog.info(
        "debts.costs.saved", .db, "the costs of a loan were saved",
        [LogPair("debt", .id(debt.id)), LogPair("costs", .count(costs.count))])
    }
    return true
  }

  /// What `create` writes, not yet written: for a change that joins it with another one.
  func createChange(
    _ debt: Debt, balance: AmountE4, on day: DateOnly, moneyMovedNow: Bool,
    account: UUID? = nil, charged: Money? = nil, at moment: Date? = nil, termPaid: Bool = false,
    costs: [DebtCost] = []
  ) -> PlanningChange? {
    guard !balance.isNegative else { return nil }
    let costs = costs.map { cost in
      var own = cost
      own.debtId = debt.id
      return own
    }
    let balance =
      balance + AmountE4.sum(costs.filter { $0.inLoan && $0.every == .once }.map(\.amountE4))
    // Named without the spaces around it: the Loans subcategory and the entry line's word
    // take the name as it is saved.
    var debt = debt
    debt.name = debt.name.trimmingCharacters(in: .whitespacesAndNewlines)
    // Made with the terms of this version in view: never asked about them as an old debt.
    debt.termsReviewed = true
    var rows = PlanningRows.empty
    rows.debts = [withSubcategory(debt, rows: &rows)]
    debt = rows.debts[0]
    let costsWritten = costOperations(debt, costs: costs, account: account, rows: &rows)
    // What is owed when the debt is written down is not money that moves now, unless it is
    // (money lent or borrowed today): a reconciliation must not count an old loan as cash
    // that came in.
    if balance.raw > 0,
      var opening = try? DebtRules.opening(
        of: debt, balance: balance, date: day, moneyMovedNow: moneyMovedNow)
    {
      if moneyMovedNow {
        guard
          (try? layCash(
            on: &opening, of: debt, account: account, charged: charged, at: moment ?? Date()))
            != nil
        else { return nil }
      }
      rows.debtEntries = [opening]
      if termPaid {
        rows.debtEntries.append(
          DebtRules.makeEntry(
            debtId: debt.id, kind: .payment, amountE4: .zero, date: day,
            description: planning.environment.language("debts.monthPaid.note", table: "Debts"),
            closesTerm: true))
      }
    }
    return PlanningChange(created: costsWritten, upsert: rows)
  }

  /// A line of money borrowed or lent through the journal alone names the account it moved on
  /// — `account` while live, else the main one — its moment, and what that account was charged
  /// when it does not hold the debt's currency: `charged` when typed in that currency, else the
  /// prefill from the bank's rates of its day. Throws `FormChargeError.chargeMissing` when no
  /// rate gives the figure.
  func layCash(
    on line: inout DebtEntry, of debt: Debt, account chosen: UUID?, charged: Money?,
    at moment: Date
  ) throws {
    let environment = planning.environment
    let accounts =
      (try? environment.references?.paymentMethods(includeArchived: true))
      ?? snapshot?.dataset.paymentMethods ?? []
    let account = FormAccounts.account(chosen, among: accounts)
    line.paymentMethodId = account?.id ?? chosen
    line.occurredAt = moment
    line.date = environment.calendar.day(of: moment)
    line.accountCurrency = nil
    line.accountAmountE4 = nil
    guard let account, let leg = AccountRules.legCurrency(for: debt.currency, account: account)
    else { return }
    if let charged, charged.currency == leg, charged.amount.raw > 0 {
      line.accountCurrency = leg
      line.accountAmountE4 = charged.amount
      return
    }
    let table = (try? environment.rates?.table()) ?? RateTable()
    guard
      let figure = FormAccounts.charge(
        amount: line.amountE4.magnitude, currency: debt.currency, at: moment, rate: nil,
        account: account, table: table, calendar: environment.calendar)?.amount
    else { throw FormChargeError.chargeMissing }
    line.accountCurrency = leg
    line.accountAmountE4 = figure
  }

  @discardableResult
  func save(_ debt: Debt) -> Bool {
    var rows = PlanningRows.empty
    rows.debts = [withSubcategory(debt, rows: &rows)]
    return apply(PlanningChange(upsert: rows))
  }

  /// «Reopen»: a closed debt back in its list, as it was — a write-off made at the close stays
  /// in the journal, where «Adjust» can take it back. One write, one ⌘Z.
  @discardableResult
  func reopen(_ debt: Debt) -> Bool {
    guard debt.closed else { return false }
    var reopened = debt
    reopened.closed = false
    return save(reopened)
  }

  /// What is left on a debt now: the sum of its journal as the database has it at the moment
  /// of asking, not the figure the card was drawn with — the entry line or another window may
  /// have written since. `nil` when there is no database to read.
  ///
  /// A loan that accrues interest owes its principal: the journal with the interest its payments
  /// paid first given back (`DebtInterest`) — what a payment must cover to pay it off is that and
  /// the interest accrued since (`payoff(of:)`).
  func balance(of debt: Debt) -> AmountE4? {
    guard let journal = journal(of: debt) else { return nil }
    return Self.principal(
      of: debt, journal: journal, today: planning.environment.today,
      calendar: planning.environment.calendar)
  }

  /// What a payment made today must cover to pay `debt` off: what is left of it and, on a loan
  /// that accrues interest, the interest accrued and not paid yet. `nil` without a database.
  func payoff(of debt: Debt) -> AmountE4? {
    guard let journal = journal(of: debt) else { return nil }
    let environment = planning.environment
    let principal = Self.principal(
      of: debt, journal: journal, today: environment.today, calendar: environment.calendar)
    return principal
      + DebtInterest.accruedE4(
        debt: debt, journal: journal, through: environment.today, calendar: environment.calendar)
  }

  /// The lines of `debt` as the database has them at the moment of asking; `nil` without one.
  func journal(of debt: Debt) -> [DebtEntry]? {
    guard let references = planning.environment.references else { return nil }
    return try? references.debtEntries(debtId: debt.id)
  }

  /// What is left of `debt` by `journal`: its sum, or, for a loan that accrues interest, its
  /// principal — the lines through `today` with the interest of their payments given back, and the
  /// lines still to come as they are.
  static func principal(
    of debt: Debt, journal: [DebtEntry], today: DateOnly, calendar: CalendarContext
  ) -> AmountE4 {
    guard debt.accruesInterest else { return DebtRules.balance(entries: journal) }
    return DebtRules.balance(
      entries: DebtInterest.effectiveJournal(
        debt: debt, journal: journal, through: today, calendar: calendar))
  }

  /// Whether a payment of `amount` pays off what is left, and «Pay» offers to close the debt.
  static func paysOff(_ amount: AmountE4, balance: AmountE4) -> Bool {
    amount.raw > 0 && amount >= balance
  }

  /// A subcategory once, never twice: a debt that has one keeps it even while the data on
  /// screen has not caught up with the write that made it.
  private func withSubcategory(_ debt: Debt, rows: inout PlanningRows) -> Debt {
    var debt = debt
    if debt.loansSubcategoryId == nil {
      debt.loansSubcategoryId =
        (try? planning.environment.references?.debts(includeClosed: true))?
        .first { $0.id == debt.id }?.loansSubcategoryId
    }
    guard debt.loansSubcategoryId == nil, let tree = snapshot?.ledger.tree,
      let made = SystemSubcategories.loanSubcategory(for: debt, tree: tree)
    else { return debt }
    debt.loansSubcategoryId = made.id
    rows.categories.append(made)
    return debt
  }

  /// «Pay»: an operation with the debt — an expense in Loans when the debt's payments are
  /// expenses, otherwise one that only lowers the debt; money a person returns on a debt owed
  /// to me is a reimbursement — and the journal line that lowers the balance.
  ///
  /// With `closing`, a payment that pays off what the journal has left at this moment closes
  /// the debt in the same write and the same ⌘Z, and what it paid over is written off: the
  /// closed debt owes nothing, like one closed by «Close». A payment that no longer
  /// covers the balance — a line landed since the form opened — is written alone, and the rest
  /// stays owed where it can be seen.
  ///
  /// Money given back on a debt owed to me follows the one rule of repayments
  /// (`DebtRules.repayment`): the journal takes what was owed, the debt closes once it is
  /// covered (with exactly the balance, as `closing` says), and what came back above it is
  /// income in «Доплаты» — an operation of its own in the same write, on the same account.
  ///
  /// The operation is on `paymentMethodId` while that account is live, else on the main one,
  /// with what the account was charged when it does not hold the debt's currency: `charged`
  /// when typed from the statement, else the prefill at the rate of the operation.
  ///
  /// With `closesTerm` — «в этом месяце больше платежей не будет» — the line says the due the
  /// payment was made for is closed although the payment is smaller than the monthly one. With
  /// `prepay` the payment is an early repayment and the line keeps the answer
  /// (`DebtPrepayment.marking`); the markup of an instalment plan is an operation of its own,
  /// like the interest of a loan.
  @discardableResult
  func pay(
    _ debt: Debt, amount: AmountE4, on day: Date, paymentMethodId: UUID?, closing: Bool = false,
    charged: Money? = nil, closesTerm: Bool = false, prepay: PrepayChoice? = nil
  ) -> Bool {
    guard
      let change = payChange(
        debt, amount: amount, on: day, paymentMethodId: paymentMethodId, closing: closing,
        charged: charged, closesTerm: closesTerm, prepay: prepay)
    else { return false }
    return apply(change)
  }

  /// What `pay` writes, not yet written: for a change that joins it with another one.
  func payChange(
    _ debt: Debt, amount: AmountE4, on day: Date, paymentMethodId: UUID?, closing: Bool = false,
    charged: Money? = nil, closesTerm: Bool = false, prepay: PrepayChoice? = nil
  ) -> PlanningChange? {
    guard !debt.closed else { return nil }
    var rows = PlanningRows.empty
    let debt = withSubcategory(debt, rows: &rows)
    if !rows.categories.isEmpty { rows.debts = [debt] }
    let date = planning.environment.calendar.day(of: day)
    guard
      let entry = try? paymentOperation(
        debt, amount: amount, on: day, account: paymentMethodId, charged: charged)
    else { return nil }
    if debt.direction == .owedToMe, let left = balance(of: debt) {
      guard
        let written = try? repayment(debt, by: entry, balance: left, date: date, closing: closing)
      else { return nil }
      rows.debtEntries = written.line.map { [$0] } ?? []
      if written.closes {
        var closed = debt
        closed.closed = true
        rows.debts = [closed]
      }
      return PlanningChange(created: [entry] + written.surplus, upsert: rows)
    }
    guard
      let outcome = try? DebtRules.payment(
        on: debt, amountE4: amount, date: date, transactionId: entry.id, closesTerm: closesTerm)
    else { return nil }
    rows.debtEntries = [outcome.entry]
    // On a loan that accrues interest the payment pays the interest accrued first: that part is
    // an operation of its own in «Кредиты» (`DebtInterestPayment`), and only the rest lowers the
    // principal.
    let change = DebtPrepayment.marking(
      DebtInterestPayment.parting(
        PlanningChange(created: [entry], upsert: rows), paying: debt,
        environment: planning.environment, snapshot: snapshot),
      debt: debt, choice: prepay)
    let interest = AmountE4.sum(
      change.created.dropFirst()
        .filter { DebtInterestPayment.payment(ofKey: $0.transaction.externalId) != nil }
        .map(\.transaction.amountE4))
    rows = change.upsert
    if closing, let left = balance(of: debt), let owed = payoff(of: debt),
      Self.paysOff(amount, balance: owed)
    {
      let closed = DebtRules.closing(
        debt, balance: left + outcome.entry.amountE4 + interest, writeOffRemainder: true,
        date: date)
      rows.debts = [closed.debt]
      if let writeOff = closed.entry { rows.debtEntries.append(writeOff) }
    }
    var written = change
    written.upsert = rows
    return written
  }

  /// A repayment `entry` of `debt` owed to me, against what is left of it: the journal line,
  /// whether the debt closes, and the income in «Доплаты» of what came back above it — built
  /// like every surplus of money back (`MoneyBack.surplusEntry`), in the interface language.
  /// Throws when there is a surplus and no system Surcharges category to put it in.
  func repayment(
    _ debt: Debt, by entry: TransactionEntry, balance: AmountE4, date: DateOnly,
    closing: Bool = true, rubPerUnit: Decimal? = nil
  ) throws -> (line: DebtEntry?, closes: Bool, surplus: [TransactionEntry]) {
    let outcome = try DebtRules.repayment(
      on: debt, by: entry.transaction, balance: balance, date: date,
      description: entry.transaction.note, rubPerUnit: rubPerUnit, closeWhenPaidOff: closing)
    guard let surplus = outcome.surplus else { return (outcome.line, outcome.closes, []) }
    let environment = planning.environment
    guard
      let surcharges = try environment.references?.category(
        systemRole: .surcharges, kind: .income)?.id
    else { throw ReimbursementRecording.Failure.noSurchargesCategory }
    let transaction = entry.transaction
    let income = try MoneyBack.surplusEntry(
      surplus, of: entry.id, on: transaction.occurredAt, now: Date(),
      rate: surplus.currency == .rub ? nil : transaction.rate, rateDate: transaction.rateDate,
      categoryId: surcharges, note: environment.language("reimbursement.surplus", table: "Entry"))
    return (outcome.line, outcome.closes, [income])
  }

  // MARK: Deleting a debt

  /// What deleting `debt` writes and what it leaves, from the data on screen: its journal, the
  /// operations that point at it, the categories and the main account.
  static func deletion(of debt: Debt, snapshot: DataSnapshot, at instant: Date) -> DebtDeletion {
    let dataset = snapshot.dataset
    return DebtRules.deletion(
      of: debt, journal: dataset.planning.debtEntries.filter { $0.debtId == debt.id },
      entries: dataset.entries, tree: snapshot.ledger.tree,
      mainAccountId: dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id,
      calendar: snapshot.ledger.calendar, at: instant)
  }

  /// «Удалить…»: the debt leaves every list, reminder, due date, the free sum and the pickers;
  /// its live subcategory of «Кредиты» goes to the archive. Nothing else is written — the
  /// operations that paid it and its journal keep every figure they made. One write, one ⌘Z.
  @discardableResult
  func delete(_ debt: Debt, at instant: Date = Date()) -> Bool {
    guard let snapshot, debt.deletedAt == nil else { return false }
    let deletion = Self.deletion(of: debt, snapshot: snapshot, at: instant)
    var rows = PlanningRows.empty
    rows.debts = [deletion.debt]
    if let subcategory = deletion.archivedSubcategory { rows.categories = [subcategory] }
    guard apply(PlanningChange(upsert: rows, at: instant)) else {
      AppLog.error(
        "debt.deleteFailed", .db, "a debt was not deleted", [LogPair("debt", .id(debt.id))])
      return false
    }
    AppLog.info(
      "debt.deleted", .db, "a debt was deleted",
      [
        LogPair("debt", .id(debt.id)), LogPair("lines", .count(deletion.journalLines)),
        LogPair("operations", .count(deletion.operations)),
      ])
    return true
  }

  /// The operation a payment of `debt` writes — «Pay», or «Offset» with its note — on
  /// `account` while it is live, else on the main one, with «Списано со счёта» when that
  /// account does not hold the debt's currency. The forms ask «Это было до сверки?» about it
  /// before the write.
  func paymentOperation(
    _ debt: Debt, amount: AmountE4, on day: Date, account: UUID?, charged: Money?,
    note: String? = nil
  ) throws -> TransactionEntry {
    let loans = debt.loansSubcategoryId ?? snapshot?.ledger.tree.systemCategory(.loans)?.id
    var draft = DebtRules.paymentDraft(
      debt: debt, amount: amount, occurredAt: day, paymentMethodId: account,
      loansCategoryId: loans)
    draft.note = note
    try FormAccounts.lay(on: &draft, account: account, charged: charged, actions: planning)
    return try planning.operation(draft, link: nil)
  }

  /// «Offset»: I paid something for the creditor and the debt goes down. Money left my
  /// pocket, so it is an operation, counted the way a payment of this debt is — on `account`
  /// while it is live, else on the main one.
  @discardableResult
  func offset(
    _ debt: Debt, amount: AmountE4, on day: Date, description: String?, account: UUID? = nil,
    charged: Money? = nil
  ) -> Bool {
    guard !debt.closed else { return false }
    guard
      let entry = try? paymentOperation(
        debt, amount: amount, on: day, account: account, charged: charged,
        note: DebtRules.cleaned(description)),
      let line = try? DebtRules.offset(
        on: debt, amountE4: amount, date: planning.environment.calendar.day(of: day),
        transactionId: entry.id, description: description)
    else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(created: [entry], upsert: rows))
  }

  /// «Add entry»: borrowed, or the debt grew — an amount, or a share of a full amount
  /// («полная сумма 1 000 000, доля 1/2»).
  ///
  /// Money that moved is a line of cash on `account` — while live, else the main one — at
  /// `moment` (noon of `day` when none is given), with «Списано со счёта» when that account
  /// does not hold the debt's currency.
  @discardableResult
  func addEntry(
    _ debt: Debt, amount: AmountE4, fullAmount: AmountE4?, share: Decimal?, on day: DateOnly?,
    group: String?, description: String?, moneyMoved: Bool, account: UUID? = nil,
    charged: Money? = nil, at moment: Date? = nil
  ) -> Bool {
    guard !debt.closed else { return false }
    var line: DebtEntry?
    if moneyMoved {
      // Borrowed: money came in (or went out, on a debt owed to me) — a real movement.
      if let fullAmount, let share {
        line = try? DebtRules.makeShareEntry(
          debtId: debt.id, fullAmountE4: fullAmount, share: share, date: day, groupName: group,
          description: description)
      } else {
        line =
          amount.raw > 0
          ? DebtRules.makeEntry(
            debtId: debt.id, kind: .borrowed, amountE4: amount, date: day, groupName: group,
            description: description) : nil
      }
    } else {
      // The debt grew without money moving — interest, a fine, a share of a common bill.
      line = try? DebtRules.growth(
        on: debt, amountE4: amount, fullAmountE4: fullAmount, share: share, date: day,
        groupName: group, description: description)
    }
    guard var line else { return false }
    if moneyMoved {
      let calendar = planning.environment.calendar
      let when =
        moment ?? day.map { calendar.startOfDay($0).addingTimeInterval(12 * 3600) } ?? Date()
      guard
        (try? layCash(on: &line, of: debt, account: account, charged: charged, at: when)) != nil
      else { return false }
    }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(upsert: rows))
  }

  /// The open «Мне должны» debt a money back is offered to repay: the person owes no part but
  /// owes on it (`MoneyBackRefusal.owesOnDebt`). `nil` for any other refusal or a debt that is
  /// closed, gone or owed the other way.
  static func repaid(by refusal: MoneyBackRefusal, among debts: [Debt]) -> Debt? {
    guard case .owesOnDebt(let id) = refusal,
      let debt = debts.first(where: { $0.id == id }),
      !debt.closed, debt.direction == .owedToMe
    else { return nil }
    return debt
  }

  /// The payment form a money back opens as a repayment of `debt`: the amount given back when
  /// it is in the debt's currency (otherwise typed in the form), on the account it came to.
  static func repaymentSheet(of debt: Debt, money: Money, account: UUID?) -> DebtSheet {
    .repay(debt, amount: money.currency == debt.currency ? money.amount : nil, account: account)
  }

  /// What a money back that repays `debt` needs from the entry line: nothing when it is in the
  /// debt's currency — the line saves it with the debt, and asks what the line asks — or, in
  /// another currency, which the line cannot write on the debt (5 $ back on a ruble debt), the
  /// payment form of the debt on the account the money came to, the amount typed there in the
  /// debt's currency.
  static func repaymentSheetIfNeeded(of debt: Debt, money: Money, account: UUID?) -> DebtSheet? {
    money.currency == debt.currency
      ? nil : repaymentSheet(of: debt, money: money, account: account)
  }

  /// «Transfer»: a third party paid one debt off and the sum moved into another — the first
  /// closes when all of it moved, the second gets a line. «All of it» is what the journal of
  /// the first has left when the transfer is written; `balance`, the figure the card showed,
  /// stands in only without a database to read.
  @discardableResult
  func transfer(
    _ source: Debt, balance: AmountE4, to destination: Debt, amount: AmountE4, on day: DateOnly
  )
    -> Bool
  {
    guard !source.closed, !destination.closed,
      let moved = try? DebtRules.transfer(
        from: source, to: destination, amountE4: amount,
        sourceBalanceE4: self.balance(of: source) ?? balance, date: day)
    else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [moved.out, moved.into]
    if moved.closesSource {
      var closed = source
      closed.closed = true
      rows.debts = [closed]
    }
    return apply(PlanningChange(upsert: rows))
  }

  /// «Adjust»: the balance set to what it really is, by a signed line — the difference from
  /// what the journal has when it is written, so the balance comes to the figure typed even
  /// when a payment landed after the form opened. `balance`, the figure the form showed,
  /// stands in only without a database to read.
  @discardableResult
  func adjust(
    _ debt: Debt, from balance: AmountE4, to newBalance: AmountE4, on day: DateOnly, note: String?
  )
    -> Bool
  {
    guard !debt.closed,
      let line = try? DebtRules.adjustment(
        on: debt, from: self.balance(of: debt) ?? balance, to: newBalance, date: day, note: note)
    else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(upsert: rows))
  }

  /// «Close»: the debt leaves the lists; what is left of it — in the journal when it is
  /// written, not in the figure the card showed — is written off when asked, so the closed
  /// debt owes nothing. `balance` stands in only without a database to read.
  @discardableResult
  func close(_ debt: Debt, balance: AmountE4, writeOff: Bool, on day: DateOnly) -> Bool {
    guard !debt.closed else { return false }
    let closing = DebtRules.closing(
      debt, balance: self.balance(of: debt) ?? balance, writeOffRemainder: writeOff, date: day)
    var rows = PlanningRows.empty
    rows.debts = [closing.debt]
    if let line = closing.entry { rows.debtEntries = [line] }
    return apply(PlanningChange(upsert: rows))
  }
}
