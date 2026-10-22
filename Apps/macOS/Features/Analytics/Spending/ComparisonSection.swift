import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// What the comparison card draws: the counted comparison, the names of its lines and the
/// pair it was counted for.
struct ComparisonDisplay: Sendable {
  var comparison: SpendingComparison
  var names: AnalyticsNames
}

/// «Сравнение»: two periods side by side by category, place or person; the ready-made pairs of
/// one tap and any two ranges; «Я год назад» under it.
struct ComparisonSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let period: AnalyticsPeriod
  @State private var setup: ComparisonSetup

  init(period: AnalyticsPeriod) {
    self.period = period
    _setup = State(initialValue: ComparisonSetup(anchor: period.month))
  }

  private struct Request: Hashable, Sendable {
    var setup: ComparisonSetup
    var anchor: MonthKey
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SpendingBlock(
        identifier: "spending.comparison", title: t("spending.cmp.title"),
        subtitle: t("spending.cmp.basis"),
        request: Request(setup: setup, anchor: period.month),
        fetch: { snapshot, request async throws -> SpendingOutcome<ComparisonDisplay> in
          guard
            let pair = request.setup.pair(
              anchor: request.anchor, events: snapshot.dataset.events)
          else { return .empty(reason: t("spending.cmp.empty")) }
          let comparison = try await compute.analysis.spending.comparison(
            snapshot, pair: pair, dimension: request.setup.dimension,
            choice: request.setup.choice)
          return .ready(
            ComparisonDisplay(
              comparison: comparison, names: AnalyticsNames(dataset: snapshot.dataset)))
        },
        accessory: { chooser }
      ) { display in
        ComparisonTable(display: display)
      }
      controls
      YearAgoCard(month: period.month)
    }
    .onAppear { setup.chooseDefaultEvent(from: compute.snapshot?.dataset.events ?? []) }
  }

  // MARK: Controls

  private var chooser: some View {
    Picker(selection: $setup.kind) {
      ForEach(ComparisonPairKind.allCases) { kind in
        Text(verbatim: SpendingText.name(of: kind, environment)).tag(kind)
      }
    } label: {
      Text(verbatim: t("spending.cmp.pair"))
    }
    .pickerStyle(.menu)
    .fixedSize()
    .accessibilityIdentifier("spending.cmp.pair")
  }

  @ViewBuilder
  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      FlowRow(spacing: 12, lineSpacing: 8) {
        Picker(selection: $setup.dimension) {
          ForEach(ComparisonDimension.allCases, id: \.self) { dimension in
            Text(verbatim: SpendingText.name(of: dimension, environment)).tag(dimension)
          }
        } label: {
          Text(verbatim: t("spending.cmp.dimension"))
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("spending.cmp.dimension")
        Picker(selection: $setup.choice) {
          ForEach(ComparisonChoice.allCases, id: \.self) { choice in
            Text(verbatim: SpendingText.name(of: choice, environment)).tag(choice)
          }
        } label: {
          Text(verbatim: t("spending.cmp.choice"))
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("spending.cmp.choice")
      }
      if setup.kind == .eventToUsualMonth { eventPicker }
      if setup.kind == .custom { customRanges }
    }
    .padding(.horizontal, 4)
  }

  private var eventPicker: some View {
    let events = ComparisonSetup.choosableEvents(compute.snapshot?.dataset.events ?? [])
    return Picker(selection: $setup.eventId) {
      if events.isEmpty { Text(verbatim: t("spending.cmp.noEvent")).tag(UUID?.none) }
      ForEach(events, id: \.id) { event in Text(verbatim: event.name).tag(UUID?.some(event.id)) }
    } label: {
      Text(verbatim: t("spending.cmp.event"))
    }
    .pickerStyle(.menu)
    .fixedSize()
    .accessibilityIdentifier("spending.cmp.event")
  }

  private var customRanges: some View {
    VStack(alignment: .leading, spacing: 8) {
      rangeRow(t("spending.cmp.custom.current"), $setup.customCurrent, id: "current")
      rangeRow(t("spending.cmp.custom.baseline"), $setup.customBaseline, id: "baseline")
    }
  }

  private func rangeRow(_ title: String, _ range: Binding<DayRange>, id: String) -> some View {
    FlowRow(spacing: 8, lineSpacing: 6) {
      Text(verbatim: title).appFont(.callout.weight(.semibold))
      DatePicker(
        selection: dayBinding(range, start: true), displayedComponents: .date
      ) {
        Text(verbatim: t("spending.cmp.from"))
      }
      .accessibilityIdentifier("spending.cmp.\(id).from")
      DatePicker(
        selection: dayBinding(range, start: false), displayedComponents: .date
      ) {
        Text(verbatim: t("spending.cmp.to"))
      }
      .accessibilityIdentifier("spending.cmp.\(id).to")
    }
  }

  private func dayBinding(_ range: Binding<DayRange>, start: Bool) -> Binding<Date> {
    Binding(
      get: {
        environment.calendar.noon(of: start ? range.wrappedValue.start : range.wrappedValue.end)
      },
      set: { date in
        let day = environment.calendar.day(of: date)
        let current = range.wrappedValue
        range.wrappedValue = start ? DayRange(day, current.end) : DayRange(current.start, day)
      })
  }

  private func t(_ key: String) -> String { SpendingText.t(key, environment) }
}

