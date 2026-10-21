import AppCore
import SwiftUI

/// What a new debt is, as the first step of «Новый долг» asks it.
enum DebtWizardKind: String, CaseIterable, Hashable {
  case loan
  /// A loan with a schedule and early repayments, named so; not a kind of its own, and no asset
  /// is tied to it.
  case mortgage
  /// The education loan of the state programme (its preset).
  case education
  /// «Рассрочка»: a purchase paid in parts.
  case instalments
  /// A purchase on credit paid monthly.
  case purchase
  /// A credit card is an account, not a debt: the step leads to the account and its terms.
  case creditCard
  case personIOwe
  case owedToMe
  /// A pledge or a deposit owed back to me by a day.
  case pledge

  /// A loan of a bank: rate, payments, costs, early repayments.
  var isLoan: Bool { self == .loan || self == .mortgage || self == .education }
  /// Made with a purchase spent in its category.
  var isPurchase: Bool { self == .instalments || self == .purchase }
  var direction: DebtDirection { self == .owedToMe || self == .pledge ? .owedToMe : .iOwe }
  var symbol: String {
    switch self {
    case .loan: "building.columns"
    case .mortgage: "house"
    case .education: "graduationcap"
    case .instalments: "square.split.2x2"
    case .purchase: "cart"
    case .creditCard: "creditcard"
    case .personIOwe: "person.crop.circle.badge.minus"
    case .owedToMe: "person.crop.circle.badge.plus"
    case .pledge: "key"
    }
  }
}

/// «Новый долг» step by step, apart from the view so a test reads it without a window: the kind
/// → the sum and the day → the payments of that kind only → «Как это будет» with the schedule.
@MainActor
struct DebtWizardModel {
  enum Step: Int, CaseIterable { case kind, amount, payments, preview }

  /// A cost of the loan as the wizard takes it.
  struct CostDraft: Hashable, Identifiable {
    var id = UUID()
    var kind: DebtCostKind = .insurance
    var amount: AmountE4 = .zero
    var every: DebtCostEvery = .once
    var inLoan = false
  }

  var step: Step = .kind
  var kind: DebtWizardKind = .loan
  var name = ""
  var amount: AmountE4 = .zero
  var currency: CurrencyCode = .rub
  var day: DateOnly
  var personId: UUID?
  var moneyMoved = false
  var account: UUID?
  // A loan.
  var rateText = ""
  var monthly: AmountE4 = .zero
  var paymentDay = 1
  var schedule: DebtSchedule
  var pskText = ""
  var prepayAnyDay = true
  var noticeDays = DebtReminders.defaultNoticeDays
  var costs: [CostDraft] = []
  // A purchase.
  var categoryId: UUID?
  var parts = InstalmentPlan.defaultCount
  var everyTwoWeeks = true
  var markup: AmountE4 = .zero
  // A pledge.
  var returnBy: DateOnly

  init(today: DateOnly, currency: CurrencyCode) {
    day = today
    self.currency = currency
    paymentDay = min(today.day, 28)
    schedule = DebtSchedule(mainFrom: DebtSchedule.defaultMainFrom(today: today))
    returnBy = today.adding(months: 1)
  }

  /// The kind chosen: its presets laid over what was typed.
  mutating func choose(_ kind: DebtWizardKind, today: DateOnly, language: AppLanguage) {
    self.kind = kind
    if kind == .education {
      let preset = DebtSheetView.educationLoan(debt(), today: today, language: language)
      rateText = preset.rateText
      schedule = preset.schedule
      paymentDay = preset.debt.paymentDay ?? 1
      if name.isEmpty { name = preset.debt.name }
    } else if kind == .mortgage {
      schedule.byTerm = true
      schedule.months = 240
      schedule.hasGrace = false
    }
  }

  var rate: Decimal? { DebtPayoff.parseRate(rateText) }
  var psk: Decimal? { DebtPayoff.parseRate(pskText) }

