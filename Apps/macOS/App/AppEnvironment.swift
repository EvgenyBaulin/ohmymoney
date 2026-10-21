import AppCore
import AppDatabase
import Foundation
import OSLog
import Observation
import SwiftUI
import Synchronization

/// Composition root: opens the database, applies the migrations that ship in `Schema/`
/// and hands the feature views everything they need.
@MainActor
@Observable
public final class AppEnvironment {
  public enum State: Equatable {
    case starting
    case ready
    /// Why the database did not open (`StartFailure`): the main window says it in words of the
    /// Common catalog and offers to try again or to go back to a copy (`DatabaseFailureView`);
    /// the type of the error goes to the journal only.
    case failed(StartFailure)
  }

  public private(set) var state: State = .starting
  public let language: AppLanguage
  /// Light or dark and the accent colour, kept in `UserDefaults` beside the language: the
  /// first window is drawn before the database is open.
  public let theme: AppTheme
  public let calendar = CalendarContext.system

  public private(set) var stack: DatabaseStack?

  private static let log = Logger(
    subsystem: "io.github.EvgenyBaulin.ohmymoney", category: "environment")
  public private(set) var transactions: TransactionRepository?
  public private(set) var references: ReferenceRepository?
  public private(set) var settings: SettingsRepository?
  public private(set) var rates: RateRepository?
  /// The custom currencies and their rates typed by hand; every write of them is a change of
  /// the planning the caller applies through the store, one step of ⌘Z.
  public private(set) var currencies: CurrencyRepository?
  /// Names, symbols and digits of the custom currencies, read at every open; a screen that
  /// changes them reads them again (`refreshCurrencyCatalog()`). `money` writes with it.
  public private(set) var currencyCatalog = CurrencyCatalog.empty
  /// Scheduled payments, limits, goals, expectations, reconciliations and debt journals.
  public private(set) var planning: PlanningRepository?
  /// The saved «what if» scenarios.
  public private(set) var scenarios: ScenarioRepository?
  /// «Это нормально» on an anomaly.
  public private(set) var anomalies: AnomalyRepository?
  /// The accounts and their groups, and the writes of them that are no step of ⌘Z.
  public private(set) var accounts: AccountRepository?
  /// The currency of everything new (`currencies.default`), read at every open; a screen that
  /// changes it reads it again (`refreshAccountSettings()`).
  public internal(set) var defaultCurrency: CurrencyCode = .rub
  /// Where the setup of the accounts stands (`accounts.setup`); `nil` while it is still due.
  public internal(set) var accountSetup: AccountSettings.Setup?
  /// The account whose screen is open: a new operation typed in the entry line goes to it
  /// unless the line or the panel names another.
  public var focusedAccountId: UUID?
  /// The currency and the event a new operation takes while the trip mode is on (`TripBanner`
  /// keeps it up to date); `nil` — the mode is off and the entry keeps its own defaults.
  public var tripEntryDefaults: TripMode.EntryDefaults?
  /// Names the entry line can recognise: people, places, payment methods, events,
  /// goals and debts. Refreshed whenever a dictionary changes.
  public private(set) var vocabulary = ParserVocabulary.empty
  /// Whether an event covering the day is applied to a new operation by itself.
  /// Off by default: a suggestion, not a decision. Changed through
  /// `setAssignsEventAutomatically(_:)`, which keeps the old value when the write is refused.
  public private(set) var assignsEventAutomatically: Bool = false

  /// The session before this one did not end (`SessionMarker`). The application says so and
  /// offers to gather a problem report, so that the next crash does not need a terminal.
  public internal(set) var lastSessionWasInterrupted = false

  /// What went wrong with a database a restore or an import staged, found at this launch. The
  /// main window says so once and offers the way on; nothing is retried in silence.
  public enum ReplacementProblem: Equatable, Sendable {
    /// The staged database could not be put in place: the one there was is open, and the
    /// staged file waits for «Повторить» or «Отказаться».
    case notApplied
    /// The staged database is one this build would not open — damaged, or written by a newer
    /// build. It was not put in place, and the database there was is open.
    case refused
  }

  public var replacementProblem: ReplacementProblem?

  /// The offer of a problem report after an interrupted session waits for the owner: the
  /// main window asks once, and whatever the answer, the offer is spent
  /// (`ProblemReportOffer`). The label in the settings stays as the second way in.
  public var offersProblemReport = false

  /// Enabled currencies the daily table of the bank lacked when the list was checked at the
  /// first launch (`CurrencyCheck`): the main window says so once, and its «OK» empties this.
  public var currenciesMissingAtBank: [CurrencyCode] = []

  /// «Справка» → «Собрать отчёт о проблеме…» asked for the report: the settings show it on a
  /// sheet of their own, gathered (`HelpCommands.collectReport`).
  public var showsProblemReport = false

  /// ⌘F was pressed: the Transactions window puts the focus into its search field as soon
  /// as it is there — at once when it is open, when it appears otherwise — and clears this.
  public var pendingSearchFocus = false

  /// The reconciliation sheet of the main window is open: the toolbar, the Overview card and
  /// a reminder ask for it from wherever they are.
  public var showsReconciliation = false

  /// The sheet «Я в поездке» of the main window is open (the toolbar asks for it).
  public var showsTrip = false

  /// The due dates that passed unpaid were asked about at this launch already: the question
  /// comes once a launch, not at every new window. Kept in memory only.
  public var overdueAskedThisLaunch = false

  /// The reminders are open on the due dates that passed unpaid.
  public var showsOverdue = false

  /// The order of the fields of the ↓ panel and of the editor of an operation, chosen in the
  /// settings. A habit of the owner, not data of the books: kept in `UserDefaults` beside the
  /// theme, carried by the archive (`portableSettings`), never a step of ⌘Z. Written whole —
  /// every field once — whatever is set (`EntryFieldOrder.sanitized`).
  public var entryFieldOrder: [EntryField] = AppEnvironment.storedEntryFieldOrder() {
    didSet {
      guard entryFieldOrder != oldValue else { return }
      UserDefaults.standard.set(
        EntryFieldOrder.encode(EntryFieldOrder.sanitized(entryFieldOrder)),
        forKey: Self.entryFieldOrderKey)
    }
  }

  /// The key of `entryFieldOrder` in `UserDefaults` and in the archive's `settings.json`.
  /// `nonisolated`: an archive being imported writes it from off the main actor, and the test
  /// guard reads it before the first test.
  nonisolated static let entryFieldOrderKey = "entry.fieldOrder"

  /// The order `UserDefaults` keeps, read as a whole order; the standard one when there is none.
  nonisolated static func storedEntryFieldOrder(
    in defaults: UserDefaults = .standard
  ) -> [EntryField] {
    EntryFieldOrder.decode(defaults.string(forKey: entryFieldOrderKey))
  }

