import AppCore
import SwiftUI

/// The period of the tag report.
enum TagReportPeriod: String, CaseIterable, Identifiable {
  case month, year, all

  var id: String { rawValue }
  var titleKey: String { "tagreport.period.\(rawValue)" }

  /// The days it covers up to `today`; `nil` is the whole history.
  func range(today: DateOnly) -> DayRange? {
    switch self {
    case .month: DayRange(today.monthKey.firstDay, today)
    case .year: DayRange(DateOnly(year: today.year, month: 1, day: 1), today)
    case .all: nil
    }
  }
}

/// What the tag report says in words, apart from the view so a test reads it.
@MainActor
enum TagReportText {
  /// «Операция с несколькими тегами входит в каждый из них: сумма по тегам (X) больше итога
  /// (Y).» Said only when the rows really add up to more than the spending they cover.
  static func overlapCaption(_ report: TagReport, _ environment: AppEnvironment) -> String? {
    guard report.rowsOverlap else { return nil }
    return RulesText.format(
      "tagreport.overlap", environment, environment.money.rounded(report.sumOfRowsRubE4),
      environment.money.rounded(report.distinctRubE4))
  }
}

/// «По тегам»: what each tag took in a period, and the operations of the tags picked — any of
/// them or all of them. An operation with two tags counts in both rows, and the page says so.
struct TagReportSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var period: TagReportPeriod = .year
  @State private var report: TagReport?
  @State private var picked: Set<UUID> = []
  @State private var mode: TagFilter.Mode = .any

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  /// The newest this many operations are listed; the number found is said in full.
  static let listLimit = 200

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let book = dataset?.tagBook ?? TagBook()
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: t("tagreport.title")).appFont(.headline)
        Spacer()
        Picker(selection: $period) {
          ForEach(TagReportPeriod.allCases) { item in
            Text(verbatim: t(item.titleKey)).tag(item)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      if let report, !report.rows.isEmpty {
        rows(report, book: book)
        if let caption = TagReportText.overlapCaption(report, environment) {
          Label(caption, systemImage: "square.on.square")
            .appFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("tagreport.overlap")
        }
        operations(book: book)
      } else {
        Text(verbatim: t("tagreport.empty"))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      HStack {
        Spacer()
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 620)
    .task(id: ReportKey(period: period, version: compute.snapshot?.version.cacheKey ?? 0)) {
      guard let snapshot = compute.snapshot else { return }
      report = try? await compute.analysis.tags.report(
        snapshot, range: period.range(today: snapshot.today))
    }
    .accessibilityIdentifier("tagreport")
  }

  private struct ReportKey: Hashable {
    var period: TagReportPeriod
    var version: Int
  }

  private func rows(_ report: TagReport, book: TagBook) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(report.rows) { row in
        let name = book.tag(row.tagId)?.name ?? "?"
        let isPicked = picked.contains(row.tagId)
        Button {
          if isPicked { picked.remove(row.tagId) } else { picked.insert(row.tagId) }
        } label: {
          HStack {
            Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
              .accessibilityHidden(true)
            Text(verbatim: "#" + name)
            Spacer()
            Text(
              verbatim: environment.format(
                "tags.usage", table: RulesText.table, counts: row.operations)
            )
            .foregroundStyle(.secondary)
            Text(verbatim: environment.money.rounded(row.myRubE4))
              .monospacedDigit()
              .frame(minWidth: 90, alignment: .trailing)
          }
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("tagreport.row")
        Divider()
      }
    }
  }

  @ViewBuilder
  private func operations(book: TagBook) -> some View {
    if !picked.isEmpty, let snapshot = compute.snapshot {
      let found = compute.analysis.tags.entries(snapshot, matching: picked, mode: mode)
        .sorted { $0.transaction.occurredAt > $1.transaction.occurredAt }
      let names = RuleNames(dataset: snapshot.dataset)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Picker(selection: $mode) {
            Text(verbatim: t("tagreport.mode.any")).tag(TagFilter.Mode.any)
            Text(verbatim: t("tagreport.mode.all")).tag(TagFilter.Mode.all)
          } label: {
            EmptyView()
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          Spacer()
          Text(
            verbatim: environment.format(
              "tagreport.found", table: RulesText.table, counts: found.count)
          )
          .foregroundStyle(.secondary)
        }
        List(found.prefix(Self.listLimit), id: \.id) { entry in
          HStack {
            Text(verbatim: line(entry, names: names)).lineLimit(1)
            Spacer(minLength: 8)
            Text(
              verbatim: environment.money.exact(
                entry.transaction.amountE4, currency: entry.transaction.currency)
            )
            .monospacedDigit()
          }
        }
        .listStyle(.inset)
        .frame(minHeight: 120)
        .accessibilityIdentifier("tagreport.operations")
      }
    } else {
      Text(verbatim: t("tagreport.pick"))
        .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  private func line(_ entry: TransactionEntry, names: RuleNames) -> String {
    BackfillSheet.title(entry.transaction, names: names, environment: environment)
  }
}
