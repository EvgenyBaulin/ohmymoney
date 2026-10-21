import AppCore
import AppDatabase
import Foundation

/// The reconciliation sheet saved: the counted balances, the differences recorded in «Сверка»
/// and the two categories they go to; and the first counts older versions recorded as a
/// difference, made the starting point they were or kept as a real difference.
extension PlanningActions {
  /// Why saving the reconciliation sheet wrote nothing: a key of the Planning table.
  enum ReconcileFailure: String, Equatable {
    /// The write was refused; nothing was saved.
    case notSaved = "reconcile.notSaved"
    /// A difference asked for could not be written, so nothing was.
    case notRecorded = "reconcile.notRecorded"
    /// A difference in a currency without a rate today cannot be written in rubles.
    case rateMissing = "reconcile.rateMissing"
    /// No balance was counted.
    case nothingCounted = "reconcile.nothingCounted"
    /// A difference on an archived account or in a currency the account does not hold has no
    /// account to be written on.
    case notHeld = "reconcile.cannotRecord"
  }

  /// Saves the reconciliation sheet at `t0`: a counted balance for every account and currency
  /// in `counted`, and with `recordDifference` every difference as an operation in «Сверка» on
  /// its account, in its currency (`AccountReconciliation.record`) — all in one write and one
  /// step of ⌘Z. A balance counted for the first time is its starting point: nothing is
  /// compared and nothing else is written. So is a row of `startingPoints` — a pair that rested
  /// only on the zero openings older versions wrote for empty fields —, whatever the books
  /// expected. A row of `keepingFirstCounts` is such a pair the owner unticked: it compares
  /// like any row, and its count is remembered as a real difference (`reconcile.firstCountKept`)
  /// in the same step. Every compared pair asks to follow the books as of the write
  /// (`PlanningChange.settles`). Nil when it landed.
  ///
  /// `t0` is the moment the sheet counted the expected balances for, not the later instant of
  /// saving: an operation entered in between — through «Найти пропущенные…» while the sheet
  /// stood open — comes with new data and moves the sheet's moment, so it is either inside the
  /// expected balance or after the count, never written again as the difference.
  ///
  /// The «Сверка» categories themselves are outside that write: they are made the first time a
  /// difference is recorded, through the reference book, so ⌘Z takes the operations back and
  /// leaves the categories standing — the owner's categories now, to rename or to delete; the
  /// next difference makes them again.
  @discardableResult
  func reconcile(
    counted: [BalanceKey: AmountE4], rows given: [ReconcileRow], recordDifference: Bool,
    at t0: Date, startingPoints: Set<BalanceKey> = [], keepingFirstCounts: Set<BalanceKey> = []
  ) -> ReconcileFailure? {
    // A starting point compares nothing: every check below sees it as a first count.
    let rows = ReconcileSheet.compared(given, startingPoints: startingPoints)
    // The journal gets the shape of it, never an amount: how many balances were counted and
    // compared, whether the differences were asked for.
    let compared = rows.filter { $0.expected != nil && counted[$0.key] != nil }.count
    let shape = [
      LogPair("balances", .count(counted.count)), LogPair("compared", .count(compared)),
      LogPair("record", .flag(recordDifference)),
    ]
    AppLog.info("reconcile.started", .db, "a reconciliation is being saved", shape)
    let differs = rows.contains { row in
      guard let expected = row.expected, let actual = counted[row.key] else { return false }
      return actual != expected
    }
    let writes = recordDifference && differs
    // The categories are looked up only when an operation is written: a count without a
    // difference to record makes nothing — nor one whose difference cannot be written.
    var categories: (expense: UUID, income: UUID)?
    if writes {
      guard ReconcileSheet.differencesNotHeld(rows: rows, counted: counted).isEmpty else {
        AppLog.error(
          "reconcile.failed", .db, "a difference has no account to be written on; nothing saved",
          shape)
        return .notHeld
      }
      guard
        ReconcileSheet.differencesWithoutRate(rows: rows, counted: counted, rubPerUnit: rubPerUnit)
          .isEmpty
      else {
        AppLog.error(
          "reconcile.failed", .db, "a difference has no rate today; nothing was saved", shape)
        return .rateMissing
      }
      categories = reconciliationCategories()
      guard categories != nil else {
        AppLog.error(
          "reconcile.failed", .db, "the difference could not be written; nothing was saved",
          shape)
        return .notRecorded
      }
    }
    let record = AccountReconciliation.record(
      counted: counted, rows: rows, writeDifference: writes, kind: .accounts, at: t0,
      calendar: environment.calendar, tree: tree ?? CategoryTree(),
      categories: categories ?? (UUID(), UUID()), rubPerUnit: rubPerUnit, makeId: { UUID() },
      startingPoints: startingPoints)
    guard !record.balances.isEmpty else { return .nothingCounted }
    // A difference asked for and not written fails the whole reconciliation: saved without
    // it, the sheet would close as if the operation were there.
    guard record.withoutRate.isEmpty else {
      AppLog.error(
        "reconcile.failed", .db, "a difference has no rate today; nothing was saved",
        shape + [LogPair("withoutRate", .count(record.withoutRate.count))])
      return .rateMissing
    }
    var written = PlanningRows.empty
    written.reconciliations = [record.reconciliation]
    written.reconciledBalances = record.balances
    let kept = Set(
      record.balances.filter { keepingFirstCounts.contains($0.key) && !$0.isStartingPoint }
        .map(\.id))
    var settings: [String: String?] = [:]
    if !kept.isEmpty {
      settings[PlanningSettings.firstCountKeptKey] = FirstCountFix.keeping(
        kept, in: keptFirstCounts())
    }
    let change = PlanningChange(
      created: record.differences, upsert: written, settings: settings,
      settles: Set(record.balances.filter { !$0.isStartingPoint }.map(\.key)))
    guard apply(change) else {
      AppLog.error("reconcile.failed", .db, "the reconciliation was not saved", shape)
      return writes ? .notRecorded : .notSaved
    }
    // The starting points and the counts kept as a real difference are said only when there
    // are any.
    var saved = [
      LogPair("reconciliation", .id(record.reconciliation.id)),
      LogPair("balances", .count(record.balances.count)),
      LogPair("operations", .count(record.differences.count)),
    ]
    if !startingPoints.isEmpty {
      saved.append(LogPair("startingPoints", .count(startingPoints.count)))
    }
    if !kept.isEmpty { saved.append(LogPair("kept", .count(kept.count))) }
    AppLog.info("reconcile.saved", .db, "the reconciliation was saved", saved)
    return nil
  }

