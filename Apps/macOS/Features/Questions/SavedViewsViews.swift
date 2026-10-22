import AppCore
import SwiftUI

/// Changes to the saved filters and reports: each one goes through the store, so it is one
/// step of ⌘Z. An edit starts from the book the database holds, not from the snapshot on
/// screen, which may be a moment behind a write made just before.
@MainActor
struct SavedViewsEditor {
  let environment: AppEnvironment
  let store: TransactionsStore
  let compute: ComputeStore

  /// What the screens show: the snapshot's book.
  var shown: SavedViewsBook { compute.snapshot?.dataset.savedViews ?? SavedViewsBook() }

  /// What an edit starts from.
  var book: SavedViewsBook {
    (try? environment.savedViews?.book()) ?? shown
  }

  @discardableResult
  func edit(_ change: (inout SavedViewsBook) -> Void) -> Bool {
    var next = book
    change(&next)
    return store.replaceSavedViews(next)
  }
}

// MARK: - Naming a view to keep

/// «Сохранить фильтр…» / «Сохранить отчёт…»: a name, and — for a period that moves with the
/// calendar — whether it keeps moving or stays on the days it means now.
struct SaveViewSheet: View {
  enum Subject {
    case filter(TransactionFilters, columns: [String]?)
    case report(kind: ReportTable.Kind, grouping: ReportGrouping, period: AnalyticsPeriod)
  }

  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  let subject: Subject
  @State private var name = ""
  @State private var floating = true
  @State private var withColumns = false
  @State private var refused = false

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }
  private var today: DateOnly { compute.snapshot?.today ?? environment.today }

  /// The period as the words it would be kept in, or `nil` when it cannot move (a chosen span,
  /// a past month, all time).
  private var floatingWords: RelativePeriod? {
    switch subject {
    case .filter(let filters, _):
      switch filters.period {
      case .thisMonth: return .thisMonth
      case .lastMonth: return .lastMonth
      case .thisYear: return .thisYear
      case .allTime, .custom: return nil
      }
    case .report(_, _, let period):
      let words = SavedViewsText.relativePeriod(for: period, today: today)
      return words.isFloating ? words : nil
    }
  }

  private var title: String {
    switch subject {
    case .filter: t("questions.saved.save.filter")
    case .report: t("questions.saved.save.report")
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField(text: $name, prompt: Text(verbatim: t("questions.saved.name.prompt"))) {
            Text(verbatim: t("questions.saved.name"))
          }
          .accessibilityIdentifier("saved.name")
        }
        if let words = floatingWords {
          Section {
            Picker(selection: $floating) {
              Text(
                verbatim: QuestionsText.format(
                  "questions.saved.period.floating", environment,
                  QuestionsText.title(of: words, today: today, environment))
              ).tag(true)
              Text(
                verbatim: QuestionsText.format(
                  "questions.saved.period.fixed", environment,
                  QuestionsText.title(of: words.period(today: today), environment))
              ).tag(false)
            } label: {
              Text(verbatim: t("questions.saved.period"))
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("saved.period")
          } footer: {
            Text(verbatim: t("questions.saved.period.footer"))
              .appFont(.callout).foregroundStyle(.secondary)
          }
        }
        if case .filter(_, let columns) = subject, columns != nil {
          Section {
            Toggle(isOn: $withColumns) { Text(verbatim: t("questions.saved.columns")) }
              .accessibilityIdentifier("saved.columns")
          }
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        if refused {
          Label(t("questions.saved.refused"), systemImage: "exclamationmark.octagon")
            .appFont(.callout).foregroundStyle(.red)
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("saved.save")
      }
      .padding(14)
    }
    .sheetFrame(width: 460, height: 360)
    .navigationTitle(title)
    .accessibilityIdentifier("saved.sheet")
  }

  private func save() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let editor = SavedViewsEditor(environment: environment, store: store, compute: compute)
    let written: Bool
    switch subject {
    case .filter(let filters, let columns):
      let saved = filters.saved(
        named: trimmed, floating: floating, today: today,
        columns: withColumns ? columns : nil)
      written = editor.edit { $0.add(saved) }
    case .report(let kind, let grouping, let period):
      let words = SavedViewsText.relativePeriod(for: period, today: today)
      let saved = SavedReport(
        name: trimmed, kind: kind, grouping: grouping,
        period: SavedPeriod.saving(words, floating: floating, today: today))
      written = editor.edit { $0.add(saved) }
    }
    if written { dismiss() } else { refused = true }
  }
}

