import Foundation

/// A bill or a subscription that comes back on a schedule (`scheduled_payments`). `nextDate`
/// is the next due date not yet paid or skipped; `nil` once the schedule is over.
public struct ScheduledPayment: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var kind: ScheduledKind
  /// In `currency`; for a subscription the price as of today when there is no price history.
  public var amountE4: AmountE4
  public var currency: CurrencyCode
  public var categoryId: UUID?
  public var paymentMethodId: UUID?
  public var forWhom: ForWhom
  public var forPersonId: UUID?
  /// Paid for somebody who gives the money back (a subscription for someone else).
  public var reimbursable: Bool
  public var debtorPersonId: UUID?
  /// How much that person gives back, which may differ from what I pay; `nil` — all of it.
  public var reimbursementAmountE4: AmountE4?
  public var reimbursementCurrency: CurrencyCode?
  public var freq: Frequency
  /// Every `interval` weeks, months or years; at least 1.
  public var interval: Int
  /// Day of the month (monthly, yearly) or weekday 1…7, Monday first (weekly).
  public var day: Int?
  /// Month 1…12 of a yearly payment.
  public var month: Int?
  public var nextDate: DateOnly?
  public var endDate: DateOnly?
  public var trialEnd: DateOnly?
  public var cancelURL: String?
  public var remindDaysBefore: Int?
  public var active: Bool
  /// The card it is paid with, a card of `paymentMethodId`; `nil` — the account itself.
  public var cardId: UUID?
  /// The event whose budget its due dates up to the event's end belong to; `nil` — none.
  public var eventId: UUID?

  public init(
    id: UUID = UUID(), name: String, kind: ScheduledKind = .bill, amountE4: AmountE4,
    currency: CurrencyCode = .rub, categoryId: UUID? = nil, paymentMethodId: UUID? = nil,
    forWhom: ForWhom = .me, forPersonId: UUID? = nil, reimbursable: Bool = false,
    debtorPersonId: UUID? = nil, reimbursementAmountE4: AmountE4? = nil,
    reimbursementCurrency: CurrencyCode? = nil, freq: Frequency = .monthly, interval: Int = 1,
    day: Int? = nil, month: Int? = nil, nextDate: DateOnly? = nil, endDate: DateOnly? = nil,
    trialEnd: DateOnly? = nil, cancelURL: String? = nil, remindDaysBefore: Int? = nil,
    active: Bool = true, cardId: UUID? = nil, eventId: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.amountE4 = amountE4
    self.currency = currency
    self.categoryId = categoryId
    self.paymentMethodId = paymentMethodId
    self.forWhom = forWhom
    self.forPersonId = forPersonId
    self.reimbursable = reimbursable
    self.debtorPersonId = debtorPersonId
    self.reimbursementAmountE4 = reimbursementAmountE4
    self.reimbursementCurrency = reimbursementCurrency
    self.freq = freq
    self.interval = interval
    self.day = day
    self.month = month
    self.nextDate = nextDate
    self.endDate = endDate
    self.trialEnd = trialEnd
    self.cancelURL = cancelURL
    self.remindDaysBefore = remindDaysBefore
    self.active = active
    self.cardId = cardId
    self.eventId = eventId
  }
}

/// A price of a subscription from `date` on (`subscription_prices`), in the payment's
/// currency. A date in the future announces a change.
public struct SubscriptionPrice: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var paymentId: UUID
  public var date: DateOnly
  public var amountE4: AmountE4

  public init(id: UUID = UUID(), paymentId: UUID, date: DateOnly, amountE4: AmountE4) {
    self.id = id
    self.paymentId = paymentId
    self.date = date
    self.amountE4 = amountE4
  }
}

