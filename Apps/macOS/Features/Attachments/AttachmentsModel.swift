import AppCore
import AppDatabase
import Foundation
import Observation
import UniformTypeIdentifiers

/// A file waiting to be attached: a file somewhere on disk, or bytes that came without one (a
/// photo from the library, the camera, the pasteboard).
struct AttachmentSource: Identifiable, Sendable {
  enum Content: Sendable {
    case file(URL)
    case data(Data)
  }

  let id = UUID()
  var content: Content
  var fileName: String

  init(file url: URL) {
    content = .file(url)
    fileName = url.lastPathComponent
  }

  init(data: Data, fileName: String) {
    content = .data(data)
    self.fileName = fileName
  }
}

/// The files of one thing — an operation, an asset, a debt, a subscription — as the section on
/// its screen shows them: the files that are kept, what waits for the thing to be saved, and the
/// steps (add, trash, pin, change the kind), each one step of ⌘Z (`TransactionsStore`).
///
/// Nothing here changes a file: the bytes are copied as they are, however large, off the main
/// thread. A new thing has no row to point at yet (`deferred`): its files wait here and are
/// attached, as one step, after it is saved (`commitPending`).
@MainActor
@Observable
final class AttachmentsModel {
  let owner: AttachmentOwnerKind
  let ownerId: UUID
  let deferred: Bool

  /// The files that are kept, oldest first.
  private(set) var files: [AttachedFile] = []
  /// What waits for the owner to be saved (`deferred` only).
  private(set) var pending: [AttachmentSource] = []
  /// How many files of the last add did not go in.
  private(set) var failedCount = 0
  private(set) var isBusy = false
  /// Files of other places held open until they are attached or given up.
  @ObservationIgnored private var scopes: [URL] = []

  init(owner: AttachmentOwnerKind, ownerId: UUID, deferred: Bool = false) {
    self.owner = owner
    self.ownerId = ownerId
    self.deferred = deferred
  }

  func reload(service: AttachmentService?) {
    guard !deferred, let service else { return }
    files = (try? service.repository.attachments(of: owner, id: ownerId)) ?? []
  }

  // MARK: Adding

  /// What a new file is called by default: a picture or a PDF of an operation is a receipt, an
  /// asset's file is a warranty, the rest are documents. The owner changes it on the row.
  nonisolated static func defaultKind(
    for owner: AttachmentOwnerKind, fileName: String
  ) -> AttachmentKind {
    let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
    switch owner {
    case .transaction:
      return type?.conforms(to: .image) == true ? .receipt : .document
    case .asset:
      return .warranty
    case .debt, .subscription:
      return .document
    }
  }

  nonisolated static func mediaType(of fileName: String) -> String? {
    UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType
  }

  func add(
    _ sources: [AttachmentSource], service: AttachmentService?, store: TransactionsStore
  ) async {
    guard !sources.isEmpty else { return }
    failedCount = 0
    if deferred {
      for source in sources {
        if case .file(let url) = source.content, url.startAccessingSecurityScopedResource() {
          scopes.append(url)
        }
        pending.append(source)
      }
      return
    }
    guard let service else { return }
    isBusy = true
    defer { isBusy = false }
    let owner = owner
    let ownerId = ownerId
    let outcome = await Task.detached(priority: .userInitiated) {
      Self.attach(sources, to: owner, id: ownerId, with: service)
    }.value
    failedCount = outcome.failed
    store.recordAttachmentsAdded(outcome.added)
    reload(service: service)
  }

  /// The thing was saved: its waiting files go in, as one step. Returns how many did not.
  @discardableResult
  func commitPending(service: AttachmentService?, store: TransactionsStore) async -> Int {
    let waiting = pending
    pending = []
    defer { releaseScopes() }
    guard !waiting.isEmpty, let service else { return waiting.count }
    let owner = owner
    let ownerId = ownerId
    let outcome = await Task.detached(priority: .userInitiated) {
      Self.attach(waiting, to: owner, id: ownerId, with: service)
    }.value
    store.recordAttachmentsAdded(outcome.added)
    return outcome.failed
  }

  /// The thing was not saved: its waiting files are forgotten.
  func discardPending() {
    pending = []
    releaseScopes()
  }

  func removePending(_ id: UUID) {
    pending.removeAll { $0.id == id }
  }

  private func releaseScopes() {
    for url in scopes { url.stopAccessingSecurityScopedResource() }
    scopes = []
  }

  nonisolated private static func attach(
    _ sources: [AttachmentSource], to owner: AttachmentOwnerKind, id ownerId: UUID,
    with service: AttachmentService
  ) -> (added: [AttachedFile], failed: Int) {
    var added: [AttachedFile] = []
    var failed = 0
    for source in sources {
      let kind = defaultKind(for: owner, fileName: source.fileName)
      let type = mediaType(of: source.fileName)
      do {
        switch source.content {
        case .file(let url):
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          added.append(
            try service.add(
              fileAt: url, to: owner, id: ownerId, kind: kind, fileName: source.fileName,
              mediaType: type))
        case .data(let data):
          added.append(
            try service.add(
              data: data, fileName: source.fileName, to: owner, id: ownerId, kind: kind,
              mediaType: type))
        }
      } catch {
        failed += 1
        AppLog.warning(
          "attachments.addFailed", .db, "a file could not be attached",
          [LogPair("error", .error(error))])
      }
    }
    return (added, failed)
  }

  // MARK: Changing

  func trash(_ id: UUID, service: AttachmentService?, store: TransactionsStore) {
    store.trashAttachments(ids: [id])
    reload(service: service)
  }

  func setKeepForever(
    _ id: UUID, _ on: Bool, service: AttachmentService?, store: TransactionsStore
  ) {
    change(id, service: service, store: store) { $0.keepForever = on }
  }

  func setKind(
    _ id: UUID, _ kind: AttachmentKind, service: AttachmentService?, store: TransactionsStore
  ) {
    change(id, service: service, store: store) { $0.kind = kind }
  }

  private func change(
    _ id: UUID, service: AttachmentService?, store: TransactionsStore,
    _ edit: (inout AttachedFile) -> Void
  ) {
    guard var row = files.first(where: { $0.id == id }) else { return }
    edit(&row)
    store.changeAttachment(row)
    reload(service: service)
  }

  /// A path with the file's own name and extension, for the preview and the thumbnail: the
  /// folder of the files names a file by its digest, without an extension, and the system
  /// recognises a type by the name. A clone on the same volume costs nothing.
  nonisolated static func previewURL(for file: AttachedFile, in service: AttachmentService) -> URL?
  {
    guard let source = service.store.url(forHash: file.contentHash),
      FileManager.default.fileExists(atPath: source.path)
    else { return nil }
    let name = (file.fileName as NSString).lastPathComponent
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-preview", isDirectory: true)
      .appendingPathComponent(file.contentHash, isDirectory: true)
    let target = folder.appendingPathComponent(name.isEmpty ? "file" : name)
    if FileManager.default.fileExists(atPath: target.path) { return target }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: target)
      return target
    } catch {
      return nil
    }
  }
}
