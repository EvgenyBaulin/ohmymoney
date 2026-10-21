import AppCore
import Foundation

/// The words and symbols of the Planning screen's frame — the names and symbols of the blocks,
/// the totals in their headers, the sentence over them, the hints of empty blocks — apart from
/// the views, so a test reads them in both languages without a window. Nothing here counts
/// money of its own: every figure is one the blocks show already.
@MainActor
enum PlanningBlockText {
  static let table = "Planning"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  /// The title of a block, the one its card shows.
  static func name(of block: PlanningBlock, _ environment: AppEnvironment) -> String {
    t(nameKey(of: block), environment)
  }

  static func nameKey(of block: PlanningBlock) -> String {
    switch block {
    case .freeMoney: "free.title"
    case .payments: "layout.block.payments"
    case .subscriptions: "layout.block.subscriptions"
    case .expectedIncome: "expected.title"
    case .limits: "limits.title"
    case .goals: "goals.title"
    case .events: "events.title"
    case .advice: "advice.title"
    case .selfEmployment: "layout.block.selfEmployment"
    }
  }

  /// The symbol beside the title: it tells the blocks apart at a glance, the title says what
  /// each is.
  static func symbol(of block: PlanningBlock) -> String {
    switch block {
    case .freeMoney: "banknote"
    case .payments: "calendar.badge.clock"
    case .subscriptions: "arrow.triangle.2.circlepath"
    case .expectedIncome: "tray.and.arrow.down"
    case .limits: "gauge.with.dots.needle.33percent"
    case .goals: "target"
    case .events: "party.popper"
    case .advice: "lightbulb"
    case .selfEmployment: "briefcase"
    }
  }

  // MARK: The sentence

  /// «До 25 октября можно потратить ещё 18,400 ₽, впереди 3 платежа на 12,900 ₽.» — the free
  /// sum's day, its grey line and its payments. Below zero it says what is missing instead.
  static func sentence(_ summary: PlanningSummary, _ environment: AppEnvironment) -> String {
    let day = dayText(summary.until, environment)
    let money = environment.money
    let first =
      summary.left.isNegative
      ? environment.format(
        "layout.summary.short", table: table, day, money.rounded(-summary.left))
      : environment.format(
        "layout.summary.left", table: table, day, money.rounded(summary.left))
    let second: String
    if summary.dueCount == 0 {
      second = t("layout.summary.noDues", environment)
    } else {
      second = environment.format(
        "layout.summary.duesAmount", table: table,
        environment.format("layout.summary.dues", table: table, counts: summary.dueCount),
        money.rounded(summary.duesAmount))
    }
    return environment.format("layout.summary.sentence", table: table, first, second)
  }

  /// «25 октября»; a day of another year says its year, as the free sum says it.
  static func dayText(_ day: DateOnly, _ environment: AppEnvironment) -> String {
    day.year == environment.today.year
      ? environment.dates.dayAndMonth(day) : environment.dates.longDay(day)
  }

  // MARK: The totals in the headers

  /// The total in the header of `block`, from the figures the block itself shows; `nil` when the
  /// block has nothing to add up. `free` is the free sum of the block's day, `adviceCount` how
  /// many suggestions there are once they are counted.
  static func total(
    of block: PlanningBlock, _ snapshot: DataSnapshot, free: FreeMoney?, adviceCount: Int?,
    _ environment: AppEnvironment
  ) -> String? {
    let planning = snapshot.planning
    let money = environment.money
    switch block {
    case .freeMoney:
      guard let summary = free.flatMap(PlanningSummary.init) else { return nil }
      return environment.format(
        "layout.total.free", table: table, money.rounded(summary.left),
        dayText(summary.until, environment))
    case .payments:
      guard let sum = dueThisMonth(of: .bill, snapshot) else { return nil }
      return environment.format("layout.total.month", table: table, money.rounded(sum))
    case .subscriptions:
      guard planning.scheduled.contains(where: { $0.payment.kind == .subscription }) else {
        return nil
      }
      return environment.format(
        "layout.total.perMonth", table: table, money.rounded(planning.subscriptionsMonthly))
    case .expectedIncome:
      guard let sum = expectedThisMonth(snapshot) else { return nil }
      return environment.format("layout.total.expected", table: table, money.rounded(sum))
    case .limits:
      guard !planning.limits.isEmpty else { return nil }
      return environment.format("layout.total.limits", table: table, counts: planning.limits.count)
    case .goals:
      guard let goals = goalsSaved(snapshot) else { return nil }
      return String(
        format: t("planning.spentOf", environment), locale: environment.language.locale,
        money.rounded(goals.saved), money.rounded(goals.target))
    case .events:
      let count = EventsBlock.shown(planning.events, budgeted: planning.budgetedEvents).count
      guard count > 0 else { return nil }
      return environment.format("layout.total.events", table: table, counts: count)
    case .advice:
      guard let adviceCount, adviceCount > 0 else { return nil }
      return environment.format("layout.total.advice", table: table, counts: adviceCount)
    case .selfEmployment:
      guard let block = SelfEmploymentBlock.build(npd: planning.npd, today: snapshot.today),
        block.taxToPayE4.raw > 0, let due = block.due
      else { return nil }
      return environment.format(
        "layout.total.selfEmployment", table: table, money.rounded(block.taxToPayE4),
        dayText(due, environment))
    }
  }

