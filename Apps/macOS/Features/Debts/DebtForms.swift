import AppCore
import SwiftUI

/// Which form the Debts section shows.
enum DebtSheet: Identifiable {
  case create
  case pay(Debt)
  /// «Платёж» that starts at `at` from `account` — a due date paid from the reminders, dated
  /// the day it was due or now, from the account the debt is paid from. `nil` leaves the form's
  /// own start: now, the main account.
  case payAt(Debt, at: Date?, account: UUID?)
  /// «Pay» opened from a money back that turned out to be a repayment of this debt: the
  /// amount given back when it is in the debt's currency, on the account it came to.
  case repay(Debt, amount: AmountE4?, account: UUID?)
  case entry(Debt)
  case offset(Debt)
  case transfer(Debt, balance: AmountE4, others: [Debt])
  case adjust(Debt, balance: AmountE4)
  case close(Debt, balance: AmountE4)
  /// «График…»: the grace period, the main payment and how the bank counts a payment of a loan.
  case schedule(Debt)
  /// «Добавить транш…» (`TrancheSheet`).
  case tranche(Debt)

  var id: String {
    switch self {
    case .create: "create"
    case .pay(let debt): "pay-\(debt.id)"
    case .payAt(let debt, _, _): "payAt-\(debt.id)"
    case .repay(let debt, _, _): "repay-\(debt.id)"
    case .entry(let debt): "entry-\(debt.id)"
    case .offset(let debt): "offset-\(debt.id)"
    case .transfer(let debt, _, _): "transfer-\(debt.id)"
    case .adjust(let debt, _): "adjust-\(debt.id)"
    case .close(let debt, _): "close-\(debt.id)"
    case .schedule(let debt): "schedule-\(debt.id)"
    case .tranche(let debt): "tranche-\(debt.id)"
    }
  }
}

