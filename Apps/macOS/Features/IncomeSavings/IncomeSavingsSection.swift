import AppCore
import SwiftUI

/// The section «Доход и сбережения» of Analytics: the savings norm month by month, the baskets
/// against the owner's proportions, the obligatory share, the cushion in days, the stability of
/// income, the line «spending follows income», the salary effect and the financial health with
/// its history. The page is counted once (`IncomeSavingsPage`) off the main thread and the
/// cards turn ready together; a write keeps the old figures on screen until the new ones are
/// there.
struct IncomeSavingsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let isWide: Bool
  @State private var page: IncomeSavingsPage?
  @State private var failed = false

  var body: some View {
    ComputedBlock(
      title: nil, state: state, style: .plain, retry: { compute.retry(ComputeStep.data) }
    ) { page in
      IncomeSavingsCards(page: page, isWide: isWide)
    }
    .task(id: compute.generation) { await load() }
    .accessibilityIdentifier("income.section")
  }

  private var state: BlockState<IncomeSavingsPage> {
    if let waiting = compute.states.data.waiting { return waiting.never() }
    if let page { return .ready(page, at: .distantPast) }
    return failed ? .failed(messageKey: "compute.failed.step") : .calculating
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    do {
      let counted = try await IncomeSavingsPage.load(snapshot, analysis: compute.analysis)
      guard !Task.isCancelled else { return }
      page = counted
      failed = false
    } catch {
      guard !Task.isCancelled else { return }
      failed = page == nil
    }
  }
}

// MARK: - The cards

/// The cards of a counted page, so a test lays them out with figures of its own.
struct IncomeSavingsCards: View {
  @Dependency(\.environment) private var environment
  let page: IncomeSavingsPage
  let isWide: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      NormCard(page: page)
      AnalyticsPair(isWide: isWide) {
        BasketsCard(page: page)
      } second: {
        VStack(alignment: .leading, spacing: 16) {
          ObligatoryCard(share: page.obligatory)
          CushionDaysCard(days: page.cushion)
        }
      }
      AnalyticsPair(isWide: isWide) {
        StabilityCard(stability: page.stability)
      } second: {
        TrendCard(trend: page.trend, settings: page.settings)
      }
      SalaryCard(salary: page.salary)
      HealthCard(page: page)
    }
  }
}

/// The frame every card of the section stands on: a title in `.headline`, what it is measured
/// over in `.caption`, then the body. No glass — content is never glass.
private struct IncomeCard<Content: View>: View {
  @Dependency(\.environment) private var environment
  let title: String
  var subtitle: String?
  var identifier: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .appFont(.headline)
          .accessibilityAddTraits(.isHeader)
        if let subtitle {
          Text(verbatim: subtitle)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityIdentifier(identifier)
  }
}

/// «Мало данных» and its reason where a card has nothing to say yet.
private struct NotEnoughData: View {
  @Dependency(\.environment) private var environment
  let reason: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(verbatim: environment.language("common.noData"))
      } icon: {
        Image(systemName: "hourglass")
      }
      if !reason.isEmpty {
        Text(verbatim: reason)
          .appFont(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .foregroundStyle(.secondary)
  }
}

/// A figure big, with the words under it.
private struct Headline: View {
  let figure: String
  var symbol: String?
  var identifier: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let symbol {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Text(verbatim: figure)
        .appFont(.title2.monospacedDigit())
        .accessibilityIdentifier(identifier)
    }
  }
}

@MainActor private func secondaryLine(_ text: String) -> some View {
  Text(verbatim: text)
    .appFont(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
}

// MARK: Savings norm

private struct NormCard: View {
  @Dependency(\.environment) private var environment
  let page: IncomeSavingsPage

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.norm.title", environment),
      subtitle: subtitle, identifier: "income.norm"
    ) {
      if let month = page.headline, month.rateBp != nil {
        VStack(alignment: .leading, spacing: 6) {
          Headline(
            figure: IncomeSavingsText.normHeadline(month, environment),
            symbol: IncomeSavingsText.arrow(month.rateBp ?? 0), identifier: "income.norm.headline")
          secondaryLine(IncomeSavingsText.normBreakdown(month, environment))
          if page.series.contains(where: \.isPartial) {
            secondaryLine(IncomeSavingsText.t("income.norm.partialNote", environment))
          }
          ColumnChart(
            columns: IncomeSavingsText.normColumns(page.series, environment),
            valueAxisText: { IncomeSavingsText.rate(Int($0), environment) }
          )
          .accessibilityIdentifier("income.norm.chart")
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.t("income.norm.none", environment))
      }
    }
  }

  private var subtitle: String {
    IncomeSavingsText.t(
      page.settings.earningsOnly ? "income.norm.basisEarnings" : "income.norm.basisAll",
      environment)
  }
}

