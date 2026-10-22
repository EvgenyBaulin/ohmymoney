import CoreKit
import Foundation

/// What loading one line of a statement would do. Every line of the file that is not declined
/// gets exactly one of these; the preview table shows them and the person ticks the lines to
/// write.
public enum StatementRowDisposition: Sendable, Hashable {
  /// The account does not have this line yet.
  case new
  /// The account already has it (same key): skipped, never written twice.
  case duplicate
  /// A held line the account has, now posted by the bank: the stored line changes status and
  /// posting day, no second one is added.
  case statusUpgrade(existingID: String)
  /// A posted line that looks like the later self of a held one whose day or wording differ a
  /// little: proposed as a replacement of the held line.
  case heldReplacement(existingID: String)
  /// A line the person already typed by hand, within the merge tolerance: the amount becomes
  /// the bank's, the category and the comment stay the person's.
  case manualMerge(entryID: String)
  /// Several or farther hand-typed candidates: the person picks, or declines.
  case manualAsk(candidateIDs: [String])

  /// Writes something into the books (as opposed to being skipped).
  public var changesBooks: Bool {
    if case .duplicate = self { return false }
    return true
  }

  /// Whether the line is, for the person, a change to something already there.
  public var isChange: Bool {
    switch self {
    case .statusUpgrade, .heldReplacement, .manualMerge, .manualAsk: true
    case .new, .duplicate: false
    }
  }
}

/// One line of the preview table.
public struct StatementPreviewRow: Sendable, Hashable, Identifiable {
  /// Position in `StatementParseResult.operations`.
  public var index: Int
  public var operation: ImportedOperation
  public var disposition: StatementRowDisposition
  /// The other side is the owner's own account or card (by identity or by the contract the
  /// bank names); such a line is a candidate for a transfer, not a spending.
  public var isOwnTransfer: Bool

  public var id: Int { index }

  public init(
    index: Int, operation: ImportedOperation, disposition: StatementRowDisposition,
    isOwnTransfer: Bool
  ) {
    self.index = index
    self.operation = operation
    self.disposition = disposition
    self.isOwnTransfer = isOwnTransfer
  }

  /// Whether the tick starts on. A duplicate is never ticked; a hand-typed line the person
  /// has to pick is off until they do; a proposal to replace a held line is on, because the
  /// statement is the bank's own word and nothing is deleted.
  public var startsTicked: Bool {
    switch disposition {
    case .new, .statusUpgrade, .heldReplacement, .manualMerge: true
    case .duplicate, .manualAsk: false
    }
  }
}

/// The preview of one statement file against one account: every line with what it would do,
/// the lines that were declined or could not be read, and the checks of the file against
/// itself. Nothing here is written anywhere.
public struct StatementPreview: Sendable, Hashable {
  public var profileID: String
  public var header: StatementHeader
  public var rows: [StatementPreviewRow]
  public var declined: [ImportedOperation]
  public var unparsed: [StatementUnparsedLine]
  public var checks: [StatementCheck]
  public var usedLegacyEncoding: Bool
  /// Held lines the account has that no statement has posted for a long time: the person is
  /// asked whether to delete them.
  public var staleHeld: [StatementExisting]

  public init(
    profileID: String, header: StatementHeader, rows: [StatementPreviewRow],
    declined: [ImportedOperation], unparsed: [StatementUnparsedLine], checks: [StatementCheck],
    usedLegacyEncoding: Bool, staleHeld: [StatementExisting] = []
  ) {
    self.profileID = profileID
    self.header = header
    self.rows = rows
    self.declined = declined
    self.unparsed = unparsed
    self.checks = checks
    self.usedLegacyEncoding = usedLegacyEncoding
    self.staleHeld = staleHeld
  }

  /// A blocking check failed: the file is not loaded (the totals in the foot of the file do not
  /// match the lines).
  public var blockingFailures: [StatementCheck] { checks.filter { $0.blocking && !$0.passed } }
  public var isImportable: Bool { blockingFailures.isEmpty }