/// Money I expect (`expected_income`): once, in parts (a prepayment and the rest), or on a
/// schedule (monthly help in parts).
public struct ExpectedIncome: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var categoryId: UUID?
  public var personId: UUID?
  public var kind: ExpectedIncomeKind
  /// The whole amount — of the one-off income, or of one occurrence of a recurring one.
  public var totalE4: AmountE4
  public var currency: CurrencyCode
  /// When it is due (one-off), or the first due date (recurring).
  public var dueDate: DateOnly?
  public var freq: Frequency?
  public var day: Int?
  public var partsExpected: Int
  public var closed: Bool
  /// The account the money is to come to; `nil` — the account of the latest income received
  /// for it, else the main account.
  public var paymentMethodId: UUID?

  public init(
    id: UUID = UUID(), name: String, categoryId: UUID? = nil, personId: UUID? = nil,
    kind: ExpectedIncomeKind = .oneOff, totalE4: AmountE4, currency: CurrencyCode = .rub,
    dueDate: DateOnly? = nil, freq: Frequency? = nil, day: Int? = nil, partsExpected: Int = 1,
    closed: Bool = false, paymentMethodId: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.categoryId = categoryId
    self.personId = personId
    self.kind = kind
    self.totalE4 = totalE4
    self.currency = currency
    self.dueDate = dueDate
    self.freq = freq
    self.day = day
    self.partsExpected = partsExpected
    self.closed = closed
    self.paymentMethodId = paymentMethodId
  }
}

/// A received income tied to what was expected (`expected_income_links`).
public struct ExpectedIncomeLink: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var expectedIncomeId: UUID
  public var transactionId: UUID

  public init(id: UUID = UUID(), expectedIncomeId: UUID, transactionId: UUID) {
    self.id = id
    self.expectedIncomeId = expectedIncomeId
    self.transactionId = transactionId
  }
}

/// A monthly limit (`budgets`), in rubles: on a category or subcategory, on bad spending,
/// or on a «for whom» value.
public struct Budget: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var scope: BudgetScope
  public var categoryId: UUID?
  public var forWhom: ForWhom?
  public var amountE4: AmountE4
  public var rollover: Bool
  /// The month the limit started; the rollover counts from it.
  public var startMonth: MonthKey?

  public init(
    id: UUID = UUID(), scope: BudgetScope, categoryId: UUID? = nil, forWhom: ForWhom? = nil,
    amountE4: AmountE4, rollover: Bool = false, startMonth: MonthKey? = nil
  ) {
    self.id = id
    self.scope = scope
    self.categoryId = categoryId
    self.forWhom = forWhom
    self.amountE4 = amountE4
    self.rollover = rollover
    self.startMonth = startMonth
  }
}

/// One currency of a reconciliation typed by currency, with the rate it was counted at.
public struct ReconciliationAmount: Hashable, Sendable, Codable {
  public var currency: CurrencyCode
  public var amountE4: AmountE4
  /// Rubles per one unit; `nil` for rubles.
  public var rubPerUnit: Decimal?
  public var rubE4: AmountE4

  public init(currency: CurrencyCode, amountE4: AmountE4, rubPerUnit: Decimal?, rubE4: AmountE4) {
    self.currency = currency
    self.amountE4 = amountE4
    self.rubPerUnit = rubPerUnit
    self.rubE4 = rubE4
  }
}

/// What a reconciliation counted.
public enum ReconciliationKind: String, Hashable, Sendable, Codable, CaseIterable {
  /// One total in rubles, as reconciliations were made before accounts: kept as history, it
  /// anchors no balance.
  case total
  /// The sheet of every account and currency; its counts are in `ReconciledBalance`.
  case accounts
  /// Starting balances given outside the sheet: the setup of the accounts, a new account, a
  /// merge.
  case opening
}

/// Where the starting balances of an `.opening` came from — for the words of the history only;
/// nothing is computed from it. Openings written before it was kept have none.
public enum ReconciliationOrigin: String, Hashable, Sendable, Codable, CaseIterable {
  /// The setup of the accounts.
  case setup
  /// The balance given with a new account.
  case account
  /// A merge of two accounts.
  case merge
}