  /// The debt a loan, a person's debt or a pledge is saved as.
  func debt() -> Debt {
    var debt = Debt(
      direction: kind.direction, type: debtType, name: name, personId: personId,
      currency: currency, paymentsAreExpenses: kind.direction == .iOwe && kind != .education,
      termsReviewed: true)
    switch kind {
    case .loan, .mortgage, .education:
      debt.monthlyPaymentE4 = monthly.raw > 0 ? monthly : nil
      debt.paymentDay = paymentDay
      debt = DebtSheetView.made(debt, rateText: rateText, schedule: schedule)
      debt.paymentDay = paymentDay
      if kind == .education { debt.paymentsAreExpenses = false }
      debt.psk = psk
      debt.prepayAnyDay = prepayAnyDay
      debt.prepayNoticeDays = noticeDays == DebtReminders.defaultNoticeDays ? nil : noticeDays
    case .personIOwe, .owedToMe:
      if monthly.raw > 0 {
        debt.monthlyPaymentE4 = monthly
        debt.paymentDay = paymentDay
      }
    case .pledge:
      debt.pledge = true
      debt.returnBy = returnBy
    case .instalments, .purchase, .creditCard:
      break
    }
    return debt
  }

  private var debtType: DebtType {
    switch kind {
    case .loan, .mortgage, .education: .loan
    case .instalments, .purchase: .installment
    case .creditCard: .creditCard
    case .personIOwe, .owedToMe, .pledge: .personal
    }
  }

  /// The costs as the loan keeps them, from the day of the loan.
  func debtCosts(debtId: UUID) -> [DebtCost] {
    costs.filter { $0.amount.raw > 0 }.enumerated().map { index, cost in
      DebtCost(
        id: cost.id, debtId: debtId, kind: cost.kind, amountE4: cost.amount, every: cost.every,
        day: day, inLoan: cost.every == .once && cost.inLoan, sort: index)
    }
  }

  /// The purchase an instalment plan or a purchase on credit is made with.
  var purchase: DebtActions.Purchase {
    DebtActions.Purchase(
      name: name, price: amount, currency: currency, day: day, categoryId: categoryId,
      account: account, parts: kind == .instalments ? parts : nil,
      everyDays: kind == .instalments && everyTwoWeeks ? InstalmentPlan.defaultEveryDays : nil,
      paymentDay: paymentDay, markup: kind == .instalments && markup.raw > 0 ? markup : nil,
      monthly: kind == .purchase && monthly.raw > 0 ? monthly : nil)
  }

  /// Whether the step may be left forward.
  func canLeave(_ step: Step) -> Bool {
    switch step {
    case .kind: return true
    case .amount:
      guard kind != .creditCard else { return true }
      return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && amount.raw > 0
    case .payments:
      switch kind {
      case .loan, .mortgage, .education:
        return schedule.issues(
          rate: rate, monthly: monthly.raw > 0 ? monthly : nil, direction: .iOwe
        ).isEmpty && (monthly.raw > 0 || schedule.byTerm || schedule.hasGrace)
      case .instalments: return (2...120).contains(parts) && categoryId != nil
      case .purchase: return categoryId != nil
      default: return true
      }
    case .preview: return true
    }
  }

  /// One line of «Как это будет»: a due day and what it asks, and of it the interest or markup.
  struct PreviewRow: Hashable {
    var due: DateOnly
    var payment: AmountE4
    var interest: AmountE4
    var balanceAfter: AmountE4
  }

  /// «Как это будет»: the schedule of the debt — a loan by `DebtAmortization.schedule` from its
  /// first due (a loan with a grace period: its dues as the plan works them out), the parts of an
  /// instalment plan by their days —, and what it all costs.
  struct Preview: Hashable {
    var rows: [PreviewRow] = []
    var payments: AmountE4 = .zero
    var interest: AmountE4 = .zero
    var cost: DebtCostReport?
  }

