import AppCore
import AppDatabase
import CoreKit
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// Export and import of the single file that carries everything to another Mac.
///
/// The format itself lives in `CoreArchive`; this service only collects the data, writes the
/// file and verifies it straight away.
public struct ArchiveService: Sendable {
  public static let fileExtension = "ohmymoneyarchive"

  private let repository: ExportRepository
  private let appVersion: String
  private let schemaVersion: Int
  private let cipher: any ArchiveCipher
  /// Iterations of the key derivation. The real value is the OWASP recommendation and
  /// costs about half a second in a release build; tests lower it so a run does not wait
  /// on a deliberately slow function.
  private let iterations: Int

  /// `schemaVersion` is the version of the schema the archives are written with and the
  /// newest one they are opened with: the number of migrations of the database, which is the
  /// number of files in `Schema/` this build ships (`DatabaseStack` applies every one of them
  /// and refuses a database with any other). It is taken from the stack, not written down
  /// here: a literal stayed at 2 when `0003_model.sql` arrived. Only tests pass another value,
  /// to write the archive of a newer build.
  public init(
    stack: DatabaseStack,
    appVersion: String,
    schemaVersion: Int? = nil,
    cipher: any ArchiveCipher = CryptoKitArchiveCipher(),
    iterations: Int = EncryptionHeader.recommendedIterations
  ) {
    self.repository = ExportRepository(writer: stack.writer)
    self.appVersion = appVersion
    self.schemaVersion = schemaVersion ?? stack.applied.onDisk
    self.cipher = cipher
    self.iterations = iterations
  }

  /// Whether `password` locks the archive. The empty string is the File menu's «без пароля»
  /// (the owner confirmed the warning), so it writes and opens an archive in the clear, and the
  /// journal says so.
  static func encrypts(_ password: String?) -> Bool {
    !(password ?? "").isEmpty
  }

  /// Builds the archive and checks it by opening it again before handing the file over; one
  /// that does not read back is not left behind. A failure is written in the journal with the
  /// step it stopped at, then thrown for the File menu to tell the owner.
  @discardableResult
  public func exportArchive(
    to url: URL, password: String? = nil, settings: [String: String] = [:], now: Date = Date()
  ) throws -> URL {
    AppLog.info(
      "archive.export.started", .archive, "an archive is being written",
      [LogPair("encrypted", .flag(Self.encrypts(password)))])
    var step = "snapshot"
    /// Whether an archive that failed its check was taken away again; nil before the check.
    var removed: Bool?
    do {
      let snapshot = try snapshotDatabase()
      defer { try? FileManager.default.removeItem(at: snapshot.url) }

      step = "build"
      var builder = ArchiveBuilder(
        metadata: ArchiveBuilder.Metadata(
          appVersion: appVersion,
          schemaVersion: schemaVersion,
          createdAt: CalendarContext.system.day(of: now),
          platform: "macOS",
          rowCounts: snapshot.contents.rowCounts))

      try builder.add(path: ArchivePaths.database, data: snapshot.data)
      for table in snapshot.contents.tables {
        try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
      }
      try builder.add(
        path: ArchivePaths.settings,
        data: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]))

      let data: Data
      if let password, Self.encrypts(password) {
        // Salt and nonce come from the system generator, never from a seeded one.
        var random = SecureRandomSource()
        data = try builder.build(
          password: password, cipher: cipher, random: &random, iterations: iterations)
      } else {
        data = try builder.build()
      }