// MARK: Baskets

private struct BasketsCard: View {
  @Dependency(\.environment) private var environment
  let page: IncomeSavingsPage

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.baskets.title", environment),
      subtitle: IncomeSavingsText.f(
        "income.baskets.basis", environment, environment.dates.monthTitle(page.fit.month),
        IncomeSavingsText.rule(page.fit.proportions, environment)),
      identifier: "income.baskets"
    ) {
      if page.fit.incomeRub.raw > 0 {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(page.fit.lines, id: \.basket) { line in
            BasketRow(line: line)
          }
          if page.fit.isPartial {
            secondaryLine(IncomeSavingsText.t("income.baskets.partial", environment))
          }
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.t("income.baskets.noIncome", environment))
      }
    }
  }
}

private struct BasketRow: View {
  @Dependency(\.environment) private var environment
  let line: BudgetBasketLine

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Label {
          Text(verbatim: IncomeSavingsText.basketName(line.basket, environment))
        } icon: {
          Image(systemName: IncomeSavingsText.basketSymbol(line.basket))
        }
        .appFont(.callout)
        Spacer(minLength: 8)
        Label {
          Text(verbatim: IncomeSavingsText.directionWords(line.direction, environment))
        } icon: {
          Image(systemName: IncomeSavingsText.directionSymbol(line.direction))
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      TargetBar(shareBp: line.shareBp, targetBp: line.targetBp)
      secondaryLine(IncomeSavingsText.basketLine(line, environment))
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("income.basket.\(line.basket.rawValue)")
  }
}

/// A share of the income as a bar, with a tick where the owner's target stands. The words
/// beside it say the same, so the bar is hidden from VoiceOver.
struct TargetBar: View {
  let shareBp: Int?
  let targetBp: Int

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let share = CGFloat(min(max(shareBp ?? 0, 0), Shares.whole)) / CGFloat(Shares.whole)
      let target = CGFloat(min(max(targetBp, 0), Shares.whole)) / CGFloat(Shares.whole)
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(.tint).frame(width: max(share * width, share > 0 ? 3 : 0))
        Rectangle()
          .fill(.primary)
          .frame(width: 2, height: 9)
          .offset(x: min(max(target * width - 1, 0), width - 2))
      }
    }
    .frame(height: 9)
    .accessibilityHidden(true)
  }
}

// MARK: Obligatory share and cushion

private struct ObligatoryCard: View {
  @Dependency(\.environment) private var environment
  let share: ObligatoryShare

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.obligatory.title", environment),
      subtitle: IncomeSavingsText.t("income.obligatory.basis", environment),
      identifier: "income.obligatory"
    ) {
      if let headline = IncomeSavingsText.obligatoryHeadline(share, environment) {
        VStack(alignment: .leading, spacing: 6) {
          Headline(figure: headline, symbol: "lock", identifier: "income.obligatory.headline")
          ShareBar(basisPoints: share.shareBp)
          if let detail = IncomeSavingsText.obligatoryDetail(share, environment) {
            secondaryLine(detail)
          }
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.obligatoryReason(share, environment))
      }
    }
  }
}

private struct CushionDaysCard: View {
  @Dependency(\.environment) private var environment
  let days: CushionDays

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.cushion.title", environment),
      subtitle: IncomeSavingsText.t("income.cushion.basis", environment),
      identifier: "income.cushion"
    ) {
      if let headline = IncomeSavingsText.cushionHeadline(days, environment) {
        VStack(alignment: .leading, spacing: 6) {
          Headline(figure: headline, symbol: "lifepreserver", identifier: "income.cushion.days")
          if let detail = IncomeSavingsText.cushionDetail(days, environment) {
            secondaryLine(detail)
          }
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.cushionReason(days, environment))
      }
    }
  }
}

// MARK: Stability

private struct StabilityCard: View {
  @Dependency(\.environment) private var environment
  let stability: IncomeStability

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.stability.title", environment),
      subtitle: IncomeSavingsText.t("income.stability.basis", environment),
      identifier: "income.stability"
    ) {
      if let headline = IncomeSavingsText.stabilityHeadline(stability, environment) {
        VStack(alignment: .leading, spacing: 6) {
          Headline(
            figure: headline, symbol: stability.isUneven ? "waveform.path" : "equal",
            identifier: "income.stability.headline")
          ForEach(IncomeSavingsText.stabilityLines(stability, environment), id: \.self) {
            secondaryLine($0)
          }
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.stabilityReason(stability, environment))
      }
    }
  }
}