/// «How much money do I have in total» at a moment (`reconciliations`). The first one is the
/// starting point; each next one compares the actual total with the expected.
///
/// One of `kind` `.accounts` or `.opening` counts accounts one by one
/// (`ReconciledBalance`), and its moment is required; its ruble columns are for display only.
public struct Reconciliation: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var date: DateOnly
  /// The instant it was made; the window of the next reconciliation starts here.
  public var reconciledAt: Date?
  public var actualTotalRubE4: AmountE4
  public var expectedTotalRubE4: AmountE4?
  /// actual − expected; `nil` for the starting point.
  public var differenceE4: AmountE4?
  /// The operation that recorded the difference, if one was written.
  public var transactionId: UUID?
  public var breakdown: [ReconciliationAmount]
  public var kind: ReconciliationKind
  /// Where the balances of an `.opening` came from; `nil` for every other kind, and for an
  /// opening written before this was kept.
  public var origin: ReconciliationOrigin?

  public init(
    id: UUID = UUID(), date: DateOnly, reconciledAt: Date? = nil, actualTotalRubE4: AmountE4,
    expectedTotalRubE4: AmountE4? = nil, differenceE4: AmountE4? = nil,
    transactionId: UUID? = nil, breakdown: [ReconciliationAmount] = [],
    kind: ReconciliationKind = .total, origin: ReconciliationOrigin? = nil
  ) {
    self.id = id
    self.date = date
    self.reconciledAt = reconciledAt
    self.actualTotalRubE4 = actualTotalRubE4
    self.expectedTotalRubE4 = expectedTotalRubE4
    self.differenceE4 = differenceE4
    self.transactionId = transactionId
    self.breakdown = breakdown
    self.kind = kind
    self.origin = origin
  }
}

/// One counted balance of one account in one currency, at the moment of its reconciliation
/// (`reconciliation_balances`), in that currency. The first count of a pair is its starting
/// point: nothing is compared, so it has no expected balance and no difference.
public struct ReconciledBalance: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var reconciliationId: UUID
  public var accountId: UUID
  public var currency: CurrencyCode
  public var actualE4: AmountE4
  public var expectedE4: AmountE4?
  /// actual − expected; `nil` exactly when `expectedE4` is.
  public var differenceE4: AmountE4?
  /// The operation that recorded the difference, if one was written.
  public var transactionId: UUID?
  /// How a later count keeps its difference: `true` — one operation equal to the difference,
  /// none at zero, following the books; `false` — only the numbers follow, no operation.
  /// `nil` on a starting point, which has no difference to keep, and on a count of an opening.
  public var recordsDifference: Bool?

  public init(
    id: UUID = UUID(), reconciliationId: UUID, accountId: UUID, currency: CurrencyCode,
    actualE4: AmountE4, expectedE4: AmountE4? = nil, differenceE4: AmountE4? = nil,
    transactionId: UUID? = nil, recordsDifference: Bool? = nil
  ) {
    self.id = id
    self.reconciliationId = reconciliationId
    self.accountId = accountId
    self.currency = currency
    self.actualE4 = actualE4
    self.expectedE4 = expectedE4
    self.differenceE4 = differenceE4
    self.transactionId = transactionId
    self.recordsDifference = recordsDifference
  }

  public var key: BalanceKey { BalanceKey(accountId: accountId, currency: currency) }
  public var isStartingPoint: Bool { expectedE4 == nil }
}

