import AppCore
import AppDatabase
import CryptoKit
import Foundation
import Observation

/// Asks the main window to open the loading of statements, with the files that were chosen or
/// dropped (none: the window asks which). The id makes a second request for the same files a new
/// one.
struct StatementImportRequest: Identifiable, Equatable {
  let id = UUID()
  var urls: [URL]
}

/// What the person answered for a group of like operations nothing else could place.
enum StatementAnswer: Equatable {
  /// File them under this category.
  case category(UUID)
  /// «Решить позже»: they go to «Не разобрано» and come back as a question.
  case later
}

/// A question about a group of lines: who or what is this, and where does it go.
struct StatementQuestion: Identifiable, Equatable {
  var group: StatementQuestionGroup
  var lines: [StatementRowRef]
  /// The name, phone or place the lines share, as the file wrote it. Personal data: shown, never
  /// logged.
  var title: String

  var id: String { group.topic.rawValue + "|" + group.key }
  /// Money went out of the person's pocket in the group (the categories offered are spending's).
  var isSpending: Bool { group.total.isNegative }
}

/// What a finished loading did, in counts.
struct StatementImportOutcome: Equatable {
  var imports: [String] = []
  var created = 0
  var merged = 0
  var upgraded = 0
  var transfers = 0
  var duplicates = 0
  var unsorted = 0
  var waitingForRate = 0
  var staleDeleted = 0
  var remembered = 0
}

/// The loading of statements: files in, a preview per file with ticks, the pairing of transfers
/// between the files, the questions, and one write. Nothing is written before `apply()`, and what
/// is written is what the preview showed. All the arithmetic is in `CoreCSV`
/// (`StatementPreviewBuilder`, `StatementSessionPlanner`, `StatementEntryBuilder`); this class
/// holds the state of the screen and does the reading and writing.
@MainActor
@Observable
final class StatementImportModel {
  /// What was found in a file.
  enum Reading {
    case parsed(StatementParseResult)
    /// No profile knows the format; the cells of the first row, for the request for the bank.
    case unknownFormat(hint: [String])
    case unreadable
    /// A PDF without a text layer (a scan): read by the recognition of a later release.
    case scan
    case failed
  }

  struct LoadedFile: Identifiable {
    var id: Int
    var name: String
    var fileHash: String?
    var reading: Reading
    var accountID: UUID?
    var preview: StatementPreview?
    /// The lines (positions in the file) that will be written.
    var ticks: Set<Int> = []
    /// For a line with several or farther hand-typed candidates: the one the person picked.
    var manualPicks: [Int: String] = [:]
    /// The same file was loaded before and not undone.
    var loadedBefore: Date?
    /// Delete the held lines that no statement has posted for weeks.
    var deleteStaleHeld = false
    var zoneID: String = TravelDay.moscowId

    var parsed: StatementParseResult? {
      if case .parsed(let result) = reading { return result }
      return nil
    }
  }

  // MARK: State

  private(set) var files: [LoadedFile] = []
  private(set) var transfers = StatementSessionTransfers()
  /// Lines of pairs the books already hold as a transfer (the same files met again): not written
  /// and not asked about.
  private(set) var knownTransferLegs: Set<StatementRowRef> = []
  /// The external id each pair will be written under, by its outgoing line.
  private var transferIDs: [StatementRowRef: String] = [:]
  private(set) var questions: [StatementQuestion] = []
  var answers: [String: StatementAnswer] = [:]
  var remember: [String: Bool] = [:]
  /// Soft pairs the person confirmed.
  var confirmedSoft: Set<StatementRowRef> = []
  private(set) var identity = StatementIdentity()
  private(set) var isReading = false
  private(set) var outcome: StatementImportOutcome?
  private var nextFileID = 0
  private var ruleCategories: [StatementRowRef: UUID] = [:]

  // MARK: Dependencies

  let environment: AppEnvironment
  let store: TransactionsStore
  private let dataset: () -> Dataset?
  private let now: () -> Date

