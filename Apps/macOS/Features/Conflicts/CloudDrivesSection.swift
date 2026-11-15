import AppCore
import SwiftUI

/// «Облачный диск» in the exchange settings: the six drives in one list. A drive with a page of
/// its own signs in through the system sheet; a drive with a form (login and app password,
/// project address and key) asks for them here. A drive whose application key is not in this
/// build is listed, and says why it cannot be connected. Tokens and passwords go to the keychain.
struct CloudDrivesSection: View {
  @Dependency(\.environment) private var environment
  let coordinator: SyncCoordinator
  var connection = CloudDriveConnection()

  @State private var form: CloudDrive?
  @State private var values: [String: String] = [:]
  @State private var failed: CloudDrive?
  @State private var busy: CloudDrive?
  @State private var connected: Set<CloudDrive> = []

  var body: some View {
    Section {
      ForEach(CloudDrive.allCases) { drive in
        row(drive)
      }
      if failed != nil {
        Text(verbatim: t("cloud.signIn.failed"))
          .appFont(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("cloud.failed")
      }
    } header: {
      Text(verbatim: t("cloud.section.title"))
    } footer: {
      Text(verbatim: t("cloud.encrypted.note"))
    }
    .task { refresh() }
    .sheet(item: $form) { drive in formSheet(drive) }
  }

  private func row(_ drive: CloudDrive) -> some View {
    let isUsed = coordinator.usesDrive && CloudDriveSelection.selected() == drive
    return VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        HStack {
          if isUsed {
            Button(t("cloud.disconnect.action")) { disconnect(drive) }
              .accessibilityIdentifier("cloud.disconnect.\(drive.rawValue)")
          } else {
            Button(t("cloud.connect.action")) { connect(drive) }
              .disabled(!drive.isConnectable || busy != nil)
              .accessibilityIdentifier("cloud.connect.\(drive.rawValue)")
          }
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: t(drive.nameKey))
          Text(verbatim: t(isUsed ? "cloud.status.connected" : "cloud.status.notConnected"))
            .appFont(.caption)
            .secondaryInk()
        }
      }
      if let reason = drive.unavailableReasonKey {
        Text(verbatim: t(reason))
          .appFont(.caption)
          .secondaryInk()
          .accessibilityIdentifier("cloud.unavailable.\(drive.rawValue)")
      }
    }
  }

  private func formSheet(_ drive: CloudDrive) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(drive.nameKey)).appFont(.headline)
      ForEach(drive.fields) { field in
        let binding = Binding(
          get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
        if field.isSecret {
          SecureField(t(field.labelKey), text: binding)
        } else {
          TextField(t(field.labelKey), text: binding)
        }
      }
      if failed == drive {
        Text(verbatim: t("cloud.input.invalid")).appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(t("action.cancel")) { form = nil }
        Button(t("cloud.connect.action")) { submit(drive) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("cloud.form.connect")
      }
    }
    .padding(20)
    .frame(minWidth: 380)
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: key.hasPrefix("action.") ? "Common" : CloudDrive.table)
  }

  private func refresh() {
    connected = Set(CloudDrive.allCases.filter { connection.isConnected($0) })
  }

  private func connect(_ drive: CloudDrive) {
    failed = nil
    if !drive.fields.isEmpty {
      values = [:]
      form = drive
      return
    }
    busy = drive
    Task {
      defer { busy = nil }
      do {
        try await connection.signIn(drive)
        use(drive)
      } catch CloudSignInError.cancelled {
        // The owner closed the sheet: nothing to say.
      } catch {
        failed = drive
      }
    }
  }

  private func submit(_ drive: CloudDrive) {
    do {
      try connection.connect(drive, values: values)
      form = nil
      values = [:]
      use(drive)
    } catch {
      failed = drive
    }
  }

  private func use(_ drive: CloudDrive) {
    guard let folder = connection.makeFolder(drive) else {
      failed = drive
      return
    }
    coordinator.useDrive(drive, folder: folder)
    refresh()
  }

  private func disconnect(_ drive: CloudDrive) {
    coordinator.useDrive(nil)
    connection.disconnect(drive)
    refresh()
  }
}