/// Settings the planning reads, kept in `settings` under these keys and passed in by the app.
public struct PlanningSettings: Hashable, Sendable, Codable {
  public static let reconcileEveryDaysKey = "planning.reconcileEveryDays"
  public static let savingsTargetKey = "planning.savingsTargetBp"
  public static let reserveGoalPlanKey = "planning.reserveGoalPlan"
  public static let reserveEventBudgetsKey = "planning.reserveEventBudgets"
  public static let reconcileIncludesGoalSavingsKey = "planning.reconcileIncludesGoalSavings"
  public static let dismissedRemindersKey = "reminders.dismissed"
  /// The categories the difference of a reconciliation is written to — «Сверка» and its
  /// income twin. Ordinary categories, made the first time a difference is recorded and
  /// remembered here by id, the way the cashback category is.
  public static let reconcileExpenseCategoryKey = "planning.reconcileExpenseCategory"
  public static let reconcileIncomeCategoryKey = "planning.reconcileIncomeCategory"
  public static let limitsTopNKey = "planning.limitsTopN"
  public static let scheduledMatchRejectionsKey = "planning.scheduledMatchRejections"
  public static let goalSavingsValuationKey = "planning.goalSavingsValuation"
  /// Counts the owner said are real differences, not first counts: one id per line.
  public static let firstCountKeptKey = "reconcile.firstCountKept"
  /// The answers to «Это было до сверки?» remembered per reconciliation
  /// (`countAnswers(from:)`).
  public static let beforeCountAnswersKey = "reconcile.beforeCountAnswers"

  /// Remind to reconcile when the last one is older than this (default 14).
  public var reconcileEveryDays: Int
  /// The target share of savings in basis points (default 1 000 = 10 %).
  public var savingsTargetBp: Int
  /// «Free to spend» keeps back what is left of this month's goal plans (default on).
  public var reserveGoalPlan: Bool
  /// «Free to spend» keeps back what is left of the budgets of the events under way and soon to
  /// come (default on); off, no budget is held back and a payment tied to an event is held back
  /// as an ordinary one.
  public var reserveEventBudgets: Bool
  /// Contributions to goals stay in the total I reconcile (default on).
  public var reconcileIncludesGoalSavings: Bool
  /// Ids of reminders put off until they change (`Reminder.id`).
  public var dismissedReminders: Set<String>
  /// How many limits the lists of limits running out show (default 5); `nil` — all of them.
  public var limitsTopN: Int?
  /// Pairs of an ordinary operation and a due date of a scheduled payment the owner said are
  /// not the same thing, one `<operation>:<payment>:<YYYY-MM-DD>` each.
  public var scheduledMatchRejections: Set<String>
  /// How the money put into a goal in another currency is valued (default today's rate).
  public var goalSavingsValuation: GoalSavingsValuation
  /// Counts of a sheet the owner said record a real difference, though every count of their
  /// account and currency before them was a starting balance of zero written before such
  /// balances were told apart from counts.
  public var firstCountKept: Set<UUID>
  /// Per reconciliation, the answer given with «Больше не спрашивать для этой сверки»: `true`
  /// — what is entered happened before that count, `false` — after it.
  public var beforeCountAnswers: [UUID: Bool]
  /// The categories the difference of a reconciliation is written to — «Сверка» and its
  /// income twin —, as the reconciliation remembers them (`reconcileExpenseCategoryKey`,
  /// `reconcileIncomeCategoryKey`). Read with the settings, never written by them.
  public var reconcileExpenseCategoryId: UUID?
  public var reconcileIncomeCategoryId: UUID?

  public init(
    reconcileEveryDays: Int = 14, savingsTargetBp: Int = 1_000, reserveGoalPlan: Bool = true,
    reconcileIncludesGoalSavings: Bool = true, dismissedReminders: Set<String> = [],
    limitsTopN: Int? = 5, scheduledMatchRejections: Set<String> = [],
    goalSavingsValuation: GoalSavingsValuation = .today, firstCountKept: Set<UUID> = [],
    beforeCountAnswers: [UUID: Bool] = [:], reconcileExpenseCategoryId: UUID? = nil,
    reconcileIncomeCategoryId: UUID? = nil, reserveEventBudgets: Bool = true
  ) {
    self.reconcileEveryDays = reconcileEveryDays
    self.savingsTargetBp = savingsTargetBp
    self.reserveGoalPlan = reserveGoalPlan
    self.reserveEventBudgets = reserveEventBudgets
    self.reconcileIncludesGoalSavings = reconcileIncludesGoalSavings
    self.dismissedReminders = dismissedReminders
    self.limitsTopN = limitsTopN
    self.scheduledMatchRejections = scheduledMatchRejections
    self.goalSavingsValuation = goalSavingsValuation
    self.firstCountKept = firstCountKept
    self.beforeCountAnswers = beforeCountAnswers
    self.reconcileExpenseCategoryId = reconcileExpenseCategoryId
    self.reconcileIncomeCategoryId = reconcileIncomeCategoryId
  }

