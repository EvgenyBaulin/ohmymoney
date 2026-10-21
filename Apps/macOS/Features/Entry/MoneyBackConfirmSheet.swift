import AppCore
import AppDatabase
import SwiftUI

/// Money back typed in the entry line — «возврат денег 1700 от Ани» — as the confirmation opens
/// with it: the draft of the line, in its currency, on its account.
struct MoneyBackPrefill: Identifiable, Equatable {
  let id = UUID()
  var draft: TransactionDraft

  /// Whom the line or the panel named, if anyone.
  var personId: UUID? { draft.parts.first?.forPersonId }
}

/// Money back worked out before anything is written: the operation as it goes in, and how the
/// money spreads over what the person owes (`MoneyBack.plan`) — oldest part first, a part it
/// covers only partly waiting for the rest, money over everything owed income in «Доплаты» —
/// all in the currency the money came in, at its own rate.
struct MoneyBackConfirmation {
  /// Why the money back cannot be worked out yet.
  enum Problem: Error, Equatable {
    /// Nobody is named: money back is money from a person.
    case noPerson
    /// A foreign amount with no rate and no figure in rubles for the account.
    case rateMissing
  }

  /// The money back as it will be written: kind, amount, currency, rubles, account, person.
  let entry: TransactionEntry
  let plan: MoneyBackPlan
  /// What the person owes, oldest first, as read when the confirmation was made.
  let owed: [OwedPart]
  /// Parts «за другого» that name nobody are waiting — kept from before a part had to name
  /// its debtor. They may be this person's, so the money is not called income while they wait.
  var unnamedPartsWait = false

  var person: UUID? { entry.parts.first?.forPersonId }

  /// `draft` is the money back of the line: its person in the first part, its account and,
  /// when the account does not hold the currency, what the account received. The rate of a
  /// foreign amount is laid from `rates` the way the save lays it, unless it was typed.
  static func make(
    draft: TransactionDraft, owed: [OwedPart], debts: [Debt], rates: RateTable,
    calendar: CalendarContext, id: UUID = UUID(), now: Date = Date(),
    debtBalances: [UUID: AmountE4] = [:]
  ) throws -> MoneyBackConfirmation {
    guard let person = draft.parts.first?.forPersonId else { throw Problem.noPerson }
    var money = draft
    money.kind = .reimbursement
    money.parts = [PartDraft(amount: draft.amount, forPersonId: person)]
    // What the account received is a figure with its currency, or nothing at all.
    if money.accountAmount == nil { money.accountCurrency = nil }
    AppEnvironment.applyRate(to: &money, from: rates, calendar: calendar)
    let rate = money.rate
    let currency = money.currency
    let entry = try money.materialize(
      id: id, now: now,
      rublesConverter: { amount in
        guard currency != .rub else { return amount }
        guard let rate, rate > 0 else { throw Problem.rateMissing }
        return try AmountE4(decimal: amount.decimal * rate)
      })
    let transaction = entry.transaction
    let theirs = owed.filter { $0.debtorPersonId == person }
      .sorted(by: MyExpensesRule.oldestFirst)
    // A person who owes on an open debt does not owe nothing, whatever the debt's currency:
    // the money is its repayment, never income. One kept in another currency is repaid in its
    // payment form (`repaymentForm`), since the line cannot write rubles on a dollar debt.
    let plan = MoneyBack.plan(
      received: transaction.amountE4, currency: transaction.currency,
      receivedRub: transaction.amountRubE4,
      rateProvisional: transaction.currency != .rub && transaction.rateProvisional
        && transaction.rateSource != .manual,
      person: person, owed: theirs, openDebts: debts, debtBalances: debtBalances)
    var confirmation = MoneyBackConfirmation(entry: entry, plan: plan, owed: theirs)
    confirmation.unnamedPartsWait = owed.contains { $0.debtorPersonId == nil }
    return confirmation
  }

  /// What recording it writes: the money back, a link for every part the money reached, the
  /// parts it settles, and the surplus — income in «Доплаты», in the money back's currency and
  /// on its account. Nothing when the plan refuses.
  func recording(
    setting: ReimbursementRecording.Setting, now: Date = Date()
  ) throws -> (
    outcome: ReimbursementOutcome, reimbursement: TransactionEntry, extra: [TransactionEntry]
  )? {
    guard plan.refusal == nil else { return nil }
    let transaction = entry.transaction
    let outcome = MoneyBack.outcome(
      plan, reimbursementTxId: entry.id, accountId: transaction.paymentMethodId)
    var extra: [TransactionEntry] = []
    if let surplus = outcome.surplus {
      // The rate the money itself came at — its rubles over its amount, as the plan took it.
      let rate =
        transaction.amountE4.isZero
        ? nil
        : DecimalMath.round(
          transaction.amountRubE4.decimal / transaction.amountE4.decimal, scale: 6)
      extra.append(
        try ReimbursementRecording.surplusEntry(
          surplus, of: entry.id, on: transaction.occurredAt, now: now,
          rate: rate, rateDate: transaction.rateDate, setting: setting))
    }
    return (outcome, entry, extra)
  }

