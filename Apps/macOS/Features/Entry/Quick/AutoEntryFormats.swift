import AppCore
import Foundation

/// The formats of bank texts at hand: the app's own, the ones the owner keeps (`settings`
/// table, so they travel in the archive and are forgotten in a copy for someone else), and the
/// ones read from a folder the owner chose (a bookmark of this Mac; never carried by the
/// archive). What a folder holds is read once and kept until the owner asks again.
///
/// A text is never kept: a proposed format holds the words of the text and made-up figures, and
/// waits for the owner's answer in the habits of this Mac (`UserDefaults`).
@MainActor
enum AutoEntryFormats {
  nonisolated static let folderKey = "autoEntry.formatsFolder"
  nonisolated static let proposalsKey = "autoEntry.formatProposals"
  nonisolated static let offersKey = "autoEntry.formatOffers"
  nonisolated static let conflictsKey = "autoEntry.formatConflicts"
  /// Not more than this many formats wait for an answer, nor conflicts: they are hints.
  nonisolated static let waitingCapacity = 20

  static let folder = BookmarkStore(key: folderKey)

  // MARK: - Library

  /// What the folder held when it was last read; `loaded` — it has been read since the start.
  private(set) static var folderContents = SmsFolderContents()
  private static var loaded = false

  static func own(_ environment: AppEnvironment) -> OwnSmsFormats {
    OwnSmsFormats.decoded((try? environment.settings?.string(OwnSmsFormats.settingsKey)) ?? nil)
  }

  static func choices(_ environment: AppEnvironment) -> SmsFormatChoices {
    SmsFormatChoices.decoded(
      (try? environment.settings?.string(SmsFormatChoices.settingsKey)) ?? nil)
  }

  @discardableResult
  static func save(_ own: OwnSmsFormats, environment: AppEnvironment) -> Bool {
    guard let text = own.encoded() else { return false }
    return AppEnvironment.attempt("autoEntry.formats", on: environment.settings) {
      try $0.set(OwnSmsFormats.settingsKey, to: text)
    }
  }

  @discardableResult
  static func save(_ choices: SmsFormatChoices, environment: AppEnvironment) -> Bool {
    guard let text = choices.encoded() else { return false }
    return AppEnvironment.attempt("autoEntry.formatChoices", on: environment.settings) {
      try $0.set(SmsFormatChoices.settingsKey, to: text)
    }
  }

  /// The parser the texts of banks are read by: the owner's formats first, then the folder's,
  /// then the app's, and the general scan for what none of them fits.
  static func parser(_ environment: AppEnvironment) -> BankTextParser {
    if !loaded { reloadFolder() }
    var parser = BankTextParser(
      formats: SmsFormatLibrary(entries: own(environment).entries)
        .adding(folderContents.entries).adding(SmsFormatLibrary.builtIn.entries))
    parser.choices = choices(environment)
    return parser
  }

  // MARK: - Folder