// MARK: Spending follows income

private struct TrendCard: View {
  @Dependency(\.environment) private var environment
  let trend: SpendingFollowsIncome
  let settings: IncomeSavingsSettings

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.trend.title", environment),
      subtitle: IncomeSavingsText.trendMonths(trend, environment),
      identifier: "income.trend"
    ) {
      if let headline = IncomeSavingsText.trendHeadline(trend, environment) {
        VStack(alignment: .leading, spacing: 8) {
          Headline(
            figure: headline,
            symbol: trend.spendingOutpacesIncome ? "arrow.up.right" : "equal",
            identifier: "income.trend.headline")
          Text(verbatim: IncomeSavingsText.trendVerdict(trend, environment))
            .appFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
          if trend.comparison == .sixToSix {
            secondaryLine(IncomeSavingsText.t("income.trend.seasonNote", environment))
          }
          nudgeSwitch
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          NotEnoughData(reason: IncomeSavingsText.t("income.trend.notEnough", environment))
          nudgeSwitch
        }
      }
    }
  }

  /// «Больше не показывать» in «Стоит посмотреть», and the way back.
  private var nudgeSwitch: some View {
    Button(
      IncomeSavingsText.t(
        settings.trendNudgeEnabled ? "income.trend.stop" : "income.trend.resume", environment)
    ) {
      var updated = settings
      updated.trendNudgeEnabled.toggle()
      environment.saveIncomeSavings(updated)
    }
    .buttonStyle(.link)
    .accessibilityIdentifier("income.trend.nudge")
  }
}

// MARK: Salary effect

private struct SalaryCard: View {
  @Dependency(\.environment) private var environment
  let salary: SalaryEffect

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.salary.title", environment),
      subtitle: IncomeSavingsText.t("income.salary.basis", environment),
      identifier: "income.salary"
    ) {
      if salary.state == .ready, let overall = salary.overall {
        VStack(alignment: .leading, spacing: 8) {
          Headline(
            figure: IncomeSavingsText.salaryHeadline(overall, environment),
            symbol: "calendar.badge.clock", identifier: "income.salary.headline")
          secondaryLine(IncomeSavingsText.salaryDetail(overall, environment))
          if salary.perIncome.count > 1 {
            ForEach(salary.perIncome) { line in
              HStack(alignment: .firstTextBaseline) {
                Text(verbatim: line.name ?? "—").appFont(.callout)
                Spacer(minLength: 8)
                Text(verbatim: IncomeSavingsText.salaryHeadline(line, environment))
                  .appFont(.callout.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
            }
          }
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.t("income.salary.notEnough", environment))
      }
    }
  }
}

// MARK: Financial health

private struct HealthCard: View {
  @Dependency(\.environment) private var environment
  let page: IncomeSavingsPage

  var body: some View {
    IncomeCard(
      title: IncomeSavingsText.t("income.health.title", environment),
      subtitle: IncomeSavingsText.t("income.health.basis", environment),
      identifier: "income.health"
    ) {
      if let headline = IncomeSavingsText.healthHeadline(page.health, environment) {
        VStack(alignment: .leading, spacing: 10) {
          Headline(figure: headline, symbol: "heart.text.square", identifier: "income.health.total")
          VStack(alignment: .leading, spacing: 8) {
            ForEach(page.health.parts) { score in
              HealthPartRow(score: score)
            }
          }
          if let left = IncomeSavingsText.notCounted(page.health, environment) {
            secondaryLine(left)
          }
          let columns = IncomeSavingsText.healthColumns(page.healthSeries, environment)
          if columns.count > 1 {
            ColumnChart(columns: columns, valueAxisText: { String($0) })
              .accessibilityIdentifier("income.health.chart")
          }
          secondaryLine(IncomeSavingsText.t("income.health.note", environment))
        }
      } else {
        NotEnoughData(reason: IncomeSavingsText.t("income.health.notEnough", environment))
      }
    }
  }
}

private struct HealthPartRow: View {
  @Dependency(\.environment) private var environment
  let score: HealthPartScore

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Label {
          Text(verbatim: IncomeSavingsText.partName(score.part, environment))
        } icon: {
          Image(systemName: IncomeSavingsText.partSymbol(score.part))
        }
        .appFont(.callout)
        Spacer(minLength: 8)
        Text(verbatim: IncomeSavingsText.partPoints(score, environment))
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if score.isCounted { ShareBar(basisPoints: score.scoreBp) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("income.health.part.\(score.part.rawValue)")
  }
}
