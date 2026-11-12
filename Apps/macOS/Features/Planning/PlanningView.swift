import AppCore
import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// The Planning section of the main window, as the design draws it: the header with the month
/// and the one main button «+ Добавить ▾»; the tabs — «Всё» and a tab for each block, the
/// cushion and the plan of the year —; on «Всё» the card «Сейчас свободно», the next 14 days and
/// the blocks as cards, three columns on a wide window and one on a narrow one, in the order the
/// owner set (`PlanningLayoutStore`), each column a run of that order. Every card has its symbol,
/// a total in its header, «все» to its tab and a chevron that collapses it for this window; a
/// long block lists its nearest items and keeps the rest behind «Показать все». Blocks of
/// content, without glass, over the planning snapshot the data step builds. Every form hangs on
/// the root of the section, and every action is one write and one step of ⌘Z.
struct PlanningView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appFontSize) private var fontSize
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.windowWidth) private var windowWidth
  /// The layout of this Mac; a test passes its own.
  var layout: PlanningLayoutStore = .shared
  @State private var sheet: PlanningSheet?
  @State private var eventForm: EventFormItem?
  /// D of the free sum as the owner picked it in the block of the free sum: the card at the top
  /// and the sentence follow it.
  @State private var until: Date?
  /// The blocks collapsed in this window; never kept.
  @State private var collapsed: Set<PlanningBlock> = []
  @State private var editing = false
  /// The tab on screen; never kept, every window opens on «Всё».
  @State private var tab: PlanningTab
  /// The whole block of the free sum, opened from the title of the card at the top.
  @State private var showsFree = false
  #if os(iOS)
    /// The width the scroll view really shows: the page is held to it, not to what the
    /// reader's proposal says, which can stand wider under a safe area at the side.
    @State private var scrollWidth: CGFloat = 0
  #endif

  init(layout: PlanningLayoutStore = .shared, tab: PlanningTab = .all) {
    self.layout = layout
    _tab = State(initialValue: tab)
  }

  /// The side margin: the phone's one, the page's own on a tablet and the Mac.
  private var pageSide: CGFloat {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .phone
        ? PhoneMetrics.screenMargin : PlanningMetrics.pageSide
    #else
      PlanningMetrics.pageSide
    #endif
  }

  var body: some View {
    let snapshot = compute.states.data.value
    let picked = until.map { environment.calendar.day(of: $0) }
    let free = snapshot.map { snapshot in
      snapshot.planning.freeMoney(
        until: FreeMoneyBlock.day(today: snapshot.today, picked: picked),
        ledger: snapshot.ledger)
    }
    GeometryReader { proxy in
      #if os(iOS)
        let content = max(0, (scrollWidth > 0 ? scrollWidth : proxy.size.width) - 2 * pageSide)
      #else
        let content = max(0, proxy.size.width - 2 * pageSide)
      #endif
      ScrollView {
        VStack(
          alignment: .leading,
          spacing: compact ? PlanningMetrics.phoneStackGap : PlanningMetrics.stackGap
        ) {
          PlanningHeader(editing: editingBinding, add: add)
          // A phone's frame has no tabs: «все» of a card still opens its block alone.
          if !compact || tab != .all { PlanningTabsRow(tab: $tab) }
          page(snapshot: snapshot, free: free, picked: picked, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
          .frame(width: content, alignment: .leading)
        #endif
        .padding(.horizontal, pageSide)
        .padding(.top, PlanningMetrics.pageTop)
        .padding(.bottom, PlanningMetrics.pageBottom)
      }
      #if os(iOS)
        .onScrollGeometryChange(for: CGFloat.self) {
          $0.containerSize.width
        } action: { _, width in
          scrollWidth = width
        }
      #endif
    }
    .background(surfaces.background)
    .screenNavigationTitle(environment.language("section.planning"))
    .sheet(item: $sheet) { sheet in
      PlanningSheetView(sheet: sheet)
        .handingOver(dependencies)
    }
    .sheet(item: $eventForm) { item in
      EventForm(original: item.event)
        .handingOver(dependencies)
    }
    .sheet(isPresented: $showsFree) {
      PlanningFreeSheet(picked: $until) { showsFree = false }
        .handingOver(dependencies)
    }
  }

  /// A phone's width: the frame of the iPhone.
  private var compact: Bool { ScreenWidth.isCompact(windowWidth) }

  /// «Изменить» orders the blocks of «Всё», so it goes there first.
  private var editingBinding: Binding<Bool> {
    Binding(
      get: { editing },
      set: { on in
        if on { tab = .all }
        editing = on
      })
  }

  @ViewBuilder
  private func page(
    snapshot: DataSnapshot?, free: FreeMoney?, picked: DateOnly?, content: CGFloat
  ) -> some View {
    switch tab {
    case .year:
      YearPlanPage()
    case .cushion:
      if let snapshot {
        CushionSection(status: snapshot.planning.cushion)
          .padding(PlanningMetrics.cardInset(compact: compact) + PlanningMetrics.cardEdge)
          .planningCardSurface()
      }
    case .all:
      if layout.order.contains(.freeMoney) {
        Group {
          if let figures = snapshot.flatMap({ Self.freeFigures($0, picked: picked, environment) }) {
            if compact {
              PlanningFreeLine(figures: figures) { showsFree = true }
            } else {
              PlanningFreeCard(
                figures: figures,
                showsColumns: PlanningPageLayout.freeShowsColumns(
                  forContent: content, fontSize: fontSize)
              ) { showsFree = true }
            }
          } else {
            // Nothing counted yet: the whole block, which says how to make the first count.
            FreeMoneyBlock(picked: $until)
          }
        }
        .guideTarget("planning.freeToSpend")
        // The tutorial's task «Посмотрите, сколько свободно» is done by the card coming on
        // screen.
        .onAppear { GuideStore.shared.report(GuideEvent.freeToSpendSeen) }
      }
      if let snapshot {
        PlanningRibbonView(
          ribbon: Self.ribbon(of: snapshot, shown: compute.snapshot), open: open)
        CreditMinimumPlanCard(snapshot: compute.snapshot ?? snapshot)
        PlanningBirthdaysStrip(snapshot: snapshot)
      }
      if editing {
        PlanningOrderEditor(layout: layout) { editing = false }
      } else {
        cards(
          PlanningPageLayout.gridBlocks(shown(snapshot)),
          columns: PlanningPageLayout.blockColumns(forContent: content, fontSize: fontSize),
          snapshot: snapshot, free: free)
      }
    default:
      cards(
        tab.blocks.filter { shown(snapshot).contains($0) }, columns: 1, snapshot: snapshot,
        free: free)
    }
  }

  /// The blocks of the order the screen shows: the block of self-employment only while it is
  /// on.
  private func shown(_ snapshot: DataSnapshot?) -> [PlanningBlock] {
    PlanningBlockText.shown(layout.order, selfEmployed: snapshot?.planning.npd != nil)
  }

  /// The free sum of the card at the top: the one Overview shows — the owner's horizon, the
  /// cushion kept out unless turned off —, or the one to the day picked in the block of the
  /// free sum.
  @MainActor
  static func freeFigures(
    _ snapshot: DataSnapshot, picked: DateOnly?, _ environment: AppEnvironment
  ) -> PlanningFreeFigures? {
    if let picked {
      let free = snapshot.planning.freeMoney(
        until: FreeMoneyBlock.day(today: snapshot.today, picked: picked), ledger: snapshot.ledger)
      return PlanningFreeFigures.make(free: free, horizon: nil, environment)
    }
    let (free, horizon) = OverviewHeadline.configured(snapshot)
    return PlanningFreeFigures.make(free: free, horizon: horizon, environment)
  }

  /// The cards in their columns, each column a run of the order.
  private func cards(
    _ blocks: [PlanningBlock], columns: Int, snapshot: DataSnapshot?, free: FreeMoney?
  ) -> some View {
    let laid = PlanningPageLayout.deal(blocks, into: columns)
    return HStack(alignment: .top, spacing: PlanningMetrics.columnGap) {
      ForEach(Array(laid.enumerated()), id: \.offset) { _, blocks in
        VStack(
          alignment: .leading,
          spacing: compact ? PlanningMetrics.phoneStackGap : PlanningMetrics.stackGap
        ) {
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
        }),
      showAll: tab == .all ? PlanningTab.tab(of: block).map { target in { tab = target } } : nil
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

  /// The next 14 days, from what the calendar plans for them. `shown` is the snapshot the screen
  /// presents, when `snapshot` is the whole one: its covered accounts decide which plans are not
  /// on the ribbon.
  static func ribbon(of snapshot: DataSnapshot, shown: DataSnapshot? = nil) -> PlanningRibbon {
    let planning = snapshot.planning
    let range = PlanningRibbon.range(today: snapshot.today)
    let plans = CalendarPlans.collect(
      ledger: snapshot.ledger, book: planning.book, today: snapshot.today, through: range.end,
      rubPerUnit: planning.rubPerUnit, matches: planning.matches)
    // Covered, a plan of a hidden account is not on its day; the two sums keep its money.
    return HiddenPlans(snapshot: shown ?? snapshot).covering(
      PlanningRibbon.build(plans: plans, today: snapshot.today, rubPerUnit: planning.rubPerUnit))
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

  /// What an item of «Добавить» opens: each the form the block of it has.
  @MainActor
  static func target(
    of addition: PlanningAddition, _ environment: AppEnvironment
  ) -> PlanningAddTarget {
    switch addition {
    case .payment: .sheet(.payment(nil))
    case .subscription: .sheet(.newSubscription(environment))
    case .income: .sheet(.expected(nil))
    case .limit: .sheet(.budget(nil))
    case .goal: .sheet(.goal(nil))
    case .event: .event
    }
  }

  private func add(_ addition: PlanningAddition) {
    switch Self.target(of: addition, environment) {
    case .sheet(let target): sheet = target
    case .event: eventForm = EventFormItem(event: nil)
    }
  }
}

/// Where an item of «Добавить» leads: a form of the section's sheets, or the form of an event,
/// which hangs on a sheet of its own.
enum PlanningAddTarget {
  case sheet(PlanningSheet)
  case event
}

/// What «Добавить» of Planning offers, in the order of the design.
enum PlanningAddition: String, CaseIterable, Identifiable {
  case payment
  case subscription
  case income
  case limit
  case goal
  case event

  var id: String { rawValue }

  var titleKey: String { "layout.add.\(rawValue)" }
}

/// The whole block of the free sum, over the screen: the day to count to, every line taken away,
/// the cushion and «Сколько нужно в этом месяце»; the card at the top follows the day picked
/// here.
struct PlanningFreeSheet: View {
  @Dependency(\.environment) private var environment
  @Binding var picked: Date?
  let done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView {
        FreeMoneyBlock(picked: $picked)
          .padding(.horizontal, 2)
      }
      HStack {
        Spacer()
        Button(PlanningBlockText.t("layout.done", environment), action: done)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("planning.free.done")
      }
    }
    .padding(20)
    .frame(minWidth: 440, idealWidth: 520, minHeight: 360, idealHeight: 560)
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
