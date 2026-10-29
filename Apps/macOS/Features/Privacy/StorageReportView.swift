import AppCore
import SwiftUI

/// «Что знает приложение»: what is kept, how much of it, and where it lies. Only a display of
/// what is already there -- counts and sizes read from the database and the disk, never a name or
/// an amount. Nothing on this screen changes anything.
struct StorageReportView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var report: StorageReport?
  @State private var places: StorageLocations?
  /// Shown as a sheet it has a way out; inside the settings it does not need one.
  var closes = true

  private static let table = "PrivacyExport"
  private func t(_ key: String) -> String { environment.language(key, table: Self.table) }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        if let report {
          Section {
            ForEach(report.lines, id: \.section) { line in
              LabeledContent {
                Text(verbatim: value(of: line)).monospacedDigit()
              } label: {
                Text(verbatim: t(line.key))
              }
              .accessibilityIdentifier("privacy.storage.\(line.section)")
            }
            LabeledContent {
              Text(verbatim: sizeText(report.totalSize)).monospacedDigit()
            } label: {
              Text(verbatim: t(StorageReport.totalKey)).fontWeight(.semibold)
            }
          } header: {
            Text(verbatim: t("privacy.storage.title")).settingsHeaderStyle()
          } footer: {
            Text(verbatim: t("privacy.storage.footer"))
              .appFont(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !report.tables.isEmpty {
            Section {
              DisclosureGroup(t("privacy.storage.tables")) {
                ForEach(report.tables, id: \.name) { table in
                  LabeledContent {
                    Text(verbatim: "\(table.rows)").monospacedDigit()
                  } label: {
                    Text(verbatim: table.name).appFont(.callout.monospaced())
                  }
                }
              }
            }
          }
          if let places {
            Section {
              place("privacy.storage.where.data", places.dataFolder)
              if let backups = places.backupsFolder {
                place("privacy.storage.where.backups", backups)
              }
              if let mirror = places.mirrorFolder { place("privacy.storage.where.mirror", mirror) }
            } header: {
              Text(verbatim: t("privacy.storage.where")).settingsHeaderStyle()
            } footer: {
              Text(verbatim: t("privacy.storage.where.footer"))
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        } else {
          ProgressView().frame(maxWidth: .infinity)
        }
      }
      .formStyle(.grouped)
      if closes {
        HStack {
          Spacer()
          Button(environment.language("action.close")) { dismiss() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("privacy.storage.close")
        }
        .padding(16)
      }
    }
    .frame(minWidth: 460, minHeight: 420)
    .task {
      report = StorageReport(await StorageFactsReader.read(environment))
      places = await StorageLocations.read(environment)
    }
    .accessibilityIdentifier("privacy.storage.sheet")
  }

  private func place(_ key: String, _ path: String) -> some View {
    LabeledContent {
      Text(verbatim: path)
        .appFont(.callout.monospaced())
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    } label: {
      Text(verbatim: t(key))
    }
  }

  /// «12 files · 3.4 MB» for a line with a count and a size, either alone for a line with one.
  private func value(of line: StorageReport.Line) -> String {
    var parts: [String] = []
    if let count = line.count {
      parts.append(environment.format(countKey(of: line.section), table: Self.table, counts: count))
    }
    if let size = line.size { parts.append(sizeText(size)) }
    return parts.joined(separator: " · ")
  }

  private func countKey(of section: StorageReport.Section) -> String {
    switch section {
    case .records: "privacy.storage.count.records"
    case .database: "privacy.storage.count.records"
    case .attachments: "privacy.storage.count.files"
    case .backups: "privacy.storage.count.copies"
    case .journal: "privacy.storage.count.lines"
    }
  }

  /// «3.4 МБ»: the point is the point on both languages, the unit is the catalog's.
  private func sizeText(_ size: StorageSize) -> String {
    size.number + " " + t(size.unit.rawValue)
  }
}
