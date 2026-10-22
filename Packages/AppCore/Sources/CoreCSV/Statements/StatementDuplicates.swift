import CoreKit
import Foundation

/// The stored identity of an operation that came from a statement. It is a versioned hash of
/// the normalised fields, never the text itself: the statement text is not kept, only what
/// is needed to recognise the same line when the same period is loaded again.
public struct StatementDedupKey: Sendable, Hashable, Codable, CustomStringConvertible {
  public static let currentVersion = "v1"
  public var value: String
  public var description: String { value }

  public init(value: String) { self.value = value }

  /// Account, day and minute of the operation, signed amount, currency, the cleaned
  /// description and, when the bank gives one, the document number. The document number only
  /// adds to the key: banks leave it empty for some operations and repeat it for a purchase
  /// and its refund, so it alone would merge or split the wrong lines. Status and posting day
  /// are left out on purpose, so a held line and its later posted self have one key.
  public init(account: String, operation: ImportedOperation) {
    let minute = operation.moment.minuteOfDay.map(String.init) ?? "-"
    let parts = [
      StatementText.collapse(account), operation.moment.day.iso, minute,
      String(operation.amount.raw), operation.currency.code,
      NameKey.fold(StatementText.collapse(operation.description)),
      NameKey.fold(operation.documentID ?? ""),
    ]
    value = Self.currentVersion + ":" + StatementText.fnv1a(parts.joined(separator: "\u{1F}"))
  }
}

/// Where an operation in the database came from.
public enum StatementSource: String, Sendable, Codable, Hashable {
  case manual
  case statement
  case screenshot
}

/// What the database remembers about an operation that was loaded from a statement; the
/// stored form of the new columns. Posting day and status are kept apart from the day of the
/// operation, the key finds the line again, the import id lets the whole import be undone.
public struct StatementOperationRecord: Sendable, Hashable, Codable {
  public var operationID: String
  public var source: StatementSource
  public var importID: String?
  public var postedOn: DateOnly?
  public var status: StatementStatus
  public var dedupKey: StatementDedupKey?

  public init(
    operationID: String, source: StatementSource, importID: String? = nil,
    postedOn: DateOnly? = nil, status: StatementStatus = .posted,
    dedupKey: StatementDedupKey? = nil
  ) {
    self.operationID = operationID
    self.source = source
    self.importID = importID
    self.postedOn = postedOn
    self.status = status
    self.dedupKey = dedupKey
  }
}

/// One loaded statement, for the list of imports and for undoing one: when, which account,
/// which period, how many lines, and the name of the file.
public struct StatementImportRecord: Sendable, Hashable, Codable {
  public var id: String
  public var accountID: String
  public var profileID: String
  public var fileName: String
  public var importedAt: Date
  public var periodFrom: DateOnly?
  public var periodTo: DateOnly?
  public var rowCount: Int
  public var newCount: Int
  public var duplicateCount: Int
  public var declinedCount: Int
  public var unparsedCount: Int

  public init(
    id: String, accountID: String, profileID: String, fileName: String, importedAt: Date,
    periodFrom: DateOnly?, periodTo: DateOnly?, rowCount: Int, newCount: Int,
    duplicateCount: Int, declinedCount: Int, unparsedCount: Int
  ) {
    self.id = id
    self.accountID = accountID
    self.profileID = profileID
    self.fileName = fileName
    self.importedAt = importedAt
    self.periodFrom = periodFrom
    self.periodTo = periodTo
    self.rowCount = rowCount
    self.newCount = newCount
    self.duplicateCount = duplicateCount
    self.declinedCount = declinedCount
    self.unparsedCount = unparsedCount
  }
}

/// An operation of the same account that is already in the database.
public struct StatementExisting: Sendable, Hashable {
  public var id: String
  public var key: StatementDedupKey
  public var status: StatementStatus
  public var day: DateOnly
  public var amount: AmountE4
  /// `ImportedOperation.placeKey` of the stored line: the place or person, folded.
  public var placeKey: String

  public init(
    id: String, key: StatementDedupKey, status: StatementStatus, day: DateOnly, amount: AmountE4,
    placeKey: String
  ) {
    self.id = id
    self.key = key
    self.status = status
    self.day = day
    self.amount = amount
    self.placeKey = placeKey
  }
}

