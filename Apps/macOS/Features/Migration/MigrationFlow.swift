import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// «Перенести из другого приложения»: a table exported from CoinKeeper, Дзен-мани, Money Manager,
/// Excel or Numbers, its columns, its accounts and categories paired with the book's own, a
/// preview, and one «Перенести». A copy of the database is made first, and ⌘Z takes the whole move
/// back. Opened from the File menu on the Mac and from Settings → Счета on every device.
struct MigrationFlow: View {
  enum Step: String, CaseIterable, Identifiable {
    case columns, pairing, preview
    var id: String { rawValue }
    var titleKey: String { "migration.step.\(rawValue)" }
  }

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var model: MigrationModel?
  @State private var step: Step = .columns
  @State private var picking = false
  @State private var failed = false

  private func t(_ key: String) -> String { MigrationText.t(key, environment) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let model {
        content(model)
        Divider()
        footer(model)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheetFrame(minWidth: 720, idealWidth: 860, minHeight: 540, idealHeight: 680)
    .task {
      guard model == nil else { return }
      model = MigrationModel(
        environment: environment, store: store, dataset: { compute.snapshot?.dataset })
    }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: Self.contentTypes, allowsMultipleSelection: false
    ) { result in
      guard case .success(let chosen) = result, let url = chosen.first, let model else { return }
      step = .columns
      Task { await model.load(url: url) }
    }
    .accessibilityIdentifier("migration.flow")
  }