  /// How a new operation is filled in, chosen in Settings → «Ввод»: the line at the bottom of the
  /// window, or the form of every field at the right (`EntryStyle`). A habit of the owner, kept in
  /// `UserDefaults` beside the order of the fields, carried by the archive (`portableSettings`),
  /// never a step of ⌘Z.
  public var entryStyle: EntryStyle = AppEnvironment.storedEntryStyle() {
    didSet {
      guard entryStyle != oldValue else { return }
      UserDefaults.standard.set(entryStyle.rawValue, forKey: Self.entryStyleKey)
    }
  }

  /// The key of `entryStyle` in `UserDefaults` and in the archive's `settings.json`.
  nonisolated static let entryStyleKey = "entry.style"

  /// The style `UserDefaults` keeps; the line when there is none or the word is not known.
  nonisolated static func storedEntryStyle(in defaults: UserDefaults = .standard) -> EntryStyle {
    EntryStyle(stored: defaults.string(forKey: entryStyleKey))
  }

  /// How Overview lays out its tiles — the groups in their order, the tiles in them, the hidden
  /// ones (`OverviewLayout`) —, edited in Settings → «Оформление» and on Overview itself
  /// («Изменить»). A habit of the owner, kept in `UserDefaults`, carried by the archive
  /// (`portableSettings`), never a step of ⌘Z. Beside the layout the flat list of the tiles shown
  /// is written under the key of the builds before groups (`overviewTilesKey`), so a build that
  /// knows only the list still shows what this one shows.
  public var overviewLayout: OverviewLayout = AppEnvironment.storedOverviewLayout() {
    didSet {
      guard overviewLayout != oldValue else { return }
      UserDefaults.standard.set(overviewLayout.encode(), forKey: Self.overviewLayoutKey)
      UserDefaults.standard.set(
        OverviewTiles.encode(overviewLayout.shown), forKey: Self.overviewTilesKey)
    }
  }

  /// The tiles Overview shows, group after group. Set to a flat list, it shows exactly those
  /// tiles, each in its group (`OverviewLayout.showingOnly`) — how the starter sets and the tests
  /// ask for tiles.
  public var overviewTiles: [OverviewTile] {
    get { overviewLayout.shown }
    set { overviewLayout = overviewLayout.showingOnly(newValue) }
  }

  /// The groups of Overview the owner collapsed: a habit of this Mac, kept in `UserDefaults` and
  /// not carried by the archive.
  public var overviewCollapsed: Set<OverviewTileGroup> = AppEnvironment.storedOverviewCollapsed() {
    didSet {
      guard overviewCollapsed != oldValue else { return }
      UserDefaults.standard.set(
        OverviewLayout.encodeCollapsed(overviewCollapsed), forKey: Self.overviewCollapsedKey)
    }
  }

  /// The key of the flat list of the builds before groups in `UserDefaults` and in the archive's
  /// `settings.json`: read where no layout is kept yet, written beside the layout.
  nonisolated static let overviewTilesKey = "overview.tiles"
  /// The key of `overviewLayout` in `UserDefaults` and in the archive's `settings.json`.
  nonisolated static let overviewLayoutKey = "overview.layout"
  /// The key of `overviewCollapsed` in `UserDefaults`.
  nonisolated static let overviewCollapsedKey = "overview.collapsed"

  /// The layout `UserDefaults` keeps; without one, the flat list of the builds before groups with
  /// every tile it lacks added at the end; without that either, the standard layout.
  nonisolated static func storedOverviewLayout(
    in defaults: UserDefaults = .standard
  ) -> OverviewLayout {
    OverviewLayout.decode(defaults.string(forKey: overviewLayoutKey))
      ?? OverviewLayout(tiles: OverviewTiles.decode(defaults.string(forKey: overviewTilesKey)))
  }

  /// The collapsed groups `UserDefaults` keeps.
  nonisolated static func storedOverviewCollapsed(
    in defaults: UserDefaults = .standard
  ) -> Set<OverviewTileGroup> {
    OverviewLayout.decodeCollapsed(defaults.string(forKey: overviewCollapsedKey))
  }

  /// «Найти пропущенные…» of a reconciliation: the Transactions window shows these days as
  /// soon as it is there, then clears this.
  public var pendingTransactionsRange: DayRange?

  /// Custom captions for the "for whom" values, for example Partner → «Девушка». Set from
  /// the settings; the tests set it directly, to see a caption reach a report and its CSV.
  public internal(set) var forWhomLabels: [ForWhom: String] = [:]
  /// Where the trained category model waits for the entry line. It belongs to the
  /// environment because it outlives a window and is read from several.
  let categoryModel = CategoryModelBox()
  public private(set) var backups: BackupService?
  /// The weekly check of the database and its repair (`IntegrityCheckService`).
  private(set) var integrity: IntegrityCheckService?
  @ObservationIgnored private var integrityLoop: Task<Void, Never>?
  public private(set) var csvExport: CSVExportService?
  public private(set) var archives: ArchiveService?
  public private(set) var rateService: RateService?
  /// The folder the owner picked for mirrored copies, usually inside iCloud Drive. The test
  /// host is the app itself, in the owner's container: it keeps a key of its own, so no test
  /// opens the owner's folder, saves its bookmark again or mirrors a synthetic copy into it.
  public internal(set) var backupFolder = BookmarkStore(
    key: AppEnvironment.isTestHost ? "tests.backup.folder" : "backup.folder")
  /// A folder was chosen, but its bookmark no longer opens — renamed, moved, gone with its
  /// volume. Nothing is mirrored until it is chosen again, and the Backups tab says so.
  public private(set) var mirrorFolderUnavailable = false
  /// The same folder once access has been opened for it. Kept here because every
  /// `startAccessingSecurityScopedResource` has to be balanced exactly once, and the
  /// application needs that access for as long as it runs.
  public private(set) var mirrorFolder: URL?
  /// The launch put an imported database in place and no folder for the copies opened: the
  /// main window asks for one once. Cleared when the question is answered.
  public var asksForMirrorFolder = false
  /// An archive Finder handed over before the database opened: a double click that launches
  /// the app delivers it while the launch still waits. It is taken up once the database has
  /// opened, or answered in words when it did not (`ArchiveImportFlow.resumeDeferred`).
  public var pendingArchiveImport: URL?

  /// «Скрыть суммы» of this Mac (`AmountPrivacy`): read by `money`, so every money text of
  /// the interface follows it.
  public let amounts: AmountPrivacy
  /// «Блокировать OhMyMoney» of this Mac (`PrivacyLock`): the cover of every window. Set once here;
  /// a test hands in a lock that applies, since the host's own never locks.
  var lock: PrivacyLock

