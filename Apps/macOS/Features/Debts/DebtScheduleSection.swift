import AppCore
import SwiftUI

/// The schedule of a loan as its form edits it: a grace period and what its payments are, the
/// main payment worked out over a number of months, and how the bank counts a payment. It reads
/// a debt and writes one (`applied(to:rate:)`); everything it says is checked before the form
/// saves (`issues`).
struct DebtSchedule: Equatable {
  /// What a payment of the grace period is, as the form offers it.
  enum GraceKind: String, CaseIterable, Hashable {
    /// The state programme: 40 % of the interest in the first year, 60 % in the second, then all.
    case programme
    /// All of the interest on the money drawn.
    case interest
    /// The same sum every month.
    case fixed
  }

  /// «Как банк засчитывает платёж?»
  enum PaymentOrder: Hashable {
    /// The interest accrued first, the rest off the debt (`Debt.accruesInterest`).
    case interestFirst
    /// All of it off the debt.
    case allToDebt
  }

  /// What keeps the form from saving.
  enum Issue: Hashable {
    /// The grace interest, a main payment over a term and the bank's order need a rate.
    case rateMissing
    /// «Фиксированный» without a sum.
    case graceAmountMissing
    /// A grace period with neither a main payment nor a term to work it out over.
    case mainPaymentMissing
    /// «Как банк засчитывает платёж?» is not answered.
    case orderUnanswered
  }

  static let monthsRange = 1...600

  var hasGrace = false
  var mainFrom: DateOnly
  var graceKind: GraceKind = .programme
  var graceAmount: AmountE4 = .zero
  /// «Рассчитать по сроку»: the main payment is the annuity over `months`.
  var byTerm = false
  var months = 180
  /// `nil` until the owner answers.
  var order: PaymentOrder?

  init(mainFrom: DateOnly) {
    self.mainFrom = mainFrom
  }

  /// The schedule `debt` has: an existing loan with a rate answered as it is kept — it has said
  /// how the bank counts its payments by accruing interest or not.
  init(debt: Debt, today: DateOnly) {
    self.init(mainFrom: debt.grace?.mainFrom ?? Self.defaultMainFrom(today: today))
    if let grace = debt.grace {
      hasGrace = true
      switch grace.payment {
      case .programme: graceKind = .programme
      case .interest: graceKind = .interest
      case .fixed(let amount):
        graceKind = .fixed
        graceAmount = amount
      }
    }
    if let months = debt.repayMonths {
      byTerm = true
      self.months = months
    }
    if debt.interestRate != nil { order = debt.accruesInterest ? .interestFirst : .allToDebt }
  }

  /// The first day of a main schedule nobody has said yet: the 1st of the month a year on.
  static func defaultMainFrom(today: DateOnly) -> DateOnly {
    var month = today.monthKey
    for _ in 0..<12 { month = month.next }
    return DateOnly(year: month.year, month: month.month, day: 1)
  }

  /// «Образовательный кредит (госпрограмма)»: the grace payments of the state programme, the main
  /// debt over 15 years. How the bank counts a payment is still asked.
  static func educationLoan(today: DateOnly) -> DebtSchedule {
    var schedule = DebtSchedule(mainFrom: defaultMainFrom(today: today))
    schedule.hasGrace = true
    schedule.graceKind = .programme
    schedule.byTerm = true
    schedule.months = 180
    schedule.order = nil
    return schedule
  }

  /// The rate of the education loan of the state programme, in percent.
  static let educationLoanRate = "3"

  /// Whether the debt needs a day of payment: a grace period or a term asks for monthly dues.
  var needsPaymentDay: Bool { hasGrace || byTerm }

  /// Whether «Как банк засчитывает платёж?» is asked: a loan I owe with a rate.
  static func asksOrder(rate: Decimal?, direction: DebtDirection) -> Bool {
    rate != nil && direction == .iOwe
  }

  /// What keeps the form from saving, for a debt of `direction` with `rate` and the main payment
  /// `monthly` typed.
  func issues(rate: Decimal?, monthly: AmountE4?, direction: DebtDirection) -> [Issue] {
    var found: [Issue] = []
    let grace = hasGrace && direction == .iOwe
    let needsRate = (grace && graceKind != .fixed) || byTerm
    if needsRate && rate == nil { found.append(.rateMissing) }
    if grace && graceKind == .fixed && graceAmount.raw <= 0 { found.append(.graceAmountMissing) }
    if grace && !byTerm && (monthly ?? .zero).raw <= 0 { found.append(.mainPaymentMissing) }
    if Self.asksOrder(rate: rate, direction: direction) && order == nil {
      found.append(.orderUnanswered)
    }
    return found
  }