  func preview(calendar: CalendarContext) -> Preview {
    switch kind {
    case .loan, .mortgage, .education:
      let made = debt()
      let inLoan = AmountE4.sum(costs.filter { $0.inLoan && $0.every == .once }.map(\.amount))
      let principal = amount + inLoan
      let firstDue =
        DebtStart.firstMonth(of: made, startsOn: day, calendar: calendar).map {
          DebtDueState.payday(paymentDay, in: $0)
        } ?? DebtDueState.payday(paymentDay, in: day.monthKey.next)
      if made.grace != nil {
        let journal = [
          DebtEntry(debtId: made.id, date: day, amountE4: principal, kind: .borrowed)
        ]
        let plan = DebtSchedulePlan.plan(
          debt: made, journal: journal, firstDue: firstDue, paymentDay: paymentDay, today: day,
          calendar: calendar)
        let rows = (0..<min(made.repayMonths.map { $0 + 24 } ?? 240, 600)).compactMap {
          index -> PreviewRow? in
          let amount = plan.instalments.amount(at: index)
          guard amount.raw > 0 else { return nil }
          return PreviewRow(
            due: DebtDueState.payday(paymentDay, in: firstDue.monthKey.adding(months: index)),
            payment: amount, interest: .zero, balanceAfter: .zero)
        }
        return Preview(rows: rows, payments: AmountE4.sum(rows.map(\.payment)))
      }
      let percent = made.interestRate ?? 0
      let payment =
        made.monthlyPaymentE4
        ?? InterestMath.annuity(principal: principal, percent: percent, months: schedule.months)
      let schedule = DebtAmortization.schedule(
        principal: principal, percent: percent, payment: payment, firstDue: firstDue,
        paymentDay: paymentDay)
      var preview = Preview(
        rows: schedule.map {
          PreviewRow(
            due: $0.due, payment: $0.paymentE4, interest: $0.interestE4,
            balanceAfter: $0.balanceAfterE4)
        },
        payments: AmountE4.sum(schedule.map(\.paymentE4)),
        interest: AmountE4.sum(schedule.map(\.interestE4)))
      if !schedule.isEmpty {
        preview.cost = DebtCostReport.report(
          debt: made, borrowedE4: principal, costs: debtCosts(debtId: made.id),
          schedule: schedule, paidE4: .zero, firstDay: day)
      }
      return preview
    case .instalments:
      let total = amount + markup
      // Each part is its share of the price and its share of the markup, as the plan saved asks
      // (`InstalmentPlan.instalments`), not a share of the two together.
      let shares = InstalmentPlan.markupShares(markup: markup, count: parts)
      let amounts = zip(InstalmentPlan.parts(total: amount, count: parts), shares).map { $0 + $1 }
      let days: [DateOnly]
      if everyTwoWeeks {
        days = InstalmentPlan.dueDays(
          steps: DebtSteps(everyDays: InstalmentPlan.defaultEveryDays, firstDue: day),
          count: parts)
      } else {
        let first =
          DebtDueState.payday(paymentDay, in: day.monthKey) > day
          ? day.monthKey : day.monthKey.next
        days = (0..<parts).map { DebtDueState.payday(paymentDay, in: first.adding(months: $0)) }
      }
      var left = total
      let rows = zip(days, zip(amounts, shares)).map { day, pair in
        left = left - pair.0
        return PreviewRow(due: day, payment: pair.0, interest: pair.1, balanceAfter: left)
      }
      return Preview(rows: rows, payments: total, interest: markup)
    case .purchase:
      guard monthly.raw > 0 else { return Preview(payments: amount) }
      var left = amount
      var rows: [PreviewRow] = []
      var month =
        DebtDueState.payday(paymentDay, in: day.monthKey) > day ? day.monthKey : day.monthKey.next
      while left.raw > 0, rows.count < 600 {
        let pays = min(monthly, left)
        left = left - pays
        rows.append(
          PreviewRow(
            due: DebtDueState.payday(paymentDay, in: month), payment: pays, interest: .zero,
            balanceAfter: left))
        month = month.next
      }
      return Preview(rows: rows, payments: amount)
    case .creditCard, .personIOwe, .owedToMe, .pledge:
      return Preview(payments: amount)
    }
  }
}