  public var money: MoneyFormatter {
    MoneyFormatter(
      locale: language.locale, hidesAmounts: amounts.hidesAmounts,
      currencyStyle: theme.currencyStyle, catalog: currencyCatalog)
  }
  public var dates: DateFormatting { DateFormatting(locale: language.locale, calendar: calendar) }

  /// Where the moment `today` is taken from: the wall clock in the app, a fixed day in a test,
  /// so a rule about «a passed event» is judged on the day the test names, not on the date
  /// the tests happen to run (the yearly rollover went red on 1 January 2027 otherwise).
  @ObservationIgnored var now: () -> Date = { Date() }

  public var today: DateOnly { calendar.day(of: now()) }

  public init() {
    language = AppLanguage()
    theme = AppTheme()
    // The test host keeps neither switch: a test that hides the amounts or locks never does so
    // for the owner, whose `UserDefaults` the host shares. A data set is never locked.
    let defaults: UserDefaults? = Self.isTestHost ? nil : .standard
    amounts = AmountPrivacy(defaults: defaults)
    // The password of the lock lives in the Keychain of this Mac; the test host never touches it.
    lock = PrivacyLock(
      applies: !Self.isTestHost && AppPaths.dataSet == nil, defaults: defaults,
      passwords: Self.isTestHost ? InMemoryLockPasswordStore() : KeychainLockPasswordStore())
  }

  /// The stand-in of a view shown without the app's dependencies: never started, so it opens no
  /// database and writes nothing.
  init(missingDependency reader: String) {
    language = AppLanguage(missingDependency: reader)
    theme = AppTheme()
    amounts = AmountPrivacy(defaults: nil)
    lock = PrivacyLock(applies: false, defaults: nil)
  }

  /// Whether this is the stand-in of `AppDependencies.missing(in:)`.
  public var isPlaceholder: Bool { language.missingDependency != nil }

