import CoreKit
import Foundation

/// What the first month checks, counted from the data as it is: never from a «Готово» button.
public struct FirstMonthFacts: Hashable, Sendable {
  /// The setup of the accounts was finished (or skipped for good): there is something to count
  /// money on.
  public var accountsReady: Bool
  /// Operations typed by hand.
  public var operations: Int
  /// Days with entry (`HabitEntryDays`).
  public var entryDays: Int
  /// Scheduled payments and subscriptions.
  public var scheduledPayments: Int
  /// Limits of categories.
  public var limits: Int
  public var goals: Int
  /// Counts of the accounts — the setup's starting balances are not a count.
  public var counts: Int

  public init(
    accountsReady: Bool = false, operations: Int = 0, entryDays: Int = 0,
    scheduledPayments: Int = 0, limits: Int = 0, goals: Int = 0, counts: Int = 0
  ) {
    self.accountsReady = accountsReady
    self.operations = operations
    self.entryDays = entryDays
    self.scheduledPayments = scheduledPayments
    self.limits = limits
    self.goals = goals
    self.counts = counts
  }
}

/// What makes a task of the first month done.
public enum FirstMonthCondition: Hashable, Sendable {
  case accountsReady
  case operations(Int)
  case entryDays(Int)
  case scheduledPayment
  case limit
  case goal
  case counts(Int)

  public func isMet(by facts: FirstMonthFacts) -> Bool {
    switch self {
    case .accountsReady: facts.accountsReady
    case .operations(let count): facts.operations >= count
    case .entryDays(let count): facts.entryDays >= count
    case .scheduledPayment: facts.scheduledPayments > 0
    case .limit: facts.limits > 0
    case .goal: facts.goals > 0
    case .counts(let count): facts.counts >= count
    }
  }
}

/// One task of the first month: on which day of the month it comes, what to do, where to press
/// («Показать, где» walks the hints as a task of the tutorial does) and what makes it done.
public struct FirstMonthTask: Hashable, Sendable, Identifiable {
  public var id: String
  /// The day of the first month it comes on, counted from 1.
  public var day: Int
  public var title: GuideText
  /// Why: one sentence.
  public var why: GuideText
  public var hints: [GuideHint]
  public var done: FirstMonthCondition

  public init(
    id: String, day: Int, title: GuideText, why: GuideText, hints: [GuideHint] = [],
    done: FirstMonthCondition
  ) {
    self.id = id
    self.day = day
    self.title = title
    self.why = why
    self.hints = hints
    self.done = done
  }
}

/// The checklist of the first month: setting up step by step — accounts, subscriptions, limits,
/// the first count —, a task or two on its day, no more. Kept in the guide's memory on this Mac
/// (`FirstMonthProgress`), never in the database.
public enum FirstMonth {
  /// How long the checklist lasts.
  public static let length = 30

