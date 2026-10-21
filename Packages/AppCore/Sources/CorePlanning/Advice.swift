import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

// MARK: - What a suggestion is made of

/// The kinds of suggestion of the Advice block, in no particular order; the
/// report lists them in the order `AdviceBook.build` gives. The title of a suggestion is
/// `advice.<kind>.title` in the Planning table.
public enum AdviceKind: String, CaseIterable, Sendable {
  case canSave
  case savingsRate
  case limitSuggestion
  case growingCategory
  case badComparison
  case badCutScenario
  case badLimitSuggestion
  case goal
  case debtLoad
  case debtPayoff
  case owedByPerson
  case oldestOwed
  case subscriptions
  case subscriptionsForOthers
  case eventSaving
  case forWhomShare
  case cashback

  /// `advice.<kind>.title`; with a subject the title takes its name for `%@`.
  public var titleKey: String { "advice.\(rawValue).title" }
}

/// What a suggestion or one of its lines is about. Names are the owner's own names of his
/// things, `nil` when the thing has none (a person-less group, say); the app puts them into
/// the words and supplies its own for a category (its path) and a «for whom» value.
public enum AdviceSubject: Hashable, Sendable {
  case category(UUID)
  case forWhom(ForWhom)
  case goal(String?)
  case debt(String?)
  case event(String?)
  case person(String?)
  case paymentMethod(String?)
}

/// What a line of a formula does: adds, takes away, gives the result, or only informs.
public enum AdviceOp: Hashable, Sendable {
  case plus
  case minus
  case equals
  case none
}

/// The number of a line, typed so the app formats it in the language of the moment.
public enum AdviceValue: Hashable, Sendable {
  /// Rubles.
  case money(AmountE4)
  /// An amount in its own currency — a debt in dollars, say.
  case moneyIn(CurrencyCode, AmountE4)
  /// 10 000 = 100 %.
  case basisPoints(Int)
  case months(Int)
  case days(Int)
  case count(Int)
  case month(MonthKey)
  case date(DateOnly)
  /// From … to …, in rubles.
  case range(AmountE4, AmountE4)
}

/// One line of the formula of a suggestion: a key of the Planning table (`advice.term.…`, or
/// the keys of `CanSave.Key`), what it does, its number and, when the words take a name, what
/// the line is about.
public struct AdviceTerm: Hashable, Sendable {
  public var key: String
  public var op: AdviceOp
  public var value: AdviceValue
  public var subject: AdviceSubject?

  public init(key: String, op: AdviceOp = .none, value: AdviceValue, subject: AdviceSubject? = nil)
  {
    self.key = key
    self.op = op
    self.value = value
    self.subject = subject
  }
}

/// A suggestion either stands on the numbers or says why there are too few of them — never a
/// made-up advice: with too little data it says «мало данных».
public enum AdviceStatus: Hashable, Sendable {
  case ready
  /// `advice.reason.<why>` in the Planning table.
  case notEnoughData(reasonKey: String)
}

/// One suggestion: its kind and subject, the terms of its formula, the result they give and
/// the notes around it. A suggestion without enough data carries no terms at all.
public struct Advice: Identifiable, Hashable, Sendable {
  /// `<kind>` or `<kind>:<id of the subject>` — stable from one run to the next.
  public var id: String
  public var kind: AdviceKind
  public var subject: AdviceSubject?
  public var status: AdviceStatus
  public var terms: [AdviceTerm]
  public var result: AdviceTerm?
  public var notes: [AdviceTerm]

  public init(
    id: String, kind: AdviceKind, subject: AdviceSubject? = nil, status: AdviceStatus = .ready,
    terms: [AdviceTerm] = [], result: AdviceTerm? = nil, notes: [AdviceTerm] = []
  ) {
    self.id = id
    self.kind = kind
    self.subject = subject
    self.status = status
    self.terms = terms
    self.result = result
    self.notes = notes
  }

  /// The suggestion of `kind` that has too little to stand on.
  static func notEnoughData(
    _ kind: AdviceKind, reason: String, subject: AdviceSubject? = nil, idSuffix: String? = nil
  ) -> Advice {
    Advice(
      id: AdviceBook.id(kind, idSuffix), kind: kind, subject: subject,
      status: .notEnoughData(reasonKey: reason))
  }
}

/// The Advice block: «can save this month», the savings rate and every suggestion in order.
public struct AdviceReport: Hashable, Sendable {
  public var canSave: CanSave
  /// The savings rate of the current month.
  public var savingsRate: SavingsRate
  public var items: [Advice]