      step = "write"
      try data.write(to: url, options: .atomic)
      // Verify what actually landed on disk, not what we think we wrote. A file that does not
      // read back is taken away: left under the name the owner chose, it is the one they would
      // carry to the other Mac. It is not written under another name first and renamed after
      // the check: the sandbox opens the file chosen in the save panel, not its folder.
      step = "verify"
      do {
        _ = try openArchive(at: url, password: password)
      } catch {
        removed = (try? FileManager.default.removeItem(at: url)) != nil
        throw error
      }
      AppLog.info(
        "archive.export.done", .archive, "the archive was written and read back",
        [LogPair("bytes", .bytes(data.count))])
      return url
    } catch {
      var pairs = Self.journalPairs(for: error, step: step)
      if let removed { pairs.append(LogPair("removed", .flag(removed))) }
      AppLog.error(
        "archive.export.failed", .archive, "the archive was not written, or did not read back",
        pairs)
      throw error
    }
  }

  public func openArchive(
    at url: URL, password: String? = nil
  ) throws
    -> ArchiveOpener.OpenedArchive
  {
    let data = try Data(contentsOf: url)
    if let password, Self.encrypts(password) {
      return try ArchiveOpener.open(
        data, password: password, cipher: cipher, supportedSchemaVersion: schemaVersion)
    }
    return try ArchiveOpener.open(data, supportedSchemaVersion: schemaVersion)
  }

  /// Reads the magic only, not the whole file: the question is asked on the main thread.
  public func isEncrypted(at url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let start = try handle.read(upToCount: EncryptionHeader.magic.count) ?? Data()
    return ArchiveOpener.isEncrypted(start)
  }

  /// Same question, for call sites that cannot deal with a thrown error.
  public func isEncryptedSafely(at url: URL) -> Bool {
    (try? isEncrypted(at: url)) ?? false
  }

  /// Writes the database the archive carries to `target`. Nothing is checked here:
  /// `ArchiveImportFlow.stageReplacement` checks the file written, then makes the copy of the
  /// current state, and only then gives it the name the launch looks for.
  public func replaceDatabase(with archive: ArchiveOpener.OpenedArchive, at target: URL) throws {
    guard let database = archive.database else {
      throw CoreError.invalidArchive(reason: .manifestUnreadable)
    }
    try database.write(to: target, options: .atomic)
  }

  /// The database, its CSV files and their row counts, taken in one read transaction: the
  /// manifest counts the database inside the archive and the files beside it, not three
  /// moments of a database the rate step writes to in the background.
  private func snapshotDatabase() throws -> (
    url: URL, data: Data, contents: ExportRepository.Snapshot
  ) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-archive-\(UUID().uuidString).sqlite")
    do {
      let contents = try repository.snapshot(to: url)
      return (url, try Data(contentsOf: url), contents)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// What the journal says about an export or an import that failed: the step it stopped at,
  /// the error's type and, when a check refused the archive, which check. Never a path, a name
  /// or an amount («Что логируется обязательно»: «любая перехваченная ошибка: тип»).
  static func journalPairs(for error: Error, step: String) -> [LogPair] {
    var pairs = [
      LogPair("step", .token(step)),
      LogPair("error", .error(error)),
    ]
    switch error {
    case CoreError.invalidArchive(let reason):
      pairs.append(LogPair("reason", .token(reason.rawValue)))
    case CoreError.unsupportedSchemaVersion(let found, let supported):
      pairs += [
        LogPair("reason", .token("newerSchema")), LogPair("found", .count(found)),
        LogPair("supported", .count(supported)),
      ]
    case let refusal as ArchiveImportFlow.Refusal:
      pairs.append(LogPair("reason", .token(refusal.token)))
    case let unreadable as ArchiveManifest.Unreadable:
      // The field is a name the format defines, never a value or a key of the file.
      pairs += [
        LogPair("reason", .token(CoreError.ArchiveProblem.manifestUnreadable.rawValue)),
        LogPair("field", .token(unreadable.field)),
        LogPair("problem", .token(unreadable.problem.rawValue)),
      ]
    default:
      break
    }
    return pairs
  }
}

/// Importing an archive replaces every table, so the order of the two steps is the whole
/// point: the copy of the current state has to be on disk before anything is staged.
///
/// The steps live here rather than in the File menu because the menu cannot be exercised
/// without a window, and this is the part that must never be got wrong.
enum ArchiveImportFlow {
  /// Why the database an archive carries is not staged. The checks of the archive itself —
  /// format, digests, row counts — passed: they prove the bytes are what the other side wrote,
  /// not that this build can open them.
  enum Refusal: Error, Equatable {
    /// Not a database, or one that fails its integrity check.
    case databaseDamaged
    /// A database of a newer build: «если новее — отказ с просьбой обновить приложение».
    case newerSchema

    /// What the owner reads, from the Settings catalog.
    var messageKey: String {
      switch self {
      case .databaseDamaged: "archive.error.database"
      case .newerSchema: "archive.error.newerSchema"
      }
    }

    var token: String {
      switch self {
      case .databaseDamaged: "damaged"
      case .newerSchema: "newerSchema"
      }
    }
  }