  /// What the payments of `kind` still ask this month, in rubles at today's rates: every unpaid
  /// due through the last day of the month, overdue ones included, each at the price of its own
  /// date — the free sum's rule (`CashPlan.scheduledStillDueThisMonth`). `nil` when there is no
  /// payment of the kind.
  static func dueThisMonth(of kind: ScheduledKind, _ snapshot: DataSnapshot) -> AmountE4? {
    let planning = snapshot.planning
    guard planning.scheduled.contains(where: { $0.payment.kind == kind }) else { return nil }
    return CashPlan.scheduledStillDueThisMonth(
      of: kind, ledger: snapshot.ledger, book: snapshot.dataset.planning,
      accounts: planning.accounts, today: snapshot.today, rubPerUnit: planning.rubPerUnit,
      matches: planning.matches)
  }

  /// What the expected incomes still wait for this month, in rubles: what is left of each of
  /// their dues of this month. `nil` when nothing is expected.
  static func expectedThisMonth(_ snapshot: DataSnapshot) -> AmountE4? {
    let statuses = snapshot.planning.expected
    guard !statuses.isEmpty else { return nil }
    let month = snapshot.today.monthKey
    return AmountE4.sum(
      statuses.flatMap(\.occurrences).filter { $0.due.monthKey == month }.map {
        $0.remainingRub ?? .zero
      })
  }

  /// What the live goals hold of what they need, in rubles at today's rates; a goal without a
  /// rate is left out of both. `nil` with no goal.
  static func goalsSaved(_ snapshot: DataSnapshot) -> (saved: AmountE4, target: AmountE4)? {
    let goals = snapshot.planning.goals.filter { !$0.goal.archived }
    guard !goals.isEmpty else { return nil }
    var saved = AmountE4.zero
    var target = AmountE4.zero
    for status in goals {
      guard let have = status.rubles(status.saved), let need = status.rubles(status.goal.targetE4)
      else { continue }
      saved += have
      target += need
    }
    return (saved, target)
  }

  // MARK: Empty blocks

  /// The hint of an empty block and the words of its button; `nil` for a block that is never
  /// empty in that way — the free sum speaks of the first count, the suggestions of what data
  /// they lack.
  static func emptyHint(of block: PlanningBlock) -> (text: String, button: String)? {
    switch block {
    case .payments: ("layout.empty.payments", "layout.empty.payments.add")
    case .subscriptions: ("layout.empty.subscriptions", "layout.empty.subscriptions.add")
    case .expectedIncome: ("layout.empty.expected", "layout.empty.expected.add")
    case .limits: ("layout.empty.limits", "layout.empty.limits.add")
    case .goals: ("layout.empty.goals", "layout.empty.goals.add")
    case .events: ("layout.empty.events", "layout.empty.events.add")
    case .freeMoney, .advice, .selfEmployment: nil
    }
  }

  // MARK: How many items

  /// «3», «5», «10», «Все».
  static func lengthTitle(_ length: PlanningListLength, _ environment: AppEnvironment) -> String {
    switch length {
    case .count(let count): environment.money.count(Int64(count))
    case .all: t("layout.length.all", environment)
    }
  }

  /// «Как в настройках (5)».
  static func globalLengthTitle(
    _ length: PlanningListLength, _ environment: AppEnvironment
  )
    -> String
  {
    environment.format("layout.length.global", table: table, lengthTitle(length, environment))
  }

  /// Every key of the frame, so a test finds each in both languages.
  static let keys = [
    "layout.block.payments", "layout.block.subscriptions", "layout.summary.left",
    "layout.summary.short", "layout.summary.dues", "layout.summary.duesAmount",
    "layout.summary.noDues", "layout.summary.sentence", "layout.ribbon.title",
    "layout.ribbon.incomes", "layout.ribbon.payments", "layout.ribbon.totals",
    "layout.ribbon.empty", "layout.ribbon.withoutRate", "layout.ribbon.open", "layout.add",
    "layout.add.payment", "layout.add.subscription", "layout.add.income", "layout.add.goal",
    "layout.add.event", "layout.add.limit", "layout.add.subscriptionButton", "layout.edit",
    "layout.done", "layout.reset",
    "layout.edit.hint", "layout.drag", "layout.moveUp", "layout.moveDown", "layout.collapse",
    "layout.expand", "layout.length", "layout.length.global", "layout.length.all",
    "layout.showAll", "layout.showLess", "layout.total.free", "layout.total.month",
    "layout.total.perMonth", "layout.total.expected", "layout.total.limits",
    "layout.total.events", "layout.total.advice", "layout.empty.payments",
    "layout.empty.payments.add", "layout.empty.subscriptions", "layout.empty.subscriptions.add",
    "layout.empty.expected", "layout.empty.expected.add", "layout.empty.limits",
    "layout.empty.limits.add", "layout.empty.goals", "layout.empty.goals.add",
    "layout.empty.events", "layout.empty.events.add", "layout.block.selfEmployment",
    "layout.total.selfEmployment",
  ]

  // MARK: Which blocks show

  /// The blocks of `order` the screen shows: «Самозанятость» only while self-employment is on —
  /// off, nothing of it is seen. The order itself keeps the block where the owner put it.
  static func shown(_ order: [PlanningBlock], selfEmployed: Bool) -> [PlanningBlock] {
    selfEmployed ? order : order.filter { $0 != .selfEmployment }
  }
}