  /// `debt` with this schedule, at `rate`: a grace period only on a debt I owe, a term in place of
  /// a typed main payment, interest accrued only when the bank counts it first.
  func applied(to debt: Debt, rate: Decimal?) -> Debt {
    var made = debt
    made.interestRate = rate
    if hasGrace && debt.direction == .iOwe {
      let payment: GracePayment =
        switch graceKind {
        case .programme: .programme
        case .interest: .interest
        case .fixed: .fixed(graceAmount)
        }
      made.grace = DebtGrace(mainFrom: mainFrom, payment: payment)
    } else {
      made.grace = nil
    }
    if byTerm {
      made.repayMonths = min(max(months, Self.monthsRange.lowerBound), Self.monthsRange.upperBound)
      made.monthlyPaymentE4 = nil
    } else {
      made.repayMonths = nil
    }
    made.accruesInterest = rate != nil && order == .interestFirst
    return made
  }

  /// The main payment over `months` of `principal` at `rate` — what «Рассчитать по сроку» shows;
  /// `nil` without a rate or anything owed.
  func annuity(principal: AmountE4, rate: Decimal?) -> AmountE4? {
    guard byTerm, let rate, principal.raw > 0 else { return nil }
    return InterestMath.annuity(principal: principal, percent: rate, months: months)
  }
}

/// «График» of a loan's form: the grace period, the main payment over a term, and «Как банк
/// засчитывает платёж?» — asked of a loan with a rate, with no answer assumed.
struct DebtScheduleSection: View {
  @Dependency(\.environment) private var environment
  @Binding var schedule: DebtSchedule
  let direction: DebtDirection
  let rate: Decimal?
  /// What the main payment is worked out of, as the form knows it.
  let principal: AmountE4
  let currency: CurrencyCode

  var body: some View {
    Section {
      if direction == .iOwe {
        Toggle(t("schedule.grace"), isOn: $schedule.hasGrace)
          .accessibilityIdentifier("debt.schedule.grace")
        if schedule.hasGrace {
          DatePicker(
            t("schedule.mainFrom"), selection: mainFromDate, displayedComponents: .date)
          Picker(t("schedule.graceKind"), selection: $schedule.graceKind) {
            ForEach(DebtSchedule.GraceKind.allCases, id: \.self) { kind in
              Text(verbatim: t("schedule.graceKind.\(kind.rawValue)")).tag(kind)
            }
          }
          .accessibilityIdentifier("debt.schedule.graceKind")
          if schedule.graceKind == .fixed {
            LabeledContent(t("schedule.graceAmount")) {
              HStack {
                AmountField(amount: $schedule.graceAmount)
                Text(verbatim: currency.code).foregroundStyle(.secondary)
              }
            }
          }
          caption(t("schedule.graceKind.\(schedule.graceKind.rawValue).hint"))
        }
      }
      Toggle(t("schedule.byTerm"), isOn: $schedule.byTerm)
        .accessibilityIdentifier("debt.schedule.byTerm")
      if schedule.byTerm {
        Stepper(value: $schedule.months, in: DebtSchedule.monthsRange) {
          Text(
            verbatim: environment.format("schedule.months", table: "Debts", "\(schedule.months)"))
        }
        if let annuity = schedule.annuity(principal: principal, rate: rate) {
          caption(
            environment.format(
              "schedule.annuity", table: "Debts",
              environment.money.exact(annuity, currency: currency)))
        }
      }
      if DebtSchedule.asksOrder(rate: rate, direction: direction) {
        Picker(t("schedule.order"), selection: $schedule.order) {
          Text(verbatim: "—").tag(DebtSchedule.PaymentOrder?.none)
          Text(verbatim: t("schedule.order.interestFirst"))
            .tag(DebtSchedule.PaymentOrder?.some(.interestFirst))
          Text(verbatim: t("schedule.order.allToDebt"))
            .tag(DebtSchedule.PaymentOrder?.some(.allToDebt))
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("debt.schedule.order")
        caption(t(schedule.order == nil ? "schedule.order.ask" : "schedule.order.hint"))
      }
      ForEach(issues, id: \.self) { issue in
        Label {
          Text(verbatim: t(Self.issueKey(issue)))
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .appFont(.caption).foregroundStyle(.secondary)
      }
    } header: {
      Text(verbatim: t("schedule.title"))
    }
  }

  /// What keeps the form from saving, but the unanswered question — it says so itself.
  private var issues: [DebtSchedule.Issue] {
    schedule.issues(rate: rate, monthly: nil, direction: direction).filter {
      $0 != .orderUnanswered && $0 != .mainPaymentMissing
    }
  }

  static func issueKey(_ issue: DebtSchedule.Issue) -> String {
    switch issue {
    case .rateMissing: "schedule.issue.rate"
    case .graceAmountMissing: "schedule.issue.graceAmount"
    case .mainPaymentMissing: "schedule.issue.mainPayment"
    case .orderUnanswered: "schedule.order.ask"
    }
  }

  private var mainFromDate: Binding<Date> {
    let calendar = environment.calendar
    return Binding(
      get: { calendar.startOfDay(schedule.mainFrom).addingTimeInterval(12 * 3600) },
      set: { schedule.mainFrom = calendar.day(of: $0) })
  }

  private func caption(_ text: String) -> some View {
    Text(verbatim: text)
      .appFont(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
