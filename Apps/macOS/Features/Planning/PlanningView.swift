import AppCore
import SwiftUI

/// The Planning section of the main window, ⌘2. At the top one sentence of where the money
/// stands — the free sum's day, what is left of it and the payments ahead —, the «+» menu of
/// every form and «Изменить» for the order of the blocks; then the next 14 days on a ribbon; then
/// the blocks as cards, two columns on a wide window and one on a narrow one, in the order the
/// owner set (`PlanningLayoutStore`). Every card has its symbol, a total in its header and a
/// chevron that collapses it for this window; a long block lists its nearest items and keeps the
/// rest behind «Показать все». Blocks of content, without glass, over the planning snapshot the
/// data step builds. Every form hangs on the root of the section, and every action is one write
/// and one step of ⌘Z.
struct PlanningView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// The layout of this Mac; a test passes its own.
  var layout: PlanningLayoutStore = .shared
  @State private var sheet: PlanningSheet?
  @State private var eventForm: EventFormItem?
  /// D of the free sum as the owner picked it: the free money block and the sentence share it.
  @State private var until: Date?
  /// The blocks collapsed in this window; never kept.
  @State private var collapsed: Set<PlanningBlock> = []
  @State private var editing = false
  /// The month's blocks or the plan of the year (`YearPlanPage`); never kept.
  @State private var area: PlanningArea = .month

  /// Two columns from this width of content on, one below it.
  static let twoColumnsFrom: CGFloat = 760

  static func columns(forWidth width: CGFloat) -> Int {
    width >= twoColumnsFrom ? 2 : 1
  }

  var body: some View {
    let snapshot = compute.states.data.value
    let free = snapshot.map { snapshot in
      snapshot.planning.freeMoney(
        until: FreeMoneyBlock.day(
          today: snapshot.today, picked: until.map { environment.calendar.day(of: $0) }),
        ledger: snapshot.ledger)
    }
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          PlanningTopBar(editing: $editing, add: add)
          PlanningAreaPicker(area: $area)
          if area == .year {
            YearPlanPage()
          } else {
            if let free, layout.order.contains(.freeMoney),
              let hero = PlanningHero.make(
                free: free, environment: environment)
            {
              ScreenHero(
                caption: hero.caption, figure: hero.figure, lines: hero.lines,
                figureIdentifier: "planning.hero.figure"
              )
              .accessibilityIdentifier("planning.summary")
            }
            if let snapshot {
              PlanningRibbonView(ribbon: Self.ribbon(of: snapshot), open: open)
            }
            if editing {
              PlanningOrderEditor(layout: layout) { editing = false }
            } else {
              cards(
                columns: Self.columns(forWidth: proxy.size.width - 40), snapshot: snapshot,
                free: free)
            }
          }
        }
        .padding(20)
      }
    }
    .screenNavigationTitle(environment.language("section.planning"))
    .sheet(item: $sheet) { sheet in
      PlanningSheetView(sheet: sheet)
        .handingOver(dependencies)
    }
    .sheet(item: $eventForm) { item in
      EventForm(original: item.event)
        .handingOver(dependencies)
    }
  }

  /// The cards in their columns, each column taking the blocks in turn.
  private func cards(columns: Int, snapshot: DataSnapshot?, free: FreeMoney?) -> some View {
    let laid = PlanningBlocks.columns(
      PlanningBlockText.shown(layout.order, selfEmployed: snapshot?.planning.npd != nil),
      count: columns)
    return HStack(alignment: .top, spacing: 16) {
      ForEach(Array(laid.enumerated()), id: \.offset) { _, blocks in
        VStack(alignment: .leading, spacing: 16) {
          ForEach(blocks, id: \.self) { block in
            card(block, snapshot: snapshot, free: free)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func card(
    _ block: PlanningBlock, snapshot: DataSnapshot?, free: FreeMoney?
  )
    -> some View
  {
    PlanningCard(
      block: block,
      total: snapshot.flatMap {
        PlanningBlockText.total(
          of: block, $0, free: free, adviceCount: compute.states.advice.value?.items.count,
          environment)
      },
      layout: layout,
      collapsed: Binding(
        get: { collapsed.contains(block) },
        set: { isCollapsed in
          if isCollapsed { collapsed.insert(block) } else { collapsed.remove(block) }
        })
    ) {
      content(of: block)
    }
  }

  @ViewBuilder
  private func content(of block: PlanningBlock) -> some View {
    switch block {
    case .freeMoney: FreeMoneyBlock(picked: $until)
    case .payments:
      ScheduledBlock(sheet: $sheet, kind: .bill, length: layout.length(of: .payments))
    case .subscriptions:
      ScheduledBlock(
        sheet: $sheet, kind: .subscription, length: layout.length(of: .subscriptions))
    case .expectedIncome:
      ExpectedIncomeBlock(sheet: $sheet, length: layout.length(of: .expectedIncome))
    case .limits: LimitsBlock(sheet: $sheet)
    case .goals: GoalsBlock(sheet: $sheet, length: layout.length(of: .goals))
    case .events: EventsBlock()
    case .advice: AdviceBlock()
    case .selfEmployment: SelfEmploymentBlockView()
    }
  }

  /// The next 14 days, from what the calendar plans for them.
  static func ribbon(of snapshot: DataSnapshot) -> PlanningRibbon {
    let planning = snapshot.planning
    let range = PlanningRibbon.range(today: snapshot.today)
    let plans = CalendarPlans.collect(
      ledger: snapshot.ledger, book: planning.book, today: snapshot.today, through: range.end,
      rubPerUnit: planning.rubPerUnit, matches: planning.matches)
    return PlanningRibbon.build(
      plans: plans, today: snapshot.today, rubPerUnit: planning.rubPerUnit)
  }

  /// A plan of the ribbon opens what it is: an income its form, a payment or a subscription its
  /// form, a debt the Debts section, where its payments are made.
  private func open(_ plan: CalendarPlan) {
    guard let snapshot = compute.states.data.value else { return }
    switch Self.target(of: plan, in: snapshot.dataset.planning) {
    case .some(let target): sheet = target
    case nil:
      NotificationCenter.default.post(
        name: .selectSection, object: MainWindow.Section.debts.shortcutIndex)
    }
  }

  /// The form a plan of the ribbon opens; `nil` for a debt, whose place is the Debts section.
  static func target(of plan: CalendarPlan, in book: PlanningBook) -> PlanningSheet? {
    switch plan.kind {
    case .income:
      return book.expected.first { $0.id == plan.sourceId }.map { .expected($0) }
    case .payment:
      return book.scheduled.first { $0.id == plan.sourceId }.map { .payment($0) }
    }
  }

  /// What «+» adds: each item opens the form the block of it has.
  private func add(_ addition: PlanningAddition) {
    switch addition {
    case .payment: sheet = .payment(nil)
    case .subscription: sheet = .newSubscription(environment)
    case .income: sheet = .expected(nil)
    case .goal: sheet = .goal(nil)
    case .event: eventForm = EventFormItem(event: nil)
    case .limit: sheet = .budget(nil)
    }
  }
}

/// What the «+» menu of Planning offers, in its order.
enum PlanningAddition: String, CaseIterable, Identifiable {
  case payment
  case subscription
  case income
  case goal
  case event
  case limit

  var id: String { rawValue }

  var titleKey: String { "layout.add.\(rawValue)" }
}

/// The line over the blocks: the title with its subtitle, and the actions — «Хватит ли?»,
/// «Что если», «+» with every form, «Изменить». On a phone's width the four buttons would not
/// fit beside the title, so they fold into one menu at its right.
struct PlanningTopBar: View {
  @Dependency(\.environment) private var environment
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dependencies) private var dependencies
  @Environment(\.windowWidth) private var windowWidth
  @State private var asksAfford = false
  @Binding var editing: Bool
  let add: (PlanningAddition) -> Void

  private var compact: Bool { ScreenWidth.isCompact(windowWidth) }

  var body: some View {
    HStack(alignment: compact ? .top : .firstTextBaseline, spacing: 12) {
      ScreenTitleBlock(
        title: environment.language("section.planning"),
        subtitle: PlanningBlockText.t("layout.subtitle", environment),
        identifier: "planning.title")
      Spacer(minLength: 8)
      if compact {
        actionsMenu
      } else {
        wideActions
      }
    }
    .sheet(isPresented: $asksAfford) { AffordSheet().handingOver(dependencies) }
  }

  private var affordButton: some View {
    Button(environment.language("afford.title", table: "WhatIf")) { asksAfford = true }
      .accessibilityIdentifier("planning.afford")
  }

  private var whatIfButton: some View {
    Button(environment.language("window.whatIf")) { AppScreens.open(.whatIf, with: openWindow) }
      .accessibilityIdentifier("planning.whatIf")
  }

  private var editButton: some View {
    Button(PlanningBlockText.t(editing ? "layout.done" : "layout.edit", environment)) {
      editing.toggle()
    }
    .accessibilityIdentifier("planning.edit")
  }

  @ViewBuilder
  private var addItems: some View {
    ForEach(PlanningAddition.allCases) { addition in
      Button(PlanningBlockText.t(addition.titleKey, environment)) { add(addition) }
    }
  }

  private var wideActions: some View {
    HStack(spacing: 12) {
      affordButton.buttonStyle(.bordered).fixedSize()
      whatIfButton.buttonStyle(.bordered).fixedSize()
      Menu {
        addItems
      } label: {
        Label {
          Text(verbatim: PlanningBlockText.t("layout.add", environment))
        } icon: {
          Image(systemName: "plus")
        }
      }
      .menuStyle(.button)
      .buttonStyle(.bordered)
      .fixedSize()
      .accessibilityIdentifier("planning.add")
      editButton.buttonStyle(.bordered).fixedSize()
    }
  }

  /// One round button: the forms first, then the two questions, then the order of the blocks.
  private var actionsMenu: some View {
    Menu {
      Section { addItems }
      Section {
        affordButton
        whatIfButton
        editButton
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .appFont(.title2)
        .accessibilityLabel(Text(verbatim: PlanningBlockText.t("layout.add", environment)))
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
    .accessibilityIdentifier("planning.actions")
  }
}

/// Which form the section shows.
enum PlanningSheet: Identifiable {
  /// A payment to edit, or nil for an empty new one.
  case payment(ScheduledPayment?)
  /// A new payment the form starts filled in — from a subscription candidate, or paid from the
  /// account whose screen is open. It carries an id but is not in the database: nothing is
  /// edited, no price of it has changed. `currencyChosen` is false when the currency only
  /// follows the account: another account picked in the form then moves it.
  case newPayment(ScheduledPayment, currencyChosen: Bool = true)
  case markAsPaid(ScheduledStatus)
  case budget(Budget?)
  case goal(Goal?)
  case moveGoal(GoalStatus, withdraw: Bool)
  case expected(ExpectedIncome?)
  case linkIncome(ExpectedIncomeStatus)

  /// «Завести» from a subscription candidate: the form filled in with what the purchases
  /// suggest — the amount, the category, the rhythm and the account (and card) the latest
  /// purchase was paid from, so the payment shows on that account's screen.
  static func subscription(from candidate: SubscriptionCandidate, name: String) -> PlanningSheet {
    .newPayment(
      ScheduledPayment(
        name: name, kind: .subscription, amountE4: candidate.typicalAmount,
        currency: candidate.currency, categoryId: candidate.categoryId,
        paymentMethodId: candidate.paymentMethodId, freq: candidate.freq,
        cardId: candidate.cardId))
  }

  /// «Подписка» of «+» and of the block «Подписки»: an empty payment that starts as a
  /// subscription, in the default currency, due today; its currency follows the account picked.
  @MainActor
  static func newSubscription(_ environment: AppEnvironment) -> PlanningSheet {
    var payment = ScheduledPaymentForm.newPayment(
      defaultCurrency: environment.defaultCurrency, today: environment.today)
    payment.kind = .subscription
    return .newPayment(payment, currencyChosen: false)
  }

  /// The payment the form edits — saved over it, with a price edit when the amount changed —
  /// or nil when the form makes a new one.
  var editedPayment: ScheduledPayment? {
    guard case .payment(let payment) = self else { return nil }
    return payment
  }

  /// What the payment form starts with: the payment it edits, or the one a candidate
  /// suggests; nil for an empty form.
  var startingPayment: ScheduledPayment? {
    switch self {
    case .payment(let payment): payment
    case .newPayment(let payment, _): payment
    default: nil
    }
  }

  /// Whether the currency the form starts with is the owner's — a payment saved, a candidate's
  /// purchases — and stays when an account is picked.
  var startCurrencyChosen: Bool {
    switch self {
    case .payment(let payment): payment != nil
    case .newPayment(_, let currencyChosen): currencyChosen
    default: false
    }
  }

  var id: String {
    switch self {
    case .payment(let payment): "payment-\(payment?.id.uuidString ?? "new")"
    case .newPayment(let payment, _): "payment-new-\(payment.id.uuidString)"
    case .markAsPaid(let status): "paid-\(status.id)"
    case .budget(let budget): "budget-\(budget?.id.uuidString ?? "new")"
    case .goal(let goal): "goal-\(goal?.id.uuidString ?? "new")"
    case .moveGoal(let status, let withdraw): "move-\(status.id)-\(withdraw)"
    case .expected(let income): "expected-\(income?.id.uuidString ?? "new")"
    case .linkIncome(let status): "link-\(status.id)"
    }
  }
}

/// «+ доход месяца 120 000 ₽ − потрачено 96 300 ₽ …»: every term of a formula on a line of
/// its own, sign first, so the formula reads fully («формула видна полностью»).
struct FormulaLines: View {
  @Dependency(\.environment) private var environment
  let lines: [(key: String, plus: Bool, amount: AmountE4)]
  var exact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(verbatim: PlanningText.sign(line.plus))
            .frame(width: 10, alignment: .leading)
          Text(verbatim: environment.language(line.key, table: "Planning"))
          Spacer(minLength: 8)
          Text(
            verbatim: exact
              ? environment.money.exact(line.amount) : environment.money.rounded(line.amount)
          )
          .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
      }
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }
}