/// What loading a statement into an account would do, line by line.
public struct StatementImportDiff: Sendable, Hashable {
  /// Indices into the incoming list: lines the database does not have yet.
  public var newIndices: [Int] = []
  /// Lines the database already has, to be skipped.
  public var duplicateIndices: [Int] = []
  /// A held line the database has, now posted in the statement: the stored line is updated
  /// (status, posting day), no second one is added.
  public var statusUpgrades: [StatementStatusUpgrade] = []
  /// A posted line that is the later self of a held one whose wording or day differ a little
  /// (see `StatementDeduplicator.heldMatchWindowDays`): proposed as a replacement.
  public var heldReplacements: [StatementStatusUpgrade] = []
}

public struct StatementStatusUpgrade: Sendable, Hashable {
  public var incomingIndex: Int
  public var existingID: String
}

public enum StatementDeduplicator {
  /// How far apart in days a held line and its posted self may be (the bank posts a Friday
  /// purchase on Monday).
  public static let heldMatchWindowDays = 5
  /// A held line that no statement has posted for this many days is asked about.
  public static let staleHeldDays = 14

  /// Compares the lines of a statement with what an account already holds.
  ///
  /// Lines are counted per key, not looked up: if the file has two identical lines and the
  /// database one, one line is new. Two real identical purchases are not merged, and
  /// loading overlapping statements adds only the difference. Among equal keys, a held
  /// stored line is paired with a posted incoming one first, so the update lands on the
  /// right line.
  public static func diff(
    incoming: [ImportedOperation], account: String, existing: [StatementExisting]
  ) -> StatementImportDiff {
    var result = StatementImportDiff()
    var existingByKey: [StatementDedupKey: [StatementExisting]] = [:]
    for item in existing { existingByKey[item.key, default: []].append(item) }
    // Held stored lines first, so they pair with posted incoming lines.
    for key in existingByKey.keys {
      existingByKey[key]?.sort { ($0.status == .pending ? 0 : 1) < ($1.status == .pending ? 0 : 1) }
    }
    var usedExisting = Set<String>()
    var pendingNew: [Int] = []

    var incomingByKey: [StatementDedupKey: [Int]] = [:]
    var keyOrder: [StatementDedupKey] = []
    for (index, operation) in incoming.enumerated() {
      let key = StatementDedupKey(account: account, operation: operation)
      if incomingByKey[key] == nil { keyOrder.append(key) }
      incomingByKey[key, default: []].append(index)
    }
    for key in keyOrder {
      let indices = incomingByKey[key] ?? []
      // Posted incoming lines pair with held stored lines first.
      let ordered = indices.sorted {
        (incoming[$0].status == .posted ? 0 : 1, $0) < (incoming[$1].status == .posted ? 0 : 1, $1)
      }
      let stored = existingByKey[key] ?? []
      for (position, index) in ordered.enumerated() {
        if position < stored.count {
          let match = stored[position]
          usedExisting.insert(match.id)
          if match.status == .pending, incoming[index].status == .posted {
            result.statusUpgrades.append(
              StatementStatusUpgrade(incomingIndex: index, existingID: match.id))
          } else {
            result.duplicateIndices.append(index)
          }
        } else {
          pendingNew.append(index)
        }
      }
    }

    // Held stored lines that no line paired with may be the earlier self of a posted line
    // under another day or wording: same amount and place, a few days apart.
    var openHeld = existing.filter { $0.status == .pending && !usedExisting.contains($0.id) }
    for index in pendingNew.sorted() {
      let operation = incoming[index]
      guard operation.status == .posted else {
        result.newIndices.append(index)
        continue
      }
      let candidates = openHeld.enumerated().filter { _, held in
        held.amount == operation.amount && held.placeKey == operation.placeKey
          && abs(StatementMoment.days(from: held.day, to: operation.moment.day))
            <= heldMatchWindowDays
      }
      if let best = candidates.min(by: {
        abs(StatementMoment.days(from: $0.element.day, to: operation.moment.day))
          < abs(StatementMoment.days(from: $1.element.day, to: operation.moment.day))
      }) {
        result.heldReplacements.append(
          StatementStatusUpgrade(incomingIndex: index, existingID: best.element.id))
        openHeld.remove(at: best.offset)
      } else {
        result.newIndices.append(index)
      }
    }
    result.newIndices.sort()
    result.duplicateIndices.sort()
    return result
  }