  public var newCount: Int { rows.filter { $0.disposition == .new }.count }
  public var duplicateCount: Int {
    rows.filter { if case .duplicate = $0.disposition { true } else { false } }.count
  }
  public var changedCount: Int { rows.filter { $0.disposition.isChange }.count }
  public var unparsedCount: Int { unparsed.count }
  public var declinedCount: Int { declined.count }
  /// How much money sat in the lines that could not be read.
  public var unparsedSum: AmountE4 { AmountE4.sum(unparsed.compactMap(\.amount)) }

  /// First and last day of the lines, for the title of the import.
  public var period: (from: DateOnly, to: DateOnly)? {
    if let from = header.periodFrom, let to = header.periodTo { return (from, to) }
    let days = rows.map(\.operation.moment.day)
    guard let first = days.min(), let last = days.max() else { return nil }
    return (first, last)
  }
}

public enum StatementPreviewBuilder {
  /// Compares a parsed statement with what the account already holds.
  ///
  /// `accountKey` is the stable text the account is known by in the duplicate key — the id of
  /// the account in the database. `existing` are the account's lines that came from a
  /// statement; `manual` the ones the person typed. Duplicates are counted per key (see
  /// `StatementDeduplicator.diff`), and a hand-typed line is looked for only among the lines
  /// that are new.
  public static func build(
    parse: StatementParseResult, accountKey: String, existing: [StatementExisting],
    manual: [StatementManualEntry], identity: StatementIdentity, today: DateOnly
  ) -> StatementPreview {
    let operations = parse.operations
    let diff = StatementDeduplicator.diff(
      incoming: operations, account: accountKey, existing: existing)
    var dispositions: [Int: StatementRowDisposition] = [:]
    for index in diff.duplicateIndices { dispositions[index] = .duplicate }
    for upgrade in diff.statusUpgrades {
      dispositions[upgrade.incomingIndex] = .statusUpgrade(existingID: upgrade.existingID)
    }
    for replacement in diff.heldReplacements {
      dispositions[replacement.incomingIndex] = .heldReplacement(existingID: replacement.existingID)
    }
    let matches = StatementManualMatcher.match(
      newOperations: diff.newIndices.map { (index: $0, operation: operations[$0]) },
      manual: manual)
    for match in matches {
      if match.certainty == .merge, let only = match.candidateIDs.first,
        match.candidateIDs.count == 1
      {
        dispositions[match.incomingIndex] = .manualMerge(entryID: only)
      } else {
        dispositions[match.incomingIndex] = .manualAsk(candidateIDs: match.candidateIDs)
      }
    }
    for index in diff.newIndices where dispositions[index] == nil {
      dispositions[index] = .new
    }
    let rows = operations.enumerated().map { index, operation in
      StatementPreviewRow(
        index: index, operation: operation, disposition: dispositions[index] ?? .new,
        isOwnTransfer: Self.isOwnTransfer(operation, identity: identity))
    }
    return StatementPreview(
      profileID: parse.profileID, header: parse.header, rows: rows, declined: parse.declined,
      unparsed: parse.unparsed, checks: parse.checks,
      usedLegacyEncoding: parse.usedLegacyEncoding,
      staleHeld: StatementDeduplicator.staleHeld(existing: existing, today: today, afterDiff: diff))
  }

  /// A line that moves money to or from the owner's own account: the bank names the owner's
  /// other contract, or the person on the other side is the owner by phone, name or card.
  public static func isOwnTransfer(
    _ operation: ImportedOperation, identity: StatementIdentity
  ) -> Bool {
    switch operation.kind {
    case .ownContractTransferOut, .ownContractTransferIn: return true
    case .sbpTransferOut, .sbpTransferIn, .personTransferOut, .personTransferIn,
      .cardTransferOut, .unnamedTransferIn:
      return identity.owns(operation.counterparty)
    default: return false
    }
  }
}

// MARK: - Several statements at once

/// A line of one of the files loaded together.
public struct StatementRowRef: Sendable, Hashable {
  public var file: Int
  public var row: Int

  public init(file: Int, row: Int) {
    self.file = file
    self.row = row
  }
}

/// One loaded file, as far as pairing across files needs it.
public struct StatementSessionFile: Sendable {
  public var key: Int
  /// The account the file is loaded into.
  public var accountKey: String
  public var bankName: String?
  /// The numbers by which other statements name this account: its contract and account number.
  public var ownReferences: Set<String>
  public var preview: StatementPreview