  public init(canSave: CanSave, savingsRate: SavingsRate, items: [Advice]) {
    self.canSave = canSave
    self.savingsRate = savingsRate
    self.items = items
  }
}

// MARK: - The book of suggestions

/// Suggestions built by rules on the owner's data. Every suggestion shows its
/// formula and its numbers; with too little data it says so instead. Only numbers and keys live
/// here — the app supplies the words, and the permanent line «not financial advice»
/// (`disclaimerKey`).
///
/// The order of the list: can save, the savings rate, the goals, the limits, bad spending, the
/// debts, what is owed to me, subscriptions, events, «for whom», cashback.
public enum AdviceBook {
  public static let disclaimerKey = "advice.disclaimer"

  /// The keys of the lines. The app supplies the words, in the Planning table.
  public enum Key {
    // Can save and the savings rate.
    public static let canSave = "advice.term.canSave"
    public static let canSaveRange = "advice.term.canSaveRange"
    public static let alreadySaved = "advice.term.alreadySaved"
    public static let canSaveMore = "advice.term.canSaveMore"
    public static let goalsNetThisMonth = "advice.term.goalsNetThisMonth"
    public static let incomeThisMonth = "advice.term.incomeThisMonth"
    public static let savingsRate = "advice.term.savingsRate"
    public static let goalsNetLastMonth = "advice.term.goalsNetLastMonth"
    public static let incomeLastMonth = "advice.term.incomeLastMonth"
    public static let savingsRateLastMonth = "advice.term.savingsRateLastMonth"
    public static let savingsTarget = "advice.term.savingsTarget"
    public static let shortOfTarget = "advice.term.shortOfTarget"
    public static let aboveTarget = "advice.term.aboveTarget"

    // Goals.
    public static let goalRemaining = "advice.term.goalRemaining"
    public static let goalTargetDate = "advice.term.goalTargetDate"
    public static let goalMonthsLeft = "advice.term.goalMonthsLeft"
    public static let goalPace = "advice.term.goalPace"
    public static let goalNeededMonthly = "advice.term.goalNeededMonthly"
    public static let goalProjected = "advice.term.goalProjected"
    public static let goalByTargetDate = "advice.term.goalByTargetDate"
    public static let allGoalsNeed = "advice.term.allGoalsNeed"
    public static let canSaveCovers = "advice.term.canSaveCovers"
    public static let canSaveShort = "advice.term.canSaveShort"

    // Limits.
    public static let monthsCounted = "advice.term.monthsCounted"
    public static let monthsWithSpending = "advice.term.monthsWithSpending"
    public static let monthlyRange = "advice.term.monthlyRange"
    public static let monthlyMedian = "advice.term.monthlyMedian"
    public static let suggestedLimit = "advice.term.suggestedLimit"
    public static let lastMonthSpent = "advice.term.lastMonthSpent"
    public static let usualMedian = "advice.term.usualMedian"
    public static let aboveUsual = "advice.term.aboveUsual"
    public static let growth = "advice.term.growth"
    public static let lastCompleteMonth = "advice.term.lastCompleteMonth"

    // Bad spending.
    public static let badThisMonth = "advice.term.badThisMonth"
    public static let badSameSpanLastMonth = "advice.term.badSameSpanLastMonth"
    public static let badSameSpanAverage = "advice.term.badSameSpanAverage"
    public static let badVsLastMonth = "advice.term.badVsLastMonth"
    public static let changeVsLastMonth = "advice.term.changeVsLastMonth"
    public static let changeVsAverage = "advice.term.changeVsAverage"
    public static let badMonthlyAverage = "advice.term.badMonthlyAverage"
    public static let monthsAtPace = "advice.term.monthsAtPace"
    /// «Cut by 10 / 25 / 50 %: sooner by …» and «… frees … a month», by the share cut.
    public static func sooner(cutBp: Int) -> String { "advice.term.sooner\(cutBp / 100)" }
    public static func cut(cutBp: Int) -> String { "advice.term.cut\(cutBp / 100)" }
    public static let limitFactor = "advice.term.limitFactor"

