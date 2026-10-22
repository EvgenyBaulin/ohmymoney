import AppCore
import SwiftUI

/// The second step: the lines of one file, each with its tick and what loading it would do —
/// new, already there, changing something that is there. Lines the file could not read are
/// listed after them with the money they carry, so nothing disappears quietly.
struct StatementRowsStep: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all, new, changed, duplicates, unparsed
    var id: String { rawValue }
    var titleKey: String { "import.filter.\(rawValue)" }
  }

  let model: StatementImportModel

  @Dependency(\.environment) private var environment
  @State private var fileID: Int?
  @State private var filter: Filter = .all
  @Environment(\.horizontalSizeClass) private var sizeClass

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  private var file: StatementImportModel.LoadedFile? {
    model.files.first { $0.id == fileID } ?? model.files.first { $0.preview != nil }
  }

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      if let file, let preview = file.preview {
        list(file: file, preview: preview)
      } else {
        Text(verbatim: t("import.rows.noAccount"))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        if model.files.count > 1 {
          Picker(selection: Binding(get: { file?.id }, set: { fileID = $0 })) {
            ForEach(model.files.filter { $0.preview != nil }) { file in
              Text(verbatim: file.name).tag(Optional(file.id))
            }
          } label: {
            Text(verbatim: t("import.file"))
          }
          .frame(maxWidth: 280)
        }
        Spacer()
        if let file {
          Button(t("import.tickAll")) { model.tickAll(true, file: file.id) }
          Button(t("import.tickNone")) { model.tickAll(false, file: file.id) }
        }
      }
      .buttonStyle(.link)
      // Five words in one segmented control do not fit a phone: a menu there.
      filterPicker
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var filterPicker: some View {
    let picker = Picker(selection: $filter) {
      ForEach(Filter.allCases) { filter in
        Text(verbatim: t(filter.titleKey)).tag(filter)
      }
    } label: {
      Text(verbatim: t("import.filter.label"))
    }
    .accessibilityIdentifier("import.filter")
    if sizeClass == .compact {
      picker.pickerStyle(.menu)
    } else {
      picker.pickerStyle(.segmented).labelsHidden()
    }
  }

  @ViewBuilder
  private func list(
    file: StatementImportModel.LoadedFile, preview: StatementPreview
  ) -> some View {
    let rows = preview.rows.filter { matches($0.disposition) }
    List {
      if filter == .unparsed {
        ForEach(preview.unparsed, id: \.sourceIndex) { line in
          unparsedRow(line)
        }
        if preview.unparsed.isEmpty {
          Text(verbatim: t("import.rows.noneUnparsed")).foregroundStyle(.secondary)
        }
      } else {
        ForEach(rows) { row in
          StatementRowView(model: model, file: file, row: row)
        }
        if rows.isEmpty {
          Text(verbatim: t("import.rows.none")).foregroundStyle(.secondary)
        }
      }
    }
    .listStyle(.inset)
    .accessibilityIdentifier("import.rows")
  }

  private func matches(_ disposition: StatementRowDisposition) -> Bool {
    switch filter {
    case .all: true
    case .new: disposition == .new
    case .changed: disposition.isChange
    case .duplicates: disposition == .duplicate
    case .unparsed: false
    }
  }

  private func unparsedRow(_ line: StatementUnparsedLine) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Image(systemName: "questionmark.diamond").foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: ImportText.format("import.unparsed.line", environment, line.sourceIndex + 1))
        Text(verbatim: t("import.unparsed.reason.\(line.reason.rawValue)"))
          .appFont(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      if let amount = line.amount {
        Text(verbatim: environment.money.exact(amount)).monospacedDigit()
      }
    }
    .accessibilityIdentifier("import.unparsed")
  }
}

/// One line of the preview.
struct StatementRowView: View {
  let model: StatementImportModel
  let file: StatementImportModel.LoadedFile
  let row: StatementPreviewRow

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { ImportText.t(key, environment) }
  private var ref: StatementRowRef { StatementRowRef(file: file.id, row: row.index) }