/// The forms of the Debts section: system `Form`, no glass; the main action writes one change,
/// one step of ⌘Z, and closes the sheet only over a write that landed.
struct DebtSheetView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let sheet: DebtSheet
  /// Told once the action has landed: the reminders sheet takes its row away then, so the
  /// same payment is not offered twice.
  var onDone: () -> Void = {}
  /// The due a reminder's «Платёж» is for: one of next month is paid on its own day.
  var payDue: DateOnly?

  @State private var debt = Debt(direction: .iOwe, type: .loan, name: "")
  @State private var amount: AmountE4 = .zero
  @State private var fullAmount: AmountE4 = .zero
  @State private var shareText = ""
  @State private var byShare = false
  @State private var moneyMoved = false
  @State private var date = Date()
  @State private var method: UUID?
  @State private var text = ""
  @State private var group = ""
  @State private var target: UUID?
  @State private var writeOff = true
  @State private var loaded = false
  @State private var rateText = ""
  @State private var failed: String?
  /// What is left on the debt, read from the journal when the form opens; `nil` without a
  /// database, and the figure the card was drawn with stands in (`shown`).
  @State private var balance: AmountE4?
  @State private var closesDebt = true
  /// «В этом месяце больше платежей не будет»: a payment smaller than the due closes it.
  @State private var closesTerm = false
  /// «Уменьшить срок / Уменьшить платёж» of a payment above the dues; `nil` — the answer offered
  /// first (`DebtPrepayment.question`).
  @State private var prepayChoice: PrepayChoice?
  /// «Платёж за этот месяц уже сделан?» of a loan written on its payment day: unanswered until
  /// the owner says; the form does not save before.
  @State private var monthPaid: Bool?
  /// «Списано со счёта» of the money this form moves, when its account does not hold the
  /// debt's currency.
  @State private var charge = FormCharge()
  /// The bank's rates, read once when the form opens.
  @State private var rates = RateTable()
  @State private var question: BeforeTheCountQuestion?
  /// «График» of a new loan or of the loan `.schedule` edits.
  @State private var schedule = DebtSchedule(mainFrom: DateOnly(year: 2000, month: 1, day: 1))

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: title).appFont(.headline)
      Form { fields }
        .formStyle(.grouped)
      if let failed {
        // Never left open without a word (review of the app, 19.09).
        Text(verbatim: failed)
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(action.title) {
          switch countAsk() {
          case .none:
            finish(at: date)
          case .answered(let stamp):
            // Answered for this reconciliation already: saved at that moment, unasked.
            finish(at: stamp)
          case .ask(let questions):
            question = BeforeTheCountQuestion(
              count: questions.count, reconciliation: questions.reconciliation,
              questions: questions)
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!action.enabled)
      }
    }
    .padding(20)
    .sheetFrame(width: 480)
    .onAppear(perform: load)
    .onChange(of: chargeInputs) { refreshCharge() }
    .beforeTheCountQuestions($question) { stamp in finish(at: stamp) }
  }

  /// Writes with the operation or the line dated `moment`; the sheet closes over a write that
  /// landed, and says why otherwise.
  private func finish(at moment: Date) {
    if action.run(moment) {
      onDone()
      dismiss()
    } else {
      failed = failure()
    }
  }

  // MARK: The account the money moves on

  /// The debt whose money this form moves on an account, and whether the money leaves it (a
  /// payment of a debt I owe, money lent) or comes to it; `nil` while it moves none.
  private var movesMoney: (debt: Debt, leaves: Bool)? {
    switch sheet {
    case .create:
      return moneyMoved ? (debt, debt.direction == .owedToMe) : nil
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _), .offset(let debt):
      return (debt, debt.direction == .iOwe)
    case .entry(let debt):
      return moneyMoved ? (debt, debt.direction == .owedToMe) : nil
    case .transfer, .adjust, .close, .schedule, .tranche:
      return nil
    }
  }

  /// The account row and «Списано со счёта» under it.
  @ViewBuilder
  private var accountRows: some View {
    if let moves = movesMoney {
      AccountPicker(
        title: environment.language(
          moves.leaves ? "entry.account.from" : "entry.account.to", table: "Entry"),
        accounts: methods, selection: $method)
      ChargeRow(charge: $charge)
    }
  }

  /// The money moved in the debt's currency: a share of a full amount when typed so.
  private var movedAmount: AmountE4 {
    if case .entry = sheet, byShare, let share = DebtRules.parseShare(shareText),
      let part = try? DebtRules.share(of: fullAmount, share: share)
    {
      return part
    }
    return amount
  }

  private struct ChargeInputs: Equatable {
    var amount: AmountE4
    var date: Date
    var account: UUID?
    var currency: CurrencyCode?
  }

  private var chargeInputs: ChargeInputs {
    ChargeInputs(
      amount: movedAmount, date: date, account: method, currency: movesMoney?.debt.currency)
  }

  private func refreshCharge() {
    guard let moves = movesMoney else {
      charge.refresh(nil)
      return
    }
    charge.refresh(
      FormAccounts.charge(
        amount: movedAmount, currency: moves.debt.currency, at: date, rate: nil,
        account: FormAccounts.account(method, among: methods), table: rates,
        calendar: environment.calendar))
  }

  /// What to ask «Это было до сверки в 14:05?» about before the write: every count made on the
  /// day of the operation of a payment — or of the line of money borrowed or lent — of a
  /// balance it moves, before it is saved, oldest first. A reconciliation the owner answered
  /// with «Больше не спрашивать» answers by itself (`AccountReconciliation.countToAsk`).
  private func countAsk() -> CountAsk {
    guard let dependencies, action.enabled else { return .none }
    let actions = DebtActions(dependencies)
    let remembered = environment.rememberedCountAnswers()
    switch sheet {
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _), .offset(let debt):
      guard
        let entry = try? actions.paymentOperation(
          debt, amount: amount, on: date, account: method, charged: charge.typedFigure)
      else { return .none }
      return FormAccounts.countAsk(
        about: entry, savedAt: Date(), snapshot: compute.snapshot,
        calendar: environment.calendar, remembered: remembered)
    case .create, .entry:
      guard let moves = movesMoney else { return .none }
      var line = DebtRules.makeEntry(debtId: moves.debt.id, kind: .borrowed, amountE4: movedAmount)
      guard
        (try? actions.layCash(
          on: &line, of: moves.debt, account: method, charged: charge.typedFigure, at: date))
          != nil
      else { return .none }
      return FormAccounts.countAsk(
        about: line, of: moves.debt, savedAt: Date(), snapshot: compute.snapshot,
        calendar: environment.calendar, remembered: remembered)
    case .transfer, .adjust, .close, .schedule, .tranche:
      return .none
    }
  }

  // MARK: The fields of each form

  @ViewBuilder
  private var fields: some View {
    switch sheet {
    case .create:
      Button(t("schedule.preset.educationLoan")) { applyEducationLoanPreset() }
        .accessibilityIdentifier("debt.create.educationLoan")
      TextField(t("form.name"), text: $debt.name)
      // A credit card is an account with a minus, not a debt: a debt called like an account
      // would take the same money off the free sum twice.
      if let match = accountAnswering(to: debt.name) {
        Label {
          Text(
            verbatim: environment.format("form.name.isAnAccount", table: "Debts", match.accountName)
          )
          .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Picker(t("form.direction"), selection: $debt.direction) {
        Text(verbatim: t("debts.iOwe")).tag(DebtDirection.iOwe)
        Text(verbatim: t("debts.owedToMe")).tag(DebtDirection.owedToMe)
      }
      .pickerStyle(.segmented)
      Picker(t("form.type"), selection: $debt.type) {
        ForEach(DebtType.allCases, id: \.self) {
          Text(verbatim: t("debts.type.\($0.rawValue)")).tag($0)
        }
      }
      if debt.type == .personal {
        Picker(t("form.person"), selection: $debt.personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
      }
      Picker(t("form.currency"), selection: $debt.currency) {
        ForEach(currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
      }
      LabeledContent(t("form.balance")) { amountField($amount) }
      if amount.isNegative {
        Text(verbatim: t("form.balance.negative")).appFont(.caption).foregroundStyle(.secondary)
      }
      Toggle(t("form.moneyMovedToday"), isOn: $moneyMoved)
      accountRows
      paymentFields
      if debt.direction == .iOwe {
        Toggle(t("debts.paymentsAreExpenses"), isOn: $debt.paymentsAreExpenses)
      }
      scheduleSection(principal: amount)
      // Written on the day its payment falls due: the balance is the one before or after the
      // payment, and only the owner knows which. No answer is assumed.
      if asksAboutThisMonth {
        Picker(t("form.monthPaid"), selection: $monthPaid) {
          Text(verbatim: "—").tag(Bool?.none)
          Text(verbatim: t("form.monthPaid.yes")).tag(Bool?.some(true))
          Text(verbatim: t("form.monthPaid.no")).tag(Bool?.some(false))
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("debt.create.monthPaid")
        Text(verbatim: t(monthPaid == nil ? "form.monthPaid.ask" : "form.monthPaid.hint"))
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _), .offset(let debt):
      LabeledContent(t("form.amount")) { amountField($amount, currency: debt.currency) }
      DatePicker(t("form.date"), selection: $date)
      accountRows
      if isPayment {
        Text(
          verbatim: t(
            DebtRules.paymentIsExpense(on: debt)
              ? "form.pay.expense"
              : (debt.direction == .iOwe ? "form.pay.notExpense" : "form.pay.returned"))
        )
        .appFont(.caption).foregroundStyle(.secondary)
        if let question = prepayQuestion {
          Picker(
            environment.format(
              "prepay.question", table: "Debts",
              environment.money.exact(question.excess, currency: debt.currency)),
            selection: Binding(
              get: { prepayChoice ?? question.choice }, set: { prepayChoice = $0 })
          ) {
            Text(verbatim: t("prepay.term")).tag(PrepayChoice.term)
            Text(verbatim: t("prepay.payment")).tag(PrepayChoice.payment)
            Text(verbatim: t("prepay.forward")).tag(PrepayChoice.forward)
          }
          .pickerStyle(.radioGroup)
          .accessibilityIdentifier("debt.pay.prepay")
          Text(verbatim: t("prepay.hint"))
            .appFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if offersClosingTerm {
          Toggle(t("form.pay.closesTerm"), isOn: $closesTerm)
            .accessibilityIdentifier("debt.pay.closesTerm")
          Text(verbatim: t("form.pay.closesTermHint"))
            .appFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if paysOff, let balance {
          let over = amount > balance
          let repaysOver = over && debt.direction == .owedToMe
          // Said, and closing offered: paid off and left open, the debt stayed in its list at
          // zero or below, and went on being reminded of. Money given back above a debt owed to
          // me always closes it — the rest is income — so there is nothing to ask.
          if !repaysOver {
            Toggle(t("form.pay.close"), isOn: $closesDebt)
          }
          if over {
            let split = Self.overBalance(amount, balance: balance, direction: debt.direction)
            Text(
              verbatim: environment.format(
                repaysOver ? "form.pay.overSurplus" : "form.pay.over", table: "Debts",
                environment.money.exact(split.left, currency: debt.currency),
                environment.money.exact(split.over, currency: debt.currency))
            )
            .appFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        TextField(t("form.description"), text: $text)
      }
    case .entry(let debt):
      Toggle(t("form.moneyMoved"), isOn: $moneyMoved)
      Toggle(t("form.byShare"), isOn: $byShare)
      if byShare {
        LabeledContent(t("form.fullAmount")) { amountField($fullAmount, currency: debt.currency) }
        TextField(t("form.share"), text: $shareText)
        if let share = DebtRules.parseShare(shareText),
          let part = try? DebtRules.share(of: fullAmount, share: share)
        {
          Text(verbatim: environment.money.exact(part, currency: debt.currency)).appFont(
            .caption.monospacedDigit())
        }
      } else {
        LabeledContent(t("form.amount")) { amountField($amount, currency: debt.currency) }
      }
      TextField(t("form.group"), text: $group)
      TextField(t("form.description"), text: $text)
      DatePicker(t("form.date"), selection: $date, displayedComponents: .date)
      accountRows
    case .transfer(let debt, let carried, let others):
      let balance = shown(carried)
      Text(
        verbatim: environment.format(
          "form.transfer.from", table: "Debts", debt.name,
          environment.money.exact(balance, currency: debt.currency)))
      Picker(t("form.transfer.to"), selection: $target) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(others.filter { $0.currency == debt.currency && !$0.closed }) {
          Text(verbatim: $0.name).tag(Optional($0.id))
        }
      }
      LabeledContent(t("form.amount")) { amountField($amount, currency: debt.currency) }
      if amount > balance {
        // Refused, not capped: the source would close with money on it.
        Text(verbatim: t("form.transfer.tooMuch")).appFont(.caption).foregroundStyle(.secondary)
      }
      DatePicker(t("form.date"), selection: $date, displayedComponents: .date)
    case .adjust(let debt, let carried):
      Text(
        verbatim: environment.format(
          "form.adjust.now", table: "Debts",
          environment.money.exact(shown(carried), currency: debt.currency)))
      LabeledContent(t("form.adjust.to")) { amountField($amount, currency: debt.currency) }
      if let over = Self.overpaid(to: amount) {
        // Asked, not refused: an overpaid card is below zero for real.
        Text(
          verbatim: environment.format(
            "form.adjust.negative", table: "Debts",
            environment.money.exact(over, currency: debt.currency))
        )
        .appFont(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      TextField(t("form.note"), text: $text)
    case .close(let debt, let carried):
      Text(
        verbatim: environment.format(
          "form.close.balance", table: "Debts",
          environment.money.exact(shown(carried), currency: debt.currency)))
      if !shown(carried).isZero {
        Toggle(t("form.close.writeOff"), isOn: $writeOff)
      }
    case .schedule:
      paymentFields
      scheduleSection(principal: balance ?? .zero)
    case .tranche:
      // Written by `TrancheSheet`, which the Debts section shows in place of this form.
      EmptyView()
    }
  }

  /// The rate, the main payment and its day — of a new loan and of the schedule of one. The
  /// payment is not typed when it is worked out over a term; the day is asked whenever there are
  /// monthly dues.
  @ViewBuilder
  private var paymentFields: some View {
    TextField(t("form.rate"), text: $rateText)
    if !schedule.byTerm {
      LabeledContent(t(schedule.hasGrace ? "schedule.mainPayment" : "form.monthlyPayment")) {
        amountField(
          Binding(
            get: { debt.monthlyPaymentE4 ?? .zero },
            set: { debt.monthlyPaymentE4 = $0.isZero ? nil : $0 }))
      }
      if schedule.issues(
        rate: DebtPayoff.parseRate(rateText), monthly: debt.monthlyPaymentE4,
        direction: debt.direction
      ).contains(.mainPaymentMissing) {
        Text(verbatim: t("schedule.issue.mainPayment"))
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    // A day of payment only with a payment: a loan from a friend with no schedule is not
    // reminded of on the 1st (third review, 19.09).
    if debt.monthlyPaymentE4 != nil || schedule.needsPaymentDay {
      Stepper(
        value: Binding(get: { debt.paymentDay ?? 1 }, set: { debt.paymentDay = $0 }), in: 1...31
      ) {
        Text(
          verbatim: Self.paymentDayText(debt.paymentDay ?? 1, language: environment.language))
      }
    }
  }

  private func scheduleSection(principal: AmountE4) -> some View {
    DebtScheduleSection(
      schedule: $schedule, direction: debt.direction, rate: DebtPayoff.parseRate(rateText),
      principal: principal, currency: debt.currency)
  }

  /// «Образовательный кредит (госпрограмма)»: a loan I owe at 3 %, the grace payments of the
  /// state programme, the main debt over 180 months; the tranches are the expense, so its
  /// payments are not. How the bank counts a payment is still asked.
  private func applyEducationLoanPreset() {
    let preset = Self.educationLoan(debt, today: environment.today, language: environment.language)
    debt = preset.debt
    rateText = preset.rateText
    schedule = preset.schedule
  }

  /// What the preset of the education loan makes of the debt being created.
  static func educationLoan(
    _ debt: Debt, today: DateOnly, language: AppLanguage
  ) -> (debt: Debt, rateText: String, schedule: DebtSchedule) {
    var made = debt
    made.direction = .iOwe
    made.type = .loan
    made.paymentsAreExpenses = false
    made.monthlyPaymentE4 = nil
    if made.paymentDay == nil { made.paymentDay = 1 }
    if made.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      made.name = language("schedule.preset.educationLoan.name", table: "Debts")
    }
    return (made, DebtSchedule.educationLoanRate, DebtSchedule.educationLoan(today: today))
  }

  /// The debt the create form saves: its rate, schedule and day of payment.
  static func made(
    _ debt: Debt, rateText: String, schedule: DebtSchedule
  ) -> Debt {
    let rate = DebtPayoff.parseRate(rateText)
    var made = schedule.applied(to: debt, rate: rate)
    made.paymentDay = savedPaymentDay(
      monthly: made.monthlyPaymentE4, day: made.paymentDay, scheduled: schedule.needsPaymentDay)
    if made.direction == .owedToMe { made.paymentsAreExpenses = false }
    return made
  }

  private func amountField(_ value: Binding<AmountE4>, currency: CurrencyCode? = nil) -> some View {
    HStack {
      AmountField(amount: value)
      if let currency { Text(verbatim: currency.code).foregroundStyle(.secondary) }
    }
  }

  // MARK: What «Save» does

  /// «Pay» — from the card or as the repayment a money back turned out to be.
  private var isPayment: Bool {
    switch sheet {
    case .pay, .payAt, .repay: true
    default: false
    }
  }

  /// The main action: its title, whether it can run, and the write, given the moment the money
  /// moved — the date of the form, or the one the answer about a count stamped.
  private var action: (title: String, enabled: Bool, run: (Date) -> Bool) {
    let day = environment.calendar.day(of: date)
    guard let dependencies else { return (t("form.save"), false, { _ in false }) }
    let charged = charge.typedFigure
    let complete = movesMoney == nil || charge.isComplete
    let actions = DebtActions(dependencies)
    switch sheet {
    case .create:
      let made = Self.made(debt, rateText: rateText, schedule: schedule)
      let valid =
        !debt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !amount.isNegative
        && schedule.issues(
          rate: made.interestRate, monthly: debt.monthlyPaymentE4, direction: debt.direction
        ).isEmpty
      let answered = Self.monthIsAnswered(asks: asksAboutThisMonth, monthPaid: monthPaid)
      let termPaid = asksAboutThisMonth && monthPaid == true
      return (
        t("form.save"), valid && complete && answered,
        { moment in
          actions.create(
            made, balance: amount, on: environment.today, moneyMovedNow: moneyMoved,
            account: method, charged: charged, at: moment, termPaid: termPaid)
        }
      )
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _):
      let closing = paysOff && closesDebt
      let closesTheTerm = offersClosingTerm && closesTerm
      let prepay = prepayQuestion.map { prepayChoice ?? $0.choice }
      return (
        t("debts.pay"), amount.raw > 0 && complete,
        { moment in
          actions.pay(
            debt, amount: amount, on: moment, paymentMethodId: method, closing: closing,
            charged: charged, closesTerm: closesTheTerm, prepay: prepay)
        }
      )
    case .offset(let debt):
      return (
        t("debts.offset"), amount.raw > 0 && complete,
        { moment in
          actions.offset(
            debt, amount: amount, on: moment, description: text.isEmpty ? nil : text,
            account: method, charged: charged)
        }
      )
    case .entry(let debt):
      let share = byShare ? DebtRules.parseShare(shareText) : nil
      let valid = byShare ? (share != nil && fullAmount.raw > 0) : amount.raw > 0
      return (
        t("debts.addEntry"), valid && complete,
        { moment in
          actions.addEntry(
            debt, amount: amount, fullAmount: byShare ? fullAmount : nil, share: share,
            on: environment.calendar.day(of: moment), group: group.isEmpty ? nil : group,
            description: text.isEmpty ? nil : text, moneyMoved: moneyMoved, account: method,
            charged: charged, at: moneyMoved ? moment : nil)
        }
      )
    // The actions read the journal again when they write: what landed since the form opened
    // is not written off, transferred or adjusted over.
    case .transfer(let debt, let carried, let others):
      let destination = others.first { $0.id == target }
      let balance = shown(carried)
      return (
        t("debts.transfer"), destination != nil && amount.raw > 0 && amount <= balance,
        { _ in
          guard let destination else { return false }
          return actions.transfer(debt, balance: balance, to: destination, amount: amount, on: day)
        }
      )
    case .adjust(let debt, let carried):
      let balance = shown(carried)
      return (
        t("debts.adjust"), amount != balance,
        { _ in
          actions.adjust(debt, from: balance, to: amount, on: day, note: text.isEmpty ? nil : text)
        }
      )
    case .close(let debt, let carried):
      return (
        t("debts.close"), true,
        { _ in actions.close(debt, balance: shown(carried), writeOff: writeOff, on: day) }
      )
    case .schedule:
      let made = Self.made(debt, rateText: rateText, schedule: schedule)
      let valid = schedule.issues(
        rate: made.interestRate, monthly: debt.monthlyPaymentE4, direction: debt.direction
      ).isEmpty
      return (t("form.save"), valid, { _ in actions.save(made) })
    case .tranche:
      return (t("form.save"), false, { _ in false })
    }
  }

  /// Why the action did not happen: no rate for the debt's currency on that day, or else.
  /// Why the action did not happen. Only a payment and an «Offset» write an operation that
  /// needs a rate; the other actions write the journal alone, so a rate is never the reason.
  private func failure() -> String {
    let generic = environment.language("form.notSaved", table: "Planning")
    guard let dependencies else { return generic }
    switch sheet {
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _), .offset(let debt):
      if !charge.isComplete {
        return environment.language("entry.error.chargeMissing", table: "Entry")
      }
      return environment.format(
        PlanningActions(dependencies).failureKey(currency: debt.currency, on: date, at: .debt),
        table: "Planning", debt.currency.code)
    case .create, .entry, .transfer, .adjust, .close, .schedule, .tranche:
      return generic
    }
  }

  /// The date «Платёж» starts with when it pays `due`: always now. A payment pays the earliest
  /// unpaid due whatever its date, so the date is when the money moved, never the due's —
  /// a due paid from a reminder is dated by the reminder's own question (`payAt`).
  static func payDate(due: DateOnly?, today: DateOnly, calendar: CalendarContext) -> Date? {
    nil
  }

  /// What «Платёж» starts with, for `.pay` and `.payAt`: the debt, what is left of its earliest
  /// unpaid due (the monthly payment when nothing is paid toward it), the
  /// moment — the one `.payAt` names, else `payDate`, `nil` being now — and the account — the
  /// one `.payAt` names while it is live, else the main one (`FormAccounts.account`). `nil` for
  /// every other sheet, a repayment included: that one starts with what came back.
  static func payStart(
    of sheet: DebtSheet, payDue: DateOnly?, today: DateOnly, calendar: CalendarContext,
    methods: [PaymentMethod], dues: DebtDueState? = nil
  ) -> (debt: Debt, amount: AmountE4, date: Date?, method: UUID?)? {
    let debt: Debt
    let moment: Date?
    let account: UUID?
    switch sheet {
    case .pay(let paid): (debt, moment, account) = (paid, nil, nil)
    case .payAt(let paid, let at, let from): (debt, moment, account) = (paid, at, from)
    default: return nil
    }
    return (
      debt, DebtTerms.amountToPay(debt, dues: dues),
      moment ?? payDate(due: payDue, today: today, calendar: calendar),
      FormAccounts.account(account, among: methods)?.id
    )
  }

  /// Whether «Pay» starts with «Close the debt» on once the payment covers what is left. A
  /// credit card is paid down to zero month after month and stays open; any other debt paid
  /// off is done with.
  static func closesWhenPaidOff(_ debt: Debt) -> Bool { debt.type != .creditCard }

  /// A payment above what is left on the debt, as the form says it: what is left, and what goes
  /// over it. A debt owed to me takes nothing below zero — 1.1 could leave one at −700 ₽ —, so
  /// 500 ₽ paid on it are 500 ₽ over, all of it income, as the repayment writes them.
  static func overBalance(
    _ amount: AmountE4, balance: AmountE4, direction: DebtDirection
  ) -> (left: AmountE4, over: AmountE4) {
    let left = direction == .owedToMe ? max(balance, .zero) : balance
    return (left, amount - left)
  }

  /// How much more than owed a balance below zero says was paid; `nil` at zero and above.
  static func overpaid(to balance: AmountE4) -> AmountE4? {
    balance.isNegative ? balance.magnitude : nil
  }

  /// What is left on the debt as the form shows it: the journal read when it opened, else the
  /// figure the card handed over.
  private func shown(_ carried: AmountE4) -> AmountE4 { balance ?? carried }

  /// «Платёж за этот месяц уже сделан?» must be answered before the debt is saved: «Сохранить»
  /// stays off while the question is asked and neither «Да» nor «Нет» is picked.
  nonisolated static func monthIsAnswered(asks: Bool, monthPaid: Bool?) -> Bool {
    !asks || monthPaid != nil
  }

  /// A loan written today on the day its payment falls due asks whether this month's payment is
  /// made already (`DebtTerms.asksAboutThisMonth`).
  private var asksAboutThisMonth: Bool {
    guard case .create = sheet else { return false }
    let made = Self.made(debt, rateText: rateText, schedule: schedule)
    return DebtTerms.asksAboutThisMonth(made, balance: amount, today: environment.today)
  }

  /// The state of the dues of the debt the form pays, as the planning last worked them out.
  private func dues(of debt: Debt) -> DebtDueState? {
    compute.snapshot?.planning.debts.iOwe.first { $0.debt.id == debt.id }?.dues
  }

  /// «В этом месяце больше платежей не будет» is offered while the payment typed leaves part of
  /// the due unpaid (`DebtTerms.offersClosing`); a repayment of a debt owed to me has no dues.
  private var offersClosingTerm: Bool {
    switch sheet {
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _):
      return DebtTerms.offersClosing(debt, paying: amount, dues: dues(of: debt))
    default:
      return false
    }
  }

  /// «Сверх платежа X — Уменьшить срок / Уменьшить платёж / Это платёж вперёд» of a payment of a
  /// loan above what its dues ask by the day of the form; never when it pays the debt off.
  private var prepayQuestion: (excess: AmountE4, choice: PrepayChoice)? {
    switch sheet {
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _):
      guard !paysOff else { return nil }
      return DebtPrepayment.question(
        debt: debt, amount: amount, day: environment.calendar.day(of: date), dues: dues(of: debt),
        journal: compute.snapshot?.dataset.planning.debtEntries.filter { $0.debtId == debt.id }
          ?? [])
    default:
      return nil
    }
  }

  /// The payment typed covers what is left on the debt.
  private var paysOff: Bool {
    guard let balance else { return false }
    return DebtActions.paysOff(amount, balance: balance)
  }

  /// The day of payment a new debt is saved with: the one shown — the 1st until changed —
  /// when it has a monthly payment, none without one.
  static func savedPaymentDay(monthly: AmountE4?, day: Int?, scheduled: Bool = false) -> Int? {
    monthly == nil && !scheduled ? nil : (day ?? 1)
  }

  /// The caption of the day stepper: «День платежа: 5», and at 31 «последний день» — a debt due
  /// on the 31st is due on the last day of every shorter month.
  static func paymentDayText(_ day: Int, language: AppLanguage) -> String {
    let shown = day >= 31 ? language("form.paymentDay.last", table: "Debts") : String(day)
    return language.format("form.paymentDay", table: "Debts", shown)
  }

  /// The payment on the card of a debt: «платёж 5,000 ₽, 10-го числа», and at 31 «…, в
  /// последний день месяца» — the day the stepper calls «последний день». `amount` is the
  /// payment as the card writes money.
  static func cardPaymentText(_ amount: String, day: Int?, language: AppLanguage) -> String {
    if let day, day >= 31 {
      return language.format("debts.payment.lastDay", table: "Debts", amount)
    }
    return language.format("debts.payment", table: "Debts", amount, day.map(String.init) ?? "—")
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    rates = (try? environment.rates?.table()) ?? RateTable()
    method = FormAccounts.account(nil, among: methods)?.id
    switch sheet {
    case .create:
      debt = Self.newDebt(defaultCurrency: environment.defaultCurrency)
      schedule = DebtSchedule(mainFrom: DebtSchedule.defaultMainFrom(today: environment.today))
    case .schedule(let edited):
      debt = edited
      rateText = edited.interestRate.map { environment.money.number($0) } ?? ""
      schedule = DebtSchedule(debt: edited, today: environment.today)
      balance = dependencies.flatMap { DebtActions($0).balance(of: edited) }
    case .repay(let debt, let given, let account):
      amount = given ?? debt.monthlyPaymentE4 ?? .zero
      method = FormAccounts.account(account, among: methods)?.id
      balance = dependencies.flatMap { DebtActions($0).balance(of: debt) }
      closesDebt = Self.closesWhenPaidOff(debt)
    case .transfer(let debt, let carried, _), .adjust(let debt, let carried):
      balance = dependencies.flatMap { DebtActions($0).balance(of: debt) }
      amount = shown(carried)
    case .close(let debt, _):
      balance = dependencies.flatMap { DebtActions($0).balance(of: debt) }
    default:
      break
    }
    var paidDebt: Debt?
    switch sheet {
    case .pay(let debt), .payAt(let debt, _, _): paidDebt = debt
    default: break
    }
    if let start = Self.payStart(
      of: sheet, payDue: payDue, today: environment.today, calendar: environment.calendar,
      methods: methods, dues: paidDebt.flatMap(dues(of:)))
    {
      amount = start.amount
      if let moment = start.date {
        date = moment
      }
      method = start.method
      // What pays the debt off: on a loan that accrues interest, the interest accrued too.
      balance = dependencies.flatMap { DebtActions($0).payoff(of: start.debt) }
      closesDebt = Self.closesWhenPaidOff(start.debt)
    }
    refreshCharge()
  }

  /// A new debt: one I owe, a loan, in the default currency until another is picked.
  static func newDebt(defaultCurrency: CurrencyCode) -> Debt {
    Debt(
      direction: .iOwe, type: .loan, name: "", currency: defaultCurrency,
      paymentsAreExpenses: true)
  }

  private var title: String {
    switch sheet {
    case .create: t("form.create.title")
    case .pay(let debt), .payAt(let debt, _, _), .repay(let debt, _, _):
      environment.format("form.pay.title", table: "Debts", debt.name)
    case .entry(let debt): environment.format("form.entry.title", table: "Debts", debt.name)
    case .offset(let debt): environment.format("form.offset.title", table: "Debts", debt.name)
    case .transfer(let debt, _, _):
      environment.format("form.transfer.title", table: "Debts", debt.name)
    case .adjust(let debt, _): environment.format("form.adjust.title", table: "Debts", debt.name)
    case .close(let debt, _): environment.format("form.close.title", table: "Debts", debt.name)
    case .schedule(let debt):
      environment.format("schedule.form.title", table: "Debts", debt.name)
    case .tranche(let debt): environment.format("tranche.title", table: "Debts", debt.name)
    }
  }

  private var people: [Person] { (compute.snapshot?.dataset.people ?? []).filter { !$0.archived } }
  private var methods: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
  }
  /// The live account, or the account of a live card, a new debt of this name is called after.
  private func accountAnswering(to name: String) -> DebtNaming.Match? {
    let dataset = compute.snapshot?.dataset
    return DebtNaming.accountAnswering(
      to: name, accounts: dataset?.paymentMethods ?? [], cards: dataset?.cards ?? [])
  }
  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(debt.currency) ? enabled : enabled + [debt.currency]
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