  /// What the money closes and what the person still owes after it, for the one line of the
  /// sheet: the parts closed, oldest first, each with its description; the rubles still owed.
  var closedParts: [OwedPart] {
    owed.filter { plan.closes.contains($0.partId) }
  }

  var stillOwedRub: AmountE4 { AmountE4.sum(plan.stillOwed.map(\.remainingRubE4)) }

  /// The parts the money reaches: those it closes, covers partly or passes over for their rate.
  var reachedParts: [OwedPart] {
    let reached = Set(plan.allocations.map(\.partId) + plan.closes + plan.skippedProvisional)
    return owed.filter { reached.contains($0.partId) }
  }

  /// The rubles one unit of the money came at: its rubles over its amount; 1 for rubles.
  var moneyRubPerUnit: Decimal? {
    let transaction = entry.transaction
    guard transaction.currency != .rub else { return 1 }
    guard transaction.amountE4.raw > 0, transaction.amountRubE4.raw > 0 else { return nil }
    return transaction.amountRubE4.decimal / transaction.amountE4.decimal
  }

  /// Money back that repays `debt` kept in another currency than the money came in, as the
  /// line writes it on the debt: the money converted at `debtRate` — rubles per unit of the
  /// debt, for this repayment only — into the debt's currency, that rate as the operation's
  /// own (manual) rate, and the money as it reached the account as what the account received.
  /// 10,000 ₽ back on a debt of 100 $ at 90 are 111.1111 $, the card getting 10,000 ₽.
  ///
  /// A debt kept in rubles has no rate of its own: the money's rubles are what it repays, and
  /// the operation, in rubles, carries no rate — `debtRate` is not read.
  ///
  /// `nil` when the account holds the debt's currency — the account received dollars, not
  /// rubles, and the figure is typed in the debt's own form — or when the money reached it in
  /// a currency it holds only besides its main one; and for a rate that does not convert.
  static func debtRepayment(
    of draft: TransactionDraft, money: TransactionEntry, debt: Debt, debtRate: Decimal,
    account: PaymentMethod?, received leg: MoneyLeg?, calendar: CalendarContext
  ) -> TransactionDraft? {
    let transaction = money.transaction
    guard debt.currency != transaction.currency,
      let account, let main = AccountRules.legCurrency(for: debt.currency, account: account)
    else { return nil }
    let moneyRate =
      transaction.currency == .rub
      ? Decimal(1)
      : (transaction.amountE4.raw > 0
        ? transaction.amountRubE4.decimal / transaction.amountE4.decimal : 0)
    let inRubles = debt.currency == .rub
    guard
      let amount = DebtRules.convert(
        transaction.amountE4, moneyRubPerUnit: moneyRate, debtRubPerUnit: inRubles ? 1 : debtRate),
      amount.raw > 0
    else { return nil }
    let received: MoneyLeg
    if main == transaction.currency {
      received = MoneyLeg(currency: transaction.currency, amount: transaction.amountE4)
    } else if !account.holds(transaction.currency), let leg, leg.currency == main,
      leg.amount.raw > 0
    {
      received = leg
    } else {
      return nil
    }
    var repayment = draft
    repayment.kind = .reimbursement
    repayment.currency = debt.currency
    repayment.amount = amount
    repayment.amountExpression = nil
    repayment.rate = inRubles ? nil : debtRate
    repayment.rateDate = inRubles ? nil : calendar.day(of: draft.occurredAt)
    repayment.rateSource = inRubles ? nil : .manual
    repayment.rateProvisional = false
    repayment.paymentMethodId = account.id
    repayment.accountCurrency = received.currency
    repayment.accountAmount = received.amount
    repayment.debtId = debt.id
    repayment.parts = [PartDraft(amount: amount, forPersonId: draft.parts.first?.forPersonId)]
    return repayment
  }

  /// Whether the money can be recorded as income instead: the person owes nothing, and no
  /// part that names nobody may be theirs.
  var offersIncome: Bool { plan.refusal == .owesNothing && !unnamedPartsWait }

  /// The payment form of the debt `debtId` a money back repays, when the line cannot write the
  /// repayment itself: the money came in another currency than the debt's (500 ₽ on a dollar
  /// debt). The form opens on the account the money came to, and the owner types there how
  /// much of the debt it repaid. `nil` when the line writes it, or the debt is gone.
  @MainActor static func repaymentForm(
    of debtId: UUID, money: Money, account: UUID?, among debts: [Debt]
  ) -> DebtSheet? {
    guard let debt = debts.first(where: { $0.id == debtId }) else { return nil }
    return DebtActions.repaymentSheetIfNeeded(of: debt, money: money, account: account)
  }

