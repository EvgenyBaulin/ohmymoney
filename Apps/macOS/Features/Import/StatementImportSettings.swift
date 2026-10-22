import AppCore
import AppDatabase
import SwiftUI

/// Settings → Счета → «Выписки»: load a statement, say who you are in the statements, and the
/// list of what was loaded with «Отменить загрузку» for each (the operations nobody has touched
/// since go to the bin; the ones that were edited stay).
struct StatementImportSettingsRows: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @State private var imports: [StoredImport] = []
  @State private var identity = StatementIdentity()
  @State private var loading = false
  @State private var editsIdentity = false
  @State private var undoing: StoredImport?
  @State private var failed = false

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    Group {
      Button {
        loading = true
      } label: {
        Label(t("import.settings.load"), systemImage: "tray.and.arrow.down")
      }
      .accessibilityIdentifier("import.settings.load")
      Button {
        editsIdentity = true
      } label: {
        Label(t("import.identity.open"), systemImage: "person.crop.circle")
      }
      .accessibilityIdentifier("import.settings.identity")
      if imports.isEmpty {
        Text(verbatim: t("import.history.empty"))
          .appFont(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("import.history.empty")
      }
      ForEach(imports) { stored in
        historyRow(stored)
      }
      if failed {
        Label(t("import.history.failed"), systemImage: "exclamationmark.octagon")
          .foregroundStyle(.red)
      }
    }
    .task(id: compute.generation) { reload() }
    .sheet(isPresented: $loading, onDismiss: reload) {
      StatementImportFlow(urls: []).handingOver(dependencies)
    }
    .sheet(isPresented: $editsIdentity) {
      StatementIdentitySheet(identity: identity) { new in
        let saved = store.saveIdentity(new)
        if saved { identity = new }
        return saved
      }
      .handingOver(dependencies)
    }
    .confirmationDialog(
      t("import.history.undo.title"),
      isPresented: Binding(
        get: { undoing != nil }, set: { if !$0 { undoing = nil } }),
      titleVisibility: .visible, presenting: undoing
    ) { stored in
      Button(t("import.history.undo"), role: .destructive) {
        failed = !store.undoImport(id: stored.id)
        reload()
      }
    } message: { _ in
      Text(verbatim: t("import.history.undo.message"))
    }
  }

  private func reload() {
    imports = (try? environment.statementImports?.imports()) ?? []
    identity = (try? environment.statementImports?.identity()) ?? StatementIdentity()
  }

  private func historyRow(_ stored: StoredImport) -> some View {
    let record = stored.record
    let account = compute.snapshot?.dataset.paymentMethods.first {
      $0.id.uuidString == record.accountID
    }?.name
    return HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: record.fileName.isEmpty ? t("import.history.unnamed") : record.fileName)
          .lineLimit(1).truncationMode(.middle)
        Text(verbatim: details(record, account: account))
          .appFont(.caption).foregroundStyle(.secondary)
        if stored.isUndone {
          Label(t("import.history.undone"), systemImage: "arrow.uturn.backward.circle")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if !stored.isUndone {
        Button(t("import.history.undo")) { undoing = stored }
          .buttonStyle(.link)
          .disabled(store.isWritingInBackground)
          .accessibilityIdentifier("import.history.undo")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import.history.row")
  }

  private func details(_ record: StatementImportRecord, account: String?) -> String {
    var parts: [String] = []
    if let account { parts.append(account) }
    if let from = record.periodFrom, let to = record.periodTo {
      parts.append("\(environment.dates.longDay(from)) – \(environment.dates.longDay(to))")
    }
    parts.append(
      ImportText.format(
        "import.history.counts", environment, record.newCount, record.duplicateCount))
    parts.append(environment.dates.longDay(environment.calendar.day(of: record.importedAt)))
    return parts.joined(separator: " · ")
  }
}