  /// CSV, text and Excel; a Numbers document is let through to say how to export it.
  static let contentTypes: [UTType] = [
    .commaSeparatedText, .tabSeparatedText, .plainText, .spreadsheet, .data,
  ]

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: t("migration.title")).appFont(.headline)
        Text(verbatim: t("migration.subtitle")).appFont(.callout).foregroundStyle(.secondary)
      }
      if let model, model.fileState == .table, model.outcome == nil {
        Picker(selection: $step) {
          ForEach(Step.allCases) { step in
            Text(verbatim: t(step.titleKey)).tag(step)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("migration.steps")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  @ViewBuilder
  private func content(_ model: MigrationModel) -> some View {
    if let outcome = model.outcome {
      done(outcome)
    } else {
      switch model.fileState {
      case .none: start(model, message: nil)
      case .reading:
        VStack(spacing: 12) {
          ProgressView()
          Text(verbatim: t("migration.reading")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .numbers: start(model, message: t("migration.file.numbers"))
      case .legacyExcel: start(model, message: t("migration.file.xls"))
      case .unreadable: start(model, message: t("migration.file.unreadable"))
      case .table:
        switch step {
        case .columns: MigrationColumnsStep(model: model)
        case .pairing: MigrationPairingStep(model: model)
        case .preview: MigrationPreviewStep(model: model)
        }
      }
    }
  }

  /// The empty state, and the answer to a file that is not a table.
  private func start(_ model: MigrationModel, message: String?) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "arrow.right.doc.on.clipboard")
        .appFont(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
      if let message {
        Label(message, systemImage: "exclamationmark.triangle")
          .appFont(.callout)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)
          .accessibilityIdentifier("migration.file.message")
      }
      Text(verbatim: t("migration.empty.title")).appFont(.title3)
      Text(verbatim: t("migration.empty.body"))
        .appFont(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
      Button {
        picking = true
      } label: {
        Label(t("migration.choose"), systemImage: "doc.badge.plus")
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("migration.choose")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func done(_ outcome: MigrationOutcome) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle")
        .appFont(.largeTitle).foregroundStyle(.green).accessibilityHidden(true)
      Text(verbatim: MigrationText.counted("migration.done.title", environment, outcome.written))
        .appFont(.title3)
        .accessibilityIdentifier("migration.done")
      if outcome.categoriesMade > 0 {
        Text(
          verbatim: MigrationText.counted(
            "migration.done.categories", environment, outcome.categoriesMade)
        )
        .foregroundStyle(.secondary)
      }
      Text(verbatim: t("migration.done.undo"))
        .appFont(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func footer(_ model: MigrationModel) -> some View {
    HStack(spacing: 12) {
      if model.outcome == nil, model.fileState == .table {
        Text(verbatim: MigrationText.counted("migration.summary", environment, model.toWrite))
          .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
          .accessibilityIdentifier("migration.summary")
        Button(t("migration.another")) { picking = true }
          .buttonStyle(.link)
      }
      if failed {
        Label(t("migration.failed"), systemImage: "exclamationmark.octagon")
          .appFont(.callout).foregroundStyle(.red)
      }
      Spacer()
      if model.outcome == nil {
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        if model.fileState == .table {
          if step != .preview {
            Button(t("migration.next")) {
              step = step == .columns ? .pairing : .preview
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.mapping.isComplete)
            .accessibilityIdentifier("migration.next")
          } else {
            Button(t("migration.apply")) {
              Task {
                failed = !(await model.apply())
                // The model of categories learns from the history moved in at the next count.
                if !failed { compute.run() }
              }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApply || store.isWritingInBackground)
            .accessibilityIdentifier("migration.apply")
          }
        }
      } else {
        Button(t("migration.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("migration.close")
      }
    }
    .padding(16)
  }
}

// MARK: - Columns

/// The first step: what each column is, on the first rows of the file.
struct MigrationColumnsStep: View {
  let model: MigrationModel

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { MigrationText.t(key, environment) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          Image(systemName: "doc.text").accessibilityHidden(true)
          Text(verbatim: model.fileName).lineLimit(1).truncationMode(.middle)
          Text(verbatim: "·").foregroundStyle(.secondary)
          Text(verbatim: MigrationText.source(model.mapping.source, environment))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("migration.source")
        }
        .appFont(.callout)
        if model.usedLegacyEncoding {
          Text(verbatim: t("migration.legacyEncoding")).appFont(.caption)
            .foregroundStyle(.secondary)
        }
        Text(verbatim: t("migration.columns.hint")).appFont(.callout).foregroundStyle(.secondary)
        if let table = model.table {
          columns(table)
        }
        if model.mapping.column(.date) != nil {
          Picker(
            selection: Binding(
              get: { model.mapping.dateOrder }, set: { model.setDateOrder($0) })
          ) {
            Text(verbatim: t("migration.dateOrder.dayFirst")).tag(MigrationDates.Order.dayFirst)
            Text(verbatim: t("migration.dateOrder.monthFirst")).tag(
              MigrationDates.Order.monthFirst)
          } label: {
            Text(verbatim: t("migration.dateOrder"))
          }
          .frame(maxWidth: 360)
          .accessibilityIdentifier("migration.dateOrder")
        }
        if !model.mapping.isComplete {
          Label(t("migration.columns.incomplete"), systemImage: "exclamationmark.triangle")
            .appFont(.callout)
            .accessibilityIdentifier("migration.columns.incomplete")
        } else {
          Text(verbatim: readSummary)
            .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
            .accessibilityIdentifier("migration.columns.read")
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var readSummary: String {
    let parse = model.parse
    return MigrationText.counted(
      "migration.columns.read", environment, parse.operations.count, parse.unparsed.count)
  }

  /// A column a line: its name, the role picker, and what the first rows hold in it.
  private func columns(_ table: MigrationTable) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(table.header.enumerated()), id: \.offset) { index, name in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: name.isEmpty ? "—" : name)
            .lineLimit(1)
            .frame(width: 180, alignment: .leading)
          Picker(
            selection: Binding(
              get: { model.mapping.roles[index] },
              set: { model.setRole($0, column: index) })
          ) {
            Text(verbatim: MigrationText.role(nil, environment)).tag(MigrationRole?.none)
            ForEach(MigrationRole.allCases, id: \.self) { role in
              Text(verbatim: MigrationText.role(role, environment)).tag(MigrationRole?.some(role))
            }
          } label: {
            EmptyView()
          }
          .labelsHidden()
          .frame(width: 200)
          .accessibilityIdentifier("migration.role.\(index)")
          Text(verbatim: sample(table, column: index))
            .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
  }

  private func sample(_ table: MigrationTable, column: Int) -> String {
    table.rows.prefix(3).map { table.cell($0, column) }.filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}

// MARK: - Accounts and categories

/// The second step: which own account each of the other application's accounts goes to, and
/// which own category each of its categories goes to. New categories only when the person says.
struct MigrationPairingStep: View {
  let model: MigrationModel

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { MigrationText.t(key, environment) }

  var body: some View {
    Form {
      Section {
        ForEach(accountNames, id: \.self) { name in
          Picker(
            selection: Binding(
              get: { model.account(for: name) }, set: { model.setAccount($0, for: name) })
          ) {
            Text(verbatim: t("migration.account.skip")).tag(UUID?.none)
            ForEach(model.accounts) { account in
              Text(verbatim: account.name).tag(UUID?.some(account.id))
            }
          } label: {
            Text(verbatim: name.isEmpty ? t("migration.account.unnamed") : name)
          }
          .accessibilityIdentifier("migration.account")
        }
      } header: {
        Text(verbatim: t("migration.accounts"))
      } footer: {
        Text(verbatim: t("migration.accounts.footer"))
      }
      Section {
        if model.parse.categories.isEmpty {
          Text(verbatim: t("migration.categories.none")).foregroundStyle(.secondary)
        }
        ForEach(model.parse.categories, id: \.id) { key in
          categoryRow(key)
        }
        if !model.unmatchedCategories.isEmpty {
          Button {
            model.createAllUnmatched()
          } label: {
            Label(
              MigrationText.counted(
                "migration.categories.createAll", environment, model.unmatchedCategories.count),
              systemImage: "folder.badge.plus")
          }
          .accessibilityIdentifier("migration.categories.createAll")
        }
      } header: {
        Text(verbatim: t("migration.categories"))
      } footer: {
        Text(verbatim: t("migration.categories.footer"))
      }
    }
    .formStyle(.grouped)
  }

  private var accountNames: [String] {
    let names = model.parse.accountNames
    return names.isEmpty ? [""] : names
  }

  /// The target of one category: an own category of its kind, a new one under its name, or
  /// «Не разобрано».
  private func categoryRow(_ key: MigrationCategoryKey) -> some View {
    Picker(
      selection: Binding(get: { model.target(for: key) }, set: { model.setTarget($0, for: key) })
    ) {
      Text(verbatim: t("migration.category.unsorted")).tag(MigrationCategoryTarget.unsorted)
      Text(verbatim: MigrationText.format("migration.category.create", environment, key.title))
        .tag(MigrationCategoryTarget.create)
      Divider()
      ForEach(model.categoryChoices(key.kind), id: \.id) { choice in
        Text(verbatim: choice.title).tag(MigrationCategoryTarget.existing(choice.id))
      }
    } label: {
      Label {
        Text(verbatim: key.title)
      } icon: {
        Image(systemName: key.kind == .income ? "arrow.up.circle" : "arrow.down.circle")
          .accessibilityLabel(
            Text(
              verbatim: t(key.kind == .income ? "migration.kind.income" : "migration.kind.expense"))
          )
      }
    }
    .accessibilityIdentifier("migration.category")
  }
}

// MARK: - Preview

/// The last step: how many operations, over which days, how many are there already or look like
/// something typed by hand, what cannot be moved, and the lines themselves.
struct MigrationPreviewStep: View {
  let model: MigrationModel

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { MigrationText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      facts
        .padding(16)
      Divider()
      List {
        ForEach(Array(model.parse.operations.enumerated().prefix(500)), id: \.offset) {
          index, line in
          row(index, line)
        }
        if model.parse.operations.count > 500 {
          Text(
            verbatim: MigrationText.counted(
              "migration.preview.more", environment, model.parse.operations.count - 500)
          )
          .foregroundStyle(.secondary)
        }
      }
      .listStyle(.inset)
      .accessibilityIdentifier("migration.rows")
    }
  }

  private var facts: some View {
    let preview = model.preview
    let parse = model.parse
    return VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: MigrationText.counted("migration.preview.total", environment, model.toWrite))
        .appFont(.headline)
        .accessibilityIdentifier("migration.preview.total")
      if let period = parse.period {
        Text(
          verbatim: MigrationText.format(
            "migration.preview.period", environment, environment.dates.longDay(period.from),
            environment.dates.longDay(period.to)))
      }
      fact("migration.preview.duplicates", preview.count(.duplicate), "equal")
      fact("migration.preview.likely", preview.count(.likelyDuplicate), "questionmark.circle")
      if preview.count(.likelyDuplicate) > 0 {
        Toggle(
          t("migration.preview.likely.include"),
          isOn: Binding(
            get: { model.includesLikelyDuplicates }, set: { model.includeLikelyDuplicates($0) }))
      }
      fact("migration.preview.rate", preview.count(.waitingForRate), "hourglass")
      fact("migration.preview.transfers", parse.transfers, "arrow.left.arrow.right")
      fact("migration.preview.unparsed", parse.unparsed.count, "exclamationmark.triangle")
      Label(t("migration.preview.backup"), systemImage: "externaldrive.badge.checkmark")
        .appFont(.callout).foregroundStyle(.secondary)
    }
    .monospacedDigit()
  }

  @ViewBuilder
  private func fact(_ key: String, _ count: Int, _ symbol: String) -> some View {
    if count > 0 {
      Label(MigrationText.counted(key, environment, count), systemImage: symbol)
        .appFont(.callout)
    }
  }

  private func row(_ index: Int, _ line: MigrationOperation) -> some View {
    let operation = line.operation
    let disposition =
      model.preview.dispositions.indices.contains(index)
      ? model.preview.dispositions[index] : .new
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { model.ticks.contains(index) },
          set: { on in
            if on { model.ticks.insert(index) } else { model.ticks.remove(index) }
          })
      ) {
        EmptyView()
      }
      .labelsHidden()
      .disabled(disposition == .waitingForRate)
      Text(verbatim: environment.dates.longDay(operation.moment.day))
        .frame(width: 110, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: operation.description).lineLimit(1)
        Text(
          verbatim: [line.category?.title, operation.accountRef].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        )
        .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if disposition != .new {
        Text(verbatim: t("migration.disposition.\(disposition.key)"))
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Text(verbatim: amount(operation)).monospacedDigit()
    }
  }

  private func amount(_ operation: ImportedOperation) -> String {
    let sign = operation.amount.isNegative ? "\u{2212}" : "+"
    return sign + environment.money.exact(operation.amount.magnitude, currency: operation.currency)
  }
}

extension MigrationPreview.Disposition {
  /// The end of the key of its word in the catalog.
  var key: String {
    switch self {
    case .new: "new"
    case .duplicate: "duplicate"
    case .likelyDuplicate: "likely"
    case .waitingForRate: "rate"
    }
  }
}
