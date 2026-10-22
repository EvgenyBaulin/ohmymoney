import AppCore
import SwiftUI

/// What a tile of «Доход и сбережения» shows: one figure, a caption, the detail lines of a
/// regular card and the symbol that stands for it.
struct IncomeTileFigure: Equatable {
  var value: String
  var caption: String?
  var details: [String] = []
  var symbol: String
}

/// The words of the two tiles, apart from the views so a test reads them in both languages.
@MainActor
enum IncomeTileFigures {
  /// «Норма сбережений»: the rate of the month so far, marked «пока» while it is not over, and
  /// the month before it. In the first days of a month with no income yet it shows the last
  /// complete month instead, named as such. `nil` when neither month had an income.
  static func savingsNorm(
    now: SavingsNormMonth, last: SavingsNormMonth?, _ environment: AppEnvironment
  ) -> IncomeTileFigure? {
    let shown: SavingsNormMonth
    let other: SavingsNormMonth?
    if now.rateBp != nil {
      (shown, other) = (now, last)
    } else if let last, last.rateBp != nil {
      (shown, other) = (last, nil)
    } else {
      return nil
    }
    guard let bp = shown.rateBp else { return nil }
    let month = environment.dates.monthTitle(shown.month)
    var details = [IncomeSavingsText.normBreakdown(shown, environment)]
    if let other, let otherBp = other.rateBp {
      details.append(
        IncomeSavingsText.f(
          "income.tile.norm.last", environment, environment.dates.monthTitle(other.month),
          IncomeSavingsText.rate(otherBp, environment, fractionDigits: 1)))
    }
    return IncomeTileFigure(
      value: IncomeSavingsText.rate(bp, environment, fractionDigits: 1),
      caption: shown.isPartial
        ? IncomeSavingsText.f("income.tile.norm.partial", environment, month) : month,
      details: details, symbol: IncomeSavingsText.arrow(bp))
  }

  /// «Финансовое здоровье»: «72 из 100», with the parts it was counted from. `nil` when too few
  /// parts could be counted to say a number.
  static func health(_ health: FinancialHealth, _ environment: AppEnvironment) -> IncomeTileFigure?
  {
    guard let headline = IncomeSavingsText.healthHeadline(health, environment) else { return nil }
    let counted = health.parts.filter(\.isCounted).count
    var details = health.parts.filter(\.isCounted).map {
      "\(IncomeSavingsText.partName($0.part, environment)): "
        + IncomeSavingsText.partPoints($0, environment)
    }
    if let left = IncomeSavingsText.notCounted(health, environment) { details.append(left) }
    return IncomeTileFigure(
      value: headline,
      caption: IncomeSavingsText.f(
        "income.tile.health.parts", environment, counted, health.parts.count),
      details: details, symbol: "heart.text.square")
  }
}

/// A tile of one figure: the figure big, a caption under it and, on a regular card, the lines it
/// is made of. The compact card is the same without the lines, so two stand in one cell.
private struct IncomeFigureBody: View {
  let figure: IncomeTileFigure
  let compact: Bool
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: figure.symbol)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: figure.value)
          .appFont(compact ? .title3.monospacedDigit() : .title2.monospacedDigit())
          .lineLimit(compact ? 2 : 1)
          .minimumScaleFactor(0.7)
          .accessibilityIdentifier(identifier)
      }
      if let caption = figure.caption {
        Text(verbatim: caption)
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 2 : 3)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !compact {
        ForEach(figure.details, id: \.self) { line in
          Text(verbatim: line)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// «Норма сбережений» on Overview, counted by the same rule as the section of Analytics.
struct SavingsNormTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  var compact = false
  @State private var months: (now: SavingsNormMonth, last: SavingsNormMonth)?

  var body: some View {
    let figure = months.flatMap {
      IncomeTileFigures.savingsNorm(now: $0.now, last: $0.last, environment)
    }
    ComputedBlock(
      title: OverviewTileText.name(of: .savingsRate, environment), state: state(figure),
      fillsHeight: true,
      emptyReason: environment.language("overview.savings.noIncome", table: "Overview"),
      retry: { compute.retry(ComputeStep.data) }
    ) { figure in
      IncomeFigureBody(figure: figure, compact: compact, identifier: "overview.savingsNorm.value")
    }
    .task(id: compute.generation) { await load() }
  }

  private func state(_ figure: IncomeTileFigure?) -> BlockState<IncomeTileFigure> {
    if let waiting = compute.states.data.waiting { return waiting.never() }
    guard months != nil else { return .calculating }
    return figure.map { .ready($0, at: .distantPast) } ?? .notEnoughData
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    let income = compute.analysis.incomeSavings
    let month = snapshot.today.monthKey
    guard let now = try? await income.savingsNorm(snapshot, month: month),
      let last = try? await income.savingsNorm(snapshot, month: month.previous),
      !Task.isCancelled
    else { return }
    months = (now, last)
  }
}

/// «Финансовое здоровье» on Overview: the number out of a hundred and the parts it comes from.
struct FinancialHealthTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  var compact = false
  @State private var health: FinancialHealth?

  var body: some View {
    let figure = health.flatMap { IncomeTileFigures.health($0, environment) }
    ComputedBlock(
      title: OverviewTileText.name(of: .financialHealth, environment), state: state(figure),
      fillsHeight: true,
      emptyReason: IncomeSavingsText.t("income.health.notEnough", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { figure in
      IncomeFigureBody(figure: figure, compact: compact, identifier: "overview.health.value")
    }
    .task(id: compute.generation) { await load() }
  }

  private func state(_ figure: IncomeTileFigure?) -> BlockState<IncomeTileFigure> {
    if let waiting = compute.states.data.waiting { return waiting.never() }
    guard health != nil else { return .calculating }
    return figure.map { .ready($0, at: .distantPast) } ?? .notEnoughData
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    guard let counted = try? await compute.analysis.incomeSavings.health(snapshot),
      !Task.isCancelled
    else { return }
    health = counted
  }
}
