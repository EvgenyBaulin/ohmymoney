import AppCore
import AppDatabase
import SwiftUI

/// The words of the check of the database: when it ran, what it found, what the repair asks.
enum IntegrityText {
  static let table = "Settings"

  /// «Проверено 20 окт. 2026 · Всё в порядке: 4 812 операций, 7 счетов», or how many rows are
  /// wrong, or that no check has run yet.
  @MainActor
  static func status(
    _ record: IntegrityCheckService.Record?, in environment: AppEnvironment
  )
    -> String
  {
    guard let record else { return environment.language("integrity.never", table: table) }
    let when = record.checkedAt.formatted(
      .dateTime.day().month(.abbreviated).year().locale(environment.language.locale))
    let head = environment.format("integrity.last", table: table, when)
    let report = record.report
    guard report.isHealthy else {
      return head + " · "
        + environment.format("integrity.problems", table: table, counts: report.problemCount)
    }
    return head + " · " + environment.language("integrity.ok", table: table) + ": "
      + environment.format("integrity.ok.operations", table: table, counts: report.operations)
      + ", "
      + environment.format("integrity.ok.accounts", table: table, counts: report.accounts)
  }

  /// One finding: what it is, how many rows, and whether «Исправить» would touch it.
  @MainActor
  static func finding(_ finding: DatabaseCheck.Finding, in environment: AppEnvironment) -> String {
    let title =
      finding.rule == .foreignKeys
      ? environment.format(
        "integrity.finding.foreignKeys", table: table, finding.table ?? "—")
      : environment.language("integrity.finding.\(finding.rule.rawValue)", table: table)
    let fate = environment.language(
      finding.isRepairable ? "integrity.finding.repairable" : "integrity.finding.reportOnly",
      table: table)
    return "\(title) — \(finding.count) · \(fate)"
  }

  @MainActor
  static func repairMessage(rows: Int, in environment: AppEnvironment) -> String {
    environment.format("integrity.repair.message", table: table, counts: rows)
  }

  /// What to tell the owner when the repair is over.
  @MainActor
  static func outcome(
    _ outcome: IntegrityCheckService.Repair, in environment: AppEnvironment
  )
    -> String
  {
    switch outcome {
    case .repaired(let removed):
      environment.format("integrity.repair.done", table: table, counts: removed)
    case .noCopy: environment.language("integrity.repair.noCopy", table: table)
    case .failed: environment.language("integrity.repair.failed", table: table)
    }
  }
}

/// «Проверка базы» of the Backups tab: the last result, «Проверить сейчас», and — when something
/// is wrong — what was found, «Исправить…» for the safe part and the report of the problem.
struct IntegritySettingsSection: View {
  @Dependency(\.environment) private var environment
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  @State private var asking = false
  @State private var outcome: String?

  var body: some View {
    Section {
      if let service = environment.integrity {
        content(service)
      }
    } header: {
      Text(verbatim: environment.language("integrity.heading", table: "Settings"))
    }
    .alert(
      environment.language("integrity.repair.title", table: "Settings"), isPresented: $asking
    ) {
      Button(environment.language("backups.freeUp.no", table: "Settings"), role: .cancel) {}
      Button(environment.language("integrity.repair.yes", table: "Settings"), role: .destructive) {
        repair()
      }
    } message: {
      Text(
        verbatim: IntegrityText.repairMessage(
          rows: environment.integrity?.record?.report.repairableCount ?? 0, in: environment))
    }
    .alert(
      outcome ?? "",
      isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
    ) {
      Button(environment.language("action.ok")) { outcome = nil }
    }
  }

  @ViewBuilder
  private func content(_ service: IntegrityCheckService) -> some View {
    Text(verbatim: IntegrityText.status(service.record, in: environment))
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("integrity.status")
    if let report = service.record?.report, !report.isHealthy {
      ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
        Label {
          Text(verbatim: IntegrityText.finding(finding, in: environment))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
      }
    }
    HStack(spacing: 12) {
      Button(
        environment.language(
          service.isRunning ? "integrity.checking" : "integrity.check", table: "Settings")
      ) {
        Task { await service.check() }
      }
      .disabled(service.isRunning || service.isRepairing)
      if let report = service.record?.report, report.hasRepairs {
        Button(environment.language("integrity.repair", table: "Settings")) { asking = true }
          .disabled(service.isRunning || service.isRepairing)
      }
      #if os(macOS)
        if let report = service.record?.report, !report.isHealthy {
          Button(environment.language("integrity.report", table: "Settings")) {
            HelpCommands.collectReport(environment) { openSettings() }
          }
        }
      #else
        if let report = service.record?.report, !report.isHealthy {
          Button(environment.language("integrity.report", table: "Settings")) {
            environment.showsProblemReport = true
          }
        }
      #endif
    }
  }

  private func repair() {
    guard let service = environment.integrity else { return }
    Task {
      let result = await service.repair()
      outcome = IntegrityText.outcome(result, in: environment)
    }
  }
}