  /// A folder the owner chose: remembered as a bookmark and read.
  @discardableResult
  static func chooseFolder(_ url: URL) -> SmsFolderContents {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      try folder.save(url)
    } catch {
      AppLog.warning(
        "autoEntry.folderFailed", .db, "the folder of formats could not be remembered",
        [LogPair("error", .error(error))])
    }
    return reloadFolder()
  }

  static func forgetFolder() {
    folder.clear()
    folderContents = SmsFolderContents()
    loaded = true
  }

  @discardableResult
  static func reloadFolder() -> SmsFolderContents {
    loaded = true
    guard folder.isStored, let url = folder.resolve() else {
      folderContents = SmsFolderContents()
      return folderContents
    }
    defer { folder.release(url) }
    folderContents = SmsFormatFolder.read(files: files(in: url))
    AppLog.info(
      "autoEntry.formatsFolder", .db, "the folder of formats was read",
      [
        LogPair("formats", .count(folderContents.entries.count)),
        LogPair("skipped", .count(folderContents.skipped.count)),
      ])
    return folderContents
  }

  /// A small text file is read, anything else passed over; a folder with more than this many
  /// files is not a folder of formats.
  private static let mostFiles = 5_000
  private static let largestFile = 1_000_000

  static func files(in root: URL) -> [SmsFolderFile] {
    let base = root.resolvingSymlinksInPath().path
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard
      let walker = FileManager.default.enumerator(
        at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles])
    else { return [] }
    var out: [SmsFolderFile] = []
    for case let url as URL in walker {
      guard out.count < mostFiles else { break }
      let ext = url.pathExtension.lowercased()
      guard ext == "txt" || ext == "json",
        let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
        (values.fileSize ?? 0) <= largestFile,
        let data = try? Data(contentsOf: url)
      else { continue }
      let full = url.resolvingSymlinksInPath().path
      guard full.hasPrefix(base + "/") else { continue }
      out.append(SmsFolderFile(path: String(full.dropFirst(base.count + 1)), data: data))
    }
    return out
  }

  // MARK: - Conflicts

  /// Two formats of one tier read a text differently: the ids are kept so the owner can pick
  /// once in the settings.
  static func recordConflict(_ candidates: [SmsFormatCandidate], defaults: UserDefaults = .standard)
  {
    let ids = candidates.map(\.formatId).sorted()
    var all = conflicts(defaults: defaults)
    guard !all.contains(ids) else { return }
    all.append(ids)
    if all.count > waitingCapacity { all.removeFirst(all.count - waitingCapacity) }
    defaults.set(all, forKey: conflictsKey)
  }

  static func conflicts(defaults: UserDefaults = .standard) -> [[String]] {
    defaults.array(forKey: conflictsKey) as? [[String]] ?? []
  }

  /// The owner picked: remembered, and the question is gone.
  static func resolveConflict(
    _ ids: [String], pick: String, environment: AppEnvironment, defaults: UserDefaults = .standard
  ) {
    var current = choices(environment)
    current.remember(pick, among: ids)
    save(current, environment: environment)
    defaults.set(conflicts(defaults: defaults).filter { $0 != ids }, forKey: conflictsKey)
  }

  // MARK: - Proposals

  /// A format drawn from a text a draft was made of, kept until the draft is written; the figures
  /// the text was read as, to compare with what the owner wrote.
  private struct Proposal: Codable {
    var text: String
    var amountRaw: Int64
    var kind: String
  }

  /// The text was read by the general scan: a format for its shape is drawn and waits for the
  /// draft to be finished.
  static func remember(
    message: BankMessage, draft id: UUID, defaults: UserDefaults = .standard
  ) {
    guard message.formatId == nil,
      let format = SmsFormatProposal.propose(
        text: message.source, message: message, id: "own." + UUID().uuidString.prefix(8))
    else { return }
    var all = proposals(defaults)
    all[id.uuidString] = Proposal(
      text: format.fileText, amountRaw: message.money.amount.raw, kind: message.kind.rawValue)
    if all.count > waitingCapacity, let oldest = all.keys.sorted().first {
      all[oldest] = nil
    }
    store(all, defaults)
  }

  private static func proposals(_ defaults: UserDefaults) -> [String: Proposal] {
    guard let data = defaults.data(forKey: proposalsKey) else { return [:] }
    return (try? JSONDecoder().decode([String: Proposal].self, from: data)) ?? [:]
  }

  private static func store(_ all: [String: Proposal], _ defaults: UserDefaults) {
    defaults.set(try? JSONEncoder().encode(all), forKey: proposalsKey)
  }

  /// A draft that was written as it came, without the owner's hand, offers nothing.
  static func forget(draft id: UUID, defaults: UserDefaults = .standard) {
    var all = proposals(defaults)
    guard all.removeValue(forKey: id.uuidString) != nil else { return }
    store(all, defaults)
  }

  /// The owner wrote an operation from a text of a bank. A text read by the general scan
  /// offers a format: from a pasted text with what the owner wrote (amount and kind) as the
  /// reading; from a draft (whose text is gone) only when what was written is what the draft
  /// was made as.
  static func offerFormat(
    pasted: BankMessage?, draft: UUID?, written: TransactionDraft,
    defaults: UserDefaults = .standard
  ) {
    var format: SmsFormat?
    if var message = pasted, message.formatId == nil, written.amount > .zero,
      written.currency == message.money.currency
    {
      message.money.amount = written.amount
      switch written.kind {
      case .income:
        message.operation = message.operation.kind == .income ? message.operation : .income
      case .refund: message.operation = .refund
      case .expense:
        message.operation = message.operation.kind == .expense ? message.operation : .purchase
      default: break
      }
      format = SmsFormatProposal.propose(
        text: message.source, message: message, id: "own." + UUID().uuidString.prefix(8))
    } else if let draft {
      var all = proposals(defaults)
      if let proposal = all.removeValue(forKey: draft.uuidString) {
        store(all, defaults)
        if proposal.amountRaw == written.amount.raw, proposal.kind == written.kind.rawValue,
          case .success(let parsed) = SmsFormat.parse(fileText: proposal.text, id: "own.draft")
        {
          format = parsed
        }
      }
    }
    guard let format else { return }
    var offers = offers(defaults)
    guard !offers.contains(where: { $0.text == format.fileText }) else { return }
    offers.append(OwnSmsFormats.Item(id: format.id, text: format.fileText))
    if offers.count > waitingCapacity { offers.removeFirst(offers.count - waitingCapacity) }
    defaults.set(try? JSONEncoder().encode(offers), forKey: offersKey)
  }

  static func offers(_ defaults: UserDefaults = .standard) -> [OwnSmsFormats.Item] {
    guard let data = defaults.data(forKey: offersKey) else { return [] }
    return (try? JSONDecoder().decode([OwnSmsFormats.Item].self, from: data)) ?? []
  }

  /// Keeps an offered format as the owner's own; returns the problems when it does not fit next
  /// to the ones kept (the offer is left then, to be dismissed).
  @discardableResult
  static func accept(
    _ item: OwnSmsFormats.Item, environment: AppEnvironment, defaults: UserDefaults = .standard
  ) -> [SmsFormatProblem] {
    guard case .success(let format) = SmsFormat.parse(fileText: item.text, id: item.id) else {
      return [.missingPattern]
    }
    var kept = own(environment)
    let problems = kept.add(format)
    guard problems.isEmpty else { return problems }
    save(kept, environment: environment)
    dismiss(item, defaults: defaults)
    return []
  }

  static func dismiss(_ item: OwnSmsFormats.Item, defaults: UserDefaults = .standard) {
    let rest = offers(defaults).filter { $0.id != item.id }
    defaults.set(try? JSONEncoder().encode(rest), forKey: offersKey)
  }
}
