import AppCore
import SwiftUI

/// The Reports window: the period, the tables and «Группировать по» in the sidebar, one table
/// at a time in the middle, «Выгрузить CSV…» in the toolbar.
///
/// The table is built by the core's `ReportBuilder` from the ledger of `ComputeStore` off the
/// main thread, through `compute(_:)` in `.task(id:)`, never in `body`. The table, the period
/// and the grouping on screen are a preference of the window (`UserDefaults`), never the
/// database: they are there again when the window is opened again.
struct ReportsWindow: View {
  @Environment(\.themeSurfaces) private var surfaces
  let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  private var environment: AppEnvironment { deps.environment }
  private var compute: ComputeStore { deps.compute }

  @AppStorage(ReportsSelection.tableKey) private var tableName =
    ReportTable.Kind.expensesByCategoryAndSubcategory.rawValue
  @AppStorage(ReportsSelection.periodKey) private var periodText = ""
  @AppStorage(ReportsSelection.groupingKey) private var groupingName = ReportGrouping.category
    .rawValue
  @State private var reports = ReportsStore()
  @State private var choosingPeriod = false
  /// The CSV handed to the file exporter on a phone; the Mac asks in its save panel.
  @State private var exportRequest: PersonalDataExport?
  @State private var exportFailed = false
  /// The parents the owner folded; every parent is open until then, so the table shows every
  /// line the CSV holds. A new table, period or grouping opens them all again.
  @State private var collapsed: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      detail
    }
    .themedWindowBackground()
    .sheetFrame(minWidth: Self.minimumWidth, minHeight: 480)
    .task(id: loadKey) { await load() }
    .onChange(of: request) { _, _ in collapsed = [] }
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

  // MARK: What is shown

  /// The day the data was built for: the day of Overview, not the clock of this window.
  private var today: DateOnly { compute.snapshot?.today ?? environment.today }

  private var selection: ReportsSelection {
    ReportsSelection(table: tableName, period: periodText, grouping: groupingName, today: today)
  }

  private var period: AnalyticsPeriod { selection.period }

  private var request: ReportsRequest { selection.request(today: today) }

  private var state: BlockState<ReportsModel> {
    ReportsStore.state(
      for: request, data: compute.states.data, model: reports.model, at: reports.modelAt)
  }

  private func setPeriod(_ period: AnalyticsPeriod) {
    periodText = period.clamped(to: today).storage
  }

  /// «Повторить» reruns the data step and what depends on it.
  private func retry() {
    compute.retry(ComputeStep.data)
  }

  // MARK: Building the table

  private struct LoadKey: Hashable {
    var request: ReportsRequest
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

  // MARK: The table

  private var detail: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: ReportsText.title(of: request.kind, environment))
          .appFont(.headline)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: ReportsText.subtitle(request, environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)

      if let model = state.value {
        ReportTableView(model: model, collapsed: $collapsed)
          .clipShape(.rect(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(surfaces.cardBorder, lineWidth: 0.5))
          .padding(.horizontal, 20)
        Text(verbatim: t("reports.csvNote"))
          .appFont(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 20).padding(.bottom, 12)
      } else {
        ComputedBlock(
          title: nil, state: state, style: .plain,
          emptyReason: ReportsText.emptyReason(request.kind, environment), retry: retry
        ) { _ in
          EmptyView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: The header

  /// The title and the period with the export on top, the tables as a row of chips under it,
  /// «Группировать по» beside them for the tables that group.
  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 10) {
          Text(verbatim: t("reports.window.title"))
            .appFont(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 12)
          periodControls
          exportButton
        }
        VStack(alignment: .leading, spacing: 10) {
          Text(verbatim: t("reports.window.title"))
            .appFont(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          HStack(spacing: 10) {
            periodControls
            exportButton
          }
        }
      }
      FlowRow(spacing: 6, lineSpacing: 6) {
        ForEach(ReportTable.Kind.allCases, id: \.self) { kind in
          SectionChip(
            title: ReportsText.title(of: kind, environment), symbol: "tablecells",
            selected: kind == selection.kind
          ) { tableName = kind.rawValue }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("reports.tables")
      if selection.isGroupable {
        HStack(spacing: 8) {
          Text(verbatim: t("reports.sidebar.grouping"))
            .appFont(.caption).foregroundStyle(.secondary)
          Picker(selection: groupingSelection) {
            ForEach(ReportGrouping.allCases, id: \.self) { grouping in
              Text(verbatim: ReportsText.title(of: grouping, environment)).tag(grouping)
            }
          } label: {
            Text(verbatim: t("reports.sidebar.grouping"))
          }
          .labelsHidden()
          .fixedSize()
        }
      } else {
        Text(verbatim: t("reports.grouping.spendingOnly"))
          .appFont(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  private var periodControls: some View {
    HStack(spacing: 8) { periodControlsContent }
  }

  @ViewBuilder
  private var periodControlsContent: some View {
    Picker(selection: periodKindSelection) {
      Text(verbatim: t("reports.period.month")).tag(AnalyticsPeriod.Kind.month)
      Text(verbatim: t("reports.period.year")).tag(AnalyticsPeriod.Kind.year)
    } label: {
      Text(verbatim: t("reports.period.kind"))
    }
    .pickerStyle(.segmented)
    .labelsHidden()

    HStack(spacing: 4) {
      Button {
        setPeriod(period.stepped(by: -1))
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.borderless)
      .help(t("reports.period.previous"))
      .accessibilityLabel(Text(verbatim: t("reports.period.previous")))

      Spacer(minLength: 4)
      Button {
        choosingPeriod = true
      } label: {
        Text(verbatim: AnalyticsText.title(of: period, environment))
          .monospacedDigit()
      }
      .accessibilityIdentifier("period.choose")
      .buttonStyle(.borderless)
      .help(t("reports.period.choose"))
      .popover(isPresented: $choosingPeriod) {
        PeriodChooser(period: period, today: today) { chosen in
          setPeriod(chosen)
          choosingPeriod = false
        }
        .appDependencies(deps)
      }
      .task { if await LaunchPresentation.due(.periodChooser) { choosingPeriod = true } }
      Spacer(minLength: 4)

      Button {
        setPeriod(period.stepped(by: 1))
      } label: {
        Image(systemName: "chevron.right")
      }
      .buttonStyle(.borderless)
      .disabled(!period.canStepForward(today: today))
      .help(t("reports.period.next"))
      .accessibilityLabel(Text(verbatim: t("reports.period.next")))
    }

    Button(t("reports.period.current")) {
      setPeriod(.current(period.kind, today: today))
    }
    .disabled(period.isCurrent(today: today))
  }

  private var kindSelection: Binding<ReportTable.Kind> {
    Binding(
      get: { selection.kind },
      set: { tableName = $0.rawValue })
  }

  private var periodKindSelection: Binding<AnalyticsPeriod.Kind> {
    Binding(
      get: { period.kind },
      set: { setPeriod(period.with(kind: $0)) })
  }

  /// The chosen grouping, kept while a table without grouping is on screen.
  private var groupingSelection: Binding<ReportGrouping> {
    Binding(
      get: { selection.grouping },
      set: { groupingName = $0.rawValue })
  }

  // MARK: Export

  private var exportButton: some View {
    Button {
      export()
    } label: {
      Label {
        Text(verbatim: t("reports.export"))
      } icon: {
        Image(systemName: "square.and.arrow.up")
      }
    }
    .buttonStyle(.borderedProminent)
    .labelStyle(.titleAndIcon)
    .help(t("reports.export.help"))
    // Nothing to export while the table is computed or has no lines.
    .disabled(state.value == nil)
  }

  private func export() {
    guard let model = state.value else { return }
    #if os(macOS)
      Task { await ReportExport.run(model: model, environment: environment, compute: compute) }
    #else
      let names = ReportsText.csvNames(for: model, environment)
      let name = (ReportFileName.make(for: model.request) as NSString).deletingPathExtension
      exportRequest = PersonalDataExport(
        defaultName: name,
        files: [.init(name: name + ".csv", data: ReportExport.data(model.table, names: names))])
    #endif
  }

  private func t(_ key: String) -> String { ReportsText.t(key, environment) }

  // MARK: Widths

  static let sidebarMinWidth: CGFloat = 230
  static let sidebarIdealWidth: CGFloat = 260
  static let sidebarMaxWidth: CGFloat = 340

  /// The narrowest the content goes, and so the window's minimum (`SecondaryWindow(minWidth:)`):
  /// a window allowed narrower cut the content off at both edges. The sidebar hidden at this
  /// width and shown again takes its room from the content, not from the window.
  static let minimumWidth: CGFloat = 760
}

/// The table on screen: a SwiftUI `Table`, no glass — content is never glass. Every line of
/// the model, in the order of the CSV: a parent with its children under a disclosure
/// triangle, open until the owner folds it; then the average and the total, in semibold.
/// Amounts are whole rubles in monospaced digits on the right, shares with two decimals.
/// A year with no completed month yet has its average line too, reading «мало данных».
struct ReportTableView: View {
  @Dependency(\.environment) private var environment
  let model: ReportsModel
  @Binding var collapsed: Set<String>

  /// A column of amounts: one for most tables, spending, income and net for the monthly one.
  struct MeasureColumn: Identifiable {
    let index: Int
    let title: String
    var id: Int { index }
  }

  var body: some View {
    Table(of: ReportLine.self) {
      columns
    } rows: {
      rows
    }
    // The columns differ from one table to another: each gets a table of its own.
    .id(model.request.kind)
  }

  @TableRowBuilder<ReportLine>
  private var rows: some TableRowContent<ReportLine> {
    ForEach(model.lines) { line in
      if line.children.isEmpty {
        TableRow(line)
      } else {
        DisclosureTableRow(line, isExpanded: expansion(of: line)) {
          ForEach(line.children) { child in
            TableRow(child)
          }
        }
      }
    }
  }

  private func expansion(of line: ReportLine) -> Binding<Bool> {
    Binding(
      get: { !collapsed.contains(line.id) },
      set: { isOpen in
        if isOpen { collapsed.remove(line.id) } else { collapsed.insert(line.id) }
      })
  }

  private var measures: [MeasureColumn] {
    model.table.measures.enumerated().map { index, measure in
      MeasureColumn(index: index, title: ReportsText.column(measure, environment))
    }
  }

  @TableColumnBuilder<ReportLine, Never>
  private var columns: some TableColumnContent<ReportLine, Never> {
    TableColumn(Text(verbatim: ReportsText.nameColumn(model.table.kind, environment))) { line in
      ReportNameCell(
        line: line, name: ReportsText.name(of: line, in: model, environment),
        mark: ReportsText.mark(of: line, in: model, environment))
    }
    .width(min: 180, ideal: 320)

    TableColumnForEach(measures) { column in
      TableColumn(Text(verbatim: column.title)) { line in
        Text(verbatim: ReportsText.value(of: line, at: column.index, environment))
          .monospacedDigit()
          .fontWeight(line.isSummary && !line.lacksData ? .semibold : nil)
          .foregroundStyle(line.values[column.index] == nil ? .secondary : .primary)
      }
      .width(min: 100, ideal: 140)
      .alignment(.trailing)
    }

    if model.table.hasShares {
      TableColumn(Text(verbatim: ReportsText.t("reports.column.share", environment))) { line in
        Text(verbatim: ReportsText.share(line.share, environment))
          .monospacedDigit()
          .fontWeight(line.isSummary ? .semibold : nil)
      }
      .width(min: 70, ideal: 90)
      .alignment(.trailing)
    }
  }
}

/// The name of a line; a month that is not over says so in words and with a symbol —
/// «неполный», «ещё не начался» — never by the symbol alone.
private struct ReportNameCell: View {
  let line: ReportLine
  let name: String
  let mark: (text: String, symbol: String)?

  var body: some View {
    HStack(spacing: 6) {
      Text(verbatim: name)
        .lineLimit(1)
        .fontWeight(line.isSummary ? .semibold : nil)
      if let mark {
        Label {
          Text(verbatim: mark.text)
        } icon: {
          Image(systemName: mark.symbol)
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
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
