import AppCore
import CoreKit
import SwiftUI

/// The words of the journal of openings. A line carries a token and a moment, nothing else; the
/// sentence is the catalog's.
enum PrivacyJournalText {
  /// The key (table `PrivacyExport`) of what a line says.
  static func key(for event: PrivacyJournalEntry.Event) -> String {
    switch event {
    case .opened: "privacy.journal.event.opened"
    case .unlocked(let method):
      switch method {
      case .touchID: "privacy.journal.event.unlockedTouchID"
      case .password: "privacy.journal.event.unlockedPassword"
      }
    case .locked: "privacy.journal.event.locked"
    case .hiddenShown: "privacy.journal.event.hiddenShown"
    case .exportedCopy: "privacy.journal.event.exportedCopy"
    case .readOnlyOn: "privacy.journal.event.readOnlyOn"
    case .readOnlyOff: "privacy.journal.event.readOnlyOff"
    }
  }

  /// The terms the owner may pick, in days: a month, a quarter, half a year, a year (the default),
  /// two years, five years. A term set some other way is listed as well, so the picker shows it.
  static let terms = [30, 90, 180, 365, 730, 1825]

  static func choices(including current: Int) -> [Int] {
    terms.contains(current) ? terms : (terms + [current]).sorted()
  }
}

/// «Журнал открытий»: when the app was opened, locked, unlocked, when the hidden accounts were
/// shown and when a copy was made -- newest first, kept on this Mac only. Lines older than the
/// term the owner picked are cut away.
struct PrivacyJournalView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var entries: [PrivacyJournalEntry] = []
  @State private var days = 365
  @State private var confirmsClear = false
  /// Shown as a sheet it has a way out; inside the settings it does not need one.
  var closes = true

  private static let table = "PrivacyExport"
  private func t(_ key: String) -> String { environment.language(key, table: Self.table) }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          Picker(t("privacy.journal.keep"), selection: termBinding) {
            ForEach(PrivacyJournalText.choices(including: days), id: \.self) { term in
              Text(
                verbatim: environment.format(
                  "privacy.journal.term", table: Self.table, counts: term)
              )
              .tag(term)
            }
          }
          .accessibilityIdentifier("privacy.journal.keep")
        } header: {
          Text(verbatim: t("privacy.journal.title")).settingsHeaderStyle()
        } footer: {
          Text(verbatim: t("privacy.journal.footer"))
            .appFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Section {
          if entries.isEmpty {
            Text(verbatim: t("privacy.journal.empty")).foregroundStyle(.secondary)
          } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
              LabeledContent {
                Text(verbatim: moment(entry.at)).monospacedDigit().foregroundStyle(.secondary)
              } label: {
                Text(verbatim: t(PrivacyJournalText.key(for: entry.event)))
              }
            }
          }
        }
        Section {
          Button(role: .destructive) {
            confirmsClear = true
          } label: {
            Text(verbatim: t("privacy.journal.clear"))
          }
          .disabled(entries.isEmpty)
          .accessibilityIdentifier("privacy.journal.clear")
        }
      }
      .formStyle(.grouped)
      if closes {
        HStack {
          Spacer()
          Button(environment.language("action.close")) { dismiss() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("privacy.journal.close")
        }
        .padding(16)
      }
    }
    .frame(minWidth: 420, minHeight: 380)
    .onAppear { load() }
    .confirmationDialog(
      t("privacy.journal.clear.title"), isPresented: $confirmsClear, titleVisibility: .visible
    ) {
      Button(t("privacy.journal.clear.action"), role: .destructive) {
        environment.privacyJournal.clear()
        load()
      }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: {
      Text(verbatim: t("privacy.journal.clear.body"))
    }
    .accessibilityIdentifier("privacy.journal.sheet")
  }

  private func load() {
    days = environment.privacy.journalDays
    entries = environment.privacyJournal.entries()
  }

  private var termBinding: Binding<Int> {
    Binding(
      get: { days },
      set: { value in
        days = value
        var settings = environment.privacy
        settings.journalDays = value
        try? environment.privacySettings?.save(settings)
        environment.refreshPrivacySettings()
        entries = environment.privacyJournal.entries()
      })
  }

  private func moment(_ date: Date) -> String {
    date.formatted(
      .dateTime.day().month(.abbreviated).year().hour().minute()
        .locale(environment.language.locale))
  }
}
