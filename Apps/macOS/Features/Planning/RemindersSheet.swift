import AppCore
import SwiftUI

/// What to remind of when the app opens: payments due and overdue, trials ending, a new price
/// of a subscription, debt payments and a reconciliation that is due. Shown once a day, after
/// the first reminders of the day are counted. «Later» closes it until tomorrow; × on a line
/// puts that reminder off until it changes.
///
/// With `asksOverdue` — at every launch while due dates have passed unpaid, or from
/// «Разобрать…» of the free sum — «Просроченные платежи» come first: one row per payment or
/// debt with its earliest unpaid due, read live, so an answer brings the next due of the same
/// payment. «Провести» pays it; «Уже списано до сверки» closes it without an operation when a
/// count made on the due day or later may already hold its money; «Позже» leaves everything for
/// the next launch.
///
/// A line goes away once its action or × lands: acting twice on a row that stayed would pay
/// or skip the next due date (review of the app, 19.09). Paying a reminder pays its own due
/// date, never whatever the payment is due next.
struct RemindersSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let reminders: [Reminder]
  /// The overdue section on top.
  var asksOverdue = false
  /// Opens the section a reminder is about: Planning or Debts.
  var openSection: (MainWindow.Section) -> Void = { _ in }

  @State private var handled: Set<String> = []
  @State private var failed: [String: String] = [:]
  @State private var debtSheet: DebtSheet?
  /// The reminder whose debt sheet is open: it goes once the payment lands, and the payment
  /// is for its due.
  @State private var debtReminder: Reminder?
  /// The payment whose «Провести» waits for the answer about a count, and what it pays.
  @State private var asking: Asking?
  /// «Это было до сверки в 14:05?» about every count of the day, in turn.
  @State private var countQuestion: BeforeTheCountQuestion?
  /// «Деньги за «X» ушли до сверки 10 сентября в 14:00?» — a due before a later count.
  @State private var dueQuestion: BeforeTheCountQuestion?
  /// The due a debt sheet opened from an overdue row pays.
  @State private var debtDue: DateOnly?

  /// What «Провести» is waiting to pay once the question is answered: a daily reminder's due,
  /// or an overdue row's.
  struct Asking {
    var payment: ScheduledPayment?
    var debt: Debt?
    var due: DateOnly
    /// The id the failure is shown under.
    var rowId: String
    /// The reminder to take away once it is paid; `nil` for an overdue row, which is live.
    var reminder: Reminder?
    /// The moment «Провести» dates the payment with before any answer.
    var moment: Date
  }

  /// The overdue rows, live; empty unless the sheet asks about them.
  private var overdue: [OverdueDue] {
    asksOverdue ? (compute.snapshot?.planning.overdue ?? []) : []
  }

  /// The daily reminders not handled yet, less those an overdue row stands for.
  private var shown: [Reminder] {
    let asked = Set(overdue.map(\.id))
    return reminders.filter { !handled.contains($0.id) && !asked.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("reminders.title")).appFont(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if !overdue.isEmpty {
            overdueSection
            if !shown.isEmpty { Divider() }
          }
          if shown.isEmpty && overdue.isEmpty {
            Text(verbatim: t("reminders.allDone")).foregroundStyle(.secondary)
          }
          ForEach(shown) { reminder in
            row(reminder)
            Divider()
          }
        }
      }
      .frame(maxHeight: 420)
      // «Да» keeps the moment of the due, inside the count where the money already is; «Нет»
      // dates the payment now. On a view of its own: one dialog per view.
      .beforeTheCountQuestion($dueQuestion) { count, wasBefore in
        guard let asking else { return }
        finish(
          asking,
          at: AccountReconciliation.dueAnswer(
            count: count, occurredAt: asking.moment, wasBefore: wasBefore, now: Date()))
      }
      HStack {
        Spacer()
        Button(t(shown.isEmpty && overdue.isEmpty ? "reminders.close" : "reminders.later")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 560)
    .sheet(item: $debtSheet) { sheet in
      DebtSheetView(
        sheet: sheet,
        onDone: {
          if let debtReminder { handled.insert(debtReminder.id) }
        }, payDue: debtReminder?.due ?? debtDue
      )
      .handingOver(dependencies)
    }
    // The answers date the payment before or after the counts of its day, and «Провести»
    // goes on.
    .beforeTheCountQuestions($countQuestion) { moment in
      guard let asking else { return }
      finish(asking, at: moment)
    }
  }

  // MARK: Overdue due dates

  private var overdueSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(verbatim: t("reminders.overdue.title"))
      } icon: {
        Image(systemName: "exclamationmark.circle")
      }
      .appFont(.subheadline.weight(.semibold))
      Text(verbatim: t("reminders.overdue.explain"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(overdue) { due in
        overdueRow(due)
      }
    }
  }

  private func overdueRow(_ due: OverdueDue) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: overdueText(due))
      Text(verbatim: overdueCaption(due))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        ForEach(Self.overdueActions(for: due), id: \.self) { action in
          overdueButton(action, of: due)
        }
      }
      if let reason = failed[due.id] {
        Text(verbatim: reason)
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// What an overdue row offers, in its order.
  enum OverdueAction: Hashable {
    /// «Провести».
    case pay
    /// «Пропустить» — the earliest unpaid due closes without an operation.
    case skip
    /// «Пропустить все N» — every unpaid due before today; `count` is N.
    case skipAll(count: Int)
    /// «Уже списано до сверки» — only when the account was counted after the due.
    case settled(countedAt: Date)
  }

  /// The buttons of an overdue row. «Пропустить» is for a scheduled payment nobody cancelled — a
  /// debt is owed whatever the owner thinks of it, and has no skip; «Пропустить все N» only
  /// when the payment owes more than one due.
  nonisolated static func overdueActions(for due: OverdueDue) -> [OverdueAction] {
    var actions: [OverdueAction] = [.pay]
    if !due.isDebt {
      actions.append(.skip)
      if due.moreOverdue > 0 { actions.append(.skipAll(count: due.moreOverdue + 1)) }
    }
    if let count = due.countAfter { actions.append(.settled(countedAt: count)) }
    return actions
  }

  @ViewBuilder
  private func overdueButton(_ action: OverdueAction, of due: OverdueDue) -> some View {
    switch action {
    case .pay:
      Button(t("scheduled.markAsPaid")) { payOverdue(due) }
        .buttonStyle(.bordered)
        .controlSize(.small)
    case .skip:
      Button(t("reminders.overdue.skip")) { skipOverdue(due, all: false) }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(t("reminders.overdue.skipHelp"))
    case .skipAll(let count):
      Button(
        environment.language.format("reminders.overdue.skipAll", table: "Planning", counts: count)
      ) { skipOverdue(due, all: true) }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help(t("reminders.overdue.skipHelp"))
    case .settled(let count):
      Button(t("reminders.overdue.settled")) { settle(due) }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(
          environment.format(
            "reminders.overdue.settledHelp", table: "Planning",
            environment.dates.dayAndMonth(environment.calendar.day(of: count))))
    }
  }

  /// «Аренда — 5 сентября, 30,000.00 ₽», as the reminder of the due would say it.
  private func overdueText(_ due: OverdueDue) -> String {
    let day = environment.dates.dayAndMonth(due.due)
    let amount = environment.money.exact(due.amount, currency: due.currency)
    return environment.format(
      due.isDebt ? "reminders.debtPayment" : "reminders.payment", table: "Planning", due.name, day,
      amount)
  }

  /// «просрочено», and «и ещё 2 просроченных срока» when the same payment owes more.
  private func overdueCaption(_ due: OverdueDue) -> String {
    let overdue = t("reminders.urgency.overdue")
    guard due.moreOverdue > 0 else { return overdue }
    return overdue + " · "
      + environment.language.format(
        "reminders.overdue.more", table: "Planning", counts: due.moreOverdue)
  }

  /// «Провести» of an overdue row: a scheduled payment asks about a later count first, then
  /// pays; a debt opens its payment form at the moment the answer gives, from the account it
  /// is paid from.
  private func payOverdue(_ due: OverdueDue) {
    guard let dependencies else { return }
    failed[due.id] = nil
    switch due.subject {
    case .scheduled(let id):
      guard let payment = compute.snapshot?.dataset.planning.scheduled.first(where: { $0.id == id })
      else { return }
      ask(
        Asking(
          payment: payment, due: due.due, rowId: due.id, moment: paidAt(due.due)),
        actions: PlanningActions(dependencies))
    case .debt(let id):
      guard let debt = compute.snapshot?.dataset.debts.first(where: { $0.id == id }) else { return }
      ask(
        Asking(debt: debt, due: due.due, rowId: due.id, moment: paidAt(due.due)),
        actions: PlanningActions(dependencies))
    }
  }

  /// «Пропустить» — the payment was not made, its earliest unpaid due closes without an
  /// operation — and «Пропустить все N», every unpaid due before today at once. The same write
  /// as «Пропустить» in Planning, one step of ⌘Z.
  private func skipOverdue(_ due: OverdueDue, all: Bool) {
    guard let dependencies, case .scheduled(let id) = due.subject,
      let payment = compute.snapshot?.dataset.planning.scheduled.first(where: { $0.id == id })
    else { return }
    failed[due.id] = nil
    if !Self.skip(due, all: all, payment: payment, with: PlanningActions(dependencies)) {
      failed[due.id] = t("form.notSaved")
    }
  }

  /// Closes `payment` through the due `due.skipping(all:)` without an operation.
  @discardableResult
  static func skip(
    _ due: OverdueDue, all: Bool, payment: ScheduledPayment, with actions: PlanningActions
  ) -> Bool {
    actions.skip(payment, due: due.skipping(all: all))
  }

  /// «Уже списано до сверки».
  private func settle(_ due: OverdueDue) {
    guard let dependencies else { return }
    let done: Bool
    switch due.subject {
    case .scheduled(let id):
      guard let payment = compute.snapshot?.dataset.planning.scheduled.first(where: { $0.id == id })
      else { return }
      done = PlanningActions(dependencies).settle(payment: payment, due: due.due)
    case .debt(let id):
      guard let debt = compute.snapshot?.dataset.debts.first(where: { $0.id == id }) else { return }
      done = DebtActions(dependencies).settle(debt: debt, due: due.due, owed: due.amount)
    }
    if !done { failed[due.id] = t("form.notSaved") }
  }

  /// Asks what «Провести» of `asking` has to ask, then pays: the dated question when the due
  /// lies before a later count, the questions of the day otherwise — an answer remembered for
  /// a count is used without asking (`step(for:isDebt:moment:)`).
  private func ask(_ asking: Asking, actions: PlanningActions) {
    let payer: PlanningActions.DuePayer
    if let payment = asking.payment {
      payer = .scheduled(
        payment, amount: SubscriptionMath.price(of: payment, on: asking.due, prices: prices))
    } else if let debt = asking.debt {
      payer = .debt(debt)
    } else {
      return
    }
    let question = actions.countQuestion(paying: payer, due: asking.due, on: asking.moment)
    switch Self.step(for: question, isDebt: asking.debt != nil, moment: asking.moment) {
    case .pay(let moment):
      finish(asking, at: moment)
    case .askTheDay(let questions):
      self.asking = asking
      countQuestion = BeforeTheCountQuestion(
        count: questions.count, reconciliation: questions.reconciliation, questions: questions)
    case .askTheDue(let count, let due, let reconciliation):
      self.asking = asking
      dueQuestion = BeforeTheCountQuestion(
        count: count, reconciliation: reconciliation, due: due,
        name: asking.payment?.name ?? asking.debt?.name)
    }
  }

  /// What «Провести» does before it pays.
  enum PayStep {
    /// Pays at `moment`: a scheduled payment is written at once; a debt's payment form opens
    /// there — `nil`: now — and asks about the counts of that day itself when it is saved.
    case pay(at: Date?)
    /// «Это было до сверки в 14:05?» about every count of the operation's day, in turn.
    case askTheDay(CountQuestions)
    /// «Деньги за «X» ушли до сверки 10 сентября в 14:00?», with «Больше не спрашивать» for
    /// the count's reconciliation.
    case askTheDue(count: Date, due: DateOnly, reconciliation: UUID)
  }

  /// What «Провести» of a due dated `moment` does with the question `ask` names. A debt is
  /// paid through its payment form, which asks «Это было до сверки в 14:05?» about the counts
  /// of its day on «Сохранить» — asked here too, the owner would answer it twice —, so a
  /// debt only ever gets the dated question here, and without a count the form starts now.
  static func step(for ask: DueCountAsk, isDebt: Bool, moment: Date) -> PayStep {
    switch ask {
    case .none:
      return .pay(at: isDebt ? nil : moment)
    case .sameDay(let day):
      if isDebt { return .pay(at: moment) }
      switch day {
      case .none: return .pay(at: moment)
      case .answered(let stamp): return .pay(at: stamp)
      case .ask(let questions): return .askTheDay(questions)
      }
    case .dueBefore(let count, let due, let reconciliation):
      return .askTheDue(count: count, due: due, reconciliation: reconciliation)
    case .dueAnswered(let stamp):
      return .pay(at: stamp)
    }
  }

  /// Pays what was asked about at `moment`: a scheduled payment at once, a debt through its
  /// payment form — started at `moment` (`nil`: its own start) from the account of its last
  /// payment.
  private func finish(_ asking: Asking, at moment: Date?) {
    self.asking = nil
    if let debt = asking.debt {
      guard let snapshot = compute.snapshot else { return }
      let mainId = snapshot.dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
      let account = DebtAccount.lastPayment(
        of: debt, ledger: snapshot.ledger, journal: snapshot.dataset.planning.debtEntries,
        mainId: mainId)
      debtReminder = asking.reminder
      debtDue = asking.due
      debtSheet = .payAt(debt, at: moment, account: account)
      return
    }
    guard let dependencies, let payment = asking.payment else { return }
    let actions = PlanningActions(dependencies)
    let paidAt = moment ?? asking.moment
    if actions.markAsPaid(
      payment, due: asking.due,
      amount: SubscriptionMath.price(of: payment, on: asking.due, prices: prices), on: paidAt,
      account: payment.paymentMethodId, charged: nil, updatePrice: false)
    {
      if let reminder = asking.reminder { handled.insert(reminder.id) }
    } else {
      // Not in silence: the row says why (review of the app, 19.09).
      let currency = payment.currency
      failed[asking.rowId] = environment.format(
        actions.failureKey(currency: currency, on: paidAt, at: .reminder), table: "Planning",
        currency.code)
    }
  }

  @ViewBuilder
  private func row(_ reminder: Reminder) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: reminder.urgency == .overdue ? "exclamationmark.circle" : "bell")
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: text(reminder))
        Text(verbatim: t("reminders.urgency.\(reminder.urgency)"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
        if let reason = failed[reminder.id] {
          Text(verbatim: reason)
            .appFont(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      actions(reminder)
      Button {
        if let dependencies, PlanningActions(dependencies).dismiss(reminder) {
          handled.insert(reminder.id)
        }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help(t("reminders.dismiss"))
      .accessibilityLabel(Text(verbatim: t("reminders.dismiss")))
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func actions(_ reminder: Reminder) -> some View {
    switch reminder.kind {
    case .payment:
      if let status = status(reminder), let due = reminder.due,
        Self.waits(status, for: due, matches: compute.snapshot?.planning.matches ?? .empty)
      {
        Button(t("scheduled.markAsPaid")) {
          guard let dependencies else { return }
          // Dated before a later count of the balance it moves, or on the day of a count and
          // saved after it, it asks first, as the entry line and the form do.
          ask(
            Asking(
              payment: status.payment, due: due, rowId: reminder.id, reminder: reminder,
              moment: paidAt(due)),
            actions: PlanningActions(dependencies))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Button(t("scheduled.skip")) {
          guard let dependencies else { return }
          if PlanningActions(dependencies).skip(status.payment, due: due) {
            handled.insert(reminder.id)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    case .trialEnds:
      if let link = payment(reminder)?.cancelLink {
        Button(t("scheduled.cancelLink")) { openURL(link) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    case .priceChange:
      Button(t("reminders.open")) {
        openSection(.planning)
        dismiss()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    case .debtPayment:
      if let debt = debt(reminder) {
        Button(environment.language("debts.pay", table: "Debts")) {
          debtReminder = reminder
          debtSheet = .pay(debt)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    case .reconciliation:
      Button(environment.language("reconcile.open", table: "Planning")) {
        dismiss()
        environment.showsReconciliation = true
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// The row pays only while the payment still waits for this very due date: the first one
  /// nothing paid, neither «Провести» nor an ordinary operation that matches it. `next_date`
  /// stays behind the dates such operations paid, so it is not the one to compare with; and
  /// a payment whose every due date is paid shows its last one, which waits for nothing.
  static func waits(
    _ status: ScheduledStatus, for due: DateOnly, matches: ScheduledMatches
  )
    -> Bool
  {
    status.nextUnpaid == due && ScheduledRow.canPay(status, matches: matches)
  }

  /// The moment the payment of `due` is dated with (`PlanningActions.paidAt`).
  private func paidAt(_ due: DateOnly) -> Date {
    PlanningActions.paidAt(due: due, today: environment.today, calendar: environment.calendar)
  }

  private var prices: [SubscriptionPrice] { compute.snapshot?.dataset.planning.prices ?? [] }

  private func payment(_ reminder: Reminder) -> ScheduledPayment? {
    compute.snapshot?.dataset.planning.scheduled.first { $0.id == reminder.subjectId }
  }

  private func status(_ reminder: Reminder) -> ScheduledStatus? {
    compute.snapshot?.planning.scheduled.first { $0.id == reminder.subjectId }
  }

  private func debt(_ reminder: Reminder) -> Debt? {
    compute.snapshot?.dataset.debts.first { $0.id == reminder.subjectId }
  }

  /// «Интернет — 17.09, 900 ₽», «Пробный период «Музыки» кончается 21.09», «Цена «Облака» с
  /// 01.10 — 299 ₽ вместо 249 ₽», «Кредит — платёж 25.09, 8 500 ₽», «Сверка была 20 дней
  /// назад».
  private func text(_ reminder: Reminder) -> String {
    let day = reminder.due.map { environment.dates.dayAndMonth($0) } ?? ""
    switch reminder.kind {
    case .payment:
      guard let payment = payment(reminder) else { return "—" }
      let amount =
        reminder.due.map { SubscriptionMath.price(of: payment, on: $0, prices: prices) }
        ?? payment.amountE4
      return environment.format(
        "reminders.payment", table: "Planning", payment.name, day,
        environment.money.exact(amount, currency: payment.currency))
    case .trialEnds:
      return environment.format(
        "reminders.trialEnds", table: "Planning", payment(reminder)?.name ?? "—", day)
    case .priceChange:
      guard let payment = payment(reminder), let due = reminder.due else { return "—" }
      let new = SubscriptionMath.price(of: payment, on: due, prices: prices)
      let old = SubscriptionMath.price(of: payment, on: due.adding(days: -1), prices: prices)
      return environment.format(
        "reminders.priceChange", table: "Planning", payment.name, day,
        environment.money.exact(new, currency: payment.currency),
        environment.money.exact(old, currency: payment.currency))
    case .debtPayment:
      guard let debt = debt(reminder) else { return "—" }
      let amount =
        debt.monthlyPaymentE4.map {
          environment.money.exact($0, currency: debt.currency)
        } ?? "—"
      return environment.format("reminders.debtPayment", table: "Planning", debt.name, day, amount)
    case .reconciliation:
      guard let last = compute.snapshot?.planning.lastReconciliation,
        let today = compute.snapshot?.today
      else { return t("reminders.reconciliationFirst") }
      return environment.language.format(
        "reminders.reconciliation", table: "Planning", counts: max(0, last.date.days(to: today)))
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
