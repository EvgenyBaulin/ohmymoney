import AppCore
import SwiftUI

/// How far back the chart of net worth goes. The choice is kept on this Mac
/// (`capital.chartRange`).
enum CapitalChartRange: String, CaseIterable, Hashable, Sendable {
  /// The ends of the last twelve full months — what the snapshot holds already.
  case year
  /// Since the month of the first count of any balance, worked out when asked for.
  case all

  static let storageKey = "capital.chartRange"

  /// The range kept in `defaults`; anything else is twelve months.
  static func stored(in defaults: UserDefaults = .standard) -> CapitalChartRange {
    defaults.string(forKey: storageKey).flatMap(CapitalChartRange.init(rawValue:)) ?? .year
  }

  func store(in defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.storageKey)
  }
}

/// «Капитал по месяцам»: the chart of net worth with «12 месяцев» / «Всё». Twelve months come
/// with the snapshot; «Всё» is the same rule over the whole history, worked out off the main
/// thread from the same snapshot (`NetWorth.build(months: nil)`), so the screen never waits on it.
struct CapitalChartSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let model: CapitalViewModel
  @State private var range = CapitalChartRange.year
  @State private var restored = false
  /// The points of «Всё», once worked out for the snapshot of `allVersion`.
  @State private var allPoints: [CapitalPoint]?
  @State private var allVersion: DataVersion?

  var body: some View {
    // The design's card: the title over the range, the caption of what is shown at the right,
    // the switch under them and the chart in the rest; the block inside is plain, so the title
    // stays in sight whatever the block is doing.
    VStack(alignment: .leading, spacing: 10) {
      ScreenCardHeader(
        title: CapitalText.t("capital.chart.title", environment),
        caption: CapitalText.t(
          range == .year ? "capital.chart.year" : "capital.chart.all", environment))
      rangePicker
      chartBlock
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: CapitalText.t("capital.chart.title", environment)))
    .onAppear {
      guard !restored else { return }
      restored = true
      range = CapitalChartRange.stored()
    }
    .onChange(of: range) { _, new in new.store() }
    .task(id: AllKey(range: range, version: compute.snapshot?.version)) {
      await workOutAll()
    }
  }

  private var rangePicker: some View {
    Picker(selection: $range) {
      Text(verbatim: CapitalText.t("capital.chart.year", environment))
        .tag(CapitalChartRange.year)
      Text(verbatim: CapitalText.t("capital.chart.all", environment))
        .tag(CapitalChartRange.all)
    } label: {
      Text(verbatim: CapitalText.t("capital.chart.range", environment))
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .controlSize(.small)
    .fixedSize()
    .accessibilityIdentifier("capital.chart.range")
  }

  private var chartBlock: some View {
    ComputedBlock(
      title: nil, state: state, style: .plain,
      emptyReason: CapitalText.t("capital.chart.notEnough", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { chart in
      NetWorthChart(
        model: chart,
        names: (
          CapitalText.t("capital.chart.net", environment),
          CapitalText.t("capital.chart.have", environment),
          CapitalText.t("capital.chart.owe", environment)
        ),
        label: { point in
          point.isNow
            ? CapitalText.t("capital.chart.now", environment)
            : environment.dates.shortMonth(
              point.day.monthKey, withYear: chart.points.first?.day.year != point.day.year)
        },
        spoken: { point in
          point.isNow
            ? CapitalText.t("capital.chart.now", environment)
            : environment.dates.monthTitle(point.day.monthKey)
        })
    }
  }

  /// What the block shows: the points of the range, «Считается» while «Всё» is worked out, «Мало
  /// данных» without the end of one full month.
  private var state: BlockState<NetWorthChartModel> {
    compute.states.data.flatMap { snapshot, at in
      let points: [CapitalPoint]
      switch range {
      case .year: points = model.points
      case .all:
        guard let allPoints, allVersion == snapshot.version else { return .calculating }
        points = allPoints
      }
      let chart = NetWorthChartModel(points)
      return chart.hasLine ? .ready(chart, at: at) : .notEnoughData
    }
  }

  private struct AllKey: Hashable {
    var range: CapitalChartRange
    var version: DataVersion?
  }

  /// «Всё» of the snapshot on screen, off the main thread; nothing for «12 месяцев».
  private func workOutAll() async {
    guard range == .all, let snapshot = compute.snapshot, allVersion != snapshot.version else {
      return
    }
    let points = await Self.allPoints(of: snapshot)
    guard !Task.isCancelled else { return }
    allPoints = points
    allVersion = snapshot.version
  }

  /// Net worth at the end of every month since the first count, by the rules of the snapshot.
  nonisolated static func allPoints(of snapshot: DataSnapshot) async -> [CapitalPoint] {
    await Task.detached(priority: .userInitiated) {
      let planning = snapshot.planning
      return NetWorth.build(
        ledger: snapshot.ledger, balances: planning.accounts.balances,
        debtsJournal: snapshot.dataset.planning.debtEntries, assets: snapshot.dataset.assets,
        valuations: snapshot.dataset.assetValuations, today: planning.today, now: planning.now,
        rubPerUnit: planning.rubPerUnit, dayRates: planning.dayRates, months: nil
      ).points
    }.value
  }
}