  /// What the account received when it does not hold the currency the money came in: the
  /// money at the bank's rates of its day, through rubles (`AccountRules.prefillLeg`). Nil when
  /// the account holds the currency, or a rate is missing and the figure has to be typed.
  static func prefilledLeg(
    for draft: TransactionDraft, account: PaymentMethod?, rates: RateTable,
    calendar: CalendarContext
  ) -> MoneyLeg? {
    guard let account,
      let leg = AccountRules.legCurrency(for: draft.currency, account: account)
    else { return nil }
    var rated = draft
    AppEnvironment.applyRate(to: &rated, from: rates, calendar: calendar)
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in rates.rates {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    guard
      let amount = AccountRules.prefillLeg(
        amount: draft.amount, currency: draft.currency, rate: rated.rate,
        day: calendar.day(of: draft.occurredAt), account: account,
        rates: DayRates(series: series))
    else { return MoneyLeg(currency: leg, amount: .zero) }
    return MoneyLeg(currency: leg, amount: amount)
  }
}

/// The short confirmation Enter opens for money back: from whom, how much and in which
/// currency, onto which account, and in one line what it settles — «закроет: …; останется
/// должен: …». «Вручную…» opens the per-part sheet. A person who owes nothing is refused with
/// the hint to record the money as income, or — when they owe on an open «Мне должны» debt —
/// with the offer to record it as a repayment of that debt.
struct MoneyBackConfirmSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  /// Handed to the per-part sheet, which SwiftUI lays out in a host of its own.
  @Environment(\.dependencies) private var dependencies

  let prefill: MoneyBackPrefill
  /// The person owes nothing: the line records the money, as the sheet holds it, as income.
  let recordAsIncome: (TransactionDraft) -> Void
  /// The person owes on an open debt: the line records the money, as the sheet holds it, as
  /// that debt's repayment.
  let recordAsDebtRepayment: (UUID, TransactionDraft) -> Void
  /// The money back went in: the line starts over.
  let recorded: () -> Void

  @State private var personId: UUID?
  @State private var amount: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var accountId: UUID?
  /// What the account received, typed from the statement; nil follows the prefill.
  @State private var typedLeg: AmountE4?
  /// A rate typed for a day the bank has not published yet, or has no rate for.
  @State private var typedRate = ""
  @State private var people: [Person] = []
  @State private var owed: [OwedPart] = []
  @State private var debts: [Debt] = []
  @State private var accounts: [PaymentMethod] = []
  @State private var rates = RateTable()
  @State private var errorKey: String?
  @State private var manual: ReimbursementPrefill?
  /// The purchases in other currencies the person's parts belong to, as the database has them.
  @State private var purchases: [UUID: TransactionEntry] = [:]
  /// The rate typed for a purchase, purchase → text; empty follows what the part cost.
  @State private var purchaseRates: [UUID: String] = [:]
  /// What is left on each open «Мне должны» debt, and its journal.
  @State private var debtBalances: [UUID: AmountE4] = [:]
  @State private var debtJournals: [UUID: [DebtEntry]] = [:]
  /// The rate typed for a repayment of a debt in another currency than the money's.
  @State private var debtRateText = ""
  /// «Сверх частей … — в счёт долга»: on by default, as the owner chose; off, the surplus is
  /// income in «Доплаты» as before.
  @State private var surplusToDebt = true