  /// «Сверка» and its income twin: no limit is set on them, nor on anything under them — the
  /// subcategories are found in the category tree.
  public var limitlessCategoryIds: Set<UUID> {
    Set([reconcileExpenseCategoryId, reconcileIncomeCategoryId].compactMap { $0 })
  }

  /// The answers kept under `beforeCountAnswersKey`: «<uuid> before» or «<uuid> after», one
  /// per line. A line that does not read — no id, another word, more words — is skipped, and
  /// of two lines about one reconciliation the later one counts.
  public static func countAnswers(from text: String?) -> [UUID: Bool] {
    guard let text else { return [:] }
    var answers: [UUID: Bool] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let words = line.split(whereSeparator: \.isWhitespace)
      guard words.count == 2, let id = UUID(uuidString: String(words[0])) else { continue }
      switch words[1] {
      case beforeWord: answers[id] = true
      case afterWord: answers[id] = false
      default: continue
      }
    }
    return answers
  }

  /// The text of `answers` for `beforeCountAnswersKey`, sorted by id so the same answers are
  /// always the same text; `nil` when there is none, which deletes the key.
  public static func countAnswersText(_ answers: [UUID: Bool]) -> String? {
    guard !answers.isEmpty else { return nil }
    return answers.map { (id: $0.key.uuidString, before: $0.value) }
      .sorted { $0.id < $1.id }
      .map { "\($0.id) \($0.before ? beforeWord : afterWord)" }
      .joined(separator: "\n")
  }

  private static let beforeWord = "before"
  private static let afterWord = "after"
}

/// How the money already put into a goal in another currency is counted in rubles.
public enum GoalSavingsValuation: String, Hashable, Sendable, Codable, CaseIterable {
  /// At today's rate: what the money would fetch now.
  case today
  /// At the rate of each contribution's own day: the rubles it cost.
  case deposits
}

/// Everything of planning, reconciliation and debts the snapshot carries besides the
/// operations and the dictionaries: read in the same transaction as the rest of the dataset.
public struct PlanningBook: Hashable, Sendable, Codable {
  public var scheduled: [ScheduledPayment]
  public var prices: [SubscriptionPrice]
  public var expected: [ExpectedIncome]
  public var expectedLinks: [ExpectedIncomeLink]
  public var budgets: [Budget]
  /// Oldest first.
  public var reconciliations: [Reconciliation]
  public var debtEntries: [DebtEntry]
  public var settings: PlanningSettings
  /// The counts of accounts, in the order of their reconciliations — by day, moment and the
  /// order they were made — and within one reconciliation in the order they were written.
  public var reconciledBalances: [ReconciledBalance]

  public init(
    scheduled: [ScheduledPayment] = [], prices: [SubscriptionPrice] = [],
    expected: [ExpectedIncome] = [], expectedLinks: [ExpectedIncomeLink] = [],
    budgets: [Budget] = [], reconciliations: [Reconciliation] = [],
    debtEntries: [DebtEntry] = [], settings: PlanningSettings = PlanningSettings(),
    reconciledBalances: [ReconciledBalance] = []
  ) {
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
    self.reconciliations = reconciliations
    self.debtEntries = debtEntries
    self.settings = settings
    self.reconciledBalances = reconciledBalances
  }

  public static let empty = PlanningBook()
}
