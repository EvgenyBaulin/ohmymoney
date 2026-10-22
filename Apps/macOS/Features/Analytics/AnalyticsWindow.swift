import AppCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// The Analytics window: the sections in the sidebar, the period in the toolbar, the cards of
/// the section in the middle.
///
/// The model of a section is built from the ledger of `ComputeStore` off the main thread,
/// through `compute(_:)` in `.task(id:)`, never in `body`, and kept by the version of the data
/// and the period (`AnalyticsStore`). The section and the period on screen are a preference
/// of the window (`UserDefaults`), never the database: they are there again when the window
/// is opened again. A data set keeps its own (`storageKey`).
struct AnalyticsWindow: View {
  let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  private var environment: AppEnvironment { deps.environment }
  private var compute: ComputeStore { deps.compute }

  @AppStorage(AnalyticsWindow.sectionKey) private var sectionName =
    AnalyticsSection.overview.rawValue
  @AppStorage(AnalyticsWindow.periodKey) private var periodText = ""
  @State private var analytics = AnalyticsStore()
  @State private var choosingPeriod = false
  /// `--measure --measure-runs n`: the window changes the period by itself (`make bench-app`).
  @State private var autopilot = MeasurementAutopilot(
    changes: AnalyticsMeasurement.isRequested ? LaunchOptions.current.measureRuns : nil)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      AnalyticsSectionView(
        section: section, title: AnalyticsText.title(of: period, environment), state: state,
        retry: retry
      )
      .id(section)
    }
    .themedWindowBackground()
    .navigationSubtitle(subtitle)
    .sheetFrame(minWidth: Self.minimumWidth, minHeight: 560)
    .environment(analytics)
    .journalsSection(section.rawValue, in: .analytics)
    .onAppear { beginMeasurement() }
    .onChange(of: measured) { _, _ in beginMeasurement() }
    .onChange(of: analytics.measurement.completed) { _, _ in driveMeasurement() }
    .task(id: loadKey) { await load() }
  }

  // MARK: What is shown

  private var section: AnalyticsSection {
    AnalyticsSection(rawValue: sectionName) ?? .overview
  }

  /// The day the data was built for: the day of Overview, not the clock of this window.
  private var today: DateOnly { compute.snapshot?.today ?? environment.today }

  /// The stored period, its anchor never after the month of today: a year stepped forward
  /// from December, or a text stored before, would otherwise open a month that has not come.
  private var period: AnalyticsPeriod {
    (AnalyticsPeriod(storage: periodText) ?? .current(today: today)).clamped(to: today)
  }

  private func setPeriod(_ period: AnalyticsPeriod) {
    periodText = period.clamped(to: today).storage
  }

  /// What the section is computed for. The forecast is the current month whatever the
  /// toolbar says, and takes the planned payments of the data and the remainder of step 5.
  private var request: AnalyticsRequest {
    let today = self.today
    var inputs: ForecastInputs?
    if section == .forecast, let remainder = compute.states.forecast.value,
      let snapshot = compute.snapshot
    {
      // The same planned payments as the Overview card: scheduled ones included; and the plan
      // of every account's balance through the end of the month.
      inputs = ForecastInputs(
        planned: snapshot.planning.planned.total, remainder: remainder,
        accounts: snapshot.accountPlan)
    }
    return AnalyticsRequest(
      section: section,
      period: section.followsThePeriod ? period.period : .month(today.monthKey),
      today: today, forecast: inputs,
      anomalies: section == .anomalies ? compute.states.anomalies.value : nil)
  }

  private var state: BlockState<AnalyticsModel> {
    AnalyticsStore.state(
      for: request, data: compute.states.data,
      forecast: section == .forecast ? compute.states.forecast : nil,
      anomalies: section == .anomalies ? compute.states.anomalies : nil,
      model: analytics.model, at: analytics.modelAt)
  }

  /// «Повторить» reruns the step that failed: the data, or the step this section is made of.
  private func retry() {
    if compute.states.data.phase == .failed {
      compute.retry(ComputeStep.data)
    } else if section == .anomalies {
      compute.retry(ComputeStep.anomalies)
    } else {
      compute.retry(ComputeStep.forecast)
    }
  }

  // MARK: Building the model

  private struct LoadKey: Hashable {
    var key: AnalyticsStore.Key
    var dataReady: Bool
  }

  private var loadKey: LoadKey {
    LoadKey(
      key: AnalyticsStore.Key(request: request, generation: compute.generation),
      dataReady: compute.states.data.phase == .ready)
  }

  private func load() async {
    let key = loadKey
    guard key.dataReady, section.plannedFor == nil, let ledger = compute.snapshot?.ledger
    else { return }
    if section == .forecast, key.key.request.forecast == nil { return }
    if section == .anomalies, key.key.request.anomalies == nil { return }
    await analytics.load(key.key, ledger: ledger, compute: compute)
  }

  /// What `--measure` times: the section and the period it is computed for. Another text
  /// of the same period — a year chosen again from another month — is not a change: nothing
  /// new would be computed, and the clock would never stop.
  private var measured: AnalyticsRequest.Subject { request.subject }

  /// The clock of `--measure` starts with every change of the section or the period.
  private func beginMeasurement() {
    guard section.plannedFor == nil else { return }
    analytics.measurement.begin(
      "\(section.rawValue) \(period.kind.rawValue)", for: measured)
  }

  /// `--measure-runs`: the next change half a second after the last drawing, so each is
  /// timed on a window at rest; after the last one the report, and the app quits. The report
  /// says how many live operations the charts were drawn from: a set left empty would draw
  /// fast and must not pass for a measurement.
  private func driveMeasurement() {
    guard let autopilot, let last = analytics.measurement.last else { return }
    switch autopilot.measured(last) {
    case .step(let direction):
      Task {
        try? await Task.sleep(for: .milliseconds(500))
        setPeriod(period.stepped(by: direction))
      }
    case .finish:
      let report = autopilot.report(operations: compute.snapshot?.ledger.entries.count ?? 0)
      try? report.write(to: AppPaths.measurementsURL, atomically: true, encoding: .utf8)
      #if os(macOS)
        NSApplication.shared.terminate(nil)
      #endif
    }
  }

  /// With `--measure`, the time the last change took to draw; otherwise nothing.
  private var subtitle: String {
    let measurement = analytics.measurement
    guard measurement.isEnabled else { return "" }
    if measurement.isWaiting { return t("analytics.measure.waiting") }
    guard let last = measurement.last else { return "" }
    return AnalyticsText.format(
      "analytics.measure.result", environment, environment.money.count(last.milliseconds))
  }

  // MARK: The period in the toolbar

  /// The title of the section with the period under it on the left; the period controls on the
  /// right; the sections below as a wrapping row of chips.
  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top) {
          titleBlock
          Spacer(minLength: 12)
          periodControls
        }
        VStack(alignment: .leading, spacing: 10) {
          titleBlock
          periodControls
        }
      }
      sectionChips
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: t(section.titleKey)).appFont(.title2.weight(.semibold))
      Text(verbatim: AnalyticsText.title(of: period, environment))
        .appFont(.caption).foregroundStyle(.secondary)
    }
  }

  private var sectionChips: some View {
    FlowRow(spacing: 6, lineSpacing: 6) {
      ForEach(AnalyticsSection.allCases) { item in
        SectionChip(
          title: t(item.titleKey), symbol: item.symbol, selected: item == section
        ) { sectionName = item.rawValue }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("analytics.sections")
  }

  private var periodControls: some View {
    HStack(spacing: 8) {
      let enabled = section.followsThePeriod
      Button {
        setPeriod(period.stepped(by: -1))
      } label: {
        Label {
          Text(verbatim: t("analytics.period.previous"))
        } icon: {
          Image(systemName: "chevron.left")
        }
      }
      .disabled(!enabled)

      Button {
        choosingPeriod = true
      } label: {
        Text(verbatim: AnalyticsText.title(of: period, environment))
          .monospacedDigit()
          .frame(minWidth: 130)
      }
      .accessibilityIdentifier("period.choose")
      .help(t("analytics.period.choose"))
      .disabled(!enabled)
      .popover(isPresented: $choosingPeriod) {
        PeriodChooser(period: period, today: today) { chosen in
          setPeriod(chosen)
          choosingPeriod = false
        }
        .appDependencies(deps)
      }
      .task { if await LaunchPresentation.due(.periodChooser) { choosingPeriod = true } }

      Button {
        setPeriod(period.stepped(by: 1))
      } label: {
        Label {
          Text(verbatim: t("analytics.period.next"))
        } icon: {
          Image(systemName: "chevron.right")
        }
      }
      .disabled(!enabled || !period.canStepForward(today: today))

      Picker(selection: kindSelection) {
        ForEach(AnalyticsPeriod.Kind.allCases, id: \.self) { kind in
          Text(verbatim: t(kind.titleKey)).tag(kind)
        }
      } label: {
        Text(verbatim: t("analytics.period.kind"))
      }
      .pickerStyle(.segmented)
      .disabled(!enabled)

      Button(t("analytics.period.current")) {
        setPeriod(.current(period.kind, today: today))
      }
      .disabled(!enabled || period.isCurrent(today: today))
    }
  }

  private var kindSelection: Binding<AnalyticsPeriod.Kind> {
    Binding(
      get: { period.kind },
      set: { setPeriod(period.with(kind: $0)) })
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }

  // MARK: Widths

  static let sidebarMinWidth: CGFloat = 190
  static let sidebarIdealWidth: CGFloat = 220
  static let sidebarMaxWidth: CGFloat = 300

  /// The narrowest the content goes, and so the window's minimum (`SecondaryWindow(minWidth:)`):
  /// a window allowed narrower cut the content off at both edges. The sidebar hidden at this
  /// width and shown again takes its room from the content, not from the window.
  static let minimumWidth: CGFloat = 820
}

/// The popover under the title of the period: the months of a year for a month or twelve
/// months, the recent years for a year. Nothing after today is offered. The Reports window
/// chooses its month or year with it too.
struct PeriodChooser: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  let period: AnalyticsPeriod
  let today: DateOnly
  let choose: (AnalyticsPeriod) -> Void
  @State private var year: Int

  init(period: AnalyticsPeriod, today: DateOnly, choose: @escaping (AnalyticsPeriod) -> Void) {
    self.period = period
    self.today = today
    self.choose = choose
    _year = State(initialValue: period.month.year)
  }

  var body: some View {
    VStack(spacing: 10) {
      if period.kind == .year {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 3), spacing: 6) {
          ForEach((0..<9).map { today.year - 8 + $0 }, id: \.self) { candidate in
            Button(String(candidate)) {
              choose(.year(candidate, today: today))
            }
            .buttonStyle(.bordered)
            .tint(candidate == period.month.year ? accent : nil)
          }
        }
      } else {
        HStack {
          Button {
            year -= 1
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text(verbatim: t("analytics.period.previous")))
          Spacer()
          Text(verbatim: String(year))
            .appFont(.headline.monospacedDigit())
          Spacer()
          Button {
            year += 1
          } label: {
            Image(systemName: "chevron.right")
          }
          .buttonStyle(.borderless)
          .disabled(year >= today.year)
          .accessibilityLabel(Text(verbatim: t("analytics.period.next")))
        }
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 3), spacing: 6) {
          ForEach(1...12, id: \.self) { number in
            let month = MonthKey(year: year, month: number)
            Button(environment.dates.shortMonth(month)) {
              choose(AnalyticsPeriod(kind: period.kind, month: month))
            }
            .buttonStyle(.bordered)
            .tint(month == period.month ? accent : nil)
            .disabled(month > today.monthKey)
          }
        }
      }
    }
    .padding(12)
    .frame(width: 240)
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

extension AnalyticsWindow {
  /// The names the window keeps its section and its period under in `UserDefaults`.
  nonisolated static let sectionStorageName = "analytics.section"
  nonisolated static let periodStorageName = "analytics.period"

  /// Where the window of this launch keeps them.
  nonisolated static let sectionKey = storageKey(sectionStorageName)
  nonisolated static let periodKey = storageKey(periodStorageName)

  /// A name as it is, or with the data set's after it (`analytics.period.bench`) when the app
  /// runs on a set. The Debug build and the Release build of `make bench-app` share one
  /// domain of defaults — the Debug id, one container; the owner's copy has its own. Without
  /// a key of its own, the choices of a check (`--analytics-section`) and the eight steps of
  /// the measurement would be left in the window of the everyday Debug database.
  nonisolated static func storageKey(
    _ name: String, dataSet: AppPaths.DataSet? = AppPaths.dataSet
  ) -> String {
    dataSet.map { "\(name).\($0.rawValue)" } ?? name
  }
}
