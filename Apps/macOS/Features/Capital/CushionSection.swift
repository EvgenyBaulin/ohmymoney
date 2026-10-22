import AppCore
import SwiftUI

/// The safety cushion: how many months its money lasts without income, what that is made of,
/// and the way to the goal. Shown on «Капитал» and, compact, in «Планирование».
struct CushionSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  /// Handed to the sheets: a sheet is laid out by a host of its own.
  @Environment(\.dependencies) private var dependencies

  let status: CushionStatus

  @State private var sheet: CushionSheet?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      block
      // «Мало данных» shows no content, and the accounts and categories are still set here.
      if status.state == .notEnoughData { buttons }
    }
    .sheet(item: $sheet) { sheet in
      Group {
        switch sheet {
        case .setup: CushionSetupSheet { self.sheet = nil }
        case .goal: CushionGoalForm { self.sheet = nil }
        }
      }
      .handingOver(dependencies)
    }
    .accessibilityIdentifier("cushion.section")
  }

  private var block: some View {
    ComputedBlock(
      title: CushionText.t("cushion.title", environment),
      state: CushionText.blockState(of: status),
      emptyReason: CushionText.notEnoughReason(status, environment), retry: nil
    ) { status in
      VStack(alignment: .leading, spacing: 12) {
        content(status)
        buttons
      }
    }
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      Button(CushionText.t("cushion.setup.open", environment)) { sheet = .setup }
        .accessibilityIdentifier("cushion.setup.open")
      Button(CushionText.t("cushion.goal.open", environment)) { sheet = .goal }
        .accessibilityIdentifier("cushion.goal.open")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  @ViewBuilder
  private func content(_ status: CushionStatus) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if status.state == .noAccounts {
        Label {
          Text(verbatim: CushionText.t("cushion.noAccounts", environment))
        } icon: {
          Image(systemName: CushionText.symbol)
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(verbatim: CushionText.lastsLine(status, environment))
          .appFont(.title3.weight(.semibold).monospacedDigit())
        Text(verbatim: CushionText.summaryLine(status, environment))
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        if let breakdown = CushionText.breakdown(of: status.obligatory) {
          breakdownLines(breakdown)
        }
        CushionBar(status: status, settings: settings)
        Text(verbatim: CushionText.goalHint(status.goal, settings: settings, environment))
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !status.unanchored.isEmpty {
          Label {
            Text(verbatim: CushionText.unanchoredLine(status.unanchored, dataset, environment))
          } icon: {
            Image(systemName: "hourglass")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func breakdownLines(_ breakdown: CushionBreakdown) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(breakdown.lines, id: \.key) { line in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: CushionText.t(line.key, environment))
          Spacer(minLength: 8)
          Text(verbatim: environment.money.rounded(line.amount))
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
      }
      if let floor = breakdown.floor {
        Text(
          verbatim: environment.format(
            "cushion.floor", table: CushionText.table, environment.money.rounded(floor))
        )
        .foregroundStyle(.secondary)
      }
    }
    .appFont(.caption)
    .frame(maxWidth: 360, alignment: .leading)
  }

  private var dataset: Dataset? { compute.snapshot?.dataset }
  private var settings: CapitalSettings { dataset?.capitalSettings ?? .standard }
}

/// The two sheets of the cushion.
enum CushionSheet: String, Identifiable {
  case setup
  case goal
  var id: String { rawValue }
}

/// The bar of the months the cushion lasts to the months of its goal (six without one), always
/// with its words beside it: «3.5 из 6 мес.».
struct CushionBar: View {
  @Dependency(\.environment) private var environment
  let status: CushionStatus
  let settings: CapitalSettings

  var body: some View {
    let weights = CushionText.barWeights(status)
    HStack(spacing: 8) {
      Capsule()
        .fill(.quaternary)
        .overlay {
          ProportionalRow(weights: weights) {
            Capsule().fill(.tint)
            Color.clear
          }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
      Text(verbatim: CushionText.barLabel(status, environment))
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
    }
  }
}

/// The cushion at the top of «Цели» in «Планирование», drawn like a goal: the tile, the name over
/// «3.5 из 6 мес.», the money at the right and the bar. A tap goes to «Капитал», where the
/// cushion is set up and explained. Not set up, or without the data to count the months, the
/// row says so in a line instead of the bar.
struct CushionPlanningRow: View {
  @Dependency(\.environment) private var environment
  let status: CushionStatus

  var body: some View {
    Button {
      NotificationCenter.default.post(
        name: .selectSection, object: MainWindow.Section.capital.shortcutIndex)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 12) {
          GoalTile(complete: false, symbol: CushionText.symbol)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: CushionText.t("cushion.planning.name", environment))
              .appFont(.body.weight(.semibold))
              .lineLimit(1)
            Text(verbatim: sub)
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer(minLength: 6)
          if status.state == .ready {
            Text(verbatim: environment.money.rounded(status.moneyRub))
              .appFont(.body.weight(.semibold).monospacedDigit())
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
        if status.state == .ready {
          GoalProgressBar(basisPoints: basisPoints)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint(Text(verbatim: CushionText.t("cushion.planning.open", environment)))
    .accessibilityIdentifier("planning.cushion.open")
  }

  private var sub: String {
    status.state == .ready
      ? CushionText.barLabel(status, environment)
      : CushionText.planningLine(status, environment)
  }

  /// The months the cushion lasts against the months of its goal, as the bar's share.
  private var basisPoints: Int {
    let weights = CushionText.barWeights(status)
    let whole = weights.reduce(0, +)
    return whole > 0 ? weights[0] * Shares.whole / whole : 0
  }
}

/// The obligatory spending of a month split by where it goes, the three lines adding up to the
/// monthly figure the cushion is divided by, and the floor when today's payments are above it.
struct CushionBreakdown: Equatable {
  struct Line: Equatable {
    let key: String
    let amount: AmountE4
  }

  var scheduled: AmountE4
  var debts: AmountE4
  var essential: AmountE4
  /// Today's committed payments, when they are above the median and so are the figure.
  var floor: AmountE4?

  var lines: [Line] {
    [
      Line(key: "cushion.part.scheduled", amount: scheduled),
      Line(key: "cushion.part.debts", amount: debts),
      Line(key: "cushion.part.essential", amount: essential),
    ]
  }
}

/// The words of the cushion, built from the core's figures alone.
@MainActor
enum CushionText {
  static let table = "Cushion"
  static let symbol = "lifepreserver"
  /// The months the bar runs to when the owner set no goal.
  static let defaultTargetMonths = 6

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  /// `.notEnoughData` only when the obligatory spending is not known yet; a cushion with no
  /// account is ready — it says how to mark one.
  static func blockState(of status: CushionStatus) -> BlockState<CushionStatus> {
    status.state == .notEnoughData ? .notEnoughData : .ready(status, at: .distantPast)
  }

  /// Why there is too little data: the full months the spending needs and how many there are.
  static func notEnoughReason(_ status: CushionStatus, _ environment: AppEnvironment) -> String? {
    guard status.state == .notEnoughData else { return nil }
    let full: Int
    if case .notEnoughData(let months) = status.obligatory.state { full = months } else { full = 0 }
    return t("cushion.notEnough", environment) + " "
      + environment.format("cushion.fullMonths", table: table, counts: full)
  }

  /// «3.5», «4»: the months as the core floors them, one digit after the point at most.
  static func monthsNumber(_ months: Decimal) -> String {
    NumberText.decimal(months, fractionDigits: 0...1)
  }

  static func isWhole(_ value: Decimal) -> Bool {
    DecimalMath.round(value, scale: 0) == value
  }

  /// «Без дохода вы проживёте 3.5 месяца»; a whole number takes its plural form.
  static func lastsLine(_ status: CushionStatus, _ environment: AppEnvironment) -> String {
    let months = status.months ?? 0
    if isWhole(months) {
      return environment.format("cushion.lasts", table: table, counts: whole(months))
    }
    return environment.format("cushion.lastsFraction", table: table, monthsNumber(months))
  }

  /// «Подушка 420,000 ₽ · обязательные траты ≈ 120,000 ₽ в месяц».
  static func summaryLine(_ status: CushionStatus, _ environment: AppEnvironment) -> String {
    let monthly = status.obligatory.monthlyRub.map { environment.money.rounded($0) } ?? "—"
    return environment.format(
      "cushion.summary", table: table, environment.money.rounded(status.moneyRub), monthly)
  }

  /// The median month split by the shares of the three sources over the months taken; the
  /// essential line takes what rounding leaves, so the lines add up to the median.
  static func breakdown(of obligatory: ObligatorySpending) -> CushionBreakdown? {
    guard let median = obligatory.medianRub, !obligatory.months.isEmpty else { return nil }
    let scheduled = AmountE4.sum(obligatory.months.map(\.scheduledRub))
    let debts = AmountE4.sum(obligatory.months.map(\.debtsRub))
    let essential = AmountE4.sum(obligatory.months.map(\.essentialRub))
    let total = scheduled + debts + essential
    let floor = obligatory.committedRub > median ? obligatory.committedRub : nil
    guard total.raw > 0 else {
      return CushionBreakdown(scheduled: .zero, debts: .zero, essential: median, floor: floor)
    }
    let scheduledPart = share(of: median, part: scheduled, total: total)
    let debtsPart = share(of: median, part: debts, total: total)
    return CushionBreakdown(
      scheduled: scheduledPart, debts: debtsPart, essential: median - scheduledPart - debtsPart,
      floor: floor)
  }

  /// `amount` × part ÷ total, to the whole ruble, half away from zero.
  private static func share(of amount: AmountE4, part: AmountE4, total: AmountE4) -> AmountE4 {
    let rubles = amount.decimal * Decimal(part.raw) / Decimal(total.raw)
    let rounded = DecimalMath.round(rubles, scale: 0)
    return (try? AmountE4(decimal: rounded)) ?? .zero
  }

  /// The months of the goal, six without one.
  static func targetMonths(_ status: CushionStatus) -> Int {
    status.goal?.targetMonths ?? defaultTargetMonths
  }

  /// The filled and the empty part of the bar, in tenths of a month; the filled part never
  /// passes the goal.
  static func barWeights(_ status: CushionStatus) -> [Int] {
    let target = targetMonths(status) * 10
    let months = status.months ?? 0
    let tenths = NSDecimalNumber(decimal: DecimalMath.round(months * 10, scale: 0)).intValue
    let filled = min(max(tenths, 0), target)
    return [filled, target - filled]
  }

  /// «3.5 из 6 мес.».
  static func barLabel(_ status: CushionStatus, _ environment: AppEnvironment) -> String {
    environment.format(
      "cushion.bar", table: table, monthsNumber(status.months ?? 0),
      String(targetMonths(status)))
  }

  /// «6 месяцев», «1 месяц».
  static func monthsCount(_ count: Int, _ environment: AppEnvironment) -> String {
    environment.format("cushion.monthsCount", table: table, counts: count)
  }

  /// «марта 2027» after «до»; «March 2027» in English.
  static func untilMonth(_ month: MonthKey, _ environment: AppEnvironment) -> String {
    t("cushion.month.until.\(month.month)", environment) + " " + String(month.year)
  }

  /// «июню 2027» after «к»; «June 2027» in English.
  static func byMonth(_ month: MonthKey, _ environment: AppEnvironment) -> String {
    t("cushion.month.by.\(month.month)", environment) + " " + String(month.year)
  }

  /// The way to the goal: what to put aside a month and until when, or that it is done; the
  /// month the cushion is complete at the present pace after it, or that it never is.
  static func goalHint(
    _ goal: CushionGoalStatus?, settings: CapitalSettings, _ environment: AppEnvironment
  ) -> String {
    guard let goal else { return t("cushion.goal.none", environment) }
    let months = monthsCount(goal.targetMonths, environment)
    let target = environment.money.rounded(goal.targetRub)
    if goal.reached {
      return environment.format("cushion.goal.reached", table: table, months, target)
    }
    var text: String
    if let perMonth = goal.perMonthRub, let month = settings.targetMonth {
      text = environment.format(
        "cushion.goal.byMonth", table: table, months, target, environment.money.rounded(perMonth),
        untilMonth(month, environment))
    } else {
      text = environment.format(
        "cushion.goal.perMonth", table: table, months, target,
        environment.money.rounded(goal.defaultPerMonthRub))
    }
    if let reachedBy = goal.reachedBy {
      text +=
        "; "
        + environment.format("cushion.goal.pace", table: table, byMonth(reachedBy, environment))
    } else if goal.pacePerMonthRub != nil {
      text += "; " + t("cushion.goal.paceNever", environment)
    }
    return text
  }

  /// «Не сверен: Сбер RUB, Наличные USD».
  static func unanchoredLine(
    _ keys: [BalanceKey], _ dataset: Dataset?, _ environment: AppEnvironment
  ) -> String {
    let names = keys.map { key in
      let name = dataset?.paymentMethods.first { $0.id == key.accountId }?.name ?? "—"
      return "\(name) \(key.currency.code)"
    }
    return environment.format("cushion.unanchored", table: table, names.joined(separator: ", "))
  }

  /// «3.5 мес.» — the figure of the tile and of the row in «Планирование»; `nil` while the
  /// months are not known.
  static func shortMonths(_ status: CushionStatus, _ environment: AppEnvironment) -> String? {
    guard status.state == .ready, let months = status.months else { return nil }
    return environment.format("cushion.tile.months", table: table, monthsNumber(months))
  }

  /// The row of «Планирование»: «Подушка безопасности: 3.5 мес. из 6», or what is missing.
  static func planningLine(_ status: CushionStatus, _ environment: AppEnvironment) -> String {
    switch status.state {
    case .noAccounts: return t("cushion.planning.notSet", environment)
    case .notEnoughData: return t("cushion.planning.notEnough", environment)
    case .ready:
      return environment.format("cushion.planning.row", table: table, barLabel(status, environment))
    }
  }

  /// The hint under the figure of the tile.
  static func tileHint(
    _ status: CushionStatus, settings: CapitalSettings, _ environment: AppEnvironment
  ) -> String {
    switch status.state {
    case .noAccounts: return t("cushion.noAccounts", environment)
    case .notEnoughData: return notEnoughReason(status, environment) ?? ""
    case .ready: return goalHint(status.goal, settings: settings, environment)
    }
  }

  private static func whole(_ value: Decimal) -> Int {
    NSDecimalNumber(decimal: value).intValue
  }
}