  init(
    environment: AppEnvironment, store: TransactionsStore, dataset: @escaping () -> Dataset?,
    now: @escaping () -> Date = Date.init
  ) {
    self.environment = environment
    self.store = store
    self.dataset = dataset
    self.now = now
    identity = (try? environment.statementImports?.identity()) ?? StatementIdentity()
  }

  // MARK: Reading files

  /// The accounts a statement can be loaded into.
  var accounts: [PaymentMethod] {
    (dataset()?.paymentMethods ?? []).filter { !$0.archived }
  }

  /// Reads the files and shows their previews. A file that cannot be read is a row of its own
  /// that says why, never a silent drop.
  func add(urls: [URL]) async {
    isReading = true
    defer { isReading = false }
    let owned = (try? environment.statementImports?.profiles()) ?? []
    for url in urls {
      let scoped = url.startAccessingSecurityScopedResource()
      let data = try? Data(contentsOf: url)
      if scoped { url.stopAccessingSecurityScopedResource() }
      var file = LoadedFile(id: nextFileID, name: url.lastPathComponent, reading: .failed)
      nextFileID += 1
      if let data {
        file.fileHash = Self.hash(data)
        file.reading = await Self.read(data, fileExtension: url.pathExtension, owned: owned)
        file.loadedBefore = file.fileHash.flatMap {
          (try? environment.statementImports?.liveImport(withHash: $0))?.record.importedAt
        }
      }
      if let parsed = file.parsed {
        file.accountID = suggestedAccount(profileID: parsed.profileID, header: parsed.header)
        file.zoneID = Self.zoneID(of: parsed.profileID, owned: owned)
      }
      files.append(file)
      rebuild(file: file.id)
    }
    refresh()
  }