  /// Opens the archive the owner chose for an import. The import is the one operation that
  /// replaces the whole database, so its start, what the archive holds and a refusal by one of
  /// its checks are all in the journal (counts and flags only).
  static func open(
    _ url: URL, password: String?, archives: ArchiveService
  ) throws -> ArchiveOpener.OpenedArchive {
    let bytes =
      ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    AppLog.info(
      "archive.import.started", .archive, "an archive is being opened for an import",
      [
        LogPair("password", .flag(ArchiveService.encrypts(password))),
        LogPair("bytes", .bytes(bytes)),
      ])
    do {
      let opened = try archives.openArchive(at: url, password: password)
      let counts = opened.manifest.rowCounts
      AppLog.info(
        "archive.import.opened", .archive, "the archive passed its checks",
        [
          LogPair("schema", .count(opened.manifest.schemaVersion)),
          LogPair("tables", .count(counts.count)),
          LogPair("rows", .count(counts.values.reduce(0, +))),
        ])
      return opened
    } catch {
      AppLog.error(
        "archive.import.failed", .archive, "the archive did not open",
        ArchiveService.journalPairs(for: error, step: "open"))
      throw error
    }
  }

  /// Nonisolated and async on purpose: awaited from the main actor (`run`), it runs on the
  /// global executor, so writing out and checking a large database does not stop the app.
  static func stageReplacement(
    opened: ArchiveOpener.OpenedArchive,
    archives: ArchiveService,
    backups: BackupService,
    target: URL,
    schema: any SchemaSource = BundleSchemaSource()
  ) async throws {
    // The database of the archive is written under a name the launch does not look at and
    // checked by the rules its opening will apply, before anything else: one this build cannot
    // open would take the place of the owner's at the next launch.
    let manager = FileManager.default
    let taken = URL(fileURLWithPath: target.path + ".partial")
    try? manager.removeItem(at: taken)
    defer { try? manager.removeItem(at: taken) }
    var step = "write"
    do {
      try archives.replaceDatabase(with: opened, at: taken)
      step = "check"
      switch try DatabaseStack.check(fileAt: taken, schema: schema) {
      case .sound: break
      case .damaged: throw refused(.databaseDamaged)
      case .newerSchema: throw refused(.newerSchema)
      }

      // Awaited, not scheduled: the automatic copy waits several seconds for the next change
      // and the application relaunches the moment the staging is done, so a scheduled copy
      // would never be written. A failure here stops the import — the rule is that the state
      // before the replacement exists on disk first. A database that fails its own check still
      // has its copy kept, marked as damaged: it is the state before the import.
      step = "copy"
      _ = try await backups.writeBackup(label: "before-import", keepingADamagedCopy: true)
      // The launch that puts it in place asks for the folder of the copies again: bookmarks
      // do not travel with an archive. The mark goes first, so a staged import always has it.
      step = "stage"
      let mark = AppPaths.importMark(for: target)
      try Data().write(to: mark)
      do {
        try manager.putInPlace(taken, at: target)
      } catch {
        try? manager.removeItem(at: mark)
        throw error
      }
    } catch {
      // A refusal has its own line already (`archive.import.refused`).
      if !(error is Refusal) {
        AppLog.error(
          "archive.import.failed", .archive, "the archive was not staged",
          ArchiveService.journalPairs(for: error, step: step))
      }
      throw error
    }
    applyPortableSettings(opened)
    AppLog.info(
      "archive.import.staged", .archive,
      "an archive is staged to replace the database at the next launch")
  }

  private static func refused(_ refusal: Refusal) -> Refusal {
    AppLog.error(
      "archive.import.refused", .archive, "this build cannot open the database of the archive",
      [LogPair("reason", .token(refusal.token))])
    return refusal
  }

