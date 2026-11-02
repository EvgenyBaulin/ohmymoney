import CoreKit
import Foundation

/// What moving a table in would do, line by line, before anything is written.
public struct MigrationPreview: Sendable, Hashable {
  public enum Disposition: Sendable, Hashable {
    case new
    /// The same line is in the books already (this file, or one like it, was moved in before).
    case duplicate
    /// An operation typed by hand looks like it (same account, sign and currency, a day or two
    /// apart, a near amount). Left out unless the person ticks it.
    case likelyDuplicate
    /// In a currency the rates on hand do not cover for its day: it cannot be written yet.
    case waitingForRate
  }

  /// One per operation of the parse, in its order.
  public var dispositions: [Disposition]

  public init(dispositions: [Disposition]) { self.dispositions = dispositions }

  public func count(_ disposition: Disposition) -> Int {
    dispositions.filter { $0 == disposition }.count
  }

  /// The lines ticked to be written at first: the new ones.
  public var defaultTicks: Set<Int> {
    Set(dispositions.indices.filter { dispositions[$0] == .new })
  }
}

/// What a write of a table makes: the operations and an import row per account the operations
/// went to (each account's lines can be undone as one import). New categories are made apart
/// (`MigrationCategoryPlan`).
public struct MigrationWrite: Sendable, Hashable {
  public var entries: [TransactionEntry]
  public var imports: [StatementImportRecord]
}

public enum MigrationPlanner {
  /// Sorts the lines of a parse. `account` maps the other application's account name to an own
  /// account (`nil`: not written); `existing` and `manual` are what each own account already
  /// holds; `hasRate` says whether a line's rubles can be worked out now.
  public static func preview(
    _ parse: MigrationParse, account: (String) -> UUID?,
    existing: (UUID) -> [StatementExisting], manual: (UUID) -> [StatementManualEntry],
    hasRate: (ImportedOperation) -> Bool
  ) -> MigrationPreview {
    var dispositions = Array(
      repeating: MigrationPreview.Disposition.new, count: parse.operations.count)
    var byAccount: [UUID: [Int]] = [:]
    for (index, line) in parse.operations.enumerated() {
      guard let id = account(line.operation.accountRef) else { continue }
      byAccount[id, default: []].append(index)
    }
    for (id, indices) in byAccount {
      let incoming = indices.map { parse.operations[$0].operation }
      let diff = StatementDeduplicator.diff(
        incoming: incoming, account: id.uuidString, existing: existing(id))
      for position in diff.duplicateIndices + diff.statusUpgrades.map(\.incomingIndex)
        + diff.heldReplacements.map(\.incomingIndex)
      {
        dispositions[indices[position]] = .duplicate
      }
      let fresh = diff.newIndices.map { (index: $0, operation: incoming[$0]) }
      let matches = StatementManualMatcher.match(newOperations: fresh, manual: manual(id))
      for match in matches { dispositions[indices[match.incomingIndex]] = .likelyDuplicate }
    }
    for (index, line) in parse.operations.enumerated()
    where dispositions[index] == .new && !hasRate(line.operation) {
      dispositions[index] = .waitingForRate
    }
    return MigrationPreview(dispositions: dispositions)
  }

  /// The write of the ticked lines. Lines whose account is not mapped or whose rubles cannot
  /// be worked out are left out. Every operation is filed with the source `imported`, so the
  /// model of categories learns from the moved history, and carries no external id (which would
  /// make the model ignore it).
  public static func write(
    _ parse: MigrationParse, ticks: Set<Int>, fileName: String, account: (String) -> UUID?,
    category: (MigrationCategoryKey?, CategoryKind) -> UUID?,
    quality: (UUID?) -> Quality?, rubles: (ImportedOperation) -> StatementRubles?,
    zoneID: String, now: Date, newID: () -> UUID = UUID.init
  ) -> MigrationWrite {
    var entries: [TransactionEntry] = []
    var importIDs: [UUID: UUID] = [:]
    var counts: [UUID: Int] = [:]
    var days: [UUID: (DateOnly, DateOnly)] = [:]
    for index in ticks.sorted() where parse.operations.indices.contains(index) {
      let line = parse.operations[index]
      let operation = line.operation
      guard let accountID = account(operation.accountRef), let money = rubles(operation) else {
        continue
      }
      let importID = importIDs[accountID] ?? newID()
      importIDs[accountID] = importID
      let kind = StatementEntryBuilder.kind(of: operation)
      let categoryID = category(line.category, kind == .income ? .income : .expense)
      var entry = StatementEntryBuilder.entry(
        for: operation, accountID: accountID, accountKey: accountID.uuidString,
        importID: importID, zoneID: zoneID, rubles: money,
        choice: StatementEntryChoice(
          categoryID: categoryID, categorySource: .imported,
          quality: kind.hasQuality ? quality(categoryID) : nil),
        id: newID(), now: now)
      // The other application's own name for the line, and its comment on the part.
      entry.transaction.note = operation.description.isEmpty ? nil : operation.description
      if let comment = operation.comment, !entry.parts.isEmpty { entry.parts[0].note = comment }
      entries.append(entry)
      counts[accountID, default: 0] += 1
      let day = operation.moment.day
      let span = days[accountID] ?? (day, day)
      days[accountID] = (min(span.0, day), max(span.1, day))
    }
    let imports = importIDs.sorted { $0.key.uuidString < $1.key.uuidString }.map {
      accountID, importID in
      StatementImportRecord(
        id: importID.uuidString, accountID: accountID.uuidString,
        profileID: parse.operations.first?.operation.profileID ?? "migration.spreadsheet",
        fileName: fileName, importedAt: now, periodFrom: days[accountID]?.0,
        periodTo: days[accountID]?.1, rowCount: counts[accountID] ?? 0,
        newCount: counts[accountID] ?? 0, duplicateCount: 0, declinedCount: 0,
        unparsedCount: 0)
    }
    return MigrationWrite(entries: entries, imports: imports)
  }
}