  /// SHA-256 of the file's bytes: the same file twice is noticed without keeping its text.
  nonisolated static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The reading itself, off the main actor: CSV by its header, PDF by its text layer.
  nonisolated static func read(
    _ data: Data, fileExtension: String, owned: [StatementProfile]
  ) async -> Reading {
    await Task.detached(priority: .userInitiated) { () -> Reading in
      let profiles = StatementProfiles.all + owned
      let isPDF = data.prefix(5) == Data("%PDF-".utf8) || fileExtension.lowercased() == "pdf"
      let result: StatementOutcome
      if isPDF {
        let lines = StatementPDFText.lines(from: data)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
          return .scan
        }
        result = StatementImporter.parsePDFText(lines, profiles: profiles)
      } else {
        result = StatementImporter.parseCSV(data, profiles: profiles)
      }
      switch result {
      case .parsed(let parsed): return .parsed(parsed)
      case .unknownFormat(let hint): return .unknownFormat(hint: hint)
      case .unreadable: return .unreadable
      }
    }.value
  }

  nonisolated static func zoneID(of profileID: String, owned: [StatementProfile]) -> String {
    (StatementProfiles.profile(id: profileID) ?? owned.first { $0.id == profileID })?.timeZoneID
      ?? TravelDay.moscowId
  }

  func remove(file id: Int) {
    files.removeAll { $0.id == id }
    refresh()
  }

  // MARK: Account

  /// The account the last import of this format went to; else the one whose name or bank carries
  /// the bank's name; else none, and the person picks.
  func suggestedAccount(profileID: String, header: StatementHeader) -> UUID? {
    let live = accounts
    let liveIDs = Set(live.map(\.id.uuidString))
    if let previous = (try? environment.statementImports?.imports())?.first(where: { stored in
      stored.record.profileID == profileID && !stored.isUndone
        && liveIDs.contains(stored.record.accountID)
    }) {
      return UUID(uuidString: previous.record.accountID)
    }
    guard let bankName = StatementProfiles.profile(id: profileID)?.bankName,
      let dataset = dataset()
    else { return nil }
    let wanted = NameKey.fold(bankName)
    let matches = live.filter { account in
      let bank = account.bankId.flatMap { id in dataset.banks.first { $0.id == id } }?.name
      return NameKey.fold(account.name).contains(wanted)
        || NameKey.fold(bank ?? "").contains(wanted)
    }
    return matches.count == 1 ? matches[0].id : nil
  }

  func setAccount(_ id: UUID?, for file: Int) {
    guard let index = files.firstIndex(where: { $0.id == file }) else { return }
    files[index].accountID = id
    rebuild(file: file)
    refresh()
  }

  // MARK: Preview

  /// The preview of one file against its account: the database is asked what the account holds.
  private func rebuild(file id: Int) {
    guard let index = files.firstIndex(where: { $0.id == id }), let parsed = files[index].parsed
    else { return }
    guard let accountID = files[index].accountID else {
      files[index].preview = nil
      files[index].ticks = []
      return
    }
    let imports = environment.statementImports
    let existing = (try? imports?.existing(account: accountID)) ?? []
    let days = parsed.operations.map(\.moment.day)
    var manual: [StatementManualEntry] = []
    if let first = days.min(), let last = days.max() {
      manual =
        (try? imports?.manualEntries(
          account: accountID, from: Self.shift(first, by: -StatementManualMatcher.dayWindow),
          to: Self.shift(last, by: StatementManualMatcher.dayWindow))) ?? []
    }
    let preview = StatementPreviewBuilder.build(
      parse: parsed, accountKey: accountID.uuidString, existing: existing, manual: manual,
      identity: identity, today: environment.today)
    files[index].preview = preview
    files[index].ticks = Set(preview.rows.filter(\.startsTicked).map(\.index))
    files[index].manualPicks = [:]
  }

  nonisolated static func shift(_ day: DateOnly, by days: Int) -> DateOnly {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    var parts = DateComponents()
    parts.year = day.year
    parts.month = day.month
    parts.day = day.day
    parts.hour = 12
    guard let date = calendar.date(from: parts),
      let moved = calendar.date(byAdding: .day, value: days, to: date)
    else { return day }
    let result = calendar.dateComponents([.year, .month, .day], from: moved)
    return DateOnly(
      year: result.year ?? day.year, month: result.month ?? day.month, day: result.day ?? day.day)
  }

  // MARK: Ticks

  func setTicked(_ on: Bool, row: Int, file: Int) {
    guard let index = files.firstIndex(where: { $0.id == file }) else { return }
    if on { files[index].ticks.insert(row) } else { files[index].ticks.remove(row) }
    refreshQuestions()
  }

  func tickAll(_ on: Bool, file: Int) {
    guard let index = files.firstIndex(where: { $0.id == file }),
      let rows = files[index].preview?.rows
    else { return }
    files[index].ticks = on ? Set(rows.filter { $0.disposition.changesBooks }.map(\.index)) : []
    refreshQuestions()
  }

  func pick(_ candidate: String?, row: Int, file: Int) {
    guard let index = files.firstIndex(where: { $0.id == file }) else { return }
    files[index].manualPicks[row] = candidate
    if candidate != nil { files[index].ticks.insert(row) }
  }

  func setDeleteStaleHeld(_ on: Bool, file: Int) {
    guard let index = files.firstIndex(where: { $0.id == file }) else { return }
    files[index].deleteStaleHeld = on
  }

  func confirmSoft(_ pair: StatementPairedLines, _ on: Bool) {
    if on {
      confirmedSoft.insert(pair.outgoing)
      confirmedSoft.insert(pair.incoming)
    } else {
      confirmedSoft.remove(pair.outgoing)
      confirmedSoft.remove(pair.incoming)
    }
  }

  // MARK: Who the owner is

  /// Saves who the owner is as banks write it (one step of ⌘Z) and reads every preview again:
  /// a transfer to the person's own phone is no longer a gift to a stranger.
  @discardableResult
  func saveIdentity(_ new: StatementIdentity) -> Bool {
    guard store.saveIdentity(new) else { return false }
    identity = new
    for file in files { rebuild(file: file.id) }
    refresh()
    return true
  }

  // MARK: Session

  /// Pairs the transfers between the files and asks what remains.
  func refresh() {
    let sessionFiles = files.compactMap { file -> StatementSessionFile? in
      guard let preview = file.preview, let account = file.accountID else { return nil }
      let account4 = dataset()?.paymentMethods.first { $0.id == account }
      var refs = Set<String>()
      if let number = preview.header.contractNumber { refs.insert(number) }
      if let number = preview.header.accountNumber { refs.insert(number) }
      return StatementSessionFile(
        key: file.id, accountKey: account.uuidString,
        bankName: StatementProfiles.profile(id: preview.profileID)?.bankName ?? account4?.name,
        ownReferences: refs, preview: preview)
    }
    transfers = StatementSessionPlanner.pairTransfers(
      files: sessionFiles, identity: identity, today: environment.today)
    assignTransferIDs()
    // A pair the books already hold as a transfer is the same files met again: its lines are
    // neither written nor asked about, and the id of a second equal pair stays what it was.
    let held = Set((dataset()?.transfers ?? []).compactMap(\.externalId))
    let known = (transfers.pairs + transfers.softPairs).filter {
      transferIDs[$0.outgoing].map(held.contains) ?? false
    }
    knownTransferLegs = Set(known.flatMap { [$0.outgoing, $0.incoming] })
    transfers.pairs.removeAll { knownTransferLegs.contains($0.outgoing) }
    transfers.softPairs.removeAll { knownTransferLegs.contains($0.outgoing) }
    confirmedSoft = confirmedSoft.intersection(transfers.pairedLines)
    refreshRuleCategories()
    refreshQuestions()
  }

  /// The external id of every pair, in the order the pairs were found: equal pairs get the
  /// next place, so they are told apart now and when the files are loaded again.
  private func assignTransferIDs() {
    transferIDs = [:]
    var places: [String: Int] = [:]
    for pair in transfers.pairs + transfers.softPairs {
      guard let out = row(pair.outgoing), let into = row(pair.incoming),
        let from = file(pair.outgoing.file)?.accountID, let to = file(pair.incoming.file)?.accountID
      else { continue }
      let base = StatementEntryBuilder.transferExternalID(
        outgoing: out.operation, from: from, incoming: into.operation, to: to)
      let place = places[base, default: 0]
      places[base] = place + 1
      transferIDs[pair.outgoing] =
        place == 0
        ? base
        : StatementEntryBuilder.transferExternalID(
          outgoing: out.operation, from: from, incoming: into.operation, to: to, ordinal: place)
    }
  }

  func isKnownTransfer(_ ref: StatementRowRef) -> Bool { knownTransferLegs.contains(ref) }

  private func file(_ id: Int) -> LoadedFile? { files.first { $0.id == id } }

  func row(_ ref: StatementRowRef) -> StatementPreviewRow? {
    file(ref.file)?.preview?.rows.first { $0.index == ref.row }
  }

  /// Lines that become a transfer: the pairs with no doubt, and the soft ones the person
  /// confirmed, where both halves are ticked.
  var writtenPairs: [StatementPairedLines] {
    let sure = transfers.pairs
    let soft = transfers.softPairs.filter {
      confirmedSoft.contains($0.outgoing) && confirmedSoft.contains($0.incoming)
    }
    return (sure + soft).filter { isTicked($0.outgoing) && isTicked($0.incoming) }
  }

  func isTicked(_ ref: StatementRowRef) -> Bool {
    file(ref.file)?.ticks.contains(ref.row) ?? false
  }

  private var transferLines: Set<StatementRowRef> {
    Set(writtenPairs.flatMap { [$0.outgoing, $0.incoming] }).union(knownTransferLegs)
  }

  // MARK: Rules and categories

  private func refreshRuleCategories() {
    ruleCategories = [:]
    guard let dataset = dataset() else { return }
    let tree = CategoryTree(dataset.categories)
    let rules = RuleOrder.sorted(dataset.rules).filter(\.enabled)
    guard !rules.isEmpty else { return }
    for file in files {
      guard let preview = file.preview else { continue }
      for row in preview.rows where row.disposition == .new {
        let verdict = RuleEngine.evaluate(
          subject(of: row.operation, account: file.accountID), rules: rules, tree: tree,
          presorted: true)
        if let category = verdict.category?.value {
          ruleCategories[StatementRowRef(file: file.id, row: row.index)] = category
        }
      }
    }
  }

  private func subject(of operation: ImportedOperation, account: UUID?) -> RuleSubject {
    RuleSubject(
      kind: StatementEntryBuilder.kind(of: operation), accountId: account,
      amountRubE4: operation.currency == .rub ? operation.amount.magnitude : nil,
      weekday: environment.calendar.weekdayIndex(operation.moment.day),
      minuteOfDay: operation.moment.minuteOfDay,
      texts: [operation.merchant, operation.counterparty.name, operation.description]
        .compactMap { $0 })
  }

  private func refreshQuestions() {
    var operations: [ImportedOperation] = []
    var refs: [StatementRowRef] = []
    let paired = transferLines
    for file in files {
      guard let preview = file.preview else { continue }
      for row in preview.rows where row.disposition == .new && file.ticks.contains(row.index) {
        let ref = StatementRowRef(file: file.id, row: row.index)
        // A line a rule of the person's already files, or half of a transfer, is not asked about.
        if paired.contains(ref) || ruleCategories[ref] != nil { continue }
        operations.append(row.operation)
        refs.append(ref)
      }
    }
    let selfEmployed = dataset()?.selfEmployment.enabled ?? false
    let groups = StatementQuestions.group(
      operations: operations, selfEmploymentEnabled: selfEmployed)
    questions = groups.map { group in
      let lines = group.indices.map { refs[$0] }
      let first = operations[group.indices[0]]
      let title =
        first.counterparty.name ?? first.counterparty.phone ?? first.merchant ?? first.description
      return StatementQuestion(group: group, lines: lines, title: title)
    }
    let ids = Set(questions.map(\.id))
    answers = answers.filter { ids.contains($0.key) }
  }

  func answer(_ answer: StatementAnswer?, for question: StatementQuestion) {
    if let answer { answers[question.id] = answer } else { answers[question.id] = nil }
  }

  func shouldRemember(_ question: StatementQuestion) -> Bool {
    remember[question.id] ?? question.group.rememberByDefault
  }

  /// The category a line is filed under and who chose it: a rule of the person's, the answer to
  /// its question, or «Не разобрано».
  private func category(of ref: StatementRowRef, kind: TransactionKind) -> UUID? {
    if let answered = questions.first(where: { $0.lines.contains(ref) }),
      case .category(let id)? = answers[answered.id]
    {
      let categories = dataset()?.categories ?? []
      if categories.first(where: { $0.id == id })?.kind == kind.categoryKind { return id }
    }
    return ruleCategories[ref]
  }

  // MARK: Words for the screen

  @ObservationIgnored private var cachedNames: RuleNames?

  /// «Продукты › Овощи»: how a category is named in the pickers.
  func categoryName(_ id: UUID) -> String {
    if cachedNames == nil, let dataset = dataset() { cachedNames = RuleNames(dataset: dataset) }
    return cachedNames?.category(id) ?? "?"
  }

  /// Where a new line will be filed, in words, and whether that is the category of the lines no
  /// one has placed yet.
  func filing(of ref: StatementRowRef) -> (text: String, isUnsorted: Bool)? {
    guard let row = row(ref), row.disposition == .new else { return nil }
    let kind = StatementEntryBuilder.kind(of: row.operation)
    if let id = category(of: ref, kind: kind) { return (categoryName(id), false) }
    return (ImportText.t("import.unsorted", environment), true)
  }

  /// The hand-typed operation a candidate id stands for, for the picker.
  func handEntry(_ id: String) -> TransactionEntry? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return dataset()?.entries.first { $0.id == uuid }
  }

  /// The categories an answer may file a group under: spending's or income's, never a system one.
  func categoryChoices(spending: Bool) -> [(id: UUID, title: String)] {
    guard let dataset = dataset() else { return [] }
    let tree = CategoryTree(dataset.categories)
    let kind: CategoryKind = spending ? .expense : .income
    return dataset.categories
      .filter { !$0.archived && $0.kind == kind && tree.systemRole(of: $0.id) == nil }
      .map { ($0.id, categoryName($0.id)) }
      .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
  }

  // MARK: Counts for the screen

  /// How many lines the loading writes, merges and upgrades, and how many pairs become transfers.
  var plan: (write: Int, change: Int, transfers: Int) {
    var write = 0
    var change = 0
    let skipped = transferLines
    for file in files {
      guard let preview = file.preview, preview.isImportable else { continue }
      for row in preview.rows where file.ticks.contains(row.index) {
        let ref = StatementRowRef(file: file.id, row: row.index)
        if skipped.contains(ref) { continue }
        switch row.disposition {
        case .new: write += 1
        case .duplicate: break
        case .manualAsk where file.manualPicks[row.index] == nil: write += 1
        default: change += 1
        }
      }
    }
    return (write, change, writtenPairs.count)
  }

  var canApply: Bool {
    guard outcome == nil else { return false }
    let counts = plan
    let staleDeletes = files.contains {
      $0.deleteStaleHeld && !($0.preview?.staleHeld.isEmpty ?? true)
    }
    return counts.write + counts.change + counts.transfers > 0 || staleDeletes
  }

  // MARK: Writing

  /// The category «Не разобрано» of a kind, existing or to be made.
  private struct Unsorted {
    var expense: UUID
    var income: UUID
    var made: [CoreKit.Category]
    var settings: [String: String?]
  }

  private func unsortedCategories() -> Unsorted {
    let categories = dataset()?.categories ?? []
    func existing(_ key: String, _ kind: CategoryKind) -> UUID? {
      guard let text = (try? environment.settings?.string(key)) ?? nil,
        let id = UUID(uuidString: text),
        categories.contains(where: { $0.id == id && !$0.archived && $0.kind == kind })
      else { return nil }
      return id
    }
    var made: [CoreKit.Category] = []
    var settings: [String: String?] = [:]
    let name = environment.language("import.unsorted", table: ImportText.table)
    func make(_ kind: CategoryKind) -> UUID {
      let category = CoreKit.Category(kind: kind, name: name, sort: 9_000)
      made.append(category)
      return category.id
    }
    let expense = existing(StatementSettings.unsortedCategoryKey, .expense) ?? make(.expense)
    let income = existing(ImportSettings.unsortedIncomeKey, .income) ?? make(.income)
    if made.contains(where: { $0.id == expense }) {
      settings[StatementSettings.unsortedCategoryKey] = expense.uuidString
    }
    if made.contains(where: { $0.id == income }) {
      settings[ImportSettings.unsortedIncomeKey] = income.uuidString
    }
    return Unsorted(expense: expense, income: income, made: made, settings: settings)
  }

  private func rates() -> RateTable { (try? environment.rates?.table()) ?? RateTable() }

  /// Writes everything the preview showed. The rows of the import go in first, the rules the
  /// person asked to remember next, and the operations last, so the first ⌘Z takes the
  /// operations back at once.
  @discardableResult
  func apply() -> Bool {
    guard canApply, let dataset = dataset() else { return false }
    let stamp = now()
    let tree = CategoryTree(dataset.categories)
    let table = rates()
    let unsorted = unsortedCategories()
    let paired = writtenPairs
    let pairedLines = transferLines
    var made = StatementImportOutcome()
    var created: [TransactionEntry] = []
    var rewritten: [TransactionEntry] = []
    var newTransfers: [Transfer] = []
    var upgrades: [StatementStatusWrite] = []
    var softDeleted: [UUID] = []
    var records: [(StatementImportRecord, String?)] = []
    var usesUnsorted = false
    var keysSeen: [UUID: [StatementDedupKey: Int]] = [:]

    func rubles(_ operation: ImportedOperation) -> StatementRubles? {
      StatementRubleResolver.resolve(operation) { currency, day in
        table.resolve(currency, on: day).map { ($0.rate.perUnit, $0.isProvisional) }
      }
    }

    for file in files {
      guard let preview = file.preview, preview.isImportable, let accountID = file.accountID
      else { continue }
      let importID = UUID()
      let accountKey = accountID.uuidString
      let cards = dataset.cards.filter { $0.accountId == accountID && !$0.archived }
      var written = 0
      var skippedInFile = 0
      var fileChanged = 0
      // Overlapping files of one account: a line an earlier file of this loading wrote is
      // counted as seen, per key, the way the database's own lines are.
      var inThisFile: [StatementDedupKey: Int] = [:]
      for row in preview.rows where file.ticks.contains(row.index) {
        let ref = StatementRowRef(file: file.id, row: row.index)
        if pairedLines.contains(ref) { continue }
        let operation = row.operation
        guard let money = rubles(operation) else {
          made.waitingForRate += 1
          continue
        }
        switch row.disposition {
        case .duplicate:
          continue
        case .statusUpgrade(let existingID):
          if let id = UUID(uuidString: existingID) {
            upgrades.append(
              StatementStatusWrite(
                operationId: id, status: operation.status, postedOn: operation.postedOn))
            made.upgraded += 1
            fileChanged += 1
          }
        case .heldReplacement(let existingID), .manualMerge(let existingID):
          if let merged = merge(
            existingID, operation, accountKey: accountKey, zone: file.zoneID,
            money: money, stamp: stamp)
          {
            rewritten.append(merged)
            made.merged += 1
            fileChanged += 1
          }
        case .manualAsk where file.manualPicks[row.index] != nil:
          if let merged = merge(
            file.manualPicks[row.index] ?? "", operation, accountKey: accountKey,
            zone: file.zoneID, money: money, stamp: stamp)
          {
            rewritten.append(merged)
            made.merged += 1
            fileChanged += 1
          }
        case .new, .manualAsk:
          let key = StatementDedupKey(account: accountKey, operation: operation)
          inThisFile[key, default: 0] += 1
          if inThisFile[key, default: 0] <= keysSeen[accountID, default: [:]][key, default: 0] {
            skippedInFile += 1
            made.duplicates += 1
            continue
          }
          let kind = StatementEntryBuilder.kind(of: operation)
          var categoryID = category(of: ref, kind: kind)
          if categoryID == nil {
            categoryID = kind == .income ? unsorted.income : unsorted.expense
            usesUnsorted = true
            made.unsorted += 1
          }
          let quality: Quality? =
            kind.hasQuality
            ? QualityResolver.resolve(categoryId: categoryID, categories: tree).quality : nil
          let verdictPlace = placeRule(for: operation, account: accountID, dataset: dataset)
          let card = operation.cardTail.flatMap { tail in
            cards.first { $0.last4 == tail }?.id
          }
          created.append(
            StatementEntryBuilder.entry(
              for: operation, accountID: accountID, accountKey: accountKey, importID: importID,
              zoneID: file.zoneID, rubles: money,
              choice: StatementEntryChoice(
                categoryID: categoryID,
                categorySource: ruleCategories[ref] != nil ? .imported : .manual,
                quality: quality, placeID: verdictPlace, cardID: card),
              now: stamp))
          written += 1
        }
      }
      for (key, count) in inThisFile {
        keysSeen[accountID, default: [:]][key] = max(
          keysSeen[accountID, default: [:]][key] ?? 0, count)
      }
      if file.deleteStaleHeld {
        let stale = preview.staleHeld.compactMap { UUID(uuidString: $0.id) }
        softDeleted += stale
        made.staleDeleted += stale.count
      }
      made.duplicates += preview.duplicateCount
      let touched = written + fileChanged
      let hasPair = paired.contains { $0.outgoing.file == file.id || $0.incoming.file == file.id }
      if touched > 0 || hasPair {
        let period = preview.period
        records.append(
          (
            StatementImportRecord(
              id: importID.uuidString, accountID: accountID.uuidString,
              profileID: preview.profileID, fileName: file.name, importedAt: stamp,
              periodFrom: period?.from, periodTo: period?.to,
              rowCount: preview.rows.count + preview.declinedCount + preview.unparsedCount,
              newCount: written, duplicateCount: preview.duplicateCount + skippedInFile,
              declinedCount: preview.declinedCount, unparsedCount: preview.unparsedCount),
            file.fileHash
          ))
        made.imports.append(importID.uuidString)
      }
    }

    // Transfers: both halves are lines of two files, each written to its own account.
    for pair in paired {
      guard let out = row(pair.outgoing), let into = row(pair.incoming),
        let outFile = file(pair.outgoing.file), let inFile = file(pair.incoming.file),
        let from = outFile.accountID, let to = inFile.accountID
      else { continue }
      var transfer = StatementEntryBuilder.transfer(
        outgoing: out.operation, from: from, incoming: into.operation, to: to,
        zoneID: outFile.zoneID, now: stamp)
      transfer.externalId = transferIDs[pair.outgoing] ?? transfer.externalId
      newTransfers.append(transfer)
    }
    made.duplicates += knownTransferLegs.count / 2
    made.transfers = newTransfers.count
    made.created = created.count

    // Rules to remember, one per answered group the person wants remembered.
    let rules = rulesToRemember(dataset: dataset)
    made.remembered = rules.count

    // Each of these is a step of ⌘Z; if the write of the operations is refused, they are taken
    // back, so a failure leaves no import row, no rule and no upgraded line behind.
    var steps = 0
    for record in records where store.recordImport(record.0, fileHash: record.1) { steps += 1 }
    if !upgrades.isEmpty, store.upgradeStatements(upgrades) { steps += 1 }
    for rule in rules where store.addRule(rule) { steps += 1 }

    var change = PlanningChange(
      created: created, upsert: PlanningRows(transfers: newTransfers), rewritten: rewritten,
      softDeleted: softDeleted, at: stamp)
    if usesUnsorted {
      change.upsert.categories = unsorted.made
      change.settings = unsorted.settings
    }
    let isEmpty =
      created.isEmpty && rewritten.isEmpty && newTransfers.isEmpty
      && softDeleted.isEmpty
    if !isEmpty, !store.apply(change) {
      for _ in 0..<steps { store.undo() }
      return false
    }
    outcome = made
    AppLog.info(
      "import.applied", .db, "statements were loaded",
      [
        LogPair("files", .count(records.count)), LogPair("new", .count(made.created)),
        LogPair("merged", .count(made.merged)), LogPair("upgraded", .count(made.upgraded)),
        LogPair("transfers", .count(made.transfers)),
      ])
    return true
  }

  private func merge(
    _ existingID: String, _ operation: ImportedOperation, accountKey: String, zone: String,
    money: StatementRubles, stamp: Date
  ) -> TransactionEntry? {
    guard let id = UUID(uuidString: existingID),
      let entry = (try? environment.transactions?.entry(id: id)) ?? nil
    else { return nil }
    return StatementEntryBuilder.merged(
      entry, with: operation, accountKey: accountKey, zoneID: zone, rubles: money, now: stamp)
  }

  private func placeRule(
    for operation: ImportedOperation, account: UUID, dataset: Dataset
  ) -> UUID? {
    let rules = RuleOrder.sorted(dataset.rules).filter(\.enabled)
    guard !rules.isEmpty else { return nil }
    return RuleEngine.evaluate(
      subject(of: operation, account: account), rules: rules,
      tree: CategoryTree(dataset.categories), presorted: true
    ).place?.value
  }

  private func rulesToRemember(dataset: Dataset) -> [Rule] {
    var position = (dataset.rules.map(\.position).max() ?? -1) + 1
    var result: [Rule] = []
    for question in questions where shouldRemember(question) {
      guard case .category(let id)? = answers[question.id], !question.title.isEmpty else {
        continue
      }
      result.append(
        Rule(
          name: question.title, position: position, origin: .imported,
          conditions: [.textContains(question.title)], actions: [.setCategory(id)]))
      position += 1
    }
    return result
  }
}

/// Settings keys of the loading of statements that this build adds to the ones of `CoreCSV`.
enum ImportSettings {
  /// The income twin of `StatementSettings.unsortedCategoryKey`: an income an answer was put off
  /// for goes to an income category, as an operation's category must be of its kind.
  static let unsortedIncomeKey = "import.unsortedIncomeCategory"
}