  init(
    prefill: MoneyBackPrefill, recordAsIncome: @escaping (TransactionDraft) -> Void,
    recordAsDebtRepayment: @escaping (UUID, TransactionDraft) -> Void,
    recorded: @escaping () -> Void
  ) {
    self.prefill = prefill
    self.recordAsIncome = recordAsIncome
    self.recordAsDebtRepayment = recordAsDebtRepayment
    self.recorded = recorded
    _personId = State(initialValue: prefill.personId)
    _amount = State(initialValue: prefill.draft.amount)
    _currency = State(initialValue: prefill.draft.currency)
    _accountId = State(initialValue: prefill.draft.paymentMethodId)
    _typedLeg = State(initialValue: prefill.draft.accountAmount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: t("moneyBack.title"))
        .appFont(.headline)
      fields
      Divider()
      summary
      if let errorKey {
        Text(verbatim: t(errorKey))
          .appFont(.caption)
          .foregroundStyle(.red)
      }
      buttons
    }
    .padding(20)
    .sheetFrame(minWidth: 460)
    .onAppear(perform: reload)
    // The line asked the bank for the rate of the day as it opened this: once it came, the
    // data was computed again, and the money is worked out at it.
    .onChange(of: compute.generation) { _, _ in
      rates = (try? environment.rates?.table()) ?? RateTable()
    }
    .sheet(item: $manual) { prefill in
      ReimbursementSheet(prefill: prefill) {
        recorded()
        dismiss()
      }
      .handingOver(dependencies)
    }
  }

  // MARK: Fields

  private var fields: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      GridRow {
        label("entry.fromWhom")
        Picker(selection: $personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(orderedPeople, id: \.id) { person in
            Text(verbatim: person.name).tag(UUID?.some(person.id))
          }
        } label: {
          Text(verbatim: t("entry.fromWhom"))
        }
        .labelsHidden()
        .accessibilityIdentifier("moneyBack.person")
      }
      GridRow {
        label("entry.amount")
        HStack(spacing: 8) {
          AmountField(amount: $amount)
            .frame(width: 140)
            .accessibilityLabel(Text(verbatim: t("entry.amount")))
            // What the account received was for the amount the line had.
            .onChange(of: amount) { _, _ in typedLeg = nil }
          Picker(selection: $currency) {
            ForEach(currencyChoices, id: \.code) { code in
              Text(verbatim: code.code).tag(code)
            }
          } label: {
            Text(verbatim: t("entry.currency"))
          }
          .labelsHidden()
          .fixedSize()
          .onChange(of: currency) { _, _ in typedLeg = nil }
        }
      }
      GridRow {
        label("entry.account.to")
        Picker(selection: $accountId) {
          ForEach(orderedAccounts, id: \.id) { account in
            Text(verbatim: account.name).tag(UUID?.some(account.id))
          }
        } label: {
          Text(verbatim: t("entry.account.to"))
        }
        .labelsHidden()
        .onChange(of: accountId) { _, _ in typedLeg = nil }
      }
      if let leg = legShown {
        GridRow {
          label("moneyBack.received")
          HStack(spacing: 8) {
            AmountField(
              amount: Binding(
                get: { typedLeg ?? leg.amount },
                set: { typedLeg = $0.isZero ? nil : $0 })
            )
            .frame(width: 140)
            .accessibilityLabel(Text(verbatim: t("moneyBack.received")))
            Text(verbatim: leg.currency.code)
              .foregroundStyle(.secondary)
          }
        }
      }
      // The rate of the money — typed when the bank has none of the day yet, or none at all —
      // and the rate of every purchase in a third currency the money reaches.
      MoneyBackRateRows(
        currency: currency, moneyRate: moneyRate, moneyRateLocked: legShown?.currency == .rub,
        typedMoneyRate: $typedRate, purchases: purchaseRows, purchaseRates: $purchaseRates
      )
      .onChange(of: typedRate) { _, _ in typedLeg = nil }
    }
    // A rate typed for a purchase goes with its row: when the row goes — another person, the
    // money in the purchase's own currency, less money that no longer reaches it —, so does
    // the rate.
    .onChange(of: purchaseRows.map(\.id)) { _, ids in
      purchaseRates = MoneyBackRateRows.keeping(purchaseRates, rows: ids)
    }
    .onChange(of: personId) { _, _ in purchaseRates = [:] }
    .onChange(of: currency) { _, _ in purchaseRates = [:] }
  }

  /// The rate the money is worked out at: its rubles over its amount.
  private var moneyRate: Decimal? {
    guard case .success(let confirmation) = confirmation else { return manualRate }
    return confirmation.moneyRubPerUnit
  }

  /// A row for every purchase in a third currency the money reaches, from the plan as the
  /// typed rates make it.
  private var purchaseRows: [PurchaseRateRow] {
    guard case .success(let confirmation) = confirmation else { return [] }
    return MoneyBackRateRows.rows(
      reaching: confirmation.reachedParts, money: currency, purchases: purchases,
      note: { $0.note ?? t("moneyBack.partWithoutNote") })
  }

  /// The purchases with a rate typed, and those rates. A rate stays only while its row does
  /// (`MoneyBackRateRows.keeping`): a purchase the plan no longer reaches is never written again
  /// at a rate nobody sees.
  private var repricing: [UUID: Decimal] {
    var rates: [UUID: Decimal] = [:]
    for (id, text) in purchaseRates {
      if purchases[id] != nil, let rate = MoneyBackRateRows.typedRate(text) { rates[id] = rate }
    }
    return rates
  }

  /// What the person owes, as the rates typed for the purchases make it.
  private var repricedOwed: [OwedPart] {
    MoneyBackRateRows.owed(
      owed, purchases: purchases, rates: repricing, calendar: environment.calendar)
  }

  /// The rate typed, when it is a number or a formula above zero (`RateText`).
  private var manualRate: Decimal? {
    MoneyBackRateRows.typedRate(typedRate)
  }

  // MARK: Summary

  @ViewBuilder
  private var summary: some View {
    switch confirmation {
    case .success(let confirmation):
      if let refusal = confirmation.plan.refusal {
        refusalView(refusal, of: confirmation)
      } else {
        planView(confirmation)
      }
    case .failure(.noPerson):
      // Nobody picked — perhaps a name the dictionaries do not know: it can still be income.
      VStack(alignment: .leading, spacing: 8) {
        caption("moneyBack.choosePerson")
        Button(t("moneyBack.asIncome")) {
          recordAsIncome(draft)
          dismiss()
        }
      }
    case .failure(.rateMissing):
      caption("entry.error.rateMissing")
    }
  }

  private func planView(_ confirmation: MoneyBackConfirmation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: Self.summaryLine(confirmation, words: environment.language, money: money))
        .accessibilityIdentifier("moneyBack.summary")
      if confirmation.plan.surplus.raw > 0 {
        if let target = surplusDebt(of: confirmation) {
          // The person owes on a debt too: the money over the parts may repay it.
          Toggle(isOn: $surplusToDebt) {
            Text(
              verbatim: environment.language.format(
                "moneyBack.surplusToDebt", table: "Entry",
                money.exact(confirmation.plan.surplus, currency: confirmation.plan.currency),
                target.debt.name))
          }
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("moneyBack.surplusToDebt")
          if surplusToDebt, let preview = surplusPreview(target, of: confirmation) {
            caption(text: preview).accessibilityIdentifier("moneyBack.surplusToDebt.preview")
          } else {
            surplusCaption(confirmation)
          }
        } else {
          surplusCaption(confirmation)
        }
      }
      if !confirmation.plan.skippedProvisional.isEmpty {
        Label {
          Text(
            verbatim: environment.language.format(
              "moneyBack.skipped", table: "Entry",
              counts: confirmation.plan.skippedProvisional.count))
        } icon: {
          Image(systemName: "hourglass")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  /// «Сверх всего — доход в «Доплатах»: 250.00 ₽».
  private func surplusCaption(_ confirmation: MoneyBackConfirmation) -> some View {
    Text(
      verbatim: environment.language.format(
        "moneyBack.surplus", table: "Entry",
        money.exact(confirmation.plan.surplus, currency: confirmation.plan.currency))
    )
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  /// The debt the surplus of this money back may repay, and what is left on it
  /// (`ReimbursementRecording.debtForSurplus`); only when the money, as the account got it, is
  /// all there is to split: a figure of the account's in another currency stays whole.
  private func surplusDebt(
    of confirmation: MoneyBackConfirmation
  ) -> (debt: Debt, balance: AmountE4)? {
    guard confirmation.plan.refusal == nil, confirmation.plan.surplus.raw > 0,
      let person = confirmation.person,
      confirmation.entry.transaction.accountAmountE4 == nil
    else { return nil }
    return ReimbursementRecording.debtForSurplus(
      of: person, in: confirmation.plan.currency, among: debts, balances: debtBalances)
  }

  /// «В счёт долга «Маша»: 2,000.00 ₽ — остаётся 3,000.00 ₽», and the income above the debt.
  private func surplusPreview(
    _ target: (debt: Debt, balance: AmountE4), of confirmation: MoneyBackConfirmation
  ) -> String? {
    var transaction = confirmation.entry.transaction
    transaction.amountE4 = confirmation.plan.surplus
    transaction.amountRubE4 = confirmation.plan.surplusRub
    guard
      let outcome = try? DebtRules.repayment(
        on: target.debt, by: transaction, balance: target.balance, date: nil)
    else { return nil }
    let applied = money.exact(outcome.applied, currency: target.debt.currency)
    var lines = [
      outcome.closes
        ? environment.format("moneyBack.debt.closes", table: "Entry", target.debt.name, applied)
        : environment.format(
          "moneyBack.debt.repays", table: "Entry", target.debt.name, applied,
          money.exact(target.balance - outcome.applied, currency: target.debt.currency))
    ]
    if let over = outcome.surplus {
      lines.append(
        environment.format(
          "moneyBack.surplus", table: "Entry", money.exact(over.amountE4, currency: over.currency)))
    }
    return lines.joined(separator: "\n")
  }

  /// «закроет: ужин, кино; останется должен: 800.00 ₽» — or «больше ничего не должен».
  static func summaryLine(
    _ confirmation: MoneyBackConfirmation, words: AppLanguage, money: MoneyFormatter
  ) -> String {
    var pieces: [String] = []
    let closed = confirmation.closedParts
    if !closed.isEmpty {
      let names = closed.map { part in
        let name = part.note ?? words("moneyBack.partWithoutNote", table: "Entry")
        return "\(name) (\(money.exact(part.remainingRubE4)))"
      }
      pieces.append(
        words.format("moneyBack.closes", table: "Entry", names.joined(separator: ", ")))
    }
    let still = confirmation.stillOwedRub
    pieces.append(
      still.raw > 0
        ? words.format("moneyBack.stillOwes", table: "Entry", money.exact(still))
        : words("moneyBack.owesNothingMore", table: "Entry"))
    return pieces.joined(separator: "; ")
  }

  @ViewBuilder
  private func refusalView(
    _ refusal: MoneyBackRefusal, of confirmation: MoneyBackConfirmation
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(
          verbatim: t(
            refusal == .owesNothing && !confirmation.offersIncome
              ? "moneyBack.unnamedParts" : Self.refusalKey(refusal)))
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .accessibilityIdentifier("moneyBack.refusal")
      switch refusal {
      case .owesNothing:
        if confirmation.offersIncome {
          Button(t("moneyBack.asIncome")) {
            recordAsIncome(draft)
            dismiss()
          }
        }
      case .owesOnDebt(let debtId):
        debtRepaymentView(debtId, of: confirmation)
      case .onlyProvisional, .provisionalRate, .provisionalPartsOwed:
        EmptyView()
      }
    }
  }

  /// The repayment of a debt owed to me the money turns out to be: what the debt takes and
  /// whether it closes, the income above it, and — for a debt in another currency — the rate
  /// this repayment converts at. «Записать возвратом долга» hands the line the money as the
  /// debt's own (`MoneyBackConfirmation.debtRepayment`), or, when the account holds the debt's
  /// currency, the money as it is: the debt's form then asks how much of it was repaid.
  @ViewBuilder
  private func debtRepaymentView(
    _ debtId: UUID, of confirmation: MoneyBackConfirmation
  ) -> some View {
    let debt = debts.first { $0.id == debtId }
    let converted = debt.flatMap { debtRepaymentDraft(for: $0, of: confirmation) }
    // A debt in rubles takes the money's rubles: «Курс возврата» is its rate, and it has none
    // of its own to ask.
    if let debt, debt.currency != currency, debt.currency != .rub {
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
        GridRow {
          Text(verbatim: environment.format("moneyBack.debtRate", table: "Entry", debt.name))
            .appFont(.caption).foregroundStyle(.secondary)
          HStack(spacing: 6) {
            Text(verbatim: "1 \(debt.currency.code) =").foregroundStyle(.secondary)
            RateTextField(
              title: environment.format("moneyBack.debtRate", table: "Entry", debt.name),
              text: $debtRateText,
              prompt: defaultDebtRate(debt).map { MoneyBackRateRows.shown($0) } ?? "0.00")
            Text(verbatim: "RUB").foregroundStyle(.secondary)
          }
        }
      }
      if let converted {
        caption(
          text: environment.format(
            "moneyBack.debtRate.caption", table: "Entry",
            money.exact(confirmation.entry.transaction.amountE4, currency: currency),
            money.exact(converted.amount, currency: debt.currency)))
      } else if let account {
        caption(
          text: environment.format(
            "moneyBack.debtForm", table: "Entry", account.name, debt.currency.code))
      }
    } else if let debt, debt.currency != currency, converted == nil, let account {
      caption(
        text: environment.format(
          "moneyBack.debtForm", table: "Entry", account.name, debt.currency.code))
    }
    if let debt, let preview = repaymentPreview(debt, converted: converted, of: confirmation) {
      caption(text: preview)
    }
    Button(t("moneyBack.asDebtRepayment")) {
      recordAsDebtRepayment(debtId, converted ?? draft)
      dismiss()
    }
  }

  /// The rate a repayment of `debt` converts at: 1 for a debt in rubles, whatever was typed;
  /// else the one typed, else what a unit of the debt cost when it was lent
  /// (`DebtRules.costRate`), else the bank's rate of the money's day.
  private func debtRate(_ debt: Debt) -> Decimal? {
    guard debt.currency != .rub else { return 1 }
    return MoneyBackRateRows.typedRate(debtRateText) ?? defaultDebtRate(debt)
  }

  private func defaultDebtRate(_ debt: Debt) -> Decimal? {
    guard debt.currency != .rub else { return 1 }
    let journal = debtJournals[debt.id] ?? []
    var operations: [UUID: CoreKit.Transaction] = [:]
    for id in journal.compactMap(\.transactionId) {
      if let entry = try? environment.transactions?.entry(id: id) {
        operations[id] = entry.transaction
      }
    }
    if let cost = DebtRules.costRate(of: debt, journal: journal, operations: operations) {
      return cost
    }
    return rates.resolve(debt.currency, on: environment.calendar.day(of: draft.occurredAt))?
      .rate.perUnit
  }

  private func debtRepaymentDraft(
    for debt: Debt, of confirmation: MoneyBackConfirmation
  ) -> TransactionDraft? {
    guard debt.currency != currency, let rate = debtRate(debt) else { return nil }
    return MoneyBackConfirmation.debtRepayment(
      of: draft, money: confirmation.entry, debt: debt, debtRate: rate, account: account,
      received: legShown.map { MoneyLeg(currency: $0.currency, amount: typedLeg ?? $0.amount) },
      calendar: environment.calendar)
  }

  /// «В счёт долга «Маша»: 1,000.00 ₽ — долг закроется», and the income above it.
  private func repaymentPreview(
    _ debt: Debt, converted: TransactionDraft?, of confirmation: MoneyBackConfirmation
  ) -> String? {
    guard let balance = debtBalances[debt.id] else { return nil }
    var transaction = confirmation.entry.transaction
    var rubPerUnit: Decimal?
    if let converted {
      transaction.currency = converted.currency
      transaction.amountE4 = converted.amount
      transaction.accountCurrency = converted.accountCurrency
      transaction.accountAmountE4 = converted.accountAmount
      rubPerUnit = converted.rate
    } else if debt.currency != currency {
      return nil
    }
    guard
      let outcome = try? DebtRules.repayment(
        on: debt, by: transaction, balance: balance, date: nil, rubPerUnit: rubPerUnit)
    else { return nil }
    let applied = money.exact(outcome.applied, currency: debt.currency)
    var lines = [
      outcome.closes
        ? environment.format("moneyBack.debt.closes", table: "Entry", debt.name, applied)
        : environment.format(
          "moneyBack.debt.repays", table: "Entry", debt.name, applied,
          money.exact(balance - outcome.applied, currency: debt.currency))
    ]
    if let surplus = outcome.surplus {
      lines.append(
        environment.format(
          "moneyBack.surplus", table: "Entry",
          money.exact(surplus.amountE4, currency: surplus.currency)))
    }
    return lines.joined(separator: "\n")
  }

  static func refusalKey(_ refusal: MoneyBackRefusal) -> String {
    switch refusal {
    case .owesNothing: "moneyBack.owesNothing"
    case .owesOnDebt: "moneyBack.owesOnDebt"
    case .onlyProvisional: "moneyBack.onlyProvisional"
    case .provisionalRate: "moneyBack.provisionalRate"
    case .provisionalPartsOwed: "moneyBack.provisionalPartsOwed"
    }
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack {
      Button(t("moneyBack.manual")) { openManual() }
        .disabled(personId == nil && owed.isEmpty)
      Spacer()
      Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
      Button(t("moneyBack.record"), action: record)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canRecord)
    }
  }

  private var canRecord: Bool {
    guard case .success(let confirmation) = confirmation else { return false }
    return confirmation.plan.refusal == nil && amount.raw > 0
  }

  // MARK: The draft

  /// The money back as the sheet holds it now.
  private var draft: TransactionDraft {
    var draft = prefill.draft
    draft.kind = .reimbursement
    draft.amount = amount
    draft.amountExpression = nil
    draft.currency = currency
    draft.paymentMethodId = accountId
    draft.parts = [PartDraft(amount: amount, forPersonId: personId)]
    if currency != prefill.draft.currency {
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      draft.rateProvisional = false
    }
    if currency != .rub, let rate = manualRate {
      draft.rate = rate
      draft.rateDate = environment.calendar.day(of: draft.occurredAt)
      draft.rateSource = .manual
      draft.rateProvisional = false
    }
    let leg = legShown
    draft.accountCurrency = leg?.currency
    draft.accountAmount = leg.map { typedLeg ?? $0.amount }.flatMap { $0.isZero ? nil : $0 }
    return draft
  }

  private var account: PaymentMethod? {
    accounts.first { $0.id == accountId } ?? accounts.first(where: \.isDefault)
  }

  /// «Зачислено на счёт», shown while the account does not hold the currency.
  private var legShown: MoneyLeg? {
    var bare = prefill.draft
    bare.amount = amount
    bare.currency = currency
    if currency != prefill.draft.currency { bare.rate = nil; bare.rateSource = nil }
    if currency != .rub, let rate = manualRate {
      bare.rate = rate
      bare.rateSource = .manual
      bare.rateProvisional = false
    }
    return MoneyBackConfirmation.prefilledLeg(
      for: bare, account: account, rates: rates, calendar: environment.calendar)
  }

  private var confirmation: Result<MoneyBackConfirmation, MoneyBackConfirmation.Problem> {
    do {
      return .success(
        try MoneyBackConfirmation.make(
          draft: draft, owed: repricedOwed, debts: debts, rates: rates,
          calendar: environment.calendar, debtBalances: debtBalances))
    } catch let problem as MoneyBackConfirmation.Problem {
      return .failure(problem)
    } catch {
      return .failure(.rateMissing)
    }
  }

  // MARK: Actions

  private func reload() {
    people = (try? environment.references?.people()) ?? []
    owed = (try? environment.transactions?.owedParts()) ?? []
    debts = (try? environment.references?.debts()) ?? []
    accounts = (try? environment.references?.paymentMethods()) ?? []
    rates = (try? environment.rates?.table()) ?? RateTable()
    purchases = [:]
    for id in Set(owed.filter { $0.currency != .rub }.map(\.transactionId)) {
      if let entry = try? environment.transactions?.entry(id: id) { purchases[id] = entry }
    }
    debtBalances = [:]
    debtJournals = [:]
    for debt in debts where debt.direction == .owedToMe && !debt.closed {
      guard let journal = try? environment.references?.debtEntries(debtId: debt.id) else {
        continue
      }
      debtJournals[debt.id] = journal
      debtBalances[debt.id] = DebtRules.balance(entries: journal)
    }
    if accountId == nil { accountId = accounts.first(where: \.isDefault)?.id }
    // With nobody named, the one person who owes anything is the one.
    if personId == nil {
      let debtors = Set(owed.compactMap(\.debtorPersonId))
      if debtors.count == 1 { personId = debtors.first }
    }
  }

  private func record() {
    guard case .success(let confirmation) = confirmation,
      let repository = environment.transactions
    else { return }
    do {
      let recordingSetting = try setting(
        repository, hasSurplus: confirmation.plan.surplus.raw > 0)
      guard let drawn = try confirmation.recording(setting: recordingSetting) else { return }
      var written = ReimbursementRecording(
        outcome: drawn.outcome, reimbursement: drawn.reimbursement, extra: drawn.extra)
      var settling = DebtSettling.none
      // The money over the parts repays the person's debt when the owner left the switch on.
      if surplusToDebt, let target = surplusDebt(of: confirmation),
        let split = try written.repayingDebt(
          target.debt, balance: target.balance,
          on: environment.calendar.day(of: confirmation.entry.transaction.occurredAt),
          now: Date(), setting: recordingSetting)
      {
        written = split.recording
        settling = split.settling
      }
      let write = try repository.apply(
        written.outcome, reimbursement: written.reimbursement, extra: written.extra,
        debt: settling, repricing: repricing,
        settlement: SettlementSetting(surplusNote: t("reimbursement.surplus")),
        calendar: environment.calendar)
      if !write.repricedBefore.isEmpty {
        AppLog.info(
          "moneyBack.repriced", .db, "purchases were written at a rate typed for money back",
          [LogPair("purchases", .count(write.repricedBefore.count))])
      }
      write.settlement.counts.log()
      environment.scheduleBackup()
      // Several operations and the links between them went in at once, in one write: one step
      // of ⌘Z takes all of it back.
      store.recordedMoneyBack(write)
      recorded()
      dismiss()
    } catch ReimbursementError.partNoLongerOwed {
      errorKey = "reimbursement.partGone"
      reload()
    } catch ReimbursementRecording.Failure.noSurchargesCategory {
      AppLog.error("reimb.noSurcharges", .db, "no Surcharges category for a surplus")
      errorKey = "reimbursement.noSurcharges"
    } catch AccountWriteError.chargeMissing {
      errorKey = "entry.error.chargeMissing"
    } catch {
      AppLog.error(
        "reimbursement.failed", .db, "a reimbursement was not recorded",
        [LogPair("error", .error(error))])
      errorKey = "reimbursement.failed"
    }
  }

  /// «Вручную…»: the per-part sheet, in rubles, with this money and this account.
  private func openManual() {
    let current = draft
    let rubles =
      (try? MoneyBackConfirmation.make(
        draft: current, owed: owed, debts: debts, rates: rates, calendar: environment.calendar))?
      .entry.transaction.amountRubE4
    var prefillDraft = current
    if personId == nil { prefillDraft.parts[0].forPersonId = nil }
    manual = ReimbursementPrefill(
      draft: prefillDraft, received: rubles ?? (currency == .rub ? amount : .zero),
      accounts: accounts)
  }

  private func setting(
    _ repository: TransactionRepository, hasSurplus: Bool
  ) throws
    -> ReimbursementRecording.Setting
  {
    let categories = try environment.references?.categories(includeArchived: true) ?? []
    return ReimbursementRecording.Setting(
      // What is over the parts of a person's money back is income in «Для оплаты чего-либо»,
      // made the first time there is any.
      surchargesCategoryId: hasSurplus
        ? try environment.references.map {
          try PaidForOthersCategory.ensure(references: $0, name: t("paidForOthers.category"))
        } : nil,
      categories: CategoryTree(categories),
      history: try repository.manualQualityHistory(),
      surplusNote: t("reimbursement.surplus"),
      shortfallNote: t("reimbursement.shortfall"))
  }

  // MARK: Pieces

  /// People who owe something first, then everyone else, each group by name.
  private var orderedPeople: [Person] {
    let debtors = Set(owed.compactMap(\.debtorPersonId))
    return people.sorted { left, right in
      let leftOwes = debtors.contains(left.id)
      let rightOwes = debtors.contains(right.id)
      if leftOwes != rightOwes { return leftOwes }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
  }

  private var orderedAccounts: [PaymentMethod] {
    let live = AccountRules.ordered(accounts, locale: environment.language.locale)
    guard let accountId, !live.contains(where: { $0.id == accountId }),
      let current = accounts.first(where: { $0.id == accountId })
    else { return live }
    return live + [current]
  }

  private var currencyChoices: [CurrencyCode] {
    var codes = environment.vocabulary.enabledCurrencies
    if !codes.contains(currency) { codes.append(currency) }
    return codes
  }

  private var money: MoneyFormatter { environment.money }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key))
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.leading)
  }

  private func caption(_ key: String) -> some View {
    caption(text: t(key))
  }

  private func caption(text: String) -> some View {
    Text(verbatim: text)
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}
