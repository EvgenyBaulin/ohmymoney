import AppCore
import AppDatabase
import SwiftUI

/// Settings → «Вложения»: how long receipt photos stay, how many days the trash keeps a file,
/// whether the files go to the folder of copies and into the transfer archive, how much room they
/// take, and the trash itself. The values are rows of the `settings` table (`AttachmentSettings`),
/// so they travel with the archive; like every setting they are no step of ⌘Z.
struct AttachmentsSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies
  @State private var values = AttachmentSettings()
  @State private var summary = AttachmentsSummary.empty
  @State private var showsTrash = false

  private func t(_ key: String) -> String { AttachmentsText.t(key, environment) }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: flag(\.keepReceiptsForever)) {
          Text(verbatim: t("att.settings.keepReceipts"))
          Text(verbatim: t("att.settings.keepReceiptsHint"))
        }
        .accessibilityIdentifier("settings.attachments.keepReceipts")
        Toggle(isOn: flag(\.mirror)) {
          Text(verbatim: t("att.settings.mirror"))
          Text(verbatim: t("att.settings.mirrorHint"))
        }
        .accessibilityIdentifier("settings.attachments.mirror")
        Toggle(isOn: flag(\.withAttachmentsInArchive)) {
          Text(verbatim: t("att.settings.archive"))
          Text(verbatim: t("att.settings.archiveHint"))
        }
        .accessibilityIdentifier("settings.attachments.archive")
        Stepper(value: trashDays, in: 1...365) {
          Text(
            verbatim: environment.format(
              "att.settings.trashDays", table: AttachmentsText.table, counts: values.trashDays))
        }
        .accessibilityIdentifier("settings.attachments.trashDays")
      } header: {
        Text(verbatim: t("att.settings.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("att.settings.footer"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        LabeledContent(t("att.settings.files")) {
          Text(verbatim: "\(summary.files)").monospacedDigit()
        }
        LabeledContent(t("att.settings.size")) {
          Text(verbatim: AttachmentsText.size(summary.bytes)).monospacedDigit()
        }
        LabeledContent(t("att.settings.inTrash")) {
          Text(verbatim: "\(summary.inTrash)").monospacedDigit()
        }
        Button(t("att.settings.openTrash")) { showsTrash = true }
          .accessibilityIdentifier("settings.attachments.openTrash")
      }
    }
    .formStyle(.grouped)
    .task { await load() }
    .sheet(isPresented: $showsTrash, onDismiss: { Task { await load() } }) {
      if let dependencies {
        AttachmentTrashView().handingOver(dependencies)
      }
    }
  }

  private func flag(_ path: WritableKeyPath<AttachmentSettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { values[keyPath: path] },
      set: { value in save { $0[keyPath: path] = value } })
  }

  private var trashDays: Binding<Int> {
    Binding(get: { values.trashDays }, set: { value in save { $0.trashDays = value } })
  }

  private func save(_ edit: (inout AttachmentSettings) -> Void) {
    var next = values
    edit(&next)
    guard next != values else { return }
    if environment.attempt(
      "attachments.saveFailed", on: environment.attachments?.repository, { try $0.save(next) })
    {
      values = next
    }
  }

  private func load() async {
    guard let service = environment.attachments else { return }
    values = (try? service.repository.settings()) ?? AttachmentSettings()
    summary = await Task.detached(priority: .utility) { AttachmentsSummary(service) }.value
  }
}

/// How many files there are and how much room they take.
struct AttachmentsSummary: Equatable, Sendable {
  var files: Int
  var inTrash: Int
  var bytes: Int64

  static let empty = AttachmentsSummary(files: 0, inTrash: 0, bytes: 0)

  init(files: Int, inTrash: Int, bytes: Int64) {
    self.files = files
    self.inTrash = inTrash
    self.bytes = bytes
  }

  /// Rows the owner sees (not in the trash), rows in the trash, and the bytes of the folder.
  init(_ service: AttachmentService) {
    let rows = (try? service.repository.all()) ?? []
    files = rows.filter { !$0.isInTrash }.count
    inTrash = rows.filter(\.isInTrash).count
    bytes = service.store.totalBytes()
  }
}

/// «Корзина вложений»: what was sent to the trash and is still there, with the days left, and
/// «Вернуть», «Удалить сейчас» and «Очистить корзину». A file goes for good only here, or when its
/// days run out.
struct AttachmentTrashView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var items: [AttachedFile] = []
  @State private var settings = AttachmentSettings()
  @State private var confirmsEmptying = false

  private func t(_ key: String) -> String { AttachmentsText.t(key, environment) }
  private var service: AttachmentService? { environment.attachments }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("att.trash.title")).appFont(.headline)
      if items.isEmpty {
        Text(verbatim: t("att.trash.empty")).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        List(items) { item in
          row(item)
        }
        .frame(minHeight: 200)
      }
      HStack {
        Button(t("att.trash.emptyAll"), role: .destructive) { confirmsEmptying = true }
          .disabled(items.isEmpty)
          .accessibilityIdentifier("attachments.trash.emptyAll")
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 420, idealWidth: 480, minHeight: 320, idealHeight: 420)
    .task { reload() }
    .confirmationDialog(
      t("att.trash.confirm"), isPresented: $confirmsEmptying, titleVisibility: .visible
    ) {
      Button(t("att.trash.emptyAll"), role: .destructive) {
        try? service?.emptyTrash()
        reload()
      }
    } message: {
      Text(verbatim: t("att.trash.confirmHint"))
    }
  }

  private func row(_ item: AttachedFile) -> some View {
    HStack(spacing: 10) {
      AttachmentThumbnail(file: item, service: service, side: 36)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: item.fileName).lineLimit(1).truncationMode(.middle)
        Text(verbatim: subtitle(item)).appFont(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Button(t("att.trash.restore")) {
        try? service?.restoreFromTrash(id: item.id)
        reload()
      }
      .buttonStyle(.borderless)
      Button(t("att.trash.deleteNow"), role: .destructive) {
        try? service?.delete(ids: [item.id])
        reload()
      }
      .buttonStyle(.borderless)
    }
  }

  private func subtitle(_ item: AttachedFile) -> String {
    let days = AttachmentRetention.daysLeftInTrash(item, settings: settings, now: Date()) ?? 0
    return [
      t("att.owner.\(item.ownerKind.rawValue)"), AttachmentsText.size(item.byteSize),
      environment.format("att.trash.daysLeft", table: AttachmentsText.table, counts: days),
    ].joined(separator: " · ")
  }

  private func reload() {
    guard let service else { return }
    items = (try? service.repository.trash()) ?? []
    settings = (try? service.repository.settings()) ?? AttachmentSettings()
  }
}