    // Debts and what is owed to me.
    public static let debtTotal = "advice.term.debtTotal"
    public static let debtMonthlyPayments = "advice.term.debtMonthlyPayments"
    public static let debtIncome = "advice.term.debtIncome"
    public static let debtLoad = "advice.term.debtLoad"
    public static let debtsWithoutRate = "advice.term.debtsWithoutRate"
    public static let debtsWithoutPayment = "advice.term.debtsWithoutPayment"
    public static let debtBalance = "advice.term.debtBalance"
    public static let debtRate = "advice.term.debtRate"
    public static let debtPayment = "advice.term.debtPayment"
    public static let debtExtra = "advice.term.debtExtra"
    public static let monthsSooner = "advice.term.monthsSooner"
    public static let monthsWithoutExtra = "advice.term.monthsWithoutExtra"
    public static let monthsWithExtra = "advice.term.monthsWithExtra"
    public static let interestSaved = "advice.term.interestSaved"
    public static let closesOnlyWithExtra = "advice.term.closesOnlyWithExtra"
    public static let notClosedWithin = "advice.term.notClosedWithin"
    public static let owedBy = "advice.term.owedBy"
    public static let owedByOthers = "advice.term.owedByOthers"
    public static let owedTotal = "advice.term.owedTotal"
    public static let owedSince = "advice.term.owedSince"
    public static let owedAmount = "advice.term.owedAmount"

    // Subscriptions, events, «for whom», cashback.
    public static let subscriptionsCount = "advice.term.subscriptionsCount"
    public static let subscriptionsMonthly = "advice.term.subscriptionsMonthly"
    public static let subscriptionsYearly = "advice.term.subscriptionsYearly"
    public static let forOthersPayments = "advice.term.forOthersPayments"
    public static let forOthersOperations = "advice.term.forOthersOperations"
    public static let forOthersPaid = "advice.term.forOthersPaid"
    public static let forOthersReturned = "advice.term.forOthersReturned"
    public static let forOthersWaiting = "advice.term.forOthersWaiting"
    public static let forOthersCostMe = "advice.term.forOthersCostMe"
    public static let eventBudget = "advice.term.eventBudget"
    public static let eventLastTime = "advice.term.eventLastTime"
    public static let eventSpent = "advice.term.eventSpent"
    public static let eventMonths = "advice.term.eventMonths"
    public static let eventMonthlySaving = "advice.term.eventMonthlySaving"
    public static let eventStart = "advice.term.eventStart"
    public static let forOthersThisMonth = "advice.term.forOthersThisMonth"
    public static let spentThisMonth = "advice.term.spentThisMonth"
    public static let forOthersShare = "advice.term.forOthersShare"
    /// The share of one of the last three complete months: 1 — last month … 3.
    public static func forOthersShare(monthsAgo: Int) -> String {
      "advice.term.forOthersShare\(monthsAgo)MonthsAgo"
    }
    public static let forOthersShareAverage = "advice.term.forOthersShareAverage"
    public static let cashbackReceived = "advice.term.cashbackReceived"
    public static let cashbackTurnover = "advice.term.cashbackTurnover"
    public static let cashbackShare = "advice.term.cashbackShare"
  }

  /// Why a suggestion has too little to stand on.
  public enum Reason {
    /// «Can save» and the debt load: no income this month and no history to take it from.
    public static let noIncome = CanSave.Key.noIncome
    public static let noIncomeForRate = "advice.reason.noIncomeForRate"
    public static let noCompleteMonth = "advice.reason.noCompleteMonth"
    public static let fewerThanThreeMonths = "advice.reason.fewerThanThreeMonths"
    public static let fewerThanFourMonths = "advice.reason.fewerThanFourMonths"
    public static let goalNoDateNoPace = "advice.reason.goalNoDateNoPace"
    public static let goalNoPace = "advice.reason.goalNoPace"
    public static let nothingPaidForOthers = "advice.reason.nothingPaidForOthers"
    public static let eventNoTarget = "advice.reason.eventNoTarget"
    public static let noSpending = "advice.reason.noSpending"
  }

