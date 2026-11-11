import AppCore
import SwiftUI

/// The Reports screen as the design draws it: the title with the period and «Выгрузить CSV…» at
/// the right, the tabs under it, the table of the tab, and a line about the CSV under the table.
/// A section of the main window on the Mac («Отчёты» in its sidebar), a page of «Ещё» on a phone
/// and a tablet, where the phone keeps the title in its navigation bar and puts the period and
/// the export on one line under the tabs.
///
/// The tables are built by the core's `ReportBuilder` from the ledger of `ComputeStore` off the
/// main thread, through `compute(_:)` in `.task(id:)`, never in `body`. The table, the period
/// and the grouping on screen are a preference of the window (`UserDefaults`), never the
/// database: they are there again when the window is opened again; the tab is read from them.
struct ReportsWindow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var chosenIdiom
  let deps: AppDependencies
  /// Shown inside the main window (or a window of a section): its minimum width is the
  /// window's own.
  let embedded: Bool

  init(deps: AppDependencies, embedded: Bool = false) {
    self.deps = deps
    self.embedded = embedded
    _summaries = State(
      initialValue: PeriodsBoardStore(model: SummariesModel(environment: deps.environment)))
  }

  private var environment: AppEnvironment { deps.environment }
  private var compute: ComputeStore { deps.compute }

  @AppStorage(ReportsSelection.tableKey) private var tableName =
    ReportTable.Kind.expensesByCategoryAndSubcategory.rawValue
  @AppStorage(ReportsSelection.periodKey) private var periodText = ""
  @AppStorage(ReportsSelection.groupingKey) private var groupingName = ReportGrouping.category
    .rawValue
  /// «По периодам» is on screen over the stored table.
  @AppStorage(ReportsSelection.byPeriodsKey) private var byPeriods = false
  @State private var reports = ReportsStore()
  @State private var choosingPeriod = false
  /// The CSV handed to the file exporter on a phone, locked into one file when the owner keeps
  /// «Зашифровать»; the Mac asks in its save panel.
  @State private var exportRequest: PersonalDataExport?
  @State private var exportFailed = false
  /// «По периодам»: the summaries of a week, a month and a year, in cards under the tabs.
  @State private var summaries: PeriodsBoardStore
  /// «Сохранить отчёт…» from the menu of the table.
  @State private var saving = false

  private var idiom: LayoutIdiom { LayoutIdiom.resolved(chosenIdiom) }
  private var metrics: ReportsMetrics { .of(idiom) }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: metrics.stackGap) {
        if metrics.showsTitle { titleRow }
        ReportsTabsRow(
          tabs: ReportsTab.tabs(idiom), chosen: tab, metrics: metrics, idiom: idiom,
          choose: choose)
        if !metrics.showsTitle { phoneLine }
        detail
      }
      .padding(.horizontal, metrics.side)
      .padding(.top, metrics.top)
      .padding(.bottom, StyleMetrics.pageBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    #if os(macOS)
      // ⌘P: the table on screen, on paper.
      .focusedSceneValue(\.printableTable, printable)
    #endif
    .themedWindowBackground()
    .sheet(isPresented: $saving) {
      SaveViewSheet(
        subject: .report(kind: selection.kind, grouping: selection.grouping, period: period)
      )
      .handingOver(deps)
    }
    .modifier(MinimumFit(embedded: embedded))
    .task(id: loadKey) { await load() }
    .journalsSection(selection.kind.journalName, in: .reports)
    .exportsPersonalData(
      $exportRequest, environment: environment,
      onFinished: { result in
        if case .failure = result { exportFailed = true }
      }
    )
    .alert(
      t("reports.export.failed"), isPresented: $exportFailed
    ) {
      Button(environment.language("action.ok")) {}
    }
  }

  #if os(macOS)
    /// The paper of ⌘P: the spending of «По категориям», the one table of the other tabs. «По
    /// периодам» has no table: its paper is «Печать…» of «Поделиться…».
    private var printable: PrintableTable? {
      guard tab.showsTable else { return nil }
      return state.value?.models.last.map { ReportsPrint.printable($0, environment: environment) }
    }
  #endif

  private struct MinimumFit: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
      if embedded {
        content
      } else {
        content.sheetFrame(minWidth: ReportsWindow.minimumWidth, minHeight: 480)
      }
    }
  }

  // MARK: What is shown

  /// The day the data was built for: the day of Overview, not the clock of this window.
  private var today: DateOnly { compute.snapshot?.today ?? environment.today }

  private var selection: ReportsSelection {
    ReportsSelection(table: tableName, period: periodText, grouping: groupingName, today: today)
  }

  private var tab: ReportsTab { selection.tab(idiom, byPeriods: byPeriods) }

  private var period: AnalyticsPeriod { selection.period }

  /// The tables of the tab; on «По периодам» the period total of the summary on screen.
  private var request: ReportsSheetRequest {
    if tab == .byPeriods, let id = summaries.selected,
      let summary = ReportsSheetRequest.summary(id, today: today)
    {
      return summary
    }
    return selection.sheetRequest(idiom, today: today)
  }

  private var state: BlockState<ReportsSheet> {
    ReportsStore.state(
      for: request, data: compute.states.data, sheet: reports.sheet, at: reports.sheetAt)
  }

  private func setPeriod(_ period: AnalyticsPeriod) {
    periodText = period.clamped(to: today).storage
  }

  /// A tab of a table stores its table and grouping; «По периодам» puts «Итоги» over it;
  /// «Сохранённые» opens its sheet over the tab on screen.
  private func choose(_ tab: ReportsTab) {
    switch tab {
    case .byPeriods:
      byPeriods = true
    case .saved:
      NotificationCenter.default.post(name: .manageSavedViews, object: nil)
    default:
      guard let stored = tab.stored else { return }
      byPeriods = false
      tableName = stored.kind.rawValue
      groupingName = stored.grouping.rawValue
    }
  }

  /// «Повторить» reruns the data step and what depends on it.
  private func retry() {
    compute.retry(ComputeStep.data)
  }

  // MARK: Building the tables

  private struct LoadKey: Hashable {
    var request: ReportsSheetRequest
    var generation: Int
    var dataReady: Bool
  }

  private var loadKey: LoadKey {
    LoadKey(
      request: request, generation: compute.generation,
      dataReady: compute.states.data.phase == .ready)
  }

  private func load() async {
    let key = loadKey
    guard key.dataReady, let ledger = compute.snapshot?.ledger else { return }
    await reports.load(key.request, ledger: ledger, compute: compute)
  }

  // MARK: The header

  /// «Отчёты», and at the right edge the period and «Выгрузить CSV…», the one orange button; on
  /// «По периодам» the period of the summary and «Поделиться…» before it.
  private var titleRow: some View {
    ScreenTitleRow(title: t("reports.window.title")) {
      if tab == .byPeriods {
        SummaryPeriodMenu(store: summaries)
        SummaryShareMenu(store: summaries)
      } else {
        periodButton
      }
      exportButton
    }
  }

  /// The phone: the period with its chevron at the left, «Выгрузить CSV…» in the accent at the
  /// right, 12 pt.
  private var phoneLine: some View {
    HStack {
      Button {
        choosingPeriod = true
      } label: {
        HStack(spacing: 4) {
          Text(verbatim: AnalyticsText.title(of: period, environment))
          Image(systemName: "chevron.down").appFont(AppFont.system(size: 10, weight: .semibold))
        }
        .appFont(AppFont.system(size: 12))
        .foregroundStyle(theme.contentPrimary)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("period.choose.compact")
      .popover(isPresented: $choosingPeriod) { periodPopover }
      Spacer(minLength: 8)
      Button(t("reports.export")) { export() }
        .buttonStyle(.plain)
        .appFont(AppFont.system(size: 12, weight: .medium))
        .foregroundStyle(theme.accentDefault)
        .disabled(state.value == nil)
        .accessibilityIdentifier("reports.export")
    }
  }

  /// The chosen month or year; it opens the chooser.
  private var periodButton: some View {
    Button {
      choosingPeriod = true
    } label: {
      Text(verbatim: AnalyticsText.title(of: period, environment)).monospacedDigit()
    }
    .buttonStyle(.quietAction)
    .fixedSize()
    .help(t("reports.period.choose"))
    .accessibilityIdentifier("period.choose")
    .popover(isPresented: $choosingPeriod) { periodPopover }
    .task { if await LaunchPresentation.due(.periodChooser) { choosingPeriod = true } }
  }

  /// A month or a year, the months or the years to pick from, and «Текущий».
  private var periodPopover: some View {
    VStack(spacing: 10) {
      Picker(selection: periodKindSelection) {
        Text(verbatim: t("reports.period.month")).tag(AnalyticsPeriod.Kind.month)
        Text(verbatim: t("reports.period.year")).tag(AnalyticsPeriod.Kind.year)
      } label: {
        Text(verbatim: t("reports.period.kind"))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      PeriodChooser(period: period, today: today) { chosen in
        setPeriod(chosen)
        choosingPeriod = false
      }
      Button(t("reports.period.current")) {
        setPeriod(.current(period.kind, today: today))
        choosingPeriod = false
      }
      .disabled(period.isCurrent(today: today))
    }
    .padding(.top, 12)
    .padding(.bottom, 12)
    .appDependencies(deps)
    .presentationCompactAdaptation(.popover)
  }

  private var periodKindSelection: Binding<AnalyticsPeriod.Kind> {
    Binding(
      get: { period.kind },
      set: { setPeriod(period.with(kind: $0)) })
  }

  // MARK: The table

  @ViewBuilder
  private var detail: some View {
    if tab == .byPeriods {
      PeriodsBoardView(store: summaries)
    } else if let sheet = state.value {
      let grid = ReportGridBuilder.grid(sheet, idiom, environment)
      ReportGridView(grid: grid, metrics: metrics, idiom: idiom)
        .contextMenu {
          Button(QuestionsText.t("questions.saved.save.report", environment)) { saving = true }
        }
      Text(verbatim: t(tab == .byMonth ? "reports.monthNote" : "reports.csvNote"))
        .appFont(ReportsType.note)
        .foregroundStyle(theme.contentSecondary)
        .accessibilityIdentifier("reports.note")
    } else {
      ComputedBlock(
        title: nil, state: state, style: .plain, emptyReason: emptyReason, retry: retry
      ) { _ in
        EmptyView()
      }
      .frame(maxWidth: .infinity, minHeight: 240)
    }
  }

  /// Why a tab has no lines: no spending for a tab of spending, nothing at all for the others.
  private var emptyReason: String {
    switch tab {
    case .byEvent, .byPerson, .byAccount, .byPlace: t("reports.empty.expenses")
    case .byMonth where period.kind == .year: t("reports.empty.year")
    default: t("reports.empty.periodTotal")
    }
  }

  // MARK: Export

  /// «Выгрузить CSV…», the one orange button of the screen.
  private var exportButton: some View {
    Button(t("reports.export")) { export() }
      .buttonStyle(.primaryAction)
      .fixedSize()
      .help(t("reports.export.help"))
      // Nothing to export while the table is computed or has no lines.
      .disabled(state.value == nil)
      .accessibilityIdentifier("reports.export")
  }

  private func export() {
    guard let sheet = state.value else { return }
    #if os(macOS)
      Task { await ReportExport.run(sheet: sheet, environment: environment, compute: compute) }
    #else
      exportRequest = PersonalDataExport(
        defaultName: ReportFileName.stem(for: sheet.request),
        files: ReportExport.files(sheet, environment: environment))
    #endif
  }

  private func t(_ key: String) -> String { ReportsText.t(key, environment) }

  // MARK: Widths

  /// The narrowest the content goes, and so the window's minimum (`SecondaryWindow(minWidth:)`):
  /// a window allowed narrower cut the content off at both edges.
  static let minimumWidth: CGFloat = 760
}

extension ReportTable.Kind {
  /// The table as a word of the journal. A raw value may be longer than a word of the journal
  /// is allowed to be (`LogValue.token`), and then it would come out as `<not-a-token>`.
  fileprivate var journalName: String {
    switch self {
    case .incomeByCategory: "incomeByCategory"
    case .expensesByCategoryAndSubcategory: "expensesBySubcategory"
    case .expensesByCategory: "expensesByCategory"
    case .monthly: "monthly"
    case .periodTotal: "periodTotal"
    }
  }
}