  public init(
    key: Int, accountKey: String, bankName: String?, ownReferences: Set<String>,
    preview: StatementPreview
  ) {
    self.key = key
    self.accountKey = accountKey
    self.bankName = bankName
    self.ownReferences = ownReferences
    self.preview = preview
  }
}

public struct StatementPairedLines: Sendable, Hashable {
  public var outgoing: StatementRowRef
  public var incoming: StatementRowRef
  public var strength: StatementTransferPair.Strength
}

/// A question about transfers to an account of the owner that no loaded file explains.
public struct StatementOwnAccountAsk: Sendable, Hashable {
  public var bankName: String?
  public var lines: [StatementRowRef]
  public var total: AmountE4
}

public struct StatementSessionTransfers: Sendable, Hashable {
  /// Explicit and exact pairs: safe to write as one transfer each.
  public var pairs: [StatementPairedLines] = []
  /// Equal amounts within two days: proposed with a tick, never written alone.
  public var softPairs: [StatementPairedLines] = []
  /// Lines that fit several others equally well; the person picks.
  public var ambiguous: [[StatementRowRef]] = []
  /// Unpaired transfers to the owner's own account at a bank no file was loaded for, one
  /// question per bank.
  public var withoutStatement: [StatementOwnAccountAsk] = []
  /// Unpaired outgoing own transfers still within the wait for their arriving half.
  public var onTheWay: [StatementRowRef] = []
  /// The same, waited for longer than `StatementOwnTransfers.inTransitWaitDays`.
  public var overdue: [StatementRowRef] = []

  public init() {}

  /// Every line that is a half of a pair, soft ones too.
  public var pairedLines: Set<StatementRowRef> {
    Set((pairs + softPairs).flatMap { [$0.outgoing, $0.incoming] })
  }
}

public enum StatementSessionPlanner {
  /// Finds the halves of transfers between the accounts of the files loaded together. Only
  /// new lines take part (a duplicate is already in the books), and two lines of one account
  /// never pair.
  public static func pairTransfers(
    files: [StatementSessionFile], identity: StatementIdentity, today: DateOnly
  ) -> StatementSessionTransfers {
    var legs: [StatementLeg] = []
    var refs: [Int: StatementRowRef] = [:]
    for file in files {
      for row in file.preview.rows where row.disposition == .new && row.isOwnTransfer {
        let id = legs.count
        legs.append(
          StatementLeg(
            id: id, accountKey: file.accountKey, bankName: file.bankName,
            ownReferences: file.ownReferences, operation: row.operation))
        refs[id] = StatementRowRef(file: file.key, row: row.index)
      }
    }
    let result = StatementTransferPairing.pair(legs)
    func lines(_ pair: StatementTransferPair) -> StatementPairedLines? {
      guard let out = refs[pair.outgoing], let into = refs[pair.incoming] else { return nil }
      return StatementPairedLines(outgoing: out, incoming: into, strength: pair.strength)
    }
    var transfers = StatementSessionTransfers()
    transfers.pairs = result.pairs.compactMap(lines)
    transfers.softPairs = result.softPairs.compactMap(lines)
    transfers.ambiguous = result.ambiguous.map { $0.compactMap { refs[$0] } }
    let paired = Set((result.pairs + result.softPairs).flatMap { [$0.outgoing, $0.incoming] })
    transfers.withoutStatement = StatementOwnTransfers.toAccountsWithoutStatement(
      legs: legs, paired: paired, identity: identity
    ).map { question in
      StatementOwnAccountAsk(
        bankName: question.bankName, lines: question.legIDs.compactMap { refs[$0] },
        total: question.total)
    }
    let unpairedOut = legs.filter {
      !paired.contains($0.id) && $0.operation.amount.isNegative
        && $0.operation.status != .declined
    }
    let transit = StatementOwnTransfers.inTransit(unpairedOutgoing: unpairedOut, today: today)
    transfers.onTheWay = transit.onTheWay.compactMap { refs[$0] }
    transfers.overdue = transit.overdue.compactMap { refs[$0] }
    return transfers
  }
}
