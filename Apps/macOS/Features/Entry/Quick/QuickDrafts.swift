import AppCore
import AppDatabase
import Foundation
import Observation

/// «Запишу потом»: lines the owner could not finish now. A draft is its own thing, not an
/// operation — it enters no figure until it is written as one (the answer to the question about
/// drafts). It is kept as a list in the `settings` table under `entry.pendingDrafts`, so it
/// travels in the archive with the rest of the owner's data.
///
/// The list lives in a setting rather than in a table of its own because the schema has no table
/// for drafts yet; the type of the line (`PendingDraft`) is the core's, and moving the storage
/// to a table is a change of this file alone.
protocol DraftStoring {
  func load() -> [PendingDraft]
  /// Whether the list landed.
  func save(_ drafts: [PendingDraft]) -> Bool
}

struct SettingsDraftStore: DraftStoring {
  static let key = "entry.pendingDrafts"
  let settings: SettingsRepository?

  func load() -> [PendingDraft] {
    guard let text = (try? settings?.string(Self.key)) ?? nil, let data = text.data(using: .utf8)
    else { return [] }
    return Self.decode(data)
  }

  func save(_ drafts: [PendingDraft]) -> Bool {
    guard let text = Self.encode(drafts) else { return false }
    return AppEnvironment.attempt("entry.drafts", on: settings) { try $0.set(Self.key, to: text) }
  }

  static func encode(_ drafts: [PendingDraft]) -> String? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(drafts)).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func decode(_ data: Data) -> [PendingDraft] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([PendingDraft].self, from: data)) ?? []
  }
}

/// The drafts the line and the reminder read. Waiting ones come first, the oldest at the top.
@MainActor
@Observable
final class DraftsModel {
  private(set) var drafts: [PendingDraft] = []
  /// The draft being finished in the line: it is resolved when the line is written.
  var finishing: UUID?
  @ObservationIgnored private var store: (any DraftStoring)?

  var waiting: [PendingDraft] { DraftReminder.waiting(drafts) }

  func attach(_ store: some DraftStoring) {
    self.store = store
    reload()
  }

  func reload() { drafts = store?.load() ?? [] }

  /// Keeps `text` for later. Says whether it landed; an empty text keeps nothing.
  @discardableResult
  func keep(_ text: String, now: Date = Date()) -> Bool {
    guard let draft = PendingDraft(text: text, createdAt: now) else { return false }
    return write(drafts + [draft])
  }

  /// A draft thrown away or written: it leaves the list (the resolved ones are not kept).
  @discardableResult
  func resolve(_ id: UUID) -> Bool {
    write(drafts.filter { $0.id != id })
  }

  /// The line was written: the draft it came from is done.
  func lineWritten() {
    guard let id = finishing else { return }
    finishing = nil
    resolve(id)
  }

  private func write(_ new: [PendingDraft]) -> Bool {
    guard let store, store.save(new) else { return false }
    drafts = new
    NotificationCenter.default.post(name: .draftsChanged, object: nil)
    return true
  }
}

extension Notification.Name {
  /// The drafts were written: the reminder in «Стоит посмотреть» reads them again.
  static let draftsChanged = Notification.Name("io.github.EvgenyBaulin.ohmymoney.draftsChanged")
  /// Asks the entry line to open the list of drafts (the reminder row's button).
  static let openDrafts = Notification.Name("io.github.EvgenyBaulin.ohmymoney.openDrafts")
}