// MARK: - The list

/// The saved filters and reports: apply, rename, put in another order, delete. A deleted one
/// comes back with ⌘Z.
struct SavedViewsSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeSurfaces) private var surfaces
  /// Applies a saved view in the window behind the sheet.
  let open: (UUID) -> Void

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }
  private var editor: SavedViewsEditor {
    SavedViewsEditor(environment: environment, store: store, compute: compute)
  }
  private var today: DateOnly { compute.snapshot?.today ?? environment.today }

  var body: some View {
    let book = editor.shown
    let names = AnalyticsNames(dataset: compute.snapshot?.dataset ?? Dataset())
    VStack(spacing: 0) {
      HStack {
        Text(verbatim: t("questions.saved.title")).appFont(.headline)
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("saved.close")
      }
      .padding(14)
      Divider()
      if book.filters.isEmpty && book.reports.isEmpty {
        Text(verbatim: t("questions.saved.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(24)
          .accessibilityIdentifier("saved.empty")
      } else {
        List {
          if !book.filters.isEmpty {
            Section {
              ForEach(Array(book.filters.enumerated()), id: \.element.id) { position, filter in
                SavedViewRow(
                  name: filter.name,
                  summary: SavedViewsText.summary(
                    of: filter, names: names, today: today, environment),
                  isFirst: position == 0, isLast: position == book.filters.count - 1,
                  rename: { new in editor.edit { $0.rename(filter.id, to: new) } },
                  open: { open(filter.id) },
                  move: { delta in
                    editor.edit { $0.moveFilter(from: position, to: position + delta) }
                  },
                  delete: { editor.edit { $0.remove(filter.id) } })
              }
            } header: {
              Text(verbatim: t("questions.saved.filters")).settingsHeaderStyle()
            }
          }
          if !book.reports.isEmpty {
            Section {
              ForEach(Array(book.reports.enumerated()), id: \.element.id) { position, report in
                SavedViewRow(
                  name: report.name,
                  summary: SavedViewsText.summary(of: report, today: today, environment),
                  isFirst: position == 0, isLast: position == book.reports.count - 1,
                  rename: { new in editor.edit { $0.rename(report.id, to: new) } },
                  open: { open(report.id) },
                  move: { delta in
                    editor.edit { $0.moveReport(from: position, to: position + delta) }
                  },
                  delete: { editor.edit { $0.remove(report.id) } })
              }
            } header: {
              Text(verbatim: t("questions.saved.reports")).settingsHeaderStyle()
            }
          }
        }
        .listStyle(.inset)
        Divider()
        Text(verbatim: t("questions.saved.undoHint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
      }
    }
    .sheetFrame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 480)
    .accessibilityIdentifier("saved.list")
  }
}

private struct SavedViewRow: View {
  @Dependency(\.environment) private var environment
  let name: String
  let summary: String
  let isFirst: Bool
  let isLast: Bool
  let rename: (String) -> Void
  let open: () -> Void
  let move: (Int) -> Void
  let delete: () -> Void
  @State private var editing: String?

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        if let text = editing {
          TextField(
            text: Binding(get: { editing ?? text }, set: { editing = $0 }),
            prompt: Text(verbatim: t("questions.saved.name.prompt"))
          ) {
            Text(verbatim: t("questions.saved.name"))
          }
          .onSubmit(commitRename)
          .accessibilityIdentifier("saved.row.rename")
        } else {
          Text(verbatim: name).appFont(.body.weight(.medium))
        }
        Text(verbatim: summary)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      Button(action: open) { Image(systemName: "arrow.up.forward.square") }
        .help(t("questions.saved.open"))
        .accessibilityLabel(Text(verbatim: t("questions.saved.open")))
        .accessibilityIdentifier("saved.row.open")
      Button {
        move(-1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(isFirst)
      .help(t("questions.saved.moveUp"))
      .accessibilityLabel(Text(verbatim: t("questions.saved.moveUp")))
      .accessibilityIdentifier("saved.row.up")
      Button {
        move(1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(isLast)
      .help(t("questions.saved.moveDown"))
      .accessibilityLabel(Text(verbatim: t("questions.saved.moveDown")))
      .accessibilityIdentifier("saved.row.down")
      Button {
        editing = editing == nil ? name : nil
      } label: {
        Image(systemName: "pencil")
      }
      .help(t("questions.saved.rename"))
      .accessibilityLabel(Text(verbatim: t("questions.saved.rename")))
      .accessibilityIdentifier("saved.row.edit")
      Button(role: .destructive, action: delete) { Image(systemName: "trash") }
        .help(environment.language("action.delete"))
        .accessibilityLabel(Text(verbatim: environment.language("action.delete")))
        .accessibilityIdentifier("saved.row.delete")
    }
    .buttonStyle(.borderless)
  }

  private func commitRename() {
    let trimmed = (editing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    editing = nil
    if !trimmed.isEmpty, trimmed != name { rename(trimmed) }
  }
}

// MARK: - Menus

/// The saved filters of «Операции»: apply one, save the current filters, open the list. The
/// window that owns the screen does the work, by notification.
struct SavedFiltersMenu: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    let book = compute.snapshot?.dataset.savedViews ?? SavedViewsBook()
    Menu {
      ForEach(book.filters) { filter in
        Button(filter.name) {
          NotificationCenter.default.post(name: .openSavedView, object: filter.id)
        }
      }
      if !book.filters.isEmpty { Divider() }
      Button(t("questions.saved.save.filter")) {
        NotificationCenter.default.post(name: .saveOperationsFilter, object: nil)
      }
      .accessibilityIdentifier("saved.menu.save")
      Button(t("questions.saved.manage")) {
        NotificationCenter.default.post(name: .manageSavedViews, object: nil)
      }
      .accessibilityIdentifier("saved.menu.manage")
    } label: {
      Label {
        Text(verbatim: t("questions.saved.menu"))
      } icon: {
        Image(systemName: "bookmark")
      }
    }
    .accessibilityIdentifier("operations.saved")
  }
}

/// The saved reports in the Reports window: open one, save the table on screen, open the list.
struct SavedReportsMenu: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let kind: ReportTable.Kind
  let grouping: ReportGrouping
  let period: AnalyticsPeriod
  @State private var saving = false

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    let book = compute.snapshot?.dataset.savedViews ?? SavedViewsBook()
    Menu {
      ForEach(book.reports) { report in
        Button(report.name) {
          QuestionOpening.prepareReports(
            report, today: compute.snapshot?.today ?? environment.today)
        }
      }
      if !book.reports.isEmpty { Divider() }
      Button(t("questions.saved.save.report")) { saving = true }
        .accessibilityIdentifier("saved.menu.saveReport")
      Button(t("questions.saved.manage")) {
        NotificationCenter.default.post(name: .manageSavedViews, object: nil)
      }
    } label: {
      Label {
        Text(verbatim: t("questions.saved.menu.reports"))
      } icon: {
        Image(systemName: "bookmark")
      }
    }
    .sheet(isPresented: $saving) {
      SaveViewSheet(subject: .report(kind: kind, grouping: grouping, period: period))
        .handingOver(dependencies)
    }
    .accessibilityIdentifier("reports.saved")
  }
}

/// The saved filters that have a period, to move Analytics to it.
struct SavedPeriodsMenu: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let choose: (AnalyticsPeriod) -> Void

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    let book = compute.snapshot?.dataset.savedViews ?? SavedViewsBook()
    let today = compute.snapshot?.today ?? environment.today
    let withPeriod = book.filters.filter { $0.period != nil }
    if !withPeriod.isEmpty {
      Menu {
        ForEach(withPeriod) { filter in
          if let period = filter.period {
            Button(
              "\(filter.name) · \(SavedViewsText.period(period, today: today, environment))"
            ) {
              choose(
                QuestionOpening.analyticsPeriod(for: period.resolved(today: today), today: today))
            }
          }
        }
      } label: {
        Label {
          Text(verbatim: t("questions.saved.menu"))
        } icon: {
          Image(systemName: "bookmark")
        }
      }
      .accessibilityIdentifier("analytics.saved")
    }
  }
}