  /// Every suggestion for `today`.
  ///
  /// `planning` is the planning snapshot of the same ledger; `remainder` is what the forecast
  /// expects variable spending to add over the rest of the month («can save» needs it).
  public static func build(
    planning: PlanningSnapshot, ledger: Ledger, remainder: MonthForecast.Remainder,
    today: DateOnly
  ) -> AdviceReport {
    let context = AdviceContext(ledger: ledger, today: today)
    let canSave = planning.canSave(remainder: remainder)
    let target = planning.book.settings.savingsTargetBp
    let month = today.monthKey
    let rate = SavingsRate.month(ledger: ledger, month: month, targetBp: target)
    let lastRate = SavingsRate.month(ledger: ledger, month: month.previous, targetBp: target)
    let budgets = planning.book.budgets

    var items: [Advice] = []
    items.append(AdviceRules.canSave(canSave))
    items.append(AdviceRules.savingsRate(thisMonth: rate, lastMonth: lastRate))
    items += AdviceRules.goals(planning.goals, canSaveP50: canSave.p50)
    items += AdviceRules.limitSuggestions(context, budgets: budgets)
    items += AdviceRules.growingCategories(context)
    items += AdviceRules.badComparison(context)
    items += AdviceRules.badCutScenarios(context, goals: planning.goals)
    items += AdviceRules.badLimitSuggestion(context, budgets: budgets)
    items += AdviceRules.debtLoad(
      context, debts: planning.debts, accounts: planning.accounts.balances,
      rubPerUnit: planning.rubPerUnit)
    items += AdviceRules.debtPayoffs(planning.debts)
    items += AdviceRules.owedByPerson(context, debts: planning.debts)
    items += AdviceRules.oldestOwed(context, debts: planning.debts)
    items += AdviceRules.subscriptions(
      scheduled: planning.scheduled, monthly: planning.subscriptionsMonthly,
      yearly: planning.subscriptionsYearly)
    items += AdviceRules.subscriptionsForOthers(context, book: planning.book)
    items += AdviceRules.eventSaving(planning.events)
    items += AdviceRules.forWhomShare(context)
    items += AdviceRules.cashback(context)
    return AdviceReport(canSave: canSave, savingsRate: rate, items: items)
  }

  /// `<kind>` or `<kind>:<suffix>`.
  static func id(_ kind: AdviceKind, _ suffix: String?) -> String {
    suffix.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue
  }

  /// A UUID the way the app writes ids: lower-cased.
  static func id(_ kind: AdviceKind, _ uuid: UUID) -> String {
    id(kind, uuid.uuidString.lowercased())
  }
}

// MARK: - What every rule shares

/// The ledger, the day, the months a rule looks back over and the names of the owner's things.
struct AdviceContext {
  let ledger: Ledger
  let today: DateOnly
  private let people: [UUID: String]
  private let methods: [UUID: String]

  init(ledger: Ledger, today: DateOnly) {
    self.ledger = ledger
    self.today = today
    people = Dictionary(
      ledger.dataset.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    methods = Dictionary(
      ledger.dataset.paymentMethods.map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
  }

  var month: MonthKey { today.monthKey }

  /// The last `count` complete months before this one, oldest first, none before the month
  /// the history starts in — the months of the averages and medians of the goals and the
  /// income estimate (`SavingsMath.completeMonths`).
  func completeMonths(_ count: Int) -> [MonthKey] {
    SavingsMath.completeMonths(
      before: month, historyStart: ledger.firstDay?.monthKey, count: count)
  }

  func personName(_ id: UUID?) -> String? { id.flatMap { people[$0] } }
  func methodName(_ id: UUID) -> String? { methods[id] }
}

/// The few roundings of the suggestions, each half away from zero unless it says otherwise.
enum AdviceMath {
  /// 100 ₽ — what suggested limits and extra payments are rounded to.
  static let hundred = AmountE4(whole: 100)

  /// Up to the next 100: 3 010 → 3 100, 3 000 stays; zero and below give zero.
  static func roundedUpToHundred(_ amount: AmountE4) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    let (quotient, remainder) = amount.raw.quotientAndRemainder(dividingBy: hundred.raw)
    return AmountE4(raw: (quotient + (remainder > 0 ? 1 : 0)) * hundred.raw)
  }

  /// To the nearest 100, half away from zero: 2 950 → 3 000, 2 949 → 2 900.
  static func roundedToHundred(_ value: Decimal) -> AmountE4 {
    SavingsMath.rounded(DecimalMath.round(value / 100, scale: 0) * 100)
  }

  /// To whole units of the currency, half away from zero.
  static func roundedToWhole(_ value: Decimal) -> AmountE4 {
    SavingsMath.rounded(DecimalMath.round(value, scale: 0))
  }

  /// `amount` × `bp` ÷ 10 000.
  static func share(_ amount: AmountE4, basisPoints bp: Int) -> AmountE4 {
    SavingsMath.rounded(amount.decimal * Decimal(bp) / Decimal(Shares.whole))
  }

  /// A percent as a decimal (12.5) in basis points (1 250).
  static func basisPoints(percent: Decimal) -> Int {
    (try? DecimalMath.int64(rounding: percent * 100)).map { Int(clamping: $0) } ?? Int.max
  }

  /// Rubles as rubles, any other currency with its code.
  static func money(_ amount: AmountE4, in currency: CurrencyCode) -> AdviceValue {
    currency == .rub ? .money(amount) : .moneyIn(currency, amount)
  }
}

/// The rules, one static function per kind, spread over the files `AdviceRules+…`.
enum AdviceRules {}