/// «Новый долг» in four steps (`DebtWizardModel`): the kind; the sum and the day; the payments of
/// that kind only; «Как это будет» with the schedule. «Кредитка» makes no debt: it leads to the
/// account of the card and its terms (`AccountEditor`). Saving writes one change, one step of ⌘Z.
struct DebtWizard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @State private var model = DebtWizardModel(
    today: DateOnly(year: 2000, month: 1, day: 1), currency: .rub)
  @State private var loaded = false
  @State private var failed = false
  /// The account the card's terms are given for; `nil` with the editor closed.
  @State private var editingCard: CardEdit?
  @State private var cardAccount: UUID?

  init() {}

  /// The wizard opened on `model` as it stands — its step and what it holds; for a look at a step
  /// without walking to it.
  init(model: DebtWizardModel) {
    _model = State(initialValue: model)
    _loaded = State(initialValue: true)
  }

  struct CardEdit: Identifiable {
    var id = UUID()
    var account: PaymentMethod?
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(verbatim: t("wizard.title")).appFont(.headline)
        Spacer()
        Text(
          verbatim: environment.format(
            "wizard.step", table: "Debts", String(model.step.rawValue + 1),
            String(DebtWizardModel.Step.allCases.count))
        )
        .appFont(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("debt.wizard.step")
      }
      Text(verbatim: t("wizard.step.\(model.step)")).appFont(.subheadline).foregroundStyle(
        .secondary)
      Form { content }
        .formStyle(.grouped)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if model.step != .kind {
          Button(t("wizard.back")) { back() }
            .accessibilityIdentifier("debt.wizard.back")
        }
        if model.step == .preview || (model.step == .amount && model.kind == .creditCard) {
          Button(model.kind == .creditCard ? t("wizard.card.open") : t("form.save")) { save() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(dependencies == nil || !model.canLeave(model.step))
            .accessibilityIdentifier("debt.wizard.save")
        } else {
          Button(t("wizard.next")) { forward() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canLeave(model.step))
            .accessibilityIdentifier("debt.wizard.next")
        }
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 340, idealWidth: 520, maxWidth: 560, minHeight: 420)
    .onAppear(perform: load)
    .sheet(item: $editingCard) { edit in
      AccountEditor(previous: edit.account, defaultCurrency: environment.defaultCurrency) { _ in
        editingCard = nil
        dismiss()
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.step {
    case .kind: kindStep
    case .amount: amountStep
    case .payments: paymentsStep
    case .preview: previewStep
    }
  }

  // MARK: Step 1 — the kind

  private var kindStep: some View {
    Picker(t("wizard.kind"), selection: kindBinding) {
      ForEach(DebtWizardKind.allCases, id: \.self) { kind in
        Label(t("wizard.kind.\(kind.rawValue)"), systemImage: kind.symbol).tag(kind)
      }
    }
    .pickerStyle(.radioGroup)
    .accessibilityIdentifier("debt.wizard.kind")
  }

  private var kindBinding: Binding<DebtWizardKind> {
    Binding(
      get: { model.kind },
      set: { model.choose($0, today: environment.today, language: environment.language) })
  }

  // MARK: Step 2 — the sum and the day

  @ViewBuilder
  private var amountStep: some View {
    if model.kind == .creditCard {
      Text(verbatim: t("wizard.card.hint")).fixedSize(horizontal: false, vertical: true)
      Picker(t("wizard.card.account"), selection: $cardAccount) {
        Text(verbatim: t("wizard.card.new")).tag(UUID?.none)
        ForEach(accounts) { Text(verbatim: $0.name).tag(Optional($0.id)) }
      }
    } else {
      TextField(t("form.name"), text: $model.name)
        .accessibilityIdentifier("debt.wizard.name")
      if model.kind == .personIOwe || model.kind == .owedToMe || model.kind == .pledge {
        Picker(t("form.person"), selection: $model.personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
      }
      LabeledContent(t(model.kind.isPurchase ? "wizard.price" : "form.balance")) {
        HStack {
          AmountField(amount: $model.amount)
          Picker("", selection: $model.currency) {
            ForEach(currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      DatePicker(t("wizard.day"), selection: dayBinding, displayedComponents: .date)
      if !model.kind.isPurchase {
        Toggle(t("form.moneyMovedToday"), isOn: $model.moneyMoved)
      }
      if model.kind.isPurchase || model.moneyMoved {
        AccountPicker(
          title: environment.language(
            model.kind.direction == .owedToMe ? "entry.account.from" : "entry.account.to",
            table: "Entry"),
          accounts: accounts, selection: $model.account)
      }
    }
  }

  private var dayBinding: Binding<Date> {
    Binding(
      get: { environment.calendar.noon(of: model.day) },
      set: { model.day = environment.calendar.day(of: $0) })
  }

  // MARK: Step 3 — the payments of the kind

  @ViewBuilder
  private var paymentsStep: some View {
    switch model.kind {
    case .loan, .mortgage, .education:
      TextField(t("form.rate"), text: $model.rateText)
        .accessibilityIdentifier("debt.wizard.rate")
      if !model.schedule.byTerm {
        LabeledContent(t(model.schedule.hasGrace ? "schedule.mainPayment" : "form.monthlyPayment"))
        { AmountField(amount: $model.monthly) }
      }
      dayStepper
      DebtScheduleSection(
        schedule: $model.schedule, direction: .iOwe, rate: model.rate, principal: model.amount,
        currency: model.currency)
      Section(t("wizard.loan.terms")) {
        TextField(t("wizard.psk"), text: $model.pskText)
        Toggle(t("wizard.prepayAnyDay"), isOn: $model.prepayAnyDay)
        Stepper(value: $model.noticeDays, in: 0...90) {
          Text(
            verbatim: environment.format("wizard.notice", table: "Debts", String(model.noticeDays)))
        }
      }
      Section(t("costs.title")) {
        ForEach($model.costs) { $cost in
          CostRow(cost: $cost, currency: model.currency) {
            model.costs.removeAll { $0.id == cost.id }
          }
        }
        Button(t("costs.add")) { model.costs.append(DebtWizardModel.CostDraft()) }
      }
    case .instalments:
      Stepper(value: $model.parts, in: 2...120) {
        Text(verbatim: environment.format("wizard.parts", table: "Debts", String(model.parts)))
      }
      Picker(t("wizard.step.every"), selection: $model.everyTwoWeeks) {
        Text(verbatim: t("wizard.every.twoWeeks")).tag(true)
        Text(verbatim: t("wizard.every.month")).tag(false)
      }
      .pickerStyle(.segmented)
      if !model.everyTwoWeeks { dayStepper }
      LabeledContent(t("wizard.markup")) { AmountField(amount: $model.markup) }
      Text(verbatim: t("wizard.markup.hint"))
        .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      categoryPicker
    case .purchase:
      LabeledContent(t("form.monthlyPayment")) { AmountField(amount: $model.monthly) }
      dayStepper
      categoryPicker
    case .personIOwe, .owedToMe:
      LabeledContent(t("form.monthlyPayment")) { AmountField(amount: $model.monthly) }
      if model.monthly.raw > 0 { dayStepper }
    case .pledge:
      DatePicker(t("pledge.returnBy"), selection: returnByBinding, displayedComponents: .date)
      Text(verbatim: t("pledge.hint"))
        .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    case .creditCard:
      EmptyView()
    }
  }

  private var dayStepper: some View {
    Stepper(value: $model.paymentDay, in: 1...31) {
      Text(verbatim: DebtSheetView.paymentDayText(model.paymentDay, language: environment.language))
    }
  }

  private var returnByBinding: Binding<Date> {
    Binding(
      get: { environment.calendar.noon(of: model.returnBy) },
      set: { model.returnBy = environment.calendar.day(of: $0) })
  }

  private var categoryPicker: some View {
    Picker(t("wizard.category"), selection: $model.categoryId) {
      Text(verbatim: "—").tag(UUID?.none)
      ForEach(expenseCategories, id: \.id) { item in
        Text(verbatim: item.name).tag(Optional(item.id))
      }
    }
    .accessibilityIdentifier("debt.wizard.category")
  }

  // MARK: Step 4 — «Как это будет»

  @ViewBuilder
  private var previewStep: some View {
    let preview = model.preview(calendar: environment.calendar)
    let money = environment.money
    let currency = model.currency
    if preview.rows.isEmpty {
      Text(
        verbatim: environment.format(
          "wizard.preview.plain", table: "Debts", money.exact(model.amount, currency: currency)))
    } else {
      Text(
        verbatim: environment.format(
          "wizard.preview.summary", table: "Debts", money.count(Int64(preview.rows.count)),
          money.exact(preview.payments, currency: currency),
          environment.dates.longDay(preview.rows.last?.due ?? model.day))
      )
      .fixedSize(horizontal: false, vertical: true)
      if preview.interest.raw > 0 {
        Text(
          verbatim: environment.format(
            model.kind == .instalments ? "wizard.preview.markup" : "wizard.preview.interest",
            table: "Debts", money.exact(preview.interest, currency: currency))
        )
        .foregroundStyle(.secondary)
      }
      if let cost = preview.cost {
        DebtCostLines(report: cost, currency: currency)
      }
      Section(t("wizard.preview.schedule")) {
        ForEach(Array(Self.shown(preview.rows).enumerated()), id: \.offset) { _, row in
          if let row {
            HStack {
              Text(verbatim: environment.dates.longDay(row.due)).monospacedDigit()
              Spacer()
              Text(verbatim: money.exact(row.payment, currency: currency)).monospacedDigit()
            }
            .appFont(.callout)
          } else {
            Text(verbatim: "…").foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  /// The rows the preview lists: the first six and the last, `nil` for what is left out.
  static func shown(_ rows: [DebtWizardModel.PreviewRow]) -> [DebtWizardModel.PreviewRow?] {
    guard rows.count > 8 else { return rows }
    return Array(rows.prefix(6)) + [nil, rows.last]
  }

  // MARK: Moving and saving

  private func forward() {
    guard model.canLeave(model.step),
      let next = DebtWizardModel.Step(rawValue: model.step.rawValue + 1)
    else { return }
    model.step = next
  }

  private func back() {
    if let previous = DebtWizardModel.Step(rawValue: model.step.rawValue - 1) {
      model.step = previous
    }
  }

  private func save() {
    guard let dependencies else { return }
    if model.kind == .creditCard {
      editingCard = CardEdit(account: accounts.first { $0.id == cardAccount })
      return
    }
    let actions = DebtActions(dependencies)
    let written: Bool
    if model.kind.isPurchase {
      written = actions.createPurchase(model.purchase)
    } else {
      let debt = model.debt()
      written = actions.create(
        debt, balance: model.amount, on: model.day, moneyMovedNow: model.moneyMoved,
        account: model.account, at: environment.calendar.noon(of: model.day),
        costs: model.kind.isLoan ? model.debtCosts(debtId: debt.id) : [])
    }
    if written { dismiss() } else { failed = true }
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    model = DebtWizardModel(today: environment.today, currency: environment.defaultCurrency)
    model.account = FormAccounts.account(nil, among: accounts)?.id
  }

  private var accounts: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
  }
  private var people: [Person] { (compute.snapshot?.dataset.people ?? []).filter { !$0.archived } }
  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(model.currency) ? enabled : enabled + [model.currency]
  }
  /// The live expense categories a purchase may be spent in, by their path.
  private var expenseCategories: [(id: UUID, name: String)] {
    let categories = compute.snapshot?.dataset.categories ?? []
    let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    return
      categories
      .filter { $0.kind == .expense && !$0.archived && $0.systemRole == nil }
      .map { category in
        let parent = category.parentId.flatMap { names[$0] }
        return (category.id, parent.map { "\($0) › \(category.name)" } ?? category.name)
      }
      .sorted { $0.name < $1.name }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// One cost of a loan in a form: its kind, sum, how often, and whether it is held back from the
/// loan.
struct CostRow: View {
  @Dependency(\.environment) private var environment
  @Binding var cost: DebtWizardModel.CostDraft
  let currency: CurrencyCode
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Picker("", selection: $cost.kind) {
          ForEach(DebtCostKind.allCases, id: \.self) {
            Text(verbatim: t("costs.kind.\($0.rawValue)")).tag($0)
          }
        }
        .labelsHidden()
        .fixedSize()
        AmountField(amount: $cost.amount)
        Text(verbatim: currency.code).foregroundStyle(.secondary)
        Button(role: .destructive, action: remove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(t("costs.remove"))
      }
      HStack {
        Picker("", selection: $cost.every) {
          ForEach(DebtCostEvery.allCases, id: \.self) {
            Text(verbatim: t("costs.every.\($0.rawValue)")).tag($0)
          }
        }
        .labelsHidden()
        .fixedSize()
        if cost.every == .once {
          Toggle(t("costs.inLoan"), isOn: $cost.inLoan)
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The lines of the true cost of a loan: the overpay, the real rate and, when it disagrees with
/// the contract, a word about it.
struct DebtCostLines: View {
  @Dependency(\.environment) private var environment
  let report: DebtCostReport
  let currency: CurrencyCode

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(
        verbatim: environment.format(
          "costs.overpay", table: "Debts",
          environment.money.exact(report.overpayE4, currency: currency))
      )
      if let rate = report.effectiveRate {
        Text(
          verbatim: environment.format(
            "costs.rate", table: "Debts", environment.money.number(rate, fractionDigits: 1...1)))
      }
      if report.disagreesWithContract, let gap = report.pskGap {
        Label {
          Text(
            verbatim: environment.format(
              "costs.pskGap", table: "Debts",
              environment.money.number(gap < 0 ? -gap : gap, fractionDigits: 1...1)))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .appFont(.callout)
    .accessibilityElement(children: .combine)
  }
}