  /// The settings that do not live in the database travel in `settings.json`
  /// (`AppEnvironment.portableSettings`) and are put into `UserDefaults` here, because the
  /// process relaunches a moment later and nothing reads them until it does. Currencies need
  /// nothing: they are inside the database already.
  ///
  /// Until this existed the file was written and never read, and the new Mac did not get the
  /// interface language and the theme of the old one. A value this build does not know is
  /// passed over in silence: an archive from another machine does not get to write whatever
  /// it likes into the owner's defaults.
  static func applyPortableSettings(
    _ opened: ArchiveOpener.OpenedArchive, to defaults: UserDefaults = .standard
  ) {
    guard let data = opened.settings,
      let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    else { return }
    if let language = values["language"], let choice = AppLanguage.Choice(rawValue: language) {
      // With the language of the menus beside it, as the settings write a choice.
      AppLanguage.store(choice, in: defaults)
    }
    if let scheme = values["theme.scheme"], AppTheme.Scheme(rawValue: scheme) != nil {
      defaults.set(scheme, forKey: AppTheme.schemeKey)
    }
    if let accent = values["theme.accent"], AppTheme.Accent(rawValue: accent) != nil {
      defaults.set(accent, forKey: AppTheme.accentKey)
    }
    // The order of the fields of the ↓ panel is read as a whole order before it is kept: a
    // field this build does not know goes, one it lacks takes its standard place.
    if let order = values[AppEnvironment.entryFieldOrderKey] {
      defaults.set(
        EntryFieldOrder.encode(EntryFieldOrder.decode(order)),
        forKey: AppEnvironment.entryFieldOrderKey)
    }
    // The style of the entry is kept when this build knows the word.
    if let style = values[AppEnvironment.entryStyleKey], EntryStyle(rawValue: style) != nil {
      defaults.set(style, forKey: AppEnvironment.entryStyleKey)
    }
    // The tiles of Overview are read as a list the grid can show before they are kept: a tile
    // this build does not know goes.
    if let tiles = values[AppEnvironment.overviewTilesKey] {
      defaults.set(
        OverviewTiles.encode(OverviewTiles.decode(tiles)),
        forKey: AppEnvironment.overviewTilesKey)
    }
    // The layout of Overview is read as a whole layout before it is kept. An archive of a build
    // before groups carries only the list: the layout of this Mac goes, so the list is what the
    // next launch reads.
    if let layout = OverviewLayout.decode(values[AppEnvironment.overviewLayoutKey]) {
      defaults.set(layout.encode(), forKey: AppEnvironment.overviewLayoutKey)
    } else if values[AppEnvironment.overviewTilesKey] != nil {
      defaults.removeObject(forKey: AppEnvironment.overviewLayoutKey)
    }
    // The order of the blocks of Planning, read as an order of every block once.
    PlanningLayoutStore.applyPortable(values, to: defaults)
  }

  /// What an import asks the owner and what it tells them. Alerts in the app; a test answers
  /// them itself, so the flow runs without a window and never relaunches the test host.
  struct Questions {
    /// «Загрузить этот архив?» — asked before a double-clicked archive replaces anything.
    var confirm: @MainActor () -> Bool
    /// The password of an encrypted archive.
    var password: @MainActor () -> PasswordAnswer
    /// Words of the Settings catalog that say why the import stopped.
    var report: @MainActor (String) -> Void
    /// The replacement is staged: the next launch puts it in place.
    var relaunch: @MainActor () -> Void
    /// Says, in words of the Settings catalog, that the import is at work; the closure it
    /// returns takes the words away again. Nothing in a test.
    var progress: @MainActor (String) -> @MainActor () -> Void = { _ in {} }

