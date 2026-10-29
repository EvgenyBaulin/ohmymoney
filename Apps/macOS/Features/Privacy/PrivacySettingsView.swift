import AppCore
import CoreKit
import SwiftUI

/// Settings → «Приватность»: the amounts that hide by themselves while the screen is recorded, the
/// mode that only looks, the journal of openings, what the app keeps and where, a locked copy to
/// hand to somebody, and the way to show the app on training data. The lock itself (the
/// password, the idle time) stays in «Основные», one press away.
///
/// Every switch here is a row of the `settings` table of the database (`privacy.*`), read back
/// through `AppEnvironment.privacy`; none of them is a step of ⌘Z.
struct PrivacySettingsView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @State private var showsJournal = false
  @State private var showsStorage = false
  @State private var showsExport = false
  @State private var confirmsDemo = false

  private static let table = "PrivacyExport"
  private func t(_ key: String) -> String { environment.language(key, table: Self.table) }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: autoHide) {
          Text(verbatim: t("privacy.settings.autoHide"))
          Text(verbatim: t("privacy.settings.autoHide.hint"))
        }
        .accessibilityIdentifier("settings.privacy.autoHide")
        Toggle(isOn: readOnly) {
          Text(verbatim: t("privacy.settings.readOnly"))
          Text(verbatim: t("privacy.settings.readOnly.hint"))
        }
        .accessibilityIdentifier("settings.privacy.readOnly")
        #if os(macOS)
          Button(t("privacy.settings.lock")) { SettingsNavigation.shared.section = .general }
            .accessibilityIdentifier("settings.privacy.lockLink")
        #endif
      } header: {
        Text(verbatim: t("privacy.settings.screen")).settingsHeaderStyle()
      }

      Section {
        Button(t("privacy.settings.journal")) { showsJournal = true }
          .accessibilityIdentifier("settings.privacy.journal")
        Button(t("privacy.settings.storage")) { showsStorage = true }
          .accessibilityIdentifier("settings.privacy.storage")
      } header: {
        Text(verbatim: t("privacy.settings.knows")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("privacy.settings.knows.footer"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        Button(t("privacy.settings.exportCopy")) { showsExport = true }
          .disabled(environment.exportCopies == nil)
          .accessibilityIdentifier("settings.privacy.exportCopy")
        #if os(macOS)
          Button(t("privacy.settings.demo")) { confirmsDemo = true }
            .disabled(DemoDataMode.isOn())
            .accessibilityIdentifier("settings.privacy.demo")
        #endif
      } header: {
        Text(verbatim: t("privacy.settings.hand")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("privacy.settings.hand.footer"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: environment.lock.presenting($showsJournal)) {
      handed { PrivacyJournalView() }
    }
    .sheet(isPresented: environment.lock.presenting($showsStorage)) {
      handed { StorageReportView() }
    }
    .sheet(isPresented: environment.lock.presenting($showsExport)) {
      handed { ExportCopyView(model: PrivacyScreens.exportModel(environment)) }
    }
    .confirmationDialog(
      t("privacy.demo.confirm.title"), isPresented: $confirmsDemo, titleVisibility: .visible
    ) {
      Button(t("privacy.demo.confirm.action")) { DemoDataMode.enter() }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: {
      Text(verbatim: t("privacy.demo.confirm.body"))
    }
  }

  /// A sheet is laid out by a host of its own: the dependencies are handed over.
  @ViewBuilder
  private func handed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if let dependencies {
      content().handingOver(dependencies)
    } else {
      content()
    }
  }

  // MARK: Bindings

  private var autoHide: Binding<Bool> {
    Binding(
      get: { environment.privacy.autoHideOnCapture },
      set: { value in change { $0.autoHideOnCapture = value } })
  }

  private var readOnly: Binding<Bool> {
    Binding(
      get: { environment.privacy.readOnly },
      set: { value in
        guard value != environment.privacy.readOnly else { return }
        // The shield switches the mode: it asks Touch ID or the password to leave it, tells the
        // barrier of the database and writes the journal line itself.
        Task { @MainActor in
          await environment.setReadOnly(value)
          environment.refreshPrivacySettings()
        }
      })
  }

  private func change(_ edit: (inout CoreKit.PrivacySettings) -> Void) {
    var settings = environment.privacy
    edit(&settings)
    try? environment.privacySettings?.save(settings)
    environment.refreshPrivacySettings()
  }
}

/// What the Mac's File menu and the settings both open, built the same way.
@MainActor
enum PrivacyScreens {
  /// The form of «Экспорт копии…», with the attached files ticked as the archive setting says.
  static func exportModel(
    _ environment: AppEnvironment, format: ExportCopyRequest.Format = .archive
  ) -> ExportCopyModel {
    let files =
      (try? environment.attachments?.repository.settings().withAttachmentsInArchive) ?? true
    return ExportCopyModel(
      today: environment.today, calendar: environment.calendar, attachmentsByDefault: files,
      format: format)
  }
}