  var body: some View {
    let operation = row.operation
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Toggle(isOn: tick) {
        EmptyView()
      }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(row.disposition == .duplicate || model.isKnownTransfer(ref))
      .accessibilityIdentifier("import.row.tick")
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(verbatim: title(operation)).lineLimit(1)
          Spacer(minLength: 8)
          Text(verbatim: amount(operation))
            .monospacedDigit()
            .foregroundStyle(operation.amount.isNegative ? Color.primary : Color.green)
        }
        HStack(spacing: 10) {
          Text(verbatim: when(operation))
            .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
          disposition
          if let filing = model.filing(of: ref) {
            Label(
              filing.text, systemImage: filing.isUnsorted ? "tray" : "folder"
            )
            .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          if row.isOwnTransfer {
            Label(t("import.row.ownTransfer"), systemImage: "arrow.left.arrow.right")
              .appFont(.caption).foregroundStyle(.secondary)
          }
          if operation.status == .pending {
            Label(t("import.row.pending"), systemImage: "hourglass")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        }
        if case .manualAsk(let candidates) = row.disposition {
          candidatePicker(candidates)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import.row")
  }

  private var tick: Binding<Bool> {
    Binding(
      get: { file.ticks.contains(row.index) && !model.isKnownTransfer(ref) },
      set: { model.setTicked($0, row: row.index, file: file.id) })
  }

  private func title(_ operation: ImportedOperation) -> String {
    operation.merchant ?? operation.counterparty.name ?? operation.counterparty.phone
      ?? operation.description
  }

  private func amount(_ operation: ImportedOperation) -> String {
    let sign = operation.amount.isNegative ? "\u{2212}" : "+"
    return sign + environment.money.exact(operation.amount.magnitude, currency: operation.currency)
  }

  private func when(_ operation: ImportedOperation) -> String {
    var text = environment.dates.longDay(operation.moment.day)
    if let minute = operation.moment.minuteOfDay {
      text += String(format: " %02d:%02d", minute / 60, minute % 60)
    }
    return text
  }

  /// The word and the symbol of what the line does; the meaning never rests on colour.
  @ViewBuilder
  private var disposition: some View {
    if model.isKnownTransfer(ref) {
      Label(t("import.row.knownTransfer"), systemImage: "equal.circle")
    } else {
      dispositionLabel
    }
  }

  @ViewBuilder
  private var dispositionLabel: some View {
    switch row.disposition {
    case .new:
      Label(t("import.row.new"), systemImage: "plus.circle")
    case .duplicate:
      Label(t("import.row.duplicate"), systemImage: "equal.circle")
    case .statusUpgrade:
      Label(t("import.row.posted"), systemImage: "checkmark.circle")
    case .heldReplacement:
      Label(t("import.row.replaces"), systemImage: "arrow.triangle.2.circlepath")
    case .manualMerge:
      Label(t("import.row.merges"), systemImage: "link")
    case .manualAsk:
      Label(t("import.row.asks"), systemImage: "questionmark.circle")
    }
  }

  @ViewBuilder
  private func candidatePicker(_ candidates: [String]) -> some View {
    Picker(
      selection: Binding(
        get: { file.manualPicks[row.index] },
        set: { model.pick($0, row: row.index, file: file.id) })
    ) {
      Text(verbatim: t("import.row.asks.none")).tag(String?.none)
      ForEach(candidates, id: \.self) { id in
        Text(verbatim: candidateTitle(id)).tag(String?.some(id))
      }
    } label: {
      Text(verbatim: t("import.row.asks.pick")).appFont(.caption)
    }
    .pickerStyle(.menu)
    .appFont(.caption)
    .accessibilityIdentifier("import.row.pick")
  }

  private func candidateTitle(_ id: String) -> String {
    guard let entry = model.handEntry(id) else { return id }
    let transaction = entry.transaction
    let day = environment.dates.longDay(
      environment.calendar.day(of: transaction.occurredAt))
    let words = (transaction.note ?? "").trimmingCharacters(in: .whitespaces)
    let money = environment.money.exact(transaction.amountE4, currency: transaction.currency)
    return [day, words, money].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