  public nonisolated static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  public nonisolated static var buildVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
  }

  public nonisolated static var systemVersion: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(version.majorVersion).\(version.minorVersion)"
  }

  /// Which build this is, for the journal and the problem report: the one that updates itself
  /// from GitHub, or the one the App Store updates.
  public nonisolated static var distribution: String {
    #if APPSTORE
      "appstore"
    #else
      "direct"
    #endif
  }

  /// The app is the host of its own unit tests. There nothing starts by itself — no
  /// pipeline, no observation of the database, no request to the bank: the tests
  /// build what they need.
  public nonisolated static var isTestHost: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// A new folder for the mirrored copies. Access to the folder that was in use is given
  /// back first, so the count of open security-scoped resources stays at one.
  public func useMirrorFolder(_ url: URL) {
    if let previous = mirrorFolder, previous != url {
      backupFolder.release(previous)
    }
    mirrorFolder = url
    mirrorFolderUnavailable = false
    if let backups {
      Task { await backups.setMirror(url) }
    }
  }

  /// Called after every change to the data: the copy itself is debounced.
  public func scheduleBackup() {
    guard let backups else { return }
    Task { await backups.scheduleBackup() }
  }

  /// Shortcut for a string with one placeholder.
  public func format(_ key: String, table: String = "Common", _ arguments: CVarArg...) -> String {
    String(format: language(key, table: table), locale: language.locale, arguments: arguments)
  }

  /// Shortcut for a string of counts, each grouped like every number (`AppLanguage`).
  public func format(_ key: String, table: String = "Common", counts: Int...) -> String {
    language.counted(key, table: table, counts)
  }

  /// The caption of a "for whom" value: the custom one when it was set, the translated
  /// default otherwise.
  public func label(for value: ForWhom) -> String {
    if let custom = forWhomLabels[value], !custom.isEmpty { return custom }
    return language("forWhom.\(value.rawValue)")
  }

  /// Returns whether the caption was written; the captions are read again either way, so a
  /// refused one shows the caption the database still has.
  @discardableResult
  public func setLabel(_ text: String, for value: ForWhom) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let written = attempt("settings.forWhom", on: settings) {
      try $0.set("forWhom.\(value.rawValue)", to: trimmed)
    }
    refreshForWhomLabels()
    return written
  }

  @discardableResult
  public func setAssignsEventAutomatically(_ isOn: Bool) -> Bool {
    guard isOn != assignsEventAutomatically else { return true }
    guard
      attempt(
        "settings.events", on: settings, { try $0.set("events.automatic", to: isOn ? "1" : "0") })
    else { return false }
    assignsEventAutomatically = isOn
    return true
  }

  /// One write of a screen that has no store of its own — a reference book, a template, a
  /// setting — and whether it landed.
  ///
  /// A refused write is never quiet: its name, the type of the error and its code go to the
  /// journal, and the caller keeps what the owner typed and says the change was not saved
  /// (`refusedWriteAlert`). A repository that is not there — the database not open yet, or already
  /// put down in the last seconds of a quit — refuses too: a write that went nowhere is not a write
  /// that landed. `name` is a word of ours, never a value.
  @discardableResult
  func attempt<Repository>(
    _ name: String, on repository: Repository?, _ write: (Repository) throws -> Void
  ) -> Bool {
    Self.attempt(name, on: repository, write)
  }

  /// The same, for a model that holds a repository of its own rather than the environment
  /// (`TemplatesModel`, `Templates.remember`).
  @discardableResult
  nonisolated static func attempt<Repository>(
    _ name: String, on repository: Repository?, _ write: (Repository) throws -> Void
  ) -> Bool {
    guard let repository else {
      AppLog.error(
        name, .db, "no database to write to", [LogPair("reason", .token("noDatabase"))])
      return false
    }
    do {
      try write(repository)
      return true
    } catch {
      AppLog.error(
        name, .db, "a write was refused",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return false
    }
  }

  // MARK: Answers about a count remembered

  /// The answers «Больше не спрашивать для этой сверки» keeps, read from the database now —
  /// not from the last snapshot of the numbers —, so an answer given a moment ago counts at
  /// once. Reconciliation → «было до сверки». Only the answers still of use are read, against
  /// the counts as the database has them now (`BeforeCountAnswers.pruned`): once every balance
  /// a count counted is counted on a later day, its answer dates nothing, though the next
  /// answer kept is the write that lets it go. Empty when there is no database, the counts
  /// cannot be read, or nothing is kept.
  func rememberedCountAnswers() -> [UUID: Bool] {
    guard let settings, let planning else { return [:] }
    let text = try? settings.string(PlanningSettings.beforeCountAnswersKey)
    let answers = PlanningSettings.countAnswers(from: text ?? nil)
    guard !answers.isEmpty, let counts = try? countedBalances(planning) else { return [:] }
    return BeforeCountAnswers.pruned(answers, balances: counts)
  }

  /// The balances as counted, from the reconciliations the database has now: what decides
  /// which answers about a count are still of use.
  private func countedBalances(_ planning: PlanningRepository) throws -> AccountBalances {
    let book = try planning.book()
    return AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances, accounts: [],
      tree: CategoryTree([]), now: now(), calendar: calendar)
  }

  /// «Забыть» under a count in the history of the sheet: its remembered answer goes, and the
  /// next operation of that day is asked again. A preference of the question, not a step of ⌘Z.
  @discardableResult
  func forgetCountAnswer(reconciliation: UUID) -> Bool {
    let written = attempt("reconcile.answerRefused", on: settings) { settings in
      var answers = PlanningSettings.countAnswers(
        from: try settings.string(PlanningSettings.beforeCountAnswersKey))
      answers[reconciliation] = nil
      try settings.set(
        PlanningSettings.beforeCountAnswersKey, to: PlanningSettings.countAnswersText(answers) ?? ""
      )
    }
    if written {
      AppLog.info(
        "reconcile.answerDropped", .db, "an answer about a count is forgotten",
        [LogPair("reconciliation", .id(reconciliation))])
    }
    return written
  }

  /// Keeps the answer to the question about the count of `reconciliation`: the next operation
  /// or transfer of that day is dated by it without asking. The answers of counts no longer on
  /// the latest counted day of any balance go in the same write (`BeforeCountAnswers.pruned`),
  /// read against the counts as the database has them now — and so does this one, when its
  /// reconciliation is no such count: no count at all, or a count of an earlier day than its
  /// balances' latest, which the next operation of its day is asked about again. A preference
  /// of the question, not a step of ⌘Z. Returns whether the answer is kept: written, and not
  /// let go of by the same write.
  @discardableResult
  func rememberCountAnswer(reconciliation: UUID, wasBefore: Bool) -> Bool {
    var isKept = false
    let written = attempt("reconcile.answerRefused", on: settings) { settings in
      guard let planning else { throw DatabaseError.notFound }
      let counts = try countedBalances(planning)
      var answers = PlanningSettings.countAnswers(
        from: try settings.string(PlanningSettings.beforeCountAnswersKey))
      answers[reconciliation] = wasBefore
      let kept = BeforeCountAnswers.pruned(answers, balances: counts)
      // No answer left is an empty text: it reads as no answer at all.
      try settings.set(
        PlanningSettings.beforeCountAnswersKey,
        to: PlanningSettings.countAnswersText(kept) ?? "")
      isKept = kept[reconciliation] != nil
    }
    guard written else { return false }
    let pairs = [
      LogPair("reconciliation", .id(reconciliation)), LogPair("before", .flag(wasBefore)),
    ]
    if isKept {
      AppLog.info("reconcile.answerKept", .db, "an answer about a count is remembered", pairs)
    } else {
      AppLog.info(
        "reconcile.answerPruned", .db,
        "an answer about a count is not kept: it is no count of its latest day", pairs)
    }
    return isKept
  }

  public func refreshForWhomLabels() {
    guard let settings else { return }
    var labels: [ForWhom: String] = [:]
    for value in ForWhom.allCases {
      if let custom = try? settings.string("forWhom.\(value.rawValue)"), !custom.isEmpty {
        labels[value] = custom
      }
    }
    forWhomLabels = labels
  }

  /// Applies the exchange rate to a draft in a foreign currency.
  ///
  /// The cached rate is used straight away so saving never waits for the network; when the
  /// day is not cached yet, the last known rate is used and the operation is marked
  /// provisional, and a background refresh fills the gap for the next one. A rate the owner
  /// typed by hand, or one that came with an import, is never touched.
  public func applyRate(to draft: inout TransactionDraft) {
    // A refund of a purchase is at the purchase's rate, whatever the day of the refund says.
    guard !Self.takesBackFromAPurchase(draft) else { return }
    let day = calendar.day(of: draft.occurredAt)
    let table = (try? rates?.table()) ?? RateTable()
    Self.applyRate(to: &draft, from: table, calendar: calendar)

    if draft.currency != .rub, draft.rateSource?.isProtected != true, let rateService {
      let currency = draft.currency
      Task { await rateService.refresh(day: day, currency: currency) }
    }
  }

  /// The rule itself, with the cache passed in: pure, so it can be exercised without a
  /// database. `RateTable` already knows the difference between a weekend the bank has said
  /// it never published — the rate of the preceding business day is final there — and a day
  /// whose own rate the cache does not hold yet, which the pipeline refines later.
  nonisolated static func applyRate(
    to draft: inout TransactionDraft, from table: RateTable, calendar: CalendarContext
  ) {
    // A refund taken back from a purchase part keeps the purchase's rate, so taking back the
    // whole part takes it to zero exactly: the rate of the refund's own day never replaces it.
    guard !takesBackFromAPurchase(draft) else { return }
    guard draft.currency != .rub else {
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      draft.rateProvisional = false
      return
    }
    guard draft.rateSource?.isProtected != true else { return }

    let day = calendar.day(of: draft.occurredAt)
    if let resolution = table.resolve(draft.currency, on: day) {
      draft.rate = resolution.rate.perUnit
      draft.rateDate = resolution.rate.date
      draft.rateSource = resolution.rate.source
      draft.rateProvisional = resolution.isProvisional
    } else if draft.rate == nil {
      // Nothing is known about this currency yet. The operation cannot be converted, and
      // the owner is told rather than handed a one-to-one total.
      draft.rateProvisional = true
    }
  }

  /// A refund that takes money back from a part of a purchase.
  nonisolated static func takesBackFromAPurchase(_ draft: TransactionDraft) -> Bool {
    draft.parts.contains { $0.refundOfPartId != nil }
  }

  /// Whether the cache can give `currency` a rate on the day of `date` — the one thing an
  /// operation in it needs before it can be counted in rubles.
  public func knowsRate(_ currency: CurrencyCode, on date: Date) -> Bool {
    guard currency != .rub else { return true }
    let table = (try? rates?.table()) ?? RateTable()
    return table.resolve(currency, on: calendar.day(of: date)) != nil
  }

  /// Converts an amount into rubles with the rate the draft carries.
  ///
  /// A foreign amount without a rate is refused rather than passed through: converting one
  /// to one would put the dollar figure into `amount_rub_e4`, and every total built on it —
  /// the month, the day, the categories, «Мне должны» — would be wrong by the rate, with
  /// nothing in the interface to show it.
  public func rublesConverter(for draft: TransactionDraft) -> (AmountE4) throws -> AmountE4 {
    guard draft.currency != .rub else { return { $0 } }
    guard let rate = draft.rate, rate > 0 else {
      return { _ in throw MoneyConversionError.rateMissing }
    }
    return { amount in try AmountE4(decimal: amount.decimal * rate) }
  }

  /// Settings that travel with the archive.
  public func portableSettings() -> [String: String] {
    var values: [String: String] = [
      "language": language.choice.rawValue,
      "theme.scheme": theme.scheme.rawValue,
      "theme.accent": theme.accent.rawValue,
      Self.entryFieldOrderKey: EntryFieldOrder.encode(entryFieldOrder),
      Self.entryStyleKey: entryStyle.rawValue,
      Self.overviewTilesKey: OverviewTiles.encode(overviewTiles),
      Self.overviewLayoutKey: overviewLayout.encode(),
      PlanningLayoutStore.orderKey: PlanningLayoutStore.portableOrder(in: .standard),
    ]
    if let currencies = try? settings?.enabledCurrencies() {
      values["currencies"] = currencies.map(\.code).joined(separator: ",")
    }
    return values
  }

  /// Opens the database of this launch. The file work and the migrations run off the main
  /// thread (`start(preparing:)`): the window draws the start meanwhile, and a slow migration
  /// of a future schema does not freeze it. A second window asking while this runs is turned
  /// away, and the first attaches what a start attaches (`AppLaunch`).
  public func start() async {
    let staging = StagingNotes()
    // The name of a main account the update may have to make, in the language of the
    // interface: the preparation runs off the main actor and cannot ask for it there.
    let context = MigrationContext(mainAccountName: language("accounts.mainDefaultName"))
    guard
      await start(preparing: { try Self.openDatabase(noting: staging, context: context) }),
      !isClosed
    else {
      return
    }
    // What the staged database came to is said once the start is over, open or not: the
    // window asks about it then.
    let notes = staging.notes
    if notes.refused {
      replacementProblem = .refused
    } else if case .notApplied = notes.replacement {
      replacementProblem = .notApplied
    }
    if notes.imported, case .ready = state { askForTheFolderOfTheCopiesIfNoneOpened() }
  }

  /// The database of this launch, from its folder: off the main thread.
  ///
  /// A database a newer build has to migrate — the owner's own after an update, a restored copy
  /// or an imported archive of an older version — is copied first, into the folder of copies,
  /// and the copy is checked (`BackupService.copyBeforeMigration`): it is the way back to the
  /// older version, which refuses the migrated file. No copy, no migration: the start fails
  /// with `StartFailure.copyBeforeUpdate` and the file stays as it was.
  private nonisolated static func openDatabase(
    noting staging: StagingNotes, context: MigrationContext
  ) throws -> DatabaseStack {
    // A data set that was not generated at this launch must be there already: the
    // Release build never makes one.
    if AppPaths.dataSet != nil,
      !FileManager.default.fileExists(atPath: AppPaths.databaseURL.path)
    {
      throw AppPaths.DataSetMissing()
    }
    try AppPaths.ensureDirectories()
    // A restore or an archive import staged a database last time: swap it in now, while
    // nothing has opened the old one yet.
    let refused = refuseAStagedDatabaseThisBuildCannotOpen()
    let replacement = AppPaths.applyPendingReplacement()
    let imported = AppPaths.takeImportMark(after: replacement)
    staging.note(.init(refused: refused, replacement: replacement, imported: imported))
    let schema = BundleSchemaSource()
    let pending = try DatabaseStack.pendingMigrations(fileAt: AppPaths.databaseURL, schema: schema)
    if let last = pending.last {
      // «перед обновлением до 10»: the schema the update goes up to is the number of its last step.
      let target = Int(last.prefix { $0.isNumber }).map(String.init)
      _ = try BackupService.copyBeforeMigration(
        of: AppPaths.databaseURL, into: AppPaths.backupsDirectory, now: Date(), schema: target)
    }
    return try DatabaseStack(url: AppPaths.databaseURL, schema: schema, context: context)
  }

  /// The start failed: said in the journal, and kept for the window by what it means. The
  /// copies stay within reach: exactly now is when one is needed, and every way back used to
  /// hang on the services an open database gives. The service of the copies is built over the
  /// file rather than over an open database (`UnopenedDatabase`): the Backups tab and the
  /// window list the copies as ever, and the state before a restore is copied from the file
  /// as it is. Nothing is mirrored and nothing scheduled — nothing writes here.
  private func fail(_ error: any Error) {
    let failure = StartFailure(error)
    // The message stays free of personal data: only the failure itself is reported.
    var pairs = [
      LogPair("error", .error(StartFailure.cause(of: error))),
      LogPair("reason", .token(failure.rawValue)),
    ]
    if let code = StartFailure.sqliteCode(of: error) { pairs.append(LogPair("code", .count(code))) }
    // «Миграции базы: с какой версии на какую, длительность, результат» — on the way down
    // too, not only in `db.opened`.
    switch error {
    case let migration as DatabaseStack.MigrationFailure:
      pairs += [
        LogPair("from", .count(migration.from)), LogPair("to", .count(migration.to)),
        LogPair("migration", .token(migration.migration ?? "none")),
        LogPair("ms", .milliseconds(migration.milliseconds)),
      ]
    case DatabaseError.migrationMismatch(let applied, let onDisk):
      pairs += [LogPair("from", .count(applied.count)), LogPair("to", .count(onDisk.count))]
    default:
      break
    }
    AppLog.error("db.failed", .db, "the database could not be opened", pairs)
    state = .failed(failure)
    backups = BackupService(
      source: UnopenedDatabase(url: AppPaths.databaseURL), directory: AppPaths.backupsDirectory)
  }

  /// A start that failed may be made again — «Повторить», or a copy staged in place of the
  /// file (`AppLaunch.retry`). Only a failed one: a start under way or done is left alone,
  /// and a closed environment opens nothing again.
  @discardableResult
  func forgetFailedStart() -> Bool {
    guard case .failed = state, !isPreparing, !isClosed else { return false }
    state = .starting
    return true
  }

  /// A staged database takes the place of the live one, and the live one is deleted once the move
  /// is done. So the staged file is asked first, by the rules the opening will apply: one this
  /// build would not open — a newer build wrote it, the disk damaged it, a build that did not check
  /// staged it — is dropped, not put in place. What it came from is still there (the copy in
  /// `backups/`, the archive), and so is the copy of the state before it. A schema this build
  /// cannot read leaves the file alone: the opening fails then anyway, and says so. Returns whether
  /// the staged file was refused.
  private nonisolated static func refuseAStagedDatabaseThisBuildCannotOpen() -> Bool {
    let staged = AppPaths.pendingReplacementURL
    guard FileManager.default.fileExists(atPath: staged.path),
      let verdict = try? DatabaseStack.check(fileAt: staged, schema: BundleSchemaSource()),
      verdict != .sound
    else { return false }
    AppLog.error(
      "db.replacementRefused", .db, "a staged database this build cannot open was not put in place",
      [LogPair("reason", .token(verdict == .newerSchema ? "newerSchema" : "damaged"))])
    AppPaths.discardPendingReplacement()
    return true
  }

  /// «После импорта приложение просит заново выбрать папку для копий бэкапов: закладки не
  /// переносятся». Asked at the launch that put the imported database in place,
  /// and only when no folder for the copies opened: on the Mac the archive came from, the folder
  /// is still there, and a data set mirrors nowhere.
  private func askForTheFolderOfTheCopiesIfNoneOpened() {
    guard AppPaths.dataSet == nil, mirrorFolder == nil else { return }
    asksForMirrorFolder = true
    AppLog.info(
      "backup.mirrorAsked", .backup, "the folder for copies is asked for after an import",
      [LogPair("unavailable", .flag(mirrorFolderUnavailable))])
  }

  /// A start whose database is made first, off the main thread: a data set generated at
  /// launch (Debug, `DataSetGeneration`). The window shows the start meanwhile; a second
  /// window asking to start is turned away until this one has finished.
  ///
  /// Returns whether this call was the one that made the database, whatever came of it:
  /// `--generate-only` quits from that window alone. A window turned away returns at once,
  /// while the set may still be half written (a second main window restored at launch).
  @discardableResult
  public func start(
    preparing prepare: @escaping @Sendable () throws -> DatabaseStack
  ) async -> Bool {
    guard case .starting = state, !isPreparing, !isClosed else { return false }
    isPreparing = true
    defer { isPreparing = false }
    do {
      let stack = try await Task.detached(priority: .userInitiated) { try prepare() }.value
      guard !isClosed else {
        // The quit closed this environment while the database was being opened: the new
        // stack is closed too, never handed out.
        await Task.detached { try? stack.close() }.value
        return true
      }
      try AppPaths.ensureDirectories()
      try open(stack)
    } catch {
      // A start the quit overtook says nothing more: the environment is closed.
      guard !isClosed else { return true }
      fail(error)
    }
    return true
  }

  /// A database is being made for this start (`start(preparing:)`).
  @ObservationIgnored private var isPreparing = false

  /// This environment has been closed and opens no database again.
  ///
  /// `close()` leaves `state` at `.starting` — the state a new environment has — so
  /// without this every `start()` after the ordered shutdown would pass its guard: in the
  /// two seconds `.terminateLater` keeps the app alive, a window whose `.task` had not run
  /// yet would open the database again, move a staged restore into place again, and leave
  /// that stack open for the rest of the process.
  ///
  /// The flag belongs to the instance, never to the type: the tests raise and drop several
  /// environments in one process, and a static flag would close the second one before it
  /// ever began.
  @ObservationIgnored public private(set) var isClosed = false

  /// Everything the app needs from an open database, and the first-launch work on it. Closes the
  /// database and lets go of everything reading it, after the pipeline has stopped. The
  /// repositories go first, so anything that still holds this environment reads `nil` rather than a
  /// closed connection.
  public func close() async {
    // The catch-up of the counts the open started writes through the stack: it lands before
    // anything is let go of.
    await countsCaughtUp()
    // A background request `applyRate` fired holds the service itself: closed first, it
    // cancels what is on its way and writes nothing after this.
    await rateService?.close()
    // The copy of the last change is written while the database is still open, not dropped;
    // no writer is left to change the database after it.
    integrityLoop?.cancel()
    integrityLoop = nil
    await backups?.finish()
    let closing = stack
    transactions = nil
    references = nil
    settings = nil
    rates = nil
    currencies = nil
    currencyCatalog = .empty
    planning = nil
    scenarios = nil
    anomalies = nil
    accounts = nil
    liveCounts = nil
    // The services were built on this stack too, and a caller that holds the environment
    // reaches them directly: `scheduleBackup()`, `applyRate(...)`. Left wired, they went on
    // writing through a closed connection for the whole terminate-later window (SQLITE_MISUSE,
    // no crash — but a late reader is owed `nil`, never a closed connection, and this is what
    // makes that true).
    backups = nil
    integrity = nil
    csvExport = nil
    archives = nil
    rateService = nil
    if let mirror = mirrorFolder {
      backupFolder.release(mirror)
      mirrorFolder = nil
    }
    // The services were built on this stack too, and a caller that holds the environment
    // reaches them directly: `scheduleBackup()`, `applyRate(...)`. Left wired, they went on
    // writing through a closed connection for the whole terminate-later window (SQLITE_MISUSE,
    // no crash — but a late reader is owed `nil`, never a closed connection, and this is what
    // makes that true).
    stack = nil
    state = .starting
    isClosed = true
    guard let closing else { return }
    // `close()` waits for the reads in flight, so it is not done on the main thread.
    let failure = await Task.detached {
      do {
        try closing.close()
        return String?.none
      } catch {
        return String(describing: type(of: error))
      }
    }.value
    if let failure {
      Self.log.error("the database did not close: \(failure, privacy: .public)")
      AppLog.error(
        "db.closeFailed", .db, "the database did not close", [LogPair("error", .typeName(failure))])
    } else {
      AppLog.info("db.closed", .db, "the database is closed")
    }
  }

  private func open(_ stack: DatabaseStack) throws {
    AppLog.info(
      "db.opened", .db, "the database is open",
      [
        LogPair("schema", .count(stack.applied.onDisk)),
        LogPair("migrated", .count(stack.applied.applied)),
        LogPair("ms", .milliseconds(stack.applied.milliseconds)),
      ])
    // What the update did to the accounts, when this open migrated: counts only.
    if !stack.applied.dataSteps.isEmpty {
      AppLog.info(
        "db.migrationStep", .db, "the data step of the update ran",
        stack.applied.dataSteps.sorted { $0.key < $1.key }.map {
          LogPair($0.key, .count($0.value))
        })
    }
    self.stack = stack
    // Every write that moves money settles the counts whose windows it reaches, in the owner's
    // calendar; «Сверка» is made again, when it has to be, in the language of the interface.
    let liveCounts = LiveCountsContext(
      calendar: calendar, categoryName: language("categories.reconciliation", table: "Settings"))
    self.liveCounts = liveCounts
    self.transactions = TransactionRepository(writer: stack.writer, liveCounts: liveCounts)
    self.references = ReferenceRepository(writer: stack.writer)
    self.settings = SettingsRepository(writer: stack.writer)
    self.rates = RateRepository(writer: stack.writer)
    self.currencies = CurrencyRepository(writer: stack.writer)
    self.planning = PlanningRepository(writer: stack.writer, liveCounts: liveCounts)
    self.scenarios = ScenarioRepository(writer: stack.writer, liveCounts: liveCounts)
    self.anomalies = AnomalyRepository(writer: stack.writer)
    self.accounts = AccountRepository(writer: stack.writer)
    let exportRepository = ExportRepository(writer: stack.writer)
    self.csvExport = CSVExportService(repository: exportRepository)
    self.archives = ArchiveService(stack: stack, appVersion: Self.appVersion)
    // A refinement that lets money back cover a part writes the income over it with the note
    // an edit gives it, in the language of the interface at that moment.
    self.rateService = RateService(
      repository: RateRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer, liveCounts: liveCounts),
      calendar: calendar, surplusNote: { TransactionsStore.surplusNote() })
    let backups = BackupService(stack: stack, directory: AppPaths.backupsDirectory)
    self.backups = backups
    // What a check found is kept in the settings of this Mac, but not by the test host or a
    // data set: neither has a book of the owner's to say anything of.
    let integrity = IntegrityCheckService(
      stack: stack, backups: backups,
      defaults: Self.isTestHost || AppPaths.dataSet != nil ? nil : .standard)
    self.integrity = integrity
    // Copies of a data set stay in its own folder: synthetic history has no place next to
    // the owner's copies in the mirrored folder.
    if AppPaths.dataSet == nil {
      if let mirror = backupFolder.resolve() {
        mirrorFolder = mirror
        Task { await backups.setMirror(mirror) }
      } else if backupFolder.isStored {
        mirrorFolderUnavailable = true
        AppLog.warning(
          "backup.mirrorUnavailable", .backup, "the folder chosen for copies could not be opened")
      }
    }
    if let references, let settings {
      try Self.seed(
        references: references, settings: settings, language: language.resolvedCode,
        isDataSet: AppPaths.dataSet != nil)
    }
    // The accounts first: every repair of the open after this one may write operations, and
    // an operation written without an account is given the main one.
    ensureMainAccount()
    ensureBanks()
    refreshAccountSettings()
    refreshCurrencyCatalog()
    dropFormulasThatNoLongerAddUp()
    chooseCashbackCategoryIfMissing()
    rolloverYearlyEvents()
    refreshVocabulary()
    refreshForWhomLabels()
    assignsEventAutomatically = (try? settings?.string("events.automatic")) == "1"
    state = .ready
    // The readable folder of a copy made before the update and the copy of the day, after the
    // launch: both read the whole database. The test host and a data set make neither — a
    // synthetic book has no copy of the day in the owner's folder.
    if !Self.isTestHost, AppPaths.dataSet == nil {
      Task.detached(priority: .utility) {
        await backups.fillReadableFolders()
        await backups.startDaily()
      }
      // The weekly check of the database: at the launch if it is due, and again every few hours
      // for an app that stays open for days.
      integrityLoop = Task { @MainActor in
        while !Task.isCancelled {
          await integrity.runIfDue()
          try? await Task.sleep(for: .seconds(6 * 3600))
        }
      }
    }
    // Beside the launch, off the main thread: on a long history the catch-up reads almost all
    // of it. Every write settles its own windows whenever it lands, and what the catch-up
    // writes reaches the figures the way any change does.
    let catchUp = ReconciliationRepository(writer: stack.writer)
    countsCatchUp = Task { await Self.settleCountsAtOpen(liveCounts, with: catchUp) }
  }

  /// How every write of this database settles the counts: the owner's calendar and «Сверка» in
  /// the language of the interface at the open. The catch-up of every full run settles with it
  /// too (`RunCountsSettle`). `nil` without an open database.
  @ObservationIgnored public private(set) var liveCounts: LiveCountsContext?

  /// The catch-up of the counts the open started (`settleCountsAtOpen`).
  @ObservationIgnored private var countsCatchUp: Task<Void, Never>?

  /// Waits until the catch-up of the counts the open started has landed; at once when there is
  /// none. `close()` waits for it before the database goes.
  public func countsCaughtUp() async {
    await countsCatchUp?.value
  }

  /// Exactly one live account is main at every open (`AccountRepository.ensureMainAccount`):
  /// a write cut short can leave two, an archived one flagged or none. A failure costs nothing
  /// but the repair, which the next open makes again; it is in the journal.
  private func ensureMainAccount() {
    guard let accounts else { return }
    do {
      guard let repair = try accounts.ensureMainAccount() else { return }
      AppLog.info(
        "accounts.mainRepaired", .db, "the accounts were left with one main account",
        [
          LogPair("account", .id(repair.mainId)), LogPair("madeMain", .flag(repair.madeMain)),
          LogPair("cleared", .count(repair.cleared)),
        ])
    } catch {
      AppLog.error(
        "accounts.repairFailed", .db, "the main account could not be checked",
        [LogPair("error", .error(error))])
    }
  }

  /// Every account is under a bank at every open (`AccountRepository.ensureBanks`): a hand edit,
  /// another program or a path that did not file an account leaves one without. A failure costs
  /// nothing but the repair, which the next open makes again; it is in the journal.
  private func ensureBanks() {
    guard let accounts else { return }
    do {
      guard let repair = try accounts.ensureBanks() else { return }
      AppLog.info(
        "accounts.banksFiled", .db, "accounts found without a bank were put under one",
        [
          LogPair("created", .count(repair.created)), LogPair("filed", .count(repair.filed)),
          LogPair("skipped", .count(repair.skipped)),
        ])
    } catch {
      AppLog.error(
        "accounts.banksFailed", .db, "the banks of the accounts could not be checked",
        [LogPair("error", .error(error))])
    }
  }

  /// The default currency and the state of the setup of the accounts, read from the database
  /// again: at every open, and by a screen that has just changed one of them.
  /// Reads the custom currencies again; nothing is kept when they cannot be read.
  public func refreshCurrencyCatalog() {
    currencyCatalog = (try? currencies?.catalog()) ?? .empty
  }

  public func refreshAccountSettings() {
    guard let settings else { return }
    defaultCurrency = (try? settings.defaultCurrency()) ?? .rub
    let stored = (try? settings.string(AccountSettings.setupKey)) ?? nil
    accountSetup = stored.flatMap {
      AccountSettings(storedValues: [AccountSettings.setupKey: $0]).setup
    }
  }

  /// The formulas kept with operations are read again at every open — a restore and an
  /// import open the database they staged the same way — by today's rule for amounts typed by
  /// hand. One saved when a lone comma was always decimal («1,500+2,50» was 4) no longer comes
  /// to its amount and is dropped; the amount stays, it is what was counted. A failure costs
  /// nothing but the check: a stale formula is only the words beside an amount.
  private func dropFormulasThatNoLongerAddUp() {
    guard let transactions else { return }
    do {
      let check = try transactions.dropFormulasThatNoLongerAddUp()
      guard check.dropped > 0 else { return }
      AppLog.info(
        "db.formulasDropped", .db, "formulas that no longer add up were dropped",
        [LogPair("checked", .count(check.checked)), LogPair("dropped", .count(check.dropped))])
    } catch {
      AppLog.error(
        "db.formulasCheckFailed", .db, "the formulas could not be checked",
        [LogPair("error", .error(error))])
    }
  }

  /// Every later count's difference follows the books once at every open, beside the launch
  /// (`ReconciliationRepository.settleAllInBackground`): the catch-up for counts whose windows
  /// got operations dated back while nothing settled them — the first open of a book of 1.1 —
  /// and for anything a missed path left behind; a difference whose count is gone goes. A first
  /// count the owner has not decided about is left as it is. Not a step of ⌘Z: the difference
  /// is derived. A failure costs nothing but the catch-up, which the next open makes again. A
  /// difference taken away because its count is gone, and a count whose difference still waits
  /// for a rate of the bank, are in the journal on their own — the second even when nothing was
  /// written.
  private static func settleCountsAtOpen(
    _ context: LiveCountsContext, with repository: ReconciliationRepository
  ) async {
    do {
      CountsJournal.record(
        try await repository.settleAllInBackground(context: context), atOpen: true)
    } catch {
      CountsJournal.failed(error)
    }
  }

  public func refreshVocabulary() {
    guard let references, let settings else { return }
    vocabulary =
      (try? references.vocabulary(
        enabledCurrencies: (try? settings.enabledCurrencies()) ?? CurrencyCode.defaultEnabled))
      ?? .empty
  }

  /// A yearly event that has already passed is recreated for the next year with the same
  /// series, which is what makes «сравнение с тем же событием прошлого года» possible.
  /// Runs at launch; an event that already exists in the series is left alone.
  ///
  /// A copy that has passed too — an event of three years ago, entered for the history or
  /// brought by an import — is rolled on in the same launch, until the series reaches an
  /// occurrence still to come: every year in between is made once, as a launch in each of
  /// those years would have made it.
  public func rolloverYearlyEvents() {
    guard let references else { return }
    var all = (try? references.events(includeArchived: true)) ?? []
    let today = self.today

    var pending = all.filter { $0.recurringYearly && $0.endDate < today }
    while !pending.isEmpty {
      let event = pending.removeFirst()
      let series = event.seriesId ?? event.id
      // The core moves the days, so 29 February becomes 28 February, never a day that is not.
      let next = EventPlanning.nextYear(of: DayRange(event.startDate, event.endDate))
      let nextStart = next.start
      let alreadyThere = all.contains { candidate in
        (candidate.seriesId ?? candidate.id) == series && candidate.startDate.year == nextStart.year
      }
      guard !alreadyThere else { continue }

      // The event keeps its length, so a trip of ten days stays ten days long.
      let nextEnd = next.end
      var original = event
      if original.seriesId == nil {
        original.seriesId = series
        try? references.save(original)
      }
      let copy = Event(
        name: event.name, kind: event.kind, startDate: nextStart, endDate: nextEnd,
        budgetE4: event.budgetE4, recurringYearly: true, seriesId: series)
      guard (try? references.save(copy)) != nil else { continue }
      all.append(copy)
      if copy.endDate < today { pending.append(copy) }
    }
  }

  private func daysBetween(_ from: DateOnly, _ to: DateOnly) -> Int {
    var days = 0
    var cursor = from
    while cursor < to, days < 400 {
      cursor = calendar.adding(days: 1, to: cursor)
      days += 1
    }
    return days
  }

  /// Cashback is the income of one category (`analytics.cashbackCategoryId`).
  /// While the setting has never been made, it goes to «Кэшбэк» under «Пассивный доход» of
  /// the starter tree, in either language; the owner changes it in Settings → Categories.
  /// A choice of «none» is a value too, and is left alone.
  private func chooseCashbackCategoryIfMissing() {
    guard let settings, let references,
      (try? settings.string(AnalyticsSettings.cashbackCategoryKey)) == nil,
      let categories = try? references.categories(includeArchived: false),
      let cashback = Self.defaultCashbackCategory(in: categories)
    else { return }
    try? settings.set(AnalyticsSettings.cashbackCategoryKey, to: cashback.id.uuidString)
  }

  /// The income subcategory called Cashback / Кэшбэк under Passive / Пассивный доход.
  nonisolated static func defaultCashbackCategory(
    in categories: [CoreKit.Category]
  ) -> CoreKit.Category? {
    let parents = Set(
      categories.filter {
        $0.kind == .income && $0.parentId == nil
          && ["passive", "пассивный доход"].contains($0.name.lowercased())
      }.map(\.id))
    return categories.first {
      $0.kind == .income && $0.parentId.map(parents.contains) == true
        && ["cashback", "кэшбэк"].contains($0.name.lowercased())
    }
  }

  /// First launch writes the starter categories in the interface language.
  ///
  /// A data set brings a category tree of its own, written before the start: the starter tree is
  /// not seeded there at all. Seeding keys on an empty table, not on `app.seeded`, so in a set
  /// whose tree had not landed it would add a second tree — two «Продукты» in every breakdown — or,
  /// with the tree landing after it, a second Goals and Loans the unique index refuses.
  nonisolated static func seed(
    references: ReferenceRepository, settings: SettingsRepository, language: String,
    isDataSet: Bool
  ) throws {
    if !isDataSet {
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: language))
    }
    if try settings.string("app.seeded") == nil {
      try settings.set("app.seeded", to: "1")
      // The ten of a fresh install, after whatever is on already: a currency an account holds
      // or the default one is never switched off here — the settings refuse that, and the
      // refusal would stop the start.
      let enabled = try settings.enabledCurrencies()
      try settings.setEnabledCurrencies(
        enabled + CurrencyCode.defaultEnabled.filter { !enabled.contains($0) })
    }
  }
}

/// Why an amount could not be turned into rubles. The case carries no amount and no
/// description: nothing personal ever reaches a message.
public enum MoneyConversionError: Error, Sendable {
  case rateMissing
}

/// What the preparation of a start found about a staged database — refused, put in place or
/// not, brought by an import. The preparation runs off the main actor (`start(preparing:)`);
/// the environment reads this back on it once the preparation is over, whether the database
/// then opened or not.
final class StagingNotes: Sendable {
  struct Notes: Sendable {
    var refused = false
    var replacement: AppPaths.Replacement = .nothingStaged
    var imported = false
  }

  private let storage = Mutex(Notes())

  func note(_ notes: Notes) {
    storage.withLock { $0 = notes }
  }

  var notes: Notes { storage.withLock { $0 } }
}
