import AppCore
import AppDatabase
import SwiftUI

/// «Сравнить с текущей»: what a copy holds against what the database holds now — counts,
/// the money on each account, the categories, the operations added and vanished since the copy,
/// and the ones changed folded into one line that opens to «было → стало». The copy is opened
/// read-only and the database only read: nothing is written to either.
struct BackupComparisonSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  /// What is compared with the database: the name shown, and how the other side is read.
  let title: String
  let compare: @Sendable (Dataset) throws -> BackupComparison

  /// A copy of the folder of copies.
  init(item: BackupList.Item) {
    let url = item.url
    title = url.lastPathComponent
    compare = { current in try BackupComparison.of(copyAt: url, with: current) }
  }

  /// Any other side, such as an archive of the transfer (`ArchiveComparison`).
  init(title: String, compare: @escaping @Sendable (Dataset) throws -> BackupComparison) {
    self.title = title
    self.compare = compare
  }

  private enum Phase {
    case loading
    /// The key of the words that say why, in the Settings catalog.
    case failed(String)
    case ready(BackupComparison)
  }

  @State private var phase = Phase.loading
  static let failedKey = "backups.compare.failed"

  /// Why the comparison stopped, in words: a wrong password is told apart from a file that cannot
  /// be read.
  static func failureKey(of error: Error) -> String {
    if let core = error as? CoreError, core == .invalidArchive(reason: .wrongPassword) {
      return "backups.compareArchive.wrongPassword"
    }
    return failedKey
  }

  /// The longest list of operations drawn; the rest is counted.
  static let shownLimit = 200

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.language("backups.compare.title", table: "Settings"))
        .appFont(.headline)
      Text(verbatim: title)
        .appFont(.caption.monospaced())
        .foregroundStyle(.secondary)
      switch phase {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 80)
      case .failed(let key):
        Text(verbatim: environment.language(key, table: "Settings"))
          .foregroundStyle(.secondary)
      case .ready(let comparison):
        ScrollView { content(comparison).frame(maxWidth: .infinity, alignment: .leading) }
      }
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 520, minHeight: 420)
    .task { await load() }
  }

  private func load() async {
    guard let stack = environment.stack else {
      phase = .failed(Self.failedKey)
      return
    }
    let compare = self.compare
    do {
      let current = try await DatasetRepository(writer: stack.writer).load(version: 0)
      let result = try await Task.detached(priority: .userInitiated) {
        try compare(current)
      }.value
      phase = .ready(result)
    } catch {
      AppLog.warning(
        "backup.compareFailed", .backup, "a copy could not be compared with the database",
        [LogPair("error", .error(error))])
      phase = .failed(Self.failureKey(of: error))
    }
  }

  @ViewBuilder
  private func content(_ comparison: BackupComparison) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if comparison.isIdentical {
        Label(
          environment.language("backups.compare.identical", table: "Settings"),
          systemImage: "equal.circle")
      }
      Text(
        verbatim: environment.format(
          "backups.compare.operations", table: "Settings", counts: comparison.operationsInCopy,
          comparison.operationsNow))
      Text(
        verbatim: environment.format(
          "backups.compare.categories", table: "Settings", counts: comparison.categoriesInCopy,
          comparison.categoriesNow))
      if !comparison.categoriesAdded.isEmpty {
        Text(
          verbatim: environment.language("backups.compare.categoriesAdded", table: "Settings")
            + " " + comparison.categoriesAdded.joined(separator: ", ")
        )
        .appFont(.callout)
      }
      if !comparison.categoriesVanished.isEmpty {
        Text(
          verbatim: environment.language("backups.compare.categoriesVanished", table: "Settings")
            + " " + comparison.categoriesVanished.joined(separator: ", ")
        )
        .appFont(.callout)
      }
      if !comparison.balances.isEmpty {
        Text(verbatim: environment.language("backups.compare.balances", table: "Settings"))
          .appFont(.subheadline.weight(.semibold))
        ForEach(Array(comparison.balances.enumerated()), id: \.offset) { _, row in
          balance(row)
        }
      }
      operations(
        "backups.compare.added", comparison.added)
      operations("backups.compare.vanished", comparison.vanished)
      if !comparison.changed.isEmpty {
        DisclosureGroup(
          environment.format(
            "backups.compare.changed", table: "Settings", counts: comparison.changed.count)
        ) {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(comparison.changed.prefix(Self.shownLimit).enumerated()), id: \.offset) {
              _, change in
              VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: describe(change.was)).foregroundStyle(.secondary)
                Text(verbatim: "→ " + describe(change.now))
              }
              .appFont(.callout)
            }
            rest(comparison.changed.count)
          }
        }
      }
    }
  }

  private func balance(_ row: BackupComparison.BalanceRow) -> some View {
    let code = CurrencyCode(row.currency)
    func text(_ value: Int64?) -> String {
      value.map { environment.money.exact(AmountE4(raw: $0), currency: code) } ?? "—"
    }
    let line =
      row.isDifferent
      ? "\(row.account): \(text(row.copyE4)) → \(text(row.currentE4))"
      : "\(row.account): \(text(row.currentE4))"
    return Text(verbatim: line).appFont(.callout.monospacedDigit())
  }

  @ViewBuilder
  private func operations(_ key: String, _ list: [BackupSnapshot.Operation]) -> some View {
    if !list.isEmpty {
      DisclosureGroup(environment.format(key, table: "Settings", counts: list.count)) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(list.prefix(Self.shownLimit).enumerated()), id: \.offset) { _, operation in
            Text(verbatim: describe(operation)).appFont(.callout)
          }
          rest(list.count)
        }
      }
    }
  }

  @ViewBuilder
  private func rest(_ count: Int) -> some View {
    if count > Self.shownLimit {
      Text(
        verbatim: environment.format(
          "backups.compare.more", table: "Settings", counts: count - Self.shownLimit)
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }

  /// «6 окт. 2026 · Кофе · Еда · −250 ₽» — the day, the note, the categories, the amount.
  private func describe(_ operation: BackupSnapshot.Operation) -> String {
    let day = operation.occurredAt.formatted(
      .dateTime.day().month(.abbreviated).year().locale(environment.language.locale))
    let sign = operation.kind == "expense" ? "−" : ""
    let amount =
      sign
      + environment.money.exact(
        AmountE4(raw: operation.amountE4), currency: CurrencyCode(operation.currency))
    let names = operation.categoryNames.filter { !$0.isEmpty }
    return ([day, operation.note ?? ""] + [names.joined(separator: ", "), amount])
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