// MARK: - The table

/// The lines of a comparison: the name, this period, the other, the change with its symbol and
/// sign; the total last; the note about the measure; the export.
private struct ComparisonTable: View {
  @Dependency(\.environment) private var environment
  let display: ComparisonDisplay
  @State private var exporting = false

  var body: some View {
    let comparison = display.comparison
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        header(SpendingText.title(of: comparison.periods.current, environment), "current")
        header(SpendingText.title(of: comparison.periods.baseline, environment), "baseline")
      }
      .appFont(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      if let note = SpendingText.measureNote(comparison, environment) {
        Label {
          Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "divide.circle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("spending.cmp.note")
      }
      ForEach(Array(comparison.rows.enumerated()), id: \.offset) { _, row in
        line(AnalyticsText.name(of: row.key, display.names, environment), row)
      }
      Divider()
      line(environment.language("common.total"), comparison.total, bold: true)
      HStack {
        Spacer()
        exportButton
      }
    }
  }

  private func header(_ title: String, _ id: String) -> some View {
    Text(verbatim: title)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("spending.cmp.header.\(id)")
  }

  private func line(_ name: String, _ row: ComparisonRow, bold: Bool = false) -> some View {
    let money = environment.money
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        Text(verbatim: money.rounded(row.current)).frame(width: 96, alignment: .trailing)
        Text(verbatim: money.rounded(row.baseline)).frame(width: 96, alignment: .trailing)
        changeLabel(row).frame(width: 150, alignment: .trailing)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: name)
        Text(verbatim: "\(money.rounded(row.current)) · \(money.rounded(row.baseline))")
          .foregroundStyle(.secondary)
        changeLabel(row)
      }
    }
    .appFont(bold ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
    .accessibilityElement(children: .combine)
  }

  private func changeLabel(_ row: ComparisonRow) -> some View {
    Label {
      Text(verbatim: SpendingText.change(row, environment))
    } icon: {
      Image(systemName: SpendingText.symbol(of: row)).accessibilityHidden(true)
    }
    .labelStyle(.titleAndIcon)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var exportButton: some View {
    Button {
      #if os(macOS)
        guard FileCommands.confirmPersonalData(environment) else { return }
      #endif
      exporting = true
    } label: {
      Label(SpendingText.t("spending.cmp.export", environment), systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .accessibilityIdentifier("spending.cmp.export")
    .fileExporter(
      isPresented: $exporting, document: ComparisonCSVDocument(data: csv),
      contentType: .commaSeparatedText,
      defaultFilename: String(
        ComparisonCSV.fileName(for: display.comparison.periods).dropLast(4))
    ) { _ in }
  }

  private var csv: Data {
    let names = display.names
    let environment = environment
    return ComparisonCSV.data(display.comparison) {
      AnalyticsText.name(of: $0, names, environment)
    }
  }
}

/// The comparison as a file the save panel writes: the core's CSV, UTF-8, read by
/// `pandas.read_csv` with no parameters.
struct ComparisonCSVDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.commaSeparatedText]
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

// MARK: - A year ago

/// «Я год назад»: the month of the toolbar against the same month a year before, by category,
/// as sentences — «Такси: на 20 % меньше». With less than a year of history: «Мало данных:
/// история с марта 2026», no ranking and no comparison with other people.
private struct YearAgoCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let month: MonthKey

  struct Display: Sendable {
    var lines: [(name: String, row: ComparisonRow)]
    var total: ComparisonRow
  }

  var body: some View {
    SpendingBlock(
      identifier: "spending.yearAgo", title: SpendingText.t("spending.yearAgo.title", environment),
      subtitle: SpendingText.t("spending.yearAgo.basis", environment), request: month,
      fetch: { snapshot, month async throws -> SpendingOutcome<Display> in
        switch try await compute.analysis.spending.yearAgo(snapshot, month: month) {
        case .notEnoughData(let start):
          return .empty(reason: SpendingText.yearAgoNoData(historyStart: start, environment))
        case .comparison(let result):
          let names = AnalyticsNames(dataset: snapshot.dataset)
          let lines = result.changes.map {
            (AnalyticsText.name(of: $0.key, names, environment), $0)
          }
          return .ready(Display(lines: lines, total: result.comparison.total))
        }
      }
    ) { display in
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(display.lines.prefix(12).enumerated()), id: \.offset) { _, item in
          if let text = SpendingText.yearAgoLine(item.row, name: item.name, environment) {
            Label {
              Text(verbatim: text)
            } icon: {
              Image(systemName: SpendingText.symbol(of: item.row)).accessibilityHidden(true)
            }
            .appFont(.callout)
          }
        }
        if let text = SpendingText.yearAgoLine(
          display.total, name: environment.language("common.total"), environment)
        {
          Divider()
          Text(verbatim: text).appFont(.callout.weight(.semibold))
        }
      }
      .accessibilityIdentifier("spending.yearAgo.lines")
    }
  }
}