    #if !os(macOS)
      /// iPhone has no modal alerts: the archive screen asks in SwiftUI, so until it does
      /// the import is declined here.
      @MainActor
      static func alerts(_ environment: AppEnvironment) -> Questions {
        Questions(
          confirm: { false }, password: { .cancelled }, report: { _ in }, relaunch: {})
      }
    #else
      @MainActor
      static func alerts(_ environment: AppEnvironment) -> Questions {
        Questions(
          confirm: {
            let confirm = NSAlert()
            confirm.messageText = environment.language("archive.import.title", table: "Settings")
            confirm.informativeText = environment.language("archive.import.body", table: "Settings")
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: environment.language("archive.import", table: "Settings"))
            confirm.addButton(withTitle: environment.language("action.cancel"))
            return confirm.runModal() == .alertFirstButtonReturn
          },
          password: {
            let ask = NSAlert()
            ask.messageText = environment.language("archive.password.title", table: "Settings")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            ask.accessoryView = field
            ask.addButton(withTitle: environment.language("action.save"))
            ask.addButton(withTitle: environment.language("action.cancel"))
            guard ask.runModal() == .alertFirstButtonReturn else { return .cancelled }
            return .given(field.stringValue)
          },
          report: { key in
            let alert = NSAlert()
            alert.messageText = environment.language(key, table: "Settings")
            alert.runModal()
          },
          relaunch: { AppRestart.relaunch() },
          progress: { key in
            let panel = ArchiveProgressPanel.show(environment.language(key, table: "Settings"))
            return { panel.close() }
          })
      }
    #endif
  }

  /// The owner's answer to the password of an encrypted archive.
  enum PasswordAnswer: Equatable {
    /// Cancel: the import stops there, as Cancel in the open panel stops it.
    case cancelled
    /// What was typed, the empty field included.
    case given(String)
  }

  /// Tells the owner which of the checks failed, instead of one message for everything.
  nonisolated static func messageKey(for error: Error) -> String {
    if let refusal = error as? ArchiveImportFlow.Refusal { return refusal.messageKey }
    if error is ArchiveManifest.Unreadable { return "archive.error.manifest" }
    guard case CoreError.invalidArchive(let reason) = error else {
      if case CoreError.unsupportedSchemaVersion = error {
        return "archive.error.newerSchema"
      }
      return "archive.import.failed"
    }
    switch reason {
    case .wrongPassword: return "archive.error.password"
    case .checksumMismatch: return "archive.error.checksum"
    case .rowCountMismatch: return "archive.error.rowCount"
    case .unsupportedFormatVersion: return "archive.error.newerFormat"
    case .notAZipContainer, .truncated: return "archive.error.damaged"
    case .manifestMissing, .manifestUnreadable: return "archive.error.manifest"
    }
  }

  /// A double click on an archive in Finder. With the database open this does what the menu
  /// does, after a confirmation: ask for the password when the file is encrypted, write the
  /// copy, stage the replacement and relaunch.
  ///
  /// A double click that launches the app hands the file over while the launch still waits on
  /// the journal, before the database is open (`AppLaunch.start`): the archive then waits in
  /// `AppEnvironment.pendingArchiveImport` for `resumeDeferred`. A database that did not open
  /// cannot be replaced from an archive, and the owner is told so in words.
  @MainActor
  static func begin(with url: URL, environment: AppEnvironment, questions: Questions? = nil) {
    // One archive at a time: a double click while another is being written or opened.
    guard !ArchiveProgressPanel.isShowing else { return }
    // Its questions are modal alerts: never over the cover of the locked app. The archive waits
    // for the unlock (the main window resumes it then).
    if environment.lock.isCovered, !environment.isClosed {
      environment.pendingArchiveImport = url
      AppLog.info(
        "archive.import.locked", .archive, "an archive handed over waits for the unlock")
      return
    }
    let questions = questions ?? .alerts(environment)
    guard let archives = environment.archives, let backups = environment.backups else {
      if case .starting = environment.state, !environment.isClosed {
        environment.pendingArchiveImport = url
        AppLog.info(
          "archive.import.deferred", .archive,
          "an archive handed over before the database opened waits for it")
      } else {
        AppLog.warning(
          "archive.cannotImport", .archive,
          "an archive was handed over while the database is not open",
          [LogPair("closed", .flag(environment.isClosed))])
        // A closed environment is the app quitting: there is nobody left to tell.
        if !environment.isClosed { questions.report("archive.import.unavailable") }
      }
      return
    }
    guard questions.confirm() else { return }
    run(url, archives: archives, backups: backups, questions: questions)
  }

  /// What an import does once the owner has chosen the file — in the open panel of the File
  /// menu, or by a double click and its confirmation: the password when the file is encrypted,
  /// the checks, the copy of the current state, the staging and the relaunch. Cancel in the
  /// password alert stops here, without a word; an empty field is a password given, and an
  /// encrypted archive refuses it in the words of a wrong one.
  ///
  /// The opening — the key derivation, up to 50 000 000 rounds for a header written elsewhere,
  /// and the digests over the whole database — runs away from the main thread while
  /// `Questions.progress` says so; on the main thread the app stood still for as long. The task
  /// returned is the rest of the import, for a test to wait on; nil when it stopped at once.
  @MainActor @discardableResult
  static func run(
    _ url: URL, archives: ArchiveService, backups: BackupService, questions: Questions
  ) -> Task<Void, Never>? {
    let password: String?
    if archives.isEncryptedSafely(at: url) {
      guard case .given(let typed) = questions.password() else { return nil }
      password = typed
    } else {
      password = nil
    }
    let working = questions.progress("archive.import.working")
    return Task { @MainActor in
      do {
        let opened = try await Task.detached(priority: .userInitiated) {
          try open(url, password: password, archives: archives)
        }.value
        // A copy of the current state is written first and waited for; the database is then
        // staged and swapped in at the next launch, because replacing a file the application
        // has open would race with the write-ahead log.
        try await stageReplacement(
          opened: opened, archives: archives, backups: backups,
          target: AppPaths.pendingReplacementURL)
      } catch {
        working()
        // The reasons differ and so should the message: a wrong password is not the same
        // problem as a file somebody edited.
        questions.report(messageKey(for: error))
        return
      }
      working()
      questions.relaunch()
    }
  }

  /// An archive Finder handed over before the database opened, taken up once the start is
  /// over: the main window asks whenever the state of the environment changes.
  @MainActor
  static func resumeDeferred(in environment: AppEnvironment, questions: Questions? = nil) {
    guard let url = environment.pendingArchiveImport else { return }
    if case .starting = environment.state, !environment.isClosed { return }
    environment.pendingArchiveImport = nil
    begin(with: url, environment: environment, questions: questions)
  }
}
