import AppCore
import SwiftUI

// MARK: - Free money

/// The free sum: what can be spent now — the money on the accounts of the summary less what the
/// goals hold — and, in grey, what of it is left once the planned payments, the debt payments,
/// the goal plans and the budgets of the events until a day D are taken away, with the daily
/// guide counted from that grey line. Due dates passed and unpaid are in it as money not yet
/// gone, and the block says how much of it they are, with the way to sort them out. D is any
/// day up to a year ahead, the end of the month unless the owner picks another.
///
/// Income still expected is shown and never added: money that has not come is not money
/// there is. With no count of any account there is nothing to show but «Мало данных» and the
/// way to the first count; the groups left out of the summary are shown apart with their own
/// totals, and get no free sum.
struct FreeMoneyBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.planningCardHosted) private var hosted
  /// D as the owner picked it, kept by the screen when it passes one: the sentence over the
  /// blocks speaks of the same day. Without one the block keeps its own.
  var picked: Binding<Date?>? = nil
  @State private var ownPick: Date?
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  private var until: Date? {
    get { picked?.wrappedValue ?? ownPick }
    nonmutating set {
      if let picked { picked.wrappedValue = newValue } else { ownPick = newValue }
    }
  }

  var body: some View {
    ComputedBlock(
      title: hosted ? nil : t("free.title"), state: compute.states.data,
      style: hosted ? .plain : .card, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let free = snapshot.planning.freeMoney(
        until: Self.day(
          today: snapshot.today, picked: until.map { environment.calendar.day(of: $0) }),
        ledger: snapshot.ledger)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(
          Self.parts(
            of: free, hasCushion: !snapshot.planning.cushion.accounts.isEmpty,
            half: snapshot.planning.halfFreeMoney(ledger: snapshot.ledger),
            payHalf: snapshot.planning.payHalf,
            cards: Self.cardsDue(snapshot, until: free.until)),
          id: \.name
        ) { part in
          view(of: part, free, snapshot)
        }
      }
    }
    .refusedWriteAlert($refused, environment)
    .guideTarget("planning.freeToSpend")
    // The tutorial's task «Посмотрите, сколько свободно до конца месяца» is done by the block
    // coming on screen.
    .onAppear { GuideStore.shared.report(GuideEvent.freeToSpendSeen) }
  }

  // MARK: What the block shows

  /// One piece of the block, in the order the block shows them.
  enum Part: Hashable {
    /// Nothing counted yet, so there is no money to start from: «Мало данных: сделайте первую
    /// сверку», with the way to the first count.
    case firstCount
    /// What can be spent now, with the day D beside it: the money now, less the goal savings
    /// when they are taken off (`spendable`: «можно тратить сейчас»).
    case main(AmountE4, spendable: Bool)
    /// Currencies the main figure leaves out for want of a rate today.
    case mainWithoutRate([CurrencyCode])
    /// Balances of the summary never counted, with the way to count them.
    case unanchored([BalanceKey])
    /// The money on the accounts and the money of the goals the main figure leaves out.
    case moneyAndGoals(AmountE4, AmountE4)
    /// The money of the safety cushion the main figure leaves out, when the owner keeps it
    /// out of the free sum.
    case cushion(AmountE4)
    /// «Учитывая запланированные События и траты» and what it takes away.
    case grey(AmountE4, lines: [FreeToSpendLine])
    /// The due dates passed and unpaid inside the grey line, with «Разобрать…».
    case overdue(AmountE4)
    /// Currencies of planned amounts left out of the lines for want of a rate today.
    case planWithoutRate([CurrencyCode])
    /// Each credit card out of the summary whose statement is to be paid by D: «Кредитка «…»
    /// к оплате до …» — the lines of the grey line add them up.
    case cardsDue([CardDue])
    /// «Можно тратить в день», from the grey line.
    case perDay(AmountE4, days: Int)
    /// «До 25-го: X · в день Y»: the grey line through the day of the next income of a month
    /// paid twice; the main figure stays the same.
    case half(AmountE4, perDay: AmountE4, until: DateOnly)
    /// «Зарплата не пришла?»: the day of the next income passed without it.
    case salaryLate(DateOnly)
    /// What the expectations still wait for until D: shown, never added.
    case stillExpected(AmountE4)
    case stillExpectedWithoutRate
    /// The switch that keeps the goals' plans back.
    case reserveSwitch
    /// The switch that keeps the safety cushion out of the free sum, once an account is marked
    /// as the cushion.
    case cushionSwitch
    /// The groups left out of the summary, each with its own total and no free sum.
    case excluded([FreeMoney.ExcludedGroup])

    /// Which piece it is, whatever figure it holds: the identity of its view, so a new figure
    /// redraws the piece in place — the day picker beside the main figure stays as it is.
    var name: String {
      switch self {
      case .firstCount: "firstCount"
      case .main: "main"
      case .mainWithoutRate: "mainWithoutRate"
      case .unanchored: "unanchored"
      case .moneyAndGoals: "moneyAndGoals"
      case .cushion: "cushion"
      case .grey: "grey"
      case .overdue: "overdue"
      case .planWithoutRate: "planWithoutRate"
      case .cardsDue: "cardsDue"
      case .perDay: "perDay"
      case .half: "half"
      case .salaryLate: "salaryLate"
      case .stillExpected: "stillExpected"
      case .stillExpectedWithoutRate: "stillExpectedWithoutRate"
      case .reserveSwitch: "reserveSwitch"
      case .cushionSwitch: "cushionSwitch"
      case .excluded: "excluded"
      }
    }
  }

  /// What the block shows of `free`: with no count only the way to the first one; the groups
  /// left out of the summary apart, in either case. `hasCushion`: an account is marked as the
  /// safety cushion, so the switch that keeps it out of the free sum is offered.
  ///
  /// `half` is the free sum through the next income of a month paid twice
  /// (`PlanningSnapshot.halfFreeMoney`) and `payHalf` that half; `cards` the credit cards out
  /// of the summary to pay by D (`cardsDue`).
  static func parts(
    of free: FreeMoney, hasCushion: Bool = false, half: FreeMoney? = nil,
    payHalf: PayHalf? = nil, cards: [CardDue] = []
  ) -> [Part] {
    var parts: [Part] = []
    switch free.state {
    case .noReconciliation:
      parts.append(.firstCount)
    case .ready:
      let spendable = free.goalSavings > .zero || free.cushion > .zero
      parts.append(.main(free.main ?? .zero, spendable: spendable))
      if !free.mainWithoutRate.isEmpty { parts.append(.mainWithoutRate(free.mainWithoutRate)) }
      if !free.unanchored.isEmpty { parts.append(.unanchored(free.unanchored)) }
      if free.goalSavings > .zero {
        parts.append(.moneyAndGoals(free.moneyNow ?? .zero, free.goalSavings))
      }
      if free.cushion > .zero { parts.append(.cushion(free.cushion)) }
      parts.append(.grey(free.grey ?? .zero, lines: free.lines))
      if free.overdue > .zero { parts.append(.overdue(free.overdue)) }
      if !free.planWithoutRate.isEmpty { parts.append(.planWithoutRate(free.planWithoutRate)) }
      if !cards.isEmpty { parts.append(.cardsDue(cards)) }
      parts.append(.perDay(free.dailyGuide, days: free.days))
      if let half, let payHalf, let grey = half.grey {
        parts.append(.half(grey, perDay: half.dailyGuide, until: half.until))
        if payHalf.late { parts.append(.salaryLate(payHalf.nextIncomeDay)) }
      }
      for line in free.info where line.key == FreeMoney.Key.stillExpected {
        parts.append(.stillExpected(line.amount))
      }
      if !free.stillExpectedWithoutRate.isEmpty { parts.append(.stillExpectedWithoutRate) }
      parts.append(.reserveSwitch)
      if hasCushion { parts.append(.cushionSwitch) }
    }
    if !free.excluded.isEmpty { parts.append(.excluded(free.excluded)) }
    return parts
  }

  /// D: the day picked, kept inside [today, today + 12 months]; the end of the month when none
  /// was picked (`FreeMoney.window`).
  static func day(today: DateOnly, picked: DateOnly?) -> DateOnly {
    FreeMoney.window(today: today, until: picked).end
  }

  @ViewBuilder
  private func view(of part: Part, _ free: FreeMoney, _ snapshot: DataSnapshot) -> some View {
    switch part {
    case .firstCount:
      noReconciliation
    case .main(let main, let spendable):
      mainLine(main, spendable: spendable, free, snapshot)
    case .mainWithoutRate(let currencies):
      caption(environment.format("free.mainWithoutRate", table: "Planning", codes(currencies)))
    case .unanchored(let keys):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        caption(
          environment.format("free.unanchored", table: "Planning", unanchored(keys, snapshot)))
        Spacer(minLength: 8)
        reconcileButton
      }
    case .moneyAndGoals(let money, let goals):
      caption(
        environment.format(
          "free.moneyAndGoals", table: "Planning", environment.money.rounded(money),
          environment.money.rounded(goals)))
    case .cushion(let amount):
      Label {
        Text(
          verbatim: environment.format(
            "free.cushion", table: "Planning", environment.money.rounded(amount)))
      } icon: {
        Image(systemName: CushionText.symbol)
      }
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    case .grey(let grey, let lines):
      Divider()
      greyLine(grey)
      FormulaLines(lines: lines.map { (key: $0.key, plus: $0.sign == .plus, amount: $0.amount) })
    case .overdue(let amount):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(
            verbatim: environment.format(
              "free.overdue", table: "Planning", environment.money.rounded(amount)))
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button(t("free.overdueReview")) { environment.showsOverdue = true }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    case .planWithoutRate(let currencies):
      caption(environment.format("free.planWithoutRate", table: "Planning", codes(currencies)))
    case .perDay(let amount, let days):
      Text(
        verbatim: environment.language.format(
          "free.perDay", table: "Planning", environment.money.rounded(amount), days)
      )
      .appFont(.callout.monospacedDigit())
      .foregroundStyle(.secondary)
    case .cardsDue(let cards):
      VStack(alignment: .leading, spacing: 2) {
        ForEach(cards) { card in
          caption(
            environment.format(
              "free.cardDue", table: "Planning", card.name, dayText(card.due, snapshot),
              environment.money.rounded(card.amount, currency: card.currency)))
        }
      }
      .accessibilityIdentifier("free.cardsDue")
    case .half(let amount, let perDay, let day):
      Text(
        verbatim: environment.format(
          "free.half", table: "Planning", dayText(day, snapshot), environment.money.rounded(amount),
          environment.money.rounded(perDay))
      )
      .appFont(.callout.monospacedDigit())
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("free.half")
    case .salaryLate(let day):
      Label {
        Text(
          verbatim: environment.format(
            "free.salaryLate", table: "Planning", dayText(day, snapshot)))
      } icon: {
        Image(systemName: "questionmark.circle")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("free.salaryLate")
    case .stillExpected(let amount):
      caption(
        environment.format(
          "free.stillExpected", table: "Planning", dayText(free.until, snapshot),
          environment.money.rounded(amount)),
        tertiary: true)
    case .stillExpectedWithoutRate:
      caption(t("free.stillExpectedWithoutRate"), tertiary: true)
    case .reserveSwitch:
      reserveSwitch(snapshot)
    case .cushionSwitch:
      settingSwitch(
        CapitalSettings.outOfFreeMoneyKey,
        isOn: snapshot.dataset.capitalSettings.outOfFreeMoney,
        label: "settings.planning.cushionOut"
      )
      .accessibilityIdentifier("free.cushionOut")
    case .excluded(let groups):
      excluded(groups)
    }
  }

  // MARK: Credit cards out of the summary

  /// A credit card out of the summary with its statement to pay by D.
  struct CardDue: Hashable, Identifiable {
    var accountId: UUID
    var name: String
    var due: DateOnly
    var amount: AmountE4
    var currency: CurrencyCode
    var id: UUID { accountId }
  }

  /// The credit cards out of the summary whose payment is due by `until`, by their day: what
  /// the line «Кредитки к оплате (вне сводки)» holds back, named card by card. A card in the
  /// summary is left out — its minus is already in the money now —, as is one with nothing to
  /// pay.
  static func cardsDue(_ snapshot: DataSnapshot, until: DateOnly) -> [CardDue] {
    let planning = snapshot.planning
    return planning.creditCards.compactMap { accountId, card -> CardDue? in
      guard let line = planning.accounts.line(of: accountId), !line.account.archived,
        !planning.accounts.isInSummary(accountId), let due = card.payBy, due <= until,
        card.toPayNoInterestE4.raw > 0
      else { return nil }
      return CardDue(
        accountId: accountId, name: line.account.name, due: due,
        amount: card.toPayNoInterestE4, currency: line.account.mainCurrency)
    }
    .sorted { ($0.due, $0.name) < ($1.due, $1.name) }
  }

  // MARK: Pieces

  /// Nothing counted yet: said in words, with the way to the first count.
  private var noReconciliation: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Label {
        Text(verbatim: t("free.noReconciliation"))
      } icon: {
        Image(systemName: "hourglass")
      }
      .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      reconcileButton
    }
  }

  private func mainLine(
    _ main: AmountE4, spendable: Bool, _ free: FreeMoney, _ snapshot: DataSnapshot
  )
    -> some View
  {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: environment.money.rounded(main))
          .appFont(.title2.monospacedDigit())
        Text(verbatim: t(spendable ? "free.mainSpendable" : "free.main"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      DatePicker(
        selection: Binding(
          get: { until ?? environment.calendar.startOfDay(free.until) },
          set: { until = $0 }),
        in: environment.calendar.startOfDay(
          snapshot.today)...environment.calendar.startOfDay(latestDay(snapshot)),
        displayedComponents: .date
      ) {
        Text(verbatim: t("free.until"))
      }
      .fixedSize()
    }
  }

  /// «Учитывая запланированные События и траты» — in grey, as the owner asked, with a word
  /// and a symbol when it is below zero.
  private func greyLine(_ grey: AmountE4) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: t("free.grey"))
      if grey.isNegative {
        Label {
          Text(verbatim: t("free.overspent"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .appFont(.caption)
      }
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(grey))
        .monospacedDigit()
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  /// The two switches of what the grey line holds back: the goals' plans and the budgets of
  /// events. A setting, not an action: the observation of the database recounts the block.
  private func reserveSwitch(_ snapshot: DataSnapshot) -> some View {
    let settings = snapshot.planning.book.settings
    return VStack(alignment: .leading, spacing: 4) {
      settingSwitch(
        PlanningSettings.reserveGoalPlanKey, isOn: settings.reserveGoalPlan,
        label: "settings.planning.reserve")
      settingSwitch(
        PlanningSettings.reserveEventBudgetsKey, isOn: settings.reserveEventBudgets,
        label: "settings.planning.reserveEvents"
      )
      .accessibilityIdentifier("free.reserveEvents")
    }
  }

  private func settingSwitch(_ key: String, isOn: Bool, label: String) -> some View {
    Toggle(
      isOn: Binding(
        get: { isOn },
        set: { reserve in
          if !environment.attempt(
            "settings.planning", on: environment.settings,
            { try $0.set(key, to: reserve ? "1" : "0") })
          {
            refused = true
          }
        })
    ) {
      Text(verbatim: environment.language(label, table: "Settings"))
    }
    .toggleStyle(.checkbox)
    .appFont(.caption)
  }

  /// Every group left out of the summary with its own total, and no free sum.
  @ViewBuilder
  private func excluded(_ groups: [FreeMoney.ExcludedGroup]) -> some View {
    Divider()
    Text(verbatim: t("free.excludedTitle"))
      .appFont(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
    ForEach(groups, id: \.group.id) { apart in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(verbatim: apart.group.name)
        } icon: {
          Image(systemName: "eye.slash")
        }
        Spacer(minLength: 8)
        Text(verbatim: apart.totalRub.map { "≈ " + environment.money.rounded($0) } ?? "—")
          .monospacedDigit()
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      if !apart.withoutRate.isEmpty {
        caption(
          environment.format(
            "free.mainWithoutRate", table: "Planning", codes(apart.withoutRate)))
      }
    }
  }

  private var reconcileButton: some View {
    Button(environment.language("reconcile.open", table: "Planning")) {
      environment.showsReconciliation = true
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func caption(_ text: String, tertiary: Bool = false) -> some View {
    Text(verbatim: text)
      .appFont(.caption.monospacedDigit())
      .foregroundStyle(tertiary ? .tertiary : .secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// «30 сентября»; a day of another year says its year.
  private func dayText(_ day: DateOnly, _ snapshot: DataSnapshot) -> String {
    day.year == snapshot.today.year
      ? environment.dates.dayAndMonth(day) : environment.dates.longDay(day)
  }

  private func latestDay(_ snapshot: DataSnapshot) -> DateOnly {
    snapshot.today.adding(months: FreeMoney.horizonMonths)
  }

  private func codes(_ currencies: [CurrencyCode]) -> String {
    currencies.map(\.code).joined(separator: ", ")
  }

  /// «Kaspi KZT, Наличные USD»: the balances never counted, by account and currency.
  private func unanchored(_ keys: [BalanceKey], _ snapshot: DataSnapshot) -> String {
    keys.map { key in
      let name = snapshot.dataset.paymentMethods.first { $0.id == key.accountId }?.name ?? "—"
      return "\(name) \(key.currency.code)"
    }.joined(separator: ", ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
