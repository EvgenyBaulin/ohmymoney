import AppCore
import AppDatabase
import CoreKit
import Foundation

/// What a copy holds, for the sheet that says it was made.
public struct ExportCopyReport: Equatable, Sendable {
  public let url: URL
  public let operations: Int
  public let transfers: Int
  public let accounts: Int
  /// Operations and transfers left out because of the span of days or the hidden accounts.
  public let operationsLeftOut: Int
  public let transfersLeftOut: Int
  public let accountsLeftOut: Int
  public let attachments: Int
  public let encrypted: Bool
}

/// «Экспорт копии»: a locked file for a person who must not see everything -- an accountant, a
/// bank, a family member. It is built only from a copy of the data (`ExportCopyMaker`), so the
/// live database, its files and its settings are never changed. The copy is cut to the span of
/// days, loses the hidden accounts when asked, has its names replaced when asked, and is packed
/// as a transfer archive (the database, the CSV files, the settings) or as the CSV files alone.
/// The names are replaced by `SQLAnonymizer` unless the caller hands in another way.
/// Both are locked with the archive's own scheme: PBKDF2-HMAC-SHA256 and AES-256-GCM.
public struct ExportCopyService: Sendable {
  private let maker: ExportCopyMaker
  private let attachmentStore: AttachmentFileStore?
  private let appVersion: String
  private let schemaVersion: Int
  private let cipher: any ArchiveCipher
  private let iterations: Int
  private let anonymizer: (any ExportCopyAnonymizing)?

  public init(
    stack: DatabaseStack,
    appVersion: String,
    schemaVersion: Int? = nil,
    cipher: any ArchiveCipher = CryptoKitArchiveCipher(),
    iterations: Int = EncryptionHeader.recommendedIterations,
    attachmentStore: AttachmentFileStore? = nil,
    anonymizer: (any ExportCopyAnonymizing)? = SQLAnonymizer()
  ) {
    self.maker = ExportCopyMaker(writer: stack.writer)
    self.attachmentStore = attachmentStore
    self.appVersion = appVersion
    self.schemaVersion = schemaVersion ?? stack.applied.onDisk
    self.cipher = cipher
    self.iterations = iterations
    self.anonymizer = anonymizer
  }

  /// What the manifest takes in the container, a roomy figure.
  private static let manifestAllowance: Int64 = 4_000_000

  /// Writes the copy to `url`, reads it back with the password before handing it over, and takes
  /// it away again if it does not read.
  @discardableResult
  public func export(
    _ request: ExportCopyRequest, to url: URL, settings: [String: String] = [:],
    now: Date = Date()
  ) throws -> ExportCopyReport {
    guard !request.password.isEmpty else { throw ExportCopyError.passwordMissing }
    if request.anonymize && anonymizer == nil { throw ExportCopyError.anonymizerMissing }

    AppLog.info(
      "copy.export.started", .archive, "a copy is being made",
      [
        LogPair("period", .flag(request.scope != .whole)),
        LogPair("anonymize", .flag(request.anonymize)),
        LogPair("hidden", .flag(request.includeHidden)),
        LogPair("files", .flag(request.includeAttachments)),
      ])
    var step = "copy"
    var removed: Bool?
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-copy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }
    do {
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let draft = try maker.make(request, in: work, anonymizer: anonymizer)

      step = "build"
      var builder = ArchiveBuilder(
        metadata: ArchiveBuilder.Metadata(
          appVersion: appVersion, schemaVersion: schemaVersion,
          createdAt: CalendarContext.system.day(of: now), platform: "macOS",
          rowCounts: draft.rowCounts))
      var databaseBytes: Int64 = 0
      if request.format == .archive {
        let database = try Data(contentsOf: draft.databaseURL)
        databaseBytes = Int64(database.count)
        try builder.add(path: ArchivePaths.database, data: database)
      }
      for table in draft.tables {
        try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
      }
      try builder.add(
        path: ArchivePaths.settings,
        data: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]))

      step = "attachments"
      var carried = 0
      if request.includeAttachments, let store = attachmentStore {
        // Everything already in the container counts against the limits of a plain zip.
        let csvBytes = draft.tables.reduce(into: Int64(0)) { $0 += Int64($1.data.count) }
        let plan = AttachmentArchive.plan(
          for: draft.attachments, baseBytes: databaseBytes + csvBytes + Self.manifestAllowance,
          baseEntries: 3 + draft.tables.count)
        for file in plan.included {
          // A file the folder no longer holds is left out: the row reads as removed by a rule.
          guard let path = AttachmentArchive.path(forHash: file.hash),
            let content = try? store.data(forHash: file.hash)
          else { continue }
          try builder.add(path: path, data: content)
          carried += 1
        }
      }

      step = "lock"
      var random = SecureRandomSource()
      let data = try builder.build(
        password: request.password, cipher: cipher, random: &random, iterations: iterations)

      step = "write"
      try data.write(to: url, options: .atomic)
      step = "verify"
      do {
        _ = try ArchiveOpener.open(
          try Data(contentsOf: url), password: request.password, cipher: cipher,
          supportedSchemaVersion: schemaVersion)
      } catch {
        removed = (try? FileManager.default.removeItem(at: url)) != nil
        throw error
      }

      let report = ExportCopyReport(
        url: url, operations: draft.rowCounts["transactions"] ?? 0,
        transfers: draft.rowCounts["transfers"] ?? 0, accounts: draft.rowCounts["payment_methods"] ?? 0,
        operationsLeftOut: draft.operationsLeftOut, transfersLeftOut: draft.transfersLeftOut,
        accountsLeftOut: draft.accountsLeftOut, attachments: carried, encrypted: true)
      AppLog.info(
        "copy.export.done", .archive, "the copy was written and read back",
        [
          LogPair("bytes", .bytes(data.count)), LogPair("operations", .count(report.operations)),
          LogPair("files", .count(carried)),
        ])
      return report
    } catch {
      var pairs = ArchiveService.journalPairs(for: error, step: step)
      if let removed { pairs.append(LogPair("removed", .flag(removed))) }
      AppLog.error(
        "copy.export.failed", .archive, "the copy was not written, or did not read back", pairs)
      throw error
    }
  }
}