  /// Held lines that are older than `staleHeldDays` on `today` and were not posted by the
  /// latest statement; the person is asked whether to delete them.
  public static func staleHeld(
    existing: [StatementExisting], today: DateOnly, afterDiff diff: StatementImportDiff
  ) -> [StatementExisting] {
    let settled = Set(
      diff.statusUpgrades.map(\.existingID) + diff.heldReplacements.map(\.existingID))
    return existing.filter {
      $0.status == .pending && !settled.contains($0.id)
        && StatementMoment.days(from: $0.day, to: today) >= staleHeldDays
    }
  }
}

/// An operation the person entered by hand, for matching with the bank's line.
public struct StatementManualEntry: Sendable, Hashable {
  public var id: String
  public var day: DateOnly
  public var amount: AmountE4
  public var currency: CurrencyCode

  public init(id: String, day: DateOnly, amount: AmountE4, currency: CurrencyCode = .rub) {
    self.id = id
    self.day = day
    self.amount = amount
    self.currency = currency
  }
}

/// A line of the bank that looks like something the person already entered.
public struct StatementManualMatch: Sendable, Hashable {
  public enum Certainty: String, Sendable, Hashable {
    /// The amounts differ by no more than the merge tolerance: merge without asking, the
    /// amount is the bank's, the category and the comment stay the person's.
    case merge
    /// The amounts differ by more than that: ask.
    case ask
  }

  public var incomingIndex: Int
  /// One candidate when `candidateIDs.count == 1`; several mean the person picks.
  public var candidateIDs: [String]
  public var certainty: Certainty
}

public enum StatementManualMatcher {
  public static let dayWindow = 2
  /// Relative difference up to which a hand-entered amount is taken as the same operation
  /// (a tip rounded in the bank's favour).
  public static let mergeTolerance = Decimal(string: "0.01")!
  /// Beyond the merge tolerance but within this, the person is asked; farther lines are not
  /// candidates at all.
  public static let askTolerance = Decimal(string: "0.20")!

  /// Looks for hand-entered operations that stand for the new bank lines: same sign and
  /// currency, a day apart by at most `dayWindow`, amounts near each other. A hand entry is
  /// used by one line only, the closest amount first.
  public static func match(
    newOperations: [(index: Int, operation: ImportedOperation)], manual: [StatementManualEntry]
  ) -> [StatementManualMatch] {
    struct Pair {
      var index: Int
      var entry: StatementManualEntry
      var relative: Decimal
      var days: Int
    }
    var pairs: [Pair] = []
    for item in newOperations where item.operation.status != .declined {
      let bank = item.operation.amount
      for entry in manual
      where entry.currency == item.operation.currency && entry.amount.isNegative == bank.isNegative
        && abs(StatementMoment.days(from: entry.day, to: item.operation.moment.day)) <= dayWindow
      {
        let base = max(bank.magnitude.raw, entry.amount.magnitude.raw)
        guard base > 0 else { continue }
        let delta = abs(bank.raw - entry.amount.raw)
        let relative = Decimal(delta) / Decimal(base)
        guard relative <= askTolerance else { continue }
        pairs.append(
          Pair(
            index: item.index, entry: entry, relative: relative,
            days: abs(StatementMoment.days(from: entry.day, to: item.operation.moment.day))))
      }
    }
    var byIndex: [Int: [Pair]] = [:]
    for pair in pairs { byIndex[pair.index, default: []].append(pair) }
    var claimed = Set<String>()
    var matches: [StatementManualMatch] = []
    for index in byIndex.keys.sorted() {
      let ranked = (byIndex[index] ?? []).sorted {
        ($0.relative, $0.days, $0.entry.id) < ($1.relative, $1.days, $1.entry.id)
      }
      let free = ranked.filter { !claimed.contains($0.entry.id) }
      guard let best = free.first else { continue }
      let nearest = free.filter { $0.relative == best.relative && $0.days == best.days }
      let certainty: StatementManualMatch.Certainty =
        best.relative <= mergeTolerance ? .merge : .ask
      if nearest.count == 1 {
        claimed.insert(best.entry.id)
        matches.append(
          StatementManualMatch(
            incomingIndex: index, candidateIDs: [best.entry.id], certainty: certainty))
      } else {
        matches.append(
          StatementManualMatch(
            incomingIndex: index, candidateIDs: nearest.map(\.entry.id), certainty: .ask))
      }
    }
    return matches
  }
}