  // MARK: The first count

  /// The ids the owner called a real difference, read from the database as it is now: another
  /// window may have added one since the numbers were built.
  func keptFirstCounts() -> Set<UUID> {
    let text = (try? environment.settings?.string(PlanningSettings.firstCountKeptKey)) ?? nil
    return Set(
      (text ?? "").split(whereSeparator: \.isNewline).compactMap {
        UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))
      })
  }

  /// «Это первая сверка — сделать точкой отсчёта»: the count, or the reconciliation of one
  /// total, becomes the starting point it was and its difference operation goes to the bin —
  /// one write, one step of ⌘Z. The balance does not move: it is what was counted.
  @discardableResult
  func fixFirstCount(_ candidate: FirstCountCandidate) -> Bool {
    let done = apply(Self.fixing(candidate))
    let pairs = [
      LogPair("count", .id(candidate.id)),
      LogPair("operation", .flag(candidate.operationId != nil)),
    ]
    if done {
      AppLog.info("reconcile.firstFixed", .db, "a first count became the starting point", pairs)
    } else {
      AppLog.error("reconcile.firstRefused", .db, "a first count was not changed", pairs)
    }
    return done
  }

  /// «Это настоящая разница»: the count is remembered as a real difference, so it is offered no
  /// more, and its pair follows the books from now on — in the same step of ⌘Z.
  @discardableResult
  func keepFirstCount(_ candidate: FirstCountCandidate) -> Bool {
    let done = apply(Self.keeping(candidate, kept: keptFirstCounts()))
    let pairs = [LogPair("count", .id(candidate.id))]
    if done {
      AppLog.info("reconcile.firstKept", .db, "a first count is a real difference", pairs)
    } else {
      AppLog.error("reconcile.firstRefused", .db, "a first count was not changed", pairs)
    }
    return done
  }

  /// «Записывать разницу» of the history: a count that keeps only its numbers records its
  /// difference again — the operation written now (over the one in the bin, if the owner
  /// deleted it), following the books from now on —, one step of ⌘Z.
  @discardableResult
  func recordDifference(of count: ReconciledBalance) -> Bool {
    let done = apply(Self.recordingAgain(count))
    let pairs = [LogPair("count", .id(count.id))]
    if done {
      AppLog.info("reconcile.recordsAgain", .db, "a count records its difference again", pairs)
    } else {
      AppLog.error("reconcile.recordRefused", .db, "a count was not set to record", pairs)
    }
    return done
  }

  /// The one write of «Записывать разницу»: the mode, with no operation linked — the owner
  /// asking, which the operation in the bin does not hold back (`LiveCounts.settle`) —, and the
  /// pair settled in the same step.
  static func recordingAgain(_ count: ReconciledBalance) -> PlanningChange {
    var asked = count
    asked.recordsDifference = true
    asked.transactionId = nil
    var rows = PlanningRows.empty
    rows.reconciledBalances = [asked]
    return PlanningChange(upsert: rows, settles: [count.key])
  }

  /// The one write of the fix: the starting point and its operation to the bin.
  static func fixing(_ candidate: FirstCountCandidate) -> PlanningChange {
    let write = FirstCountFix.fix(candidate)
    var rows = PlanningRows.empty
    rows.reconciliations = write.reconciliations
    rows.reconciledBalances = write.balances
    return PlanningChange(upsert: rows, softDeleted: write.softDeleted)
  }

  /// The one write of «Это настоящая разница»: the id added to what `kept` already holds, and
  /// the pair of a count settled against the books in the same step.
  static func keeping(_ candidate: FirstCountCandidate, kept: Set<UUID>) -> PlanningChange {
    PlanningChange(
      settings: [
        PlanningSettings.firstCountKeptKey: FirstCountFix.keeping([candidate.id], in: kept)
      ],
      settles: candidate.key.map { [$0] } ?? [])
  }

  /// Where the difference of a reconciliation goes: «Сверка», a category of its own, one for
  /// expenses and one for income.
  ///
  /// What a reconciliation records is not a purchase the owner failed to place — it is the
  /// books catching up with the money, and it belongs in a line of its own rather than mixed
  /// into «Не помню». The two categories are ordinary ones: they are made the first time a
  /// difference is recorded, in the language the interface is in, and remembered by id in the
  /// settings, exactly as the cashback category is. Renamed by the owner, they keep working;
  /// deleted, they are made again.
  func reconciliationCategories() -> (expense: UUID, income: UUID)? {
    guard let references = environment.references, let settings = environment.settings else {
      return nil
    }
    // Archived rows included: «Сверка» is an ordinary category, so the owner can put it in
    // the archive — and a category the app still writes into must not stay there. Found
    // archived, it is brought back rather than made a second time.
    let existing = (try? references.categories(includeArchived: true)) ?? []
    func pick(_ key: String, _ kind: CategoryKind) -> UUID? {
      guard let text = (try? settings.string(key)) ?? nil, let id = UUID(uuidString: text),
        var found = existing.first(where: { $0.id == id }), found.kind == kind
      else { return nil }
      guard found.archived else { return found.id }
      found.archived = false
      guard (try? references.save(found)) != nil else { return nil }
      return found.id
    }
    func make(_ key: String, _ kind: CategoryKind) -> UUID? {
      let name = environment.language("categories.reconciliation", table: "Settings")
      let sort =
        (existing.filter { $0.kind == kind && $0.parentId == nil }.map(\.sort).max() ?? 0)
        + 1
      let category = CoreKit.Category(
        parentId: nil, kind: kind, name: name, sort: sort,
        quality: kind == .expense ? .neutral : nil)
      guard (try? references.save(category)) != nil,
        (try? settings.set(key, to: category.id.uuidString)) != nil
      else { return nil }
      return category.id
    }
    let expense =
      pick(PlanningSettings.reconcileExpenseCategoryKey, .expense)
      ?? make(PlanningSettings.reconcileExpenseCategoryKey, .expense)
    let income =
      pick(PlanningSettings.reconcileIncomeCategoryKey, .income)
      ?? make(PlanningSettings.reconcileIncomeCategoryKey, .income)
    guard let expense, let income else { return nil }
    environment.refreshVocabulary()
    environment.scheduleBackup()
    return (expense, income)
  }
}