  public static let tasks: [FirstMonthTask] = [
    FirstMonthTask(
      id: "month.accounts", day: 1,
      title: GuideText("Заведите счета и их остатки", "Add your accounts and their balances"),
      why: GuideText(
        "От остатков считаются «Всего», «Можно тратить» и прогноз.",
        "«Total», «Free to spend» and the forecast start from the balances."),
      hints: [
        GuideHint(
          target: GuideTarget.settingsAccounts,
          text: GuideText("Настройки → Счета", "Settings → Accounts"),
          why: GuideText(
            "Банк, счёт, карта и остаток на сегодня.", "Bank, account, card and today's balance."),
          keys: "⌘,")
      ],
      done: .accountsReady),
    FirstMonthTask(
      id: "month.firstOperation", day: 1,
      title: GuideText("Запишите первую трату", "Write down your first expense"),
      why: GuideText(
        "Одна строка — сумма и пара слов, остальное приложение поймёт само.",
        "One line: the amount and a word or two; the app reads the rest."),
      hints: [
        GuideHint(
          target: GuideTarget.entryLine,
          text: GuideText("Строка ввода внизу окна", "The entry line at the bottom of the window"),
          keys: "⌘N", gesture: GuideText("Коснитесь «+»", "Tap «+»"), advancesOnClick: false)
      ],
      done: .operations(1)),
    FirstMonthTask(
      id: "month.subscriptions", day: 2,
      title: GuideText(
        "Добавьте подписки и регулярные платежи", "Add subscriptions and regular payments"),
      why: GuideText(
        "Приложение напомнит о них и учтёт их в свободной сумме.",
        "The app reminds you of them and keeps them in the free sum."),
      hints: [
        GuideHint(
          target: GuideTarget.planningAddPayment,
          text: GuideText("«Планирование» → «Добавить платёж»", "Planning → Add payment"),
          keys: "⌘3")
      ],
      done: .scheduledPayment),
    FirstMonthTask(
      id: "month.threeDays", day: 3,
      title: GuideText("Записывайте траты три дня", "Write down your spending for three days"),
      why: GuideText(
        "Привычка складывается из коротких дней: пара строк вечером — уже учёт.",
        "A habit is made of short days: a couple of lines in the evening is already bookkeeping."),
      done: .entryDays(3)),
    FirstMonthTask(
      id: "month.limit", day: 5,
      title: GuideText("Поставьте лимит на одну категорию", "Set a limit on one category"),
      why: GuideText(
        "Начните с той, где траты удивляют чаще всего.",
        "Start with the one that surprises you most."),
      hints: [
        GuideHint(
          target: GuideTarget.sidebarPlanning,
          text: GuideText("«Планирование» → «Лимиты»", "Planning → Limits"), keys: "⌘3")
      ],
      done: .limit),
    FirstMonthTask(
      id: "month.firstCount", day: 7,
      title: GuideText("Сделайте первую сверку", "Make your first count"),
      why: GuideText(
        "Сверка сравнивает деньги на счетах с тем, что записано, и показывает разницу.",
        "A count lays the money on the accounts against what is written and shows the difference."),
      hints: [
        GuideHint(
          target: GuideTarget.toolbarReconcile,
          text: GuideText("«Вид» → «Сверка» (⌥⌘R)", "View → Count (⌥⌘R)"))
      ],
      done: .counts(1)),
    FirstMonthTask(
      id: "month.goal", day: 10,
      title: GuideText("Заведите цель", "Start a goal"),
      why: GuideText(
        "Цель с заметкой «Зачем коплю» помогает не тратить отложенное.",
        "A goal with a note on why you save helps keep what is put aside."),
      hints: [
        GuideHint(
          target: GuideTarget.planningAddGoal,
          text: GuideText("«Планирование» → «Новая цель»", "Planning → New goal"), keys: "⌘3")
      ],
      done: .goal),
    FirstMonthTask(
      id: "month.twoWeeks", day: 14,
      title: GuideText("Две недели записей", "Two weeks of entries"),
      why: GuideText(
        "Десять дней с записями — и «Аналитика» начинает рассказывать о ваших тратах.",
        "Ten days with entries, and Analytics starts telling about your spending."),
      done: .entryDays(10)),
    FirstMonthTask(
      id: "month.secondCount", day: 28,
      title: GuideText("Сверка в конце месяца", "A count at the end of the month"),
      why: GuideText(
        "Вторая сверка покажет, сколько трат прошло мимо записей.",
        "The second count shows how much spending went unwritten."),
      hints: [
        GuideHint(
          target: GuideTarget.toolbarReconcile,
          text: GuideText("«Вид» → «Сверка» (⌥⌘R)", "View → Count (⌥⌘R)"))
      ],
      done: .counts(2)),
  ]

  /// The day of the first month `today` is, counted from 1 on the day it started; `nil` before the
  /// start and after the month.
  public static func dayIndex(start: DateOnly, today: DateOnly) -> Int? {
    let days = dayNumber(today) - dayNumber(start) + 1
    return (1...length).contains(days) ? days : nil
  }

  /// Days since 1970-01-01 (H. Hinnant's `days_from_civil`): the guide sits below the analytics,
  /// which has the same arithmetic.
  static func dayNumber(_ date: DateOnly) -> Int {
    let shiftedYear = date.month <= 2 ? date.year - 1 : date.year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let shiftedMonth = date.month > 2 ? date.month - 3 : date.month + 9
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + date.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  /// The tasks that have come by `today`, not done: the ones the card shows. Nothing outside the
  /// month.
  public static func open(
    start: DateOnly, today: DateOnly, facts: FirstMonthFacts, done: Set<String> = []
  ) -> [FirstMonthTask] {
    guard let index = dayIndex(start: start, today: today) else { return [] }
    return tasks.filter {
      $0.day <= index && !done.contains($0.id) && !$0.done.isMet(by: facts)
    }
  }

  /// «4 из 9».
  public static func progress(
    facts: FirstMonthFacts, done: Set<String> = []
  ) -> (
    done: Int, total: Int
  ) {
    (tasks.filter { done.contains($0.id) || $0.done.isMet(by: facts) }.count, tasks.count)
  }
}

/// The memory of the first month on this Mac: the day it started, the tasks found done (done
/// stays done) and whether the owner put the card away. Codable, kept as one value in the
/// settings of this Mac; a field added later must decode as absent.
public struct FirstMonthProgress: Hashable, Sendable, Codable {
  public var start: DateOnly
  public var done: Set<String>
  public var hidden: Bool

  public init(start: DateOnly, done: Set<String> = [], hidden: Bool = false) {
    self.start = start
    self.done = done
    self.hidden = hidden
  }

  /// Marks the tasks the facts show done; returns the ids found just now.
  @discardableResult
  public mutating func record(_ facts: FirstMonthFacts) -> [String] {
    var fresh: [String] = []
    for task in FirstMonth.tasks where !done.contains(task.id) && task.done.isMet(by: facts) {
      done.insert(task.id)
      fresh.append(task.id)
    }
    return fresh
  }

  /// The card shows: within the month, not put away, and something left to do by today.
  public func shows(today: DateOnly, facts: FirstMonthFacts) -> Bool {
    !hidden && !FirstMonth.open(start: start, today: today, facts: facts, done: done).isEmpty
  }
}
