import AppCore
import AppDatabase
import Foundation
import OSLog
import Observation

/// What one write of the store changed, as the app laid it over its data: the operations
/// as they are now, the ones that went, and parts whose status moved without their
/// operation being rewritten.
public struct StoreWrite: Sendable {
  public var upserted: [TransactionEntry] = []
  public var removed: [UUID] = []
  public var partStatuses: [UUID: ReimbursementStatus] = [:]

  public init(
    upserted: [TransactionEntry] = [], removed: [UUID] = [],
    partStatuses: [UUID: ReimbursementStatus] = [:], planningChanged: Bool = false
  ) {
    self.upserted = upserted
    self.removed = removed
    self.partStatuses = partStatuses
    self.planningChanged = planningChanged
  }

  /// Rows of planning changed with it (payments, limits, goals, reconciliations, journals):
  /// the pipeline reads them again at once rather than waiting for the observation.
  public var planningChanged = false

  public var isEmpty: Bool {
    upserted.isEmpty && removed.isEmpty && partStatuses.isEmpty && !planningChanged
  }

  /// The operations the write touched.
  public var touchedIds: [UUID] { upserted.map(\.id) + removed }

  /// The same write with what the counts it reached wrote in it laid over: the operations of
  /// their differences made or rewritten, the ones that went for good, and — when a count's
  /// numbers moved — planning read again, so the figures of «Сверка» follow at once.
  public func laying(_ counts: CountsSettled) -> StoreWrite {
    guard !counts.isEmpty else { return self }
    var write = self
    let replaced = Set(counts.upserted.map(\.id)).union(counts.removed)
    write.upserted = upserted.filter { !replaced.contains($0.id) } + counts.upserted
    write.removed += counts.removed.filter { !removed.contains($0) }
    write.planningChanged = planningChanged || counts.countsChanged > 0
    return write
  }
}

/// A write of the store that did not land («блок показывает сообщение…, ошибка уходит
/// в журнал»).
public struct StoreFailure: Hashable, Sendable {
  /// What the write was doing — the word the journal gets, too.
  public enum Action: String, Hashable, Sendable {
    case save, planning, edit, change, delete, undo

    /// The entry line, the editor and the actions of planning get the failure back and say
    /// it in their own words. ⌘Z, a bulk change and a deletion — above all one that lands
    /// off the main thread — have nobody to say it but the screen.
    var isShownByTheScreen: Bool {
      switch self {
      case .save, .planning, .edit: false
      case .change, .delete, .undo: true
      }
    }
  }

  public var action: Action
  public var cause: WriteFailureCause

  public init(action: Action, cause: WriteFailureCause) {
    self.action = action
    self.cause = cause
  }
}

/// Performs every change through the repository and keeps ⌘Z. The lists do not come from
/// here any more: they are the data of the calculation pipeline (`ComputeStore`), which
/// hands its ledger over after every change (`show`), so the menus and the confirmations
/// read the very operations the lists show. Deletion is soft, so undo is a single restore.
///
/// A bulk write of more than `backgroundThreshold` operations — a change, a deletion or
/// the undo of one — goes through `await writer.write`, off the main thread.
/// It is still one write and one step of ⌘Z, and `didWrite` still follows it; it only
/// lands a moment later, and its step takes the place in the stack it was asked for in.
@MainActor
@Observable
public final class TransactionsStore {
  /// The type of the error of the last write that failed.
  public private(set) var lastError: String?
  /// A failed write nobody else reports — ⌘Z, a bulk change, a deletion — for the alert of
  /// the screen (`operationPresentations`); `nil` once it has been seen.
  public private(set) var failure: StoreFailure?

  public func forgetFailure() { failure = nil }
  /// The data the lists show, from the pipeline; `nil` until its first read.
  public private(set) var listing: Ledger?

  /// Bulk writes of more operations than this leave the main thread. ⌘A over the two
  /// months Overview lists selects about 1 700 operations of the large sample, and a write
  /// that size, made where the window draws, would freeze it.
  public nonisolated static let backgroundThreshold = 1_000

  /// A bulk write too large for the main thread is on its way. The selection bar says so
  /// and disables its buttons, and the store takes no other bulk write and no undo until it
  /// lands. One operation can still be saved meanwhile — the entry line is never locked —
  /// and its step stays above the step of the bulk write, which lands where it was asked
  /// for: ⌘Z takes back the last thing the owner did first.
  public private(set) var isWritingInBackground = false
  /// That write, for a caller that has to wait for it: the tests. Whether it landed.
  @ObservationIgnored public private(set) var backgroundWrite: Task<Bool, Never>?

  /// Called after every write that landed — undo included — with what it changed. The app
  /// hangs the backup on it (a copy after every change) and lays the change over the
  /// pipeline's data, so the new row and the numbers appear at once.
  public var didWrite: (@MainActor (StoreWrite) -> Void)?

  /// Empty until the database has been opened, so the window can render immediately.
  var repository: TransactionRepository?
  private var references: ReferenceRepository?
  /// The one write path of planning: an action and its operations in one write.
  private var planning: PlanningRepository?
  /// Tags, rules, notes of days and baskets: their writes are steps of ⌘Z too (`SpendingUndo`).
  var spending: SpendingRulesRepository?
  /// The year plan, the subscription extras, the saved views and the loading of statements:
  /// their writes are steps of ⌘Z too (`LaterUndo`).
  var year: YearPlanRepository?
  var subscriptions: SubscriptionRepository?
  var savedViews: SavedViewsRepository?
  var imports: StatementImportRepository?
  /// What the last rules applied to the past wrote (`TransactionsStore+Spending`).
  @ObservationIgnored let backfillBox = BackfillBox()
  private var undoStack: [UndoStep] = []
  /// How far back ⌘Z reaches; a test sets smaller numbers.
  @ObservationIgnored var undoDepth = UndoDepth()
  /// Moves on every time the history is forgotten. A bulk write that set off before that
  /// leaves no step when it lands: its undo would reach across the write the history was
  /// forgotten for.
  @ObservationIgnored private var undoEpoch = 0

  /// How far back ⌘Z reaches: at most `levels` steps, and at most `operations` operations to
  /// write back across them — a bulk change keeps a copy of every operation it touched, and a
  /// session of «apply to past operations» on a large history kept hundreds of megabytes
  /// until quit. The oldest steps go first; the newest is kept whatever its size, so the last
  /// thing done can always be taken back.
  struct UndoDepth: Sendable {
    var levels = 100
    /// A little more than the whole large sample: one change of all of it fits.
    var operations = 25_000
  }

  /// Each step keeps what the counts its write reached wrote (`CountsSettled`): its undo hands
  /// the operations of their differences as they were back to the settle, so a difference the
  /// write took to zero comes back as the owner left it.
  enum UndoStep: Sendable {
    case created(UUID, CountsSettled)
    /// One operation edited, with the journal lines the edit moved (`EditedEntry`).
    case edited(EditedEntry)
    /// One bulk change: the operations as they were before it.
    case editedMany([TransactionEntry], CountsSettled)
    /// One bulk change that moved money on an archived account, and the transfers written
    /// with it to keep that account at zero: undone together, in one write.
    case editedManySettling(before: [TransactionEntry], transfers: [UUID], counts: CountsSettled)
    /// One deletion, of one operation or many, with everything it took along.
    case deletedMany([UUID], DeletionEffects)
    /// One action of planning — «Mark as paid», a contribution, a reconciliation, a limit, a
    /// transfer — with the operations it created, rewrote and deleted.
    case planned(PlanningUndo)
    /// Money back recorded by a sheet, with everything it wrote: its surplus and shortfalls,
    /// the parts it closed, the purchases repriced at a rate typed there and the money back of
    /// their parts balanced again.
    case moneyBack(MoneyBackWrite)
    /// A write of tags, rules, a note of a day or a basket, or rules applied to the past.
    case spending(SpendingUndo)
    /// A write of the year plan, the subscription extras, the saved views or the loading of a
    /// statement.
    case later(LaterUndo)

    /// How many operations undoing it writes.
    var size: Int {
      switch self {
      case .created, .edited: 1
      case .editedMany(let before, _), .editedManySettling(let before, _, _): before.count
      case .deletedMany(let ids, let effects): ids.count + effects.companionIds.count
      case .planned(let undo):
        max(
          1,
          undo.createdTransactionIds.count + undo.rewrittenBefore.count
            + undo.deletion.deletedIds.count + undo.deletion.companionIds.count)
      case .moneyBack(let write):
        max(1, write.created.count + write.repricedBefore.count + write.refundsBefore.count)
      case .spending(let step): step.size
      case .later(let step): step.size
      }
    }
  }

  /// What a write leaves behind once it has landed: the step that takes it back — none for
  /// an undo — and what it changed.
  struct Landed: Sendable {
    var step: UndoStep?
    var write: StoreWrite
  }

  public init(repository: TransactionRepository? = nil, references: ReferenceRepository? = nil) {
    self.repository = repository
    self.references = references
    self.standInFor = nil
  }

  /// The store of the stand-in dependencies, named after the view file that went without.
  public init(standInFor reader: String) {
    self.repository = nil
    self.references = nil
    self.standInFor = reader
  }

  /// True once the database has been opened and handed over.
  public private(set) var isAttached = false

  /// Lets go of the database: the repositories, the report of what was written and the undo
  /// history, which belongs to rows that are about to be out of reach. After this a write
  /// finds no repository and does nothing, instead of reaching a closed connection.
  public func detach() {
    repository = nil
    references = nil
    planning = nil
    spending = nil
    year = nil
    subscriptions = nil
    savedViews = nil
    imports = nil
    didWrite = nil
    letGoOfTheDatabase()
    isAttached = false
  }

  public func attach(
    _ repository: TransactionRepository, references: ReferenceRepository?,
    planning: PlanningRepository? = nil, spending: SpendingRulesRepository? = nil,
    year: YearPlanRepository? = nil, subscriptions: SubscriptionRepository? = nil,
    savedViews: SavedViewsRepository? = nil, imports: StatementImportRepository? = nil
  ) {
    self.repository = repository
    self.references = references
    self.planning = planning
    self.spending = spending
    self.year = year
    self.subscriptions = subscriptions
    self.savedViews = savedViews
    self.imports = imports
    letGoOfTheDatabase()
    isAttached = true
  }

  /// Moves on every time the store is handed a database or lets one go. A bulk write still
  /// on its way was asked of the database before: it lands there, and the store no longer
  /// waits for it (`land`).
  @ObservationIgnored private var attachment = 0

  /// Forgets what belonged to the database the store held: the steps of ⌘Z, which would undo
  /// into rows that are not there, and a bulk write on its way to it — the database the store
  /// holds now has no write on its way, and its `didWrite` must not hear of that one.
  private func letGoOfTheDatabase() {
    forgetUndoHistory()
    attachment += 1
    isWritingInBackground = false
    backgroundWrite = nil
  }

  // MARK: The stand-in

  /// Set when this store belongs to the stand-in dependencies: a view was shown without the
  /// app's own store, and nothing it writes can land anywhere. Every attempt says so in the
  /// log and on screen rather than failing quietly.
  private let standInFor: String?
  /// The view file of the last refused write; what the screen shows an alert about.
  public private(set) var refusal: String?

  private static let standInLog = Logger(
    subsystem: "io.github.EvgenyBaulin.ohmymoney", category: "dependencies")

  public func forgetRefusal() { refusal = nil }

  /// True when the write must not even be attempted, having been announced as refused.
  func refuses(_ what: String, _ file: String) -> Bool {
    guard let standInFor else { return false }
    Self.standInLog.fault(
      "a write was refused: \(standInFor, privacy: .public) asked \(what, privacy: .public) from \(file, privacy: .public)"
    )
    refusal = standInFor
    return true
  }

  /// The pipeline's ledger, after each of its reads and rebuilds.
  public func show(_ ledger: Ledger) {
    listing = ledger
  }

  // MARK: Reading what the lists show

  /// The listed operations with these ids, newest first.
  public func entries(ids: Set<UUID>) -> [TransactionEntry] {
    guard let listing else { return [] }
    return ids.compactMap { listing.entry($0) }
      .sorted { $0.transaction.occurredAt > $1.transaction.occurredAt }
  }

  public func entry(id: UUID) -> TransactionEntry? { listing?.entry(id) }

  public func totals(ids: Set<UUID>) -> RowTotals {
    listing?.rowTotals(of: ids) ?? .zero
  }

  /// Every debt, closed ones included: whether a payment is spending depends on its debt,
  /// and closing a loan must not change the days it was paid on.
  public var debts: [UUID: Debt] { listing?.debtsById ?? [:] }

  /// The categories as the dictionary holds them right now, archived ones included. Read on
  /// every call and never kept: Settings adds, re-rates and archives categories without
  /// going through the store, and a bulk change judged by an older copy would file money
  /// into a retired category, refuse a new one, or rate by a quality that is gone. The
  /// popover of a bulk change offers categories from here too, so it offers what the rule
  /// accepts.
  public func categories() -> [CoreKit.Category] {
    (try? references?.categories(includeArchived: true)) ?? []
  }

  // MARK: Writing one operation

  /// Writes an operation and returns whether it actually landed, so the entry line only
  /// clears itself over a save that happened.
  ///
  /// Whether this creates or replaces is read from the database rather than taken from the
  /// caller. Undoing a creation is a physical delete, and there is no way back from one: a
  /// call site that says "new" about an operation that was already there would turn ⌘Z
  /// into a shredder.
  @discardableResult
  public func save(_ entry: TransactionEntry, file: String = #fileID) -> Bool {
    guard !refuses("save", file), let repository else { return false }
    do {
      let previous = try repository.entry(id: entry.id)
      // What the write wrote: an operation that named no account is on the main one now, and
      // that is what the lists show and what ⌘Z takes back. A backdated one changed the
      // differences of the counts whose windows it entered, in the same write.
      let (written, counts) = try repository.saveReporting(entry)
      push(
        previous.map { .edited(EditedEntry(before: $0, after: written, counts: counts)) }
          ?? .created(written.id, counts))
      finishWrite(Self.laid(counts, over: StoreWrite(upserted: [written])))
      return true
    } catch {
      failed(.save, error, file: file)
      return false
    }
  }

  // MARK: Planning

  /// Writes one action of planning in one write and keeps one step of ⌘Z for it: the
  /// operations it creates, rewrites and deletes, the rows of planning it inserts, changes or
  /// deletes, and the settings it sets. Returns whether it landed.
  @discardableResult
  public func apply(_ change: PlanningChange, file: String = #fileID) -> Bool {
    guard !refuses("apply(PlanningChange)", file) else { return false }
    guard let planning else { return false }
    do {
      let undo = try planning.apply(change)
      push(.planned(undo))
      finishWrite(Self.applied(change, undo: undo))
      return true
    } catch {
      failed(.planning, error, file: file)
      return false
    }
  }

  /// What a change of planning wrote, as the lists lay it over their data: the operations it
  /// created and rewrote as the write left them — an operation that named no account is on
  /// the main one —, the ones it deleted with the surplus and shortfalls that went along, and
  /// the parts the deletion reopened.
  nonisolated static func applied(_ change: PlanningChange, undo: PlanningUndo) -> StoreWrite {
    let written = Set(undo.written.map(\.id))
    // Anything the write did not hand back is laid as it was asked for.
    let rewritten = change.rewritten.map { entry in
      var stamped = entry
      stamped.transaction.updatedAt = change.at
      return stamped
    }
    let asked = (change.created + rewritten).filter { !written.contains($0.id) }
    return laid(
      undo.counts,
      over: StoreWrite(
        upserted: undo.written + asked,
        removed: undo.deletion.deletedIds + undo.deletion.companionIds,
        partStatuses: statuses(undo.deletion.reopenedPartIds, .expected),
        planningChanged: true))
  }

  /// What the undo of a change of planning wrote: the operations it created are gone, and the
  /// ones it rewrote or deleted are back — as they are after the undo, read again, the live
  /// ones only — with the parts a deletion had reopened closed again.
  nonisolated static func reverted(
    _ undo: PlanningUndo, readBack: [TransactionEntry], counts: CountsSettled = .none
  ) -> StoreWrite {
    laid(
      counts,
      over: StoreWrite(
        upserted: readBack.filter { !$0.transaction.isDeleted },
        removed: undo.createdTransactionIds,
        partStatuses: statuses(undo.deletion.reopenedPartIds, .returned),
        planningChanged: true))
  }

  /// The operations the undo of a change of planning brings back — and those whose card a
  /// merge of cards moved, which it gives their card back.
  nonisolated static func broughtBack(by undo: PlanningUndo) -> [UUID] {
    undo.rewrittenBefore.map(\.id) + undo.deletion.deletedIds + undo.deletion.companionIds
      + undo.movedCards.map(\.rowId)
  }

  /// What became of the edit of a saved operation.
  public enum EditOutcome: Equatable, Sendable {
    case saved
    /// The operation was deleted after the editing began: there is nothing to save the
    /// edit over, and writing it would bring the operation back.
    case gone
    /// The write failed; `lastError` says how.
    case failed
    /// The edit may not be written, for the reason given; nothing was.
    case declined(EditRefusal)
    /// A refund or money back that covered only some of a part leans on what the edit
    /// changes; nothing was written.
    case declinedByLink(LinkedEditRefusal)
    /// A refund taken back from a purchase may not become what the edit makes it: more than is
    /// left of the part, or in another currency; nothing was written.
    case refundRefused(RefundError)
    /// The edit moves the money on an account that does not hold the currency, and nothing
    /// says what the account was charged; nothing was written.
    case chargeMissing
    /// A transfer that was to keep an archived account at zero may not be written — its other
    /// side went to the archive meanwhile, or no longer holds the currency; nothing was.
    case settlingRefused
    /// The edit would change the money of a count's difference — its amount, type, account,
    /// currency, moment or debt — or file it under a category of the app; nothing was written.
    case declinedDifference
    /// The view was shown without the app's dependencies, so there was nothing to write to.
    /// Never seen in a window that was assembled properly.
    case refused
  }

  /// Writes the edit of a saved operation — from the inspector or the edit sheet — over
  /// the operation as it is in the database at that moment, in one write.
  ///
  /// An editor holds the copy it was opened with, and the inspector keeps it while the
  /// owner works elsewhere: meanwhile a reimbursement may close one of its parts, a part
  /// may be written off, a deletion may take it away. Written as it was edited, the old
  /// copy would undo all of that. So the edit is laid over the row read inside the write
  /// (`TransactionEntry.rebased(onto:)`), and a deleted operation is not written at all.
  ///
  /// An operation that moves a debt takes its journal line along in the same write — the
  /// amount, the day and the debt the edit changed («Платёж одновременно уменьшает
  /// долг») — and one ⌘Z brings both back. `calendar` dates the line, as the entry line does.
  ///
  /// `settling` are the transfers that keep an archived account at zero when the edit changes
  /// its past (`ArchivedMoney`): written in the same write, under every rule of the edit, and
  /// taken back with it by the same ⌘Z.
  ///
  /// A purchase whose rubles the edit changes balances the money that came back for it again;
  /// a surplus written anew is noted «Излишек возврата» in the language of the interface. The
  /// counts whose windows the edit reached follow the books in the same write, and the lists lay
  /// what they wrote over what they show.
  @discardableResult
  public func saveEdit(
    _ edited: TransactionEntry, calendar: CalendarContext = .system, settling: [Transfer] = [],
    file: String = #fileID
  ) -> EditOutcome {
    guard !refuses("saveEdit", file) else { return .refused }
    guard let repository else { return .failed }
    // A payment of a loan whose interest is an operation of its own takes it along: one change.
    if settling.isEmpty, let change = interestEdit(of: edited, calendar: calendar) {
      return apply(change, file: file) ? .saved : .failed
    }
    do {
      // `edit` passes over a deleted row and stamps what it writes with this instant, so the
      // operation reported below is the very row in the database.
      let result = try repository.edit(
        id: edited.id, at: edited.transaction.updatedAt, calendar: calendar,
        settlingTransfers: settling,
        settlement: SettlementSetting(surplusNote: Self.surplusNote())
      ) { fresh in Self.laid(edited, over: fresh) }
      switch result {
      case .gone:
        return .gone
      case .unchanged:
        return .saved
      case .edited(let change):
        push(.edited(change))
        change.settlement.counts.log()
        finishWrite(
          Self.laid(
            change.counts,
            over: StoreWrite(
              upserted: [change.after], planningChanged: change.reachesBeyondTheOperation)))
        return .saved
      }
    } catch let refusal as DifferenceEditRefusal {
      // The panel never offers such a change of a count's difference; another writer may.
      AppLog.info(
        "store.differenceKept", .db, "an edit of a count's difference was not written",
        [LogPair("refusal", .token(String(describing: refusal)))])
      return .declinedDifference
    } catch let refusal as EditRefusal {
      return .declined(refusal)
    } catch let refusal as LinkedEditRefusal {
      return .declinedByLink(refusal)
    } catch let refusal as RefundError {
      return .refundRefused(refusal)
    } catch AccountWriteError.chargeMissing {
      return .chargeMissing
    } catch is SettlingTransferRefusal {
      return .settlingRefused
    } catch {
      failed(.edit, error, file: file)
      return .failed
    }
  }

  /// The edit laid over the row as it is inside the write (`rebased(onto:)`). The difference of a
  /// count keeps the money the count gives it: a backdated entry may have rewritten its amount —
  /// or turned it from spending into income — while the editor was open, and the editor never
  /// changes that money. So its type, amount, currency, rate, rubles, account, charge, moment and
  /// debts are the row's; its comment, place, card and the owner's fields of its part are the
  /// edit's — the category and rating only while the type is still the one the editor showed.
  nonisolated static func laid(
    _ edited: TransactionEntry, over fresh: TransactionEntry
  ) -> TransactionEntry {
    var laid = edited.rebased(onto: fresh)
    guard OperationEditRule.isReconcileDifference(fresh.transaction) else { return laid }
    let money = fresh.transaction
    let sameKind = laid.transaction.kind == money.kind
    laid.transaction.kind = money.kind
    laid.transaction.amountE4 = money.amountE4
    laid.transaction.amountExpr = money.amountExpr
    laid.transaction.currency = money.currency
    laid.transaction.rate = money.rate
    laid.transaction.rateDate = money.rateDate
    laid.transaction.rateSource = money.rateSource
    laid.transaction.rateProvisional = money.rateProvisional
    laid.transaction.amountRubE4 = money.amountRubE4
    laid.transaction.paymentMethodId = money.paymentMethodId
    laid.transaction.accountCurrency = money.accountCurrency
    laid.transaction.accountAmountE4 = money.accountAmountE4
    laid.transaction.occurredAt = money.occurredAt
    laid.transaction.debtId = money.debtId
    laid.transaction.creditDebtId = money.creditDebtId
    guard laid.parts.map(\.id) == fresh.parts.map(\.id) else { return laid }
    for index in laid.parts.indices {
      let stored = fresh.parts[index]
      laid.parts[index].amountE4 = stored.amountE4
      laid.parts[index].amountRubE4 = stored.amountRubE4
      laid.parts[index].goalId = stored.goalId
      if !sameKind {
        laid.parts[index].categoryId = stored.categoryId
        laid.parts[index].categorySource = stored.categorySource
        laid.parts[index].quality = stored.quality
        laid.parts[index].qualitySource = stored.qualitySource
      }
    }
    return laid
  }

  /// «Излишек возврата» in the language of the interface as it is chosen right now: the note of
  /// the income an edit or a refinement of a rate writes when money that came back now covers a
  /// part with some over. Read where the choice is stored, so a write off the main thread — the
  /// refinement of rates — has it too.
  public nonisolated static func surplusNote(_ defaults: UserDefaults = .standard) -> String {
    let words = (key: "reimbursement.surplus", table: "Entry")
    let code = AppLanguage.storedCode(in: defaults)
    let bundle =
      Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    let value = bundle.localizedString(forKey: words.key, value: nil, table: words.table)
    guard value == words.key else { return value }
    return Bundle.main.localizedString(forKey: words.key, value: words.key, table: words.table)
  }

  /// Deleting one operation is deleting many that happen to be one: the same rules, the
  /// same companions taken along, the same single step of undo.
  @discardableResult
  public func delete(id: UUID, file: String = #fileID) -> Bool {
    guard !refuses("delete(id:)", file) else { return false }
    return delete(ids: [id])
  }

  // MARK: Many operations at once

  /// What a bulk change would do to the listed operations: the text of the confirmation.
  /// The write itself works on the rows as they are in the database at that moment.
  ///
  /// `rates` — the bank's rates by day — and `calendar` work out what an account that does not
  /// hold an operation's currency is charged for it, when the change moves it there.
  public func plan(
    _ edit: BulkEdit, ids: Set<UUID>, rates: DayRates = .empty,
    calendar: CalendarContext = .system
  ) -> BulkEditPlan {
    BulkEditRule.plan(
      edit, entries: entries(ids: ids), tree: CategoryTree(categories()),
      history: qualityHistory(), accounts: accounts(), rates: rates, calendar: calendar)
  }

  /// What deleting the listed operations would take: a purchase a live refund takes money
  /// back from stays, unless that refund goes too.
  public func planDeletion(ids: Set<UUID>) -> BulkEditPlan {
    let debts = deletionDebts()
    return BulkEditRule.deletion(
      of: entries(ids: ids), refunds: listing?.refundIndex ?? .empty, deletedDebts: debts.deleted,
      paidDebts: debts.paid)
  }

  /// The closed debts deleting `ids` leaves owed again: the payment that closed them goes with
  /// the operation, and the debt stays closed unless the owner opens it
  /// (`DebtRules.closedByDeleting`). Of the operations the rules let go, as the lists have them.
  public func debtsClosedBy(deleting ids: some Collection<UUID>) -> [Debt] {
    guard let dataset = listing?.dataset, !ids.isEmpty else { return [] }
    let gone = Set(
      Self.deletable(
        entries(ids: Set(ids)), refunds: listing?.refundIndex ?? .empty, debts: deletionDebts()))
    return DebtRules.closedByDeleting(
      gone, debts: dataset.debts, journal: dataset.planning.debtEntries)
  }

  /// The debts a deletion asks about: the deleted ones, and those something ever paid
  /// (`DebtRules.paidDebts`). A purchase on credit of a deleted debt goes like any other, unless
  /// its debt was paid: then the money that left the account would be in no figure.
  func deletionDebts() -> DeletionDebts {
    guard let dataset = listing?.dataset else { return .none }
    return DeletionDebts(
      deleted: Set(dataset.deletedDebts.map(\.id)),
      paid: DebtRules.paidDebts(entries: dataset.entries, journal: dataset.planning.debtEntries))
  }

  /// The debts `BulkEditRule.deletion` asks about, read on the main thread for a deletion that
  /// may choose off it.
  struct DeletionDebts: Sendable {
    var deleted: Set<UUID>
    var paid: Set<UUID>
    static let none = DeletionDebts(deleted: [], paid: [])
  }

  /// Every account the data knows, archived ones included: an operation moved in bulk goes to
  /// the account the menu offered, and one already on an archived account keeps what it was
  /// charged there.
  private func accounts() -> [PaymentMethod] {
    listing?.dataset.paymentMethods ?? []
  }

  /// One bulk change, one write, one step of undo. More than `backgroundThreshold`
  /// operations are written off the main thread: the call returns at once, and the change
  /// is reported through `didWrite` when it has landed.
  ///
  /// `settling` are the transfers that keep an archived account at zero when the change moves
  /// money on it (`ArchivedMoney`): written in the same write, taken back by the same ⌘Z. They
  /// count the money of the operations the change was to change when they were worked out —
  /// `planned`, else those it changes as the lists have them now — so they go in only when the
  /// change lands on exactly those. When the operations changed elsewhere meanwhile nothing is
  /// written, and the screen asks for the change again (`WriteFailureCause.planOutdated`).
  @discardableResult
  public func apply(
    _ edit: BulkEdit, to ids: [UUID], rates: DayRates = .empty,
    calendar: CalendarContext = .system, settling: [Transfer] = [], planned: Set<UUID>? = nil,
    file: String = #fileID
  ) -> Bool {
    guard !refuses("apply(BulkEdit:)", file), repository != nil, !isWritingInBackground else {
      return false
    }
    let planned =
      settling.isEmpty
      ? nil
      : planned
        ?? Set(plan(edit, ids: Set(ids), rates: rates, calendar: calendar).changed.map(\.id))
    let tree = CategoryTree(categories())
    let history = qualityHistory()
    let accounts = accounts()
    return modifyMany(ids, settling: settling, planned: planned, file: file) { fresh in
      BulkEditRule.apply(
        edit, to: fresh, tree: tree, history: history, accounts: accounts, rates: rates,
        calendar: calendar
      ).changedEntry
    }
  }

  /// The new quality of a category carried over to the operations filed under it — the
  /// answer «yes» to the question Settings asks after the change. The same way
  /// as a bulk change: one write, one step of ⌘Z, off the main thread beyond
  /// `backgroundThreshold`. The rule is applied again to each row as it is in the database
  /// then, with the categories as they are then: a part rated by hand since the question
  /// was asked keeps its rating.
  @discardableResult
  public func apply(
    _ change: CategoryQualityChange, to ids: [UUID], file: String = #fileID
  )
    -> Bool
  {
    guard !refuses("apply(CategoryQualityChange:)", file) else { return false }
    guard repository != nil, !isWritingInBackground else { return false }
    let tree = CategoryTree(categories())
    return modifyMany(ids, file: file) { fresh in change.applied(to: fresh, tree: tree) }
  }

  /// Rewrites the operations `transform` changes, in one write that is one step of undo —
  /// with `settling`, the transfers that keep an archived account at zero, in the same write
  /// and the same step, when the write changes exactly the operations of `planned`.
  func modifyMany(
    _ ids: [UUID], settling: [Transfer] = [], planned: Set<UUID>? = nil, file: String,
    transform: @escaping @Sendable (TransactionEntry) -> TransactionEntry?
  ) -> Bool {
    guard let repository, !isWritingInBackground else { return false }
    let settlingIds = settling.map(\.id)
    let step: @Sendable ([TransactionEntry], CountsSettled) -> UndoStep = { before, counts in
      settlingIds.isEmpty
        ? .editedMany(before, counts)
        : .editedManySettling(before: before, transfers: settlingIds, counts: counts)
    }
    if Self.writesInBackground(ids.count) {
      runInBackground(.change, file: file) {
        let batch = try await repository.modifyReportingInBackground(
          ids: ids, settlingTransfers: settling, planned: planned, transform: transform)
        guard !batch.modified.isEmpty else { return nil }
        return Landed(
          step: step(batch.modified.map(\.before), batch.counts),
          write: Self.laid(
            batch.counts,
            over: StoreWrite(
              upserted: batch.modified.map(\.after), planningChanged: !settlingIds.isEmpty)))
      }
      return true
    }
    do {
      var after: [UUID: TransactionEntry] = [:]
      let (before, counts) = try repository.modifyReporting(
        ids: ids, settlingTransfers: settling, planned: planned
      ) { fresh in
        let changed = transform(fresh)
        after[fresh.id] = changed
        return changed
      }
      guard !before.isEmpty else { return true }
      let write = StoreWrite(
        upserted: before.compactMap { after[$0.id] }, planningChanged: !settling.isEmpty)
      record(Landed(step: step(before, counts), write: Self.laid(counts, over: write)))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }

  /// Deletes operations in one write. A purchase on credit is left alone (it is changed in
  /// Debts); whether an operation is one is read from the database, not from the list,
  /// inside the write that deletes: nothing that lands between the choice and the deletion
  /// can change what the choice was made on. More than `backgroundThreshold` operations are
  /// chosen and deleted that way off the main thread: the whole deletion is queued at once,
  /// so nothing the owner does next lands between the choice and the deletion either.
  ///
  /// A transfer the rules keep (`TransferActions.deletionRefusals`) stays, and what else is
  /// listed goes; when nothing but kept transfers is listed, nothing is written and the answer
  /// is `false`.
  ///
  /// `settling` are the transfers that keep an archived account at zero when the deletion
  /// takes money off it or leaves money on it (`ArchivedMoney`): written in the same change
  /// and taken back by the same ⌘Z. They count the money of the operations the deletion was to
  /// take when they were worked out — `planned` (`deletionPlanned(of:)`), else those it takes as
  /// the lists have them now —, so they go in only when it takes exactly those. When one was
  /// deleted elsewhere meanwhile nothing is written, and the screen asks for the deletion again
  /// (`WriteFailureCause.planOutdated`).
  ///
  /// `reopening` are the closed debts the owner asked to open again — «Удалить и открыть долг»:
  /// each is opened in the same change and by the same ⌘Z when this deletion really leaves it
  /// closed with something owed (`debtsClosedBy(deleting:)`); a debt it does not leave so is
  /// kept as it is.
  @discardableResult
  public func delete(
    ids asked: [UUID], settling: [Transfer] = [], planned: Set<UUID>? = nil,
    reopening: Set<UUID> = [], file: String = #fileID
  ) -> Bool {
    guard !refuses("delete(ids:)", file), let repository, !isWritingInBackground else {
      return false
    }
    // The interest a payment of a loan paid, an operation of its own, goes with the payment.
    let withInterest = DebtInterestPayment.goingWithTheirPayments(
      asked, among: listing?.dataset.entries ?? [])
    // Money left on an archived account is moved in the same write, never left there: a
    // deletion that would leave some and brings no transfer for it is not written (the
    // question before it — `BulkConfirmationDialog` — always brings them).
    if settling.isEmpty, !archivedLeftovers(ofDeleting: withInterest).leftovers.isEmpty {
      AppLog.info(
        "store.deleteUnsettled", .db,
        "a deletion that would leave money on an archived account was not written",
        [LogPair("count", .count(withInterest.count))])
      return false
    }
    let (transfers, kept) = transferDeletions(among: withInterest)
    let ids = kept.isEmpty ? withInterest : withInterest.filter { kept[$0] == nil }
    let opened = debtsClosedBy(deleting: ids).filter { reopening.contains($0.id) }
    if !transfers.isEmpty || !settling.isEmpty || !opened.isEmpty {
      return delete(
        ids, with: transfers, settling: settling, reopening: opened, planned: planned, file: file)
    }
    if ids.isEmpty { return kept.isEmpty }
    // A purchase a live refund takes money back from stays: the write refuses it, and would
    // refuse the whole deletion with it.
    let refunds = listing?.refundIndex ?? .empty
    let debts = deletionDebts()
    if Self.writesInBackground(ids.count) {
      runInBackground(.delete, file: file) {
        let effects = try await repository.softDeleteInBackground(ids: ids) { listed in
          Self.deletable(listed, refunds: refunds, debts: debts)
        }
        return effects.deletedIds.isEmpty ? nil : Self.deletion(effects)
      }
      return true
    }
    do {
      var listed: [TransactionEntry] = []
      let effects = try repository.softDelete(ids: ids) { rows in
        listed = rows
        return Self.deletable(rows, refunds: refunds, debts: debts)
      }
      guard !effects.deletedIds.isEmpty else {
        return BulkEditRule.deletion(
          of: listed, refunds: refunds, deletedDebts: debts.deleted, paidDebts: debts.paid
        ).skipped.isEmpty
      }
      record(Self.deletion(effects))
      return true
    } catch {
      failed(.delete, error, file: file)
      return false
    }
  }

  // MARK: The allocation of an income

  /// What the allocation of the incomes among `ids` wrote (`Allocation.linked`) and `ids` does
  /// not name already: the contributions and the transfers «Удалить и распределение» takes along
  /// in the same step of ⌘Z — `delete(ids:)` with them added deletes them as any operation and
  /// transfer. Nothing when no income among `ids` was allocated.
  public func allocation(
    ofDeleting ids: some Collection<UUID>
  ) -> (contributions: [UUID], transfers: [UUID]) {
    guard let dataset = listing?.dataset, !ids.isEmpty else { return ([], []) }
    let asked = Set(ids)
    var contributions: [UUID] = []
    var transfers: [UUID] = []
    for entry in entries(ids: asked) where entry.transaction.kind == .income {
      let linked = Allocation.linked(
        incomeId: entry.id, entries: dataset.entries, transfers: dataset.transfers)
      contributions += linked.contributions.filter { !asked.contains($0) }
      transfers += linked.transfers.filter { !asked.contains($0) }
    }
    return (contributions, transfers)
  }

  /// «Распределено больше, чем пришло»: what the allocation of the income comes to above
  /// `amount`, the sum the edit gives it; `nil` while it is not more. The edit is not refused —
  /// the sheet of the income says it too.
  public func allocatedBeyond(incomeId: UUID, amount: AmountE4) -> AmountE4? {
    guard let dataset = listing?.dataset else { return nil }
    let done = Allocation.distributed(
      incomeId: incomeId, entries: dataset.entries, transfers: dataset.transfers)
    return done > amount ? done - amount : nil
  }

  // MARK: Transfers

  /// The transfers among `ids`, as the lists show them now; the rest of `ids` are operations.
  public func transfers(among ids: some Sequence<UUID>) -> [Transfer] {
    guard let listing else { return [] }
    let wanted = Set(ids)
    guard !wanted.isEmpty else { return [] }
    return listing.dataset.transfers.filter { wanted.contains($0.id) }
  }

  /// The ids of the transfers among `ids` a deletion takes: what a confirmation of a deletion
  /// names besides the operations. A transfer the rules keep is not among them.
  public func transferIds(in ids: some Sequence<UUID>) -> [UUID] {
    transferDeletions(among: ids).going.map(\.id)
  }

  /// What a deletion of `ids` takes besides operations: the transfers among them, and the
  /// rubles of their live fees — what the question before it says —, and why each transfer
  /// the rules keep stays.
  func transferDeletion(in ids: some Sequence<UUID>) -> TransferDeletion {
    let (going, kept) = transferDeletions(among: ids)
    guard !going.isEmpty || !kept.isEmpty, let listing else { return .none }
    let fees = feeIds(of: going).compactMap { listing.entry($0) }
    return TransferDeletion(
      count: going.count, fees: AmountE4.sum(fees.map(\.transaction.amountRubE4)),
      kept: transfers(among: ids).compactMap { kept[$0.id] })
  }

  /// The transfers among `ids` a deletion takes, and why each of the others stays. The rules
  /// are those of the screen of an account (`TransferActions.deletionRefusals`): a transfer of
  /// an account in the archive, or one whose fee something came back for, is not deleted from a
  /// list either. They are read from the rows the lists show, as the rest of a deletion is.
  private func transferDeletions(
    among ids: some Sequence<UUID>
  ) -> (going: [Transfer], kept: [UUID: TransferRefusal]) {
    let transfers = transfers(among: ids)
    guard !transfers.isEmpty, let listing else { return ([], [:]) }
    let kept = TransferActions.deletionRefusals(
      of: transfers, in: listing.dataset, refunds: listing.refundIndex)
    return (transfers.filter { kept[$0.id] == nil }, kept)
  }

  /// A deletion that takes transfers along: the transfers, their fees and the operations the
  /// rules let go, in one change of planning and so one step of ⌘Z, which brings all of it back
  /// — the parts a deleted money back had closed included. The operations are chosen by the
  /// same rule as any deletion, from the rows the lists show. More than `backgroundThreshold`
  /// rows are written off the main thread.
  private func delete(
    _ ids: [UUID], with transfers: [Transfer], settling: [Transfer] = [],
    reopening: [Debt] = [], planned: Set<UUID>? = nil, file: String
  ) -> Bool {
    guard let planning else { return false }
    let transferIds = Set(transfers.map(\.id))
    let operations = entries(ids: Set(ids).subtracting(transferIds))
    // A purchase a live refund still takes money back from stays, as in any deletion: the write
    // would refuse it, and the whole change with it.
    var gone = Self.deletable(
      operations, refunds: listing?.refundIndex ?? .empty, debts: deletionDebts())
    for fee in feeIds(of: transfers) where !gone.contains(fee) { gone.append(fee) }
    // A debt the deletion leaves closed with something owed, which the owner asked to open: the
    // same change opens it, so one ⌘Z gives back the operation and the closing together.
    let reopened = reopening.map { debt -> Debt in
      var open = debt
      open.closed = false
      return open
    }
    let change = PlanningChange(
      upsert: PlanningRows(debts: reopened, transfers: settling),
      delete: PlanningRowIDs(transfers: transfers.map(\.id)), softDeleted: gone, at: Date(),
      settlingPlanned: settling.isEmpty ? nil : planned ?? Set(gone))
    if Self.writesInBackground(gone.count + transfers.count) {
      runInBackground(.delete, file: file) {
        let undo = try await planning.applyInBackground(change)
        return Landed(step: .planned(undo), write: Self.applied(change, undo: undo))
      }
      return true
    }
    do {
      let undo = try planning.apply(change)
      record(Landed(step: .planned(undo), write: Self.applied(change, undo: undo)))
      return true
    } catch {
      failed(.delete, error, file: file)
      return false
    }
  }

  // MARK: Archived accounts stay at zero

  /// What deleting `ids` — the operations the rules let go, the transfers and their fees —
  /// would leave on accounts in the archive, as the lists have the rows now; `balances` are
  /// the accounts' now, worked out from the lists' data when not given. Nothing for a deletion
  /// that moves no archived money.
  public func archivedLeftovers(
    ofDeleting ids: [UUID], balances: AccountBalances? = nil
  ) -> ArchivedMoneyCheck {
    guard let listing, listing.dataset.paymentMethods.contains(where: \.archived) else {
      return .none
    }
    let balances = balances ?? Self.balances(of: listing.dataset)
    let (going, gone) = deletionTakes(ids)
    let removed = listing.dataset.entries.filter { gone.contains($0.id) }
    return Self.archivedLeftovers(
      removing: removed, adding: [], transfersRemoved: going, dataset: listing.dataset,
      balances: balances)
  }

  /// The operations a deletion of `ids` takes, as the lists have them now: those the rules let
  /// go, and the fees of the transfers among `ids`. What `archivedLeftovers(ofDeleting:)` weighs,
  /// taken with it for `delete(ids:settling:planned:)`.
  public func deletionPlanned(of ids: [UUID]) -> Set<UUID> {
    deletionTakes(ids).operations
  }

  private func deletionTakes(_ ids: [UUID]) -> (going: [Transfer], operations: Set<UUID>) {
    let going = transferDeletions(among: ids).going
    let transferIds = Set(going.map(\.id))
    let listed = entries(ids: Set(ids).subtracting(transferIds))
    var gone = Set(
      Self.deletable(
        listed, refunds: listing?.refundIndex ?? .empty, debts: deletionDebts()))
    gone.formUnion(feeIds(of: going))
    return (going, gone)
  }

  /// What the bulk change `edit` of `ids` would leave on accounts in the archive, as the lists
  /// have the rows now.
  public func archivedLeftovers(
    of edit: BulkEdit, ids: Set<UUID>, rates: DayRates = .empty,
    calendar: CalendarContext = .system, balances: AccountBalances? = nil
  ) -> ArchivedMoneyCheck {
    guard let listing, listing.dataset.paymentMethods.contains(where: \.archived) else {
      return .none
    }
    let after = plan(edit, ids: ids, rates: rates, calendar: calendar).changed
    let before = entries(ids: Set(after.map(\.id)))
    return Self.archivedLeftovers(
      removing: before, adding: after, dataset: listing.dataset,
      balances: balances ?? Self.balances(of: listing.dataset))
  }

  /// What one edited operation would leave on accounts in the archive.
  public func archivedLeftovers(
    editing before: TransactionEntry, into after: TransactionEntry,
    balances: AccountBalances? = nil
  ) -> ArchivedMoneyCheck {
    guard let listing, listing.dataset.paymentMethods.contains(where: \.archived) else {
      return .none
    }
    return Self.archivedLeftovers(
      removing: [before], adding: [after], dataset: listing.dataset,
      balances: balances ?? Self.balances(of: listing.dataset))
  }

  /// The balances of the accounts as the lists' data has them now.
  nonisolated static func balances(of dataset: Dataset) -> AccountBalances {
    AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: Date(), calendar: .system)
  }

  /// The movements of the operations and transfers taken away and put in, weighed against the
  /// latest counts of the archived accounts (`ArchivedMoney.leftovers`).
  nonisolated static func archivedLeftovers(
    removing old: [TransactionEntry], adding new: [TransactionEntry],
    transfersRemoved: [Transfer] = [], transfersAdded: [Transfer] = [], dataset: Dataset,
    balances: AccountBalances
  ) -> ArchivedMoneyCheck {
    let accounts = dataset.paymentMethods
    guard accounts.contains(where: \.archived) else { return .none }
    let mainId = accounts.first { $0.isDefault && !$0.archived }?.id
    let tree = CategoryTree(dataset.categories)
    func moves(_ entries: [TransactionEntry]) -> [AccountMovement] {
      entries.compactMap { AccountBalances.movement(of: $0, mainId: mainId, tree: tree) }
    }
    return ArchivedMoney.leftovers(
      removing: moves(old) + transfersRemoved.flatMap(ArchivedMoney.movements(of:)),
      adding: moves(new) + transfersAdded.flatMap(ArchivedMoney.movements(of:)),
      balances: balances, accounts: accounts)
  }

  /// The live fees of these transfers (`transfer:<id>:fee`): a transfer takes its fee along.
  private func feeIds(of transfers: [Transfer]) -> [UUID] {
    guard let listing else { return [] }
    let keys = Set(transfers.map { TransferRules.feeKey(of: $0.id) })
    return listing.dataset.entries.compactMap { entry in
      guard entry.transaction.deletedAt == nil, let key = entry.transaction.externalId,
        keys.contains(key)
      else { return nil }
      return entry.id
    }
  }

  /// What of these operations a deletion takes: the rule's choice, without what is gone.
  /// `refunds` say which purchases a live refund takes money back from, `debts` which debts are
  /// deleted and which were ever paid.
  private nonisolated static func deletable(
    _ entries: [TransactionEntry], refunds: RefundIndex = .empty, debts: DeletionDebts = .none
  ) -> [UUID] {
    let going = BulkEditRule.deletion(
      of: entries, refunds: refunds, deletedDebts: debts.deleted, paidDebts: debts.paid
    ).changed.filter { !$0.transaction.isDeleted }.map(\.id)
    return DebtInterestPayment.goingWithTheirPayments(going, among: entries)
  }

  /// The step and the report of a deletion that happened.
  private nonisolated static func deletion(_ effects: DeletionEffects) -> Landed {
    Landed(
      step: .deletedMany(effects.deletedIds, effects),
      write: laid(
        effects.counts,
        over: StoreWrite(
          removed: effects.deletedIds + effects.companionIds,
          partStatuses: statuses(effects.reopenedPartIds, .expected))))
  }

  /// Whether a bulk write of this many operations leaves the main thread.
  nonisolated static func writesInBackground(_ count: Int) -> Bool {
    count > backgroundThreshold
  }

  /// Runs a bulk write off the main thread. The store stays busy until it has landed or
  /// failed; a failure goes the way of any other (`failed`) and leaves nothing to undo.
  /// `write` returns what landed, or `nil` when there was nothing to do.
  ///
  /// Where its step goes is taken now, when the write is asked for, not when it lands: a
  /// line saved in between was asked for later, and ⌘Z must take it back first. An undo that
  /// fails gives its step — `undone`, taken off the stack for the write — back to that place.
  func runInBackground(
    _ action: StoreFailure.Action, file: String, undone: UndoStep? = nil,
    _ write: @escaping @Sendable () async throws -> Landed?
  ) {
    isWritingInBackground = true
    let asked = Asked(slot: undoStack.count, epoch: undoEpoch, attachment: attachment)
    backgroundWrite = Task { [weak self] in
      let result: Result<Landed?, any Error>
      do {
        result = .success(try await write())
      } catch {
        result = .failure(error)
      }
      self?.land(result, asked: asked, action: action, file: file, undone: undone)
      if case .success = result { return true }
      return false
    }
  }

  /// Where and when a bulk write was asked for: its place in the stack, the history and the
  /// database of that moment.
  private struct Asked: Sendable {
    var slot: Int
    var epoch: Int
    var attachment: Int
  }

  /// A bulk write back from off the main thread: its step kept where it was asked for, or —
  /// an undo that failed — the undone step given back there, and the store free again.
  ///
  /// A write asked of a database the store has let go of since (`attach`, `detach`) is none
  /// of the database it holds now: no report to its `didWrite` (an overlay of rows that are
  /// not there, a backup of a change it never had), no step, and the store — free since it
  /// let go — is not touched. A failure of such a write reaches the journal only.
  private func land(
    _ result: Result<Landed?, any Error>, asked: Asked, action: StoreFailure.Action,
    file: String, undone: UndoStep?
  ) {
    guard asked.attachment == attachment else {
      if case .failure(let error) = result { failed(action, error, file: file, onScreen: false) }
      return
    }
    switch result {
    case .success(let outcome):
      if let outcome { record(outcome, at: asked.slot, epoch: asked.epoch) }
    case .failure(let error):
      if let undone { keep(undone, at: asked.slot, epoch: asked.epoch) }
      failed(action, error, file: file)
    }
    isWritingInBackground = false
    backgroundWrite = nil
    // Held back while the write was on its way (`trimUndoHistory`).
    trimUndoHistory()
  }

  // MARK: Undo

  public var canUndo: Bool { !undoStack.isEmpty && !isWritingInBackground }

  /// Undo steps only make sense against the database they were taken from, and only up to
  /// a write that ⌘Z cannot describe (a reimbursement, a part written off). A bulk write
  /// still on its way was asked for before it and is forgotten with the rest when it lands.
  public func forgetUndoHistory() {
    undoStack.removeAll()
    undoEpoch += 1
  }

  /// ⌘Z. Undo steps are kept in the store rather than in a window's UndoManager because
  /// editing happens in one window and the list lives in another. A bulk
  /// change is one step and goes back in one write.
  ///
  /// A step leaves the stack only once it has gone back. One the database refuses — an
  /// operation filed since under the category it created — stays where it is, the journal
  /// and the screen say so (`failure`), and the next ⌘Z tries it again rather than reaching
  /// past it to the step before.
  public func undo(file: String = #fileID) {
    guard !refuses("undo", file) else { return }
    guard let repository, !isWritingInBackground, let step = undoStack.last else { return }
    if Self.writesInBackground(step.size) {
      undoStack.removeLast()
      let (planning, spending) = (planning, spending)
      runInBackground(.undo, file: file, undone: step) {
        Landed(
          step: nil,
          write: try await Self.undoInBackground(
            step, repository: repository, planning: planning, spending: spending))
      }
      return
    }
    do {
      let write: StoreWrite
      switch step {
      case .created(let id, let counts):
        let back = try repository.purge(id: id, templates: counts.operationsBefore)
        write = Self.laid(back, over: StoreWrite(removed: [id]))
      case .edited(let change):
        let back = try repository.revert(change)
        write = Self.laid(back, over: Self.revertedEdit(change))
      case .editedMany(let before, let counts):
        // My change is taken back from the rows as they are now: a part written off or a
        // rate refined since the change stays as it is.
        let snapshots = Self.byId(before)
        var reverted: [UUID: TransactionEntry] = [:]
        // What the account was charged comes back with the account: the undo puts back what
        // the operations were, a row of the time before accounts included, and asks nothing.
        let (changed, back) = try repository.modifyReporting(
          ids: before.map(\.id), checkingCharges: false, templates: counts.operationsBefore
        ) { fresh in
          let back = snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
          reverted[fresh.id] = back
          return back
        }
        write = Self.laid(back, over: StoreWrite(upserted: changed.compactMap { reverted[$0.id] }))
      case .editedManySettling(let before, let transfers, let counts):
        let snapshots = Self.byId(before)
        var reverted: [UUID: TransactionEntry] = [:]
        let (changed, back) = try repository.modifyReporting(
          ids: before.map(\.id), checkingCharges: false, removingTransfers: transfers,
          templates: counts.operationsBefore
        ) { fresh in
          let back = snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
          reverted[fresh.id] = back
          return back
        }
        write = Self.laid(
          back,
          over: StoreWrite(upserted: changed.compactMap { reverted[$0.id] }, planningChanged: true))
      case .deletedMany(let ids, let effects):
        let back = try repository.restore(ids: ids, effects: effects)
        // What comes back is whatever the rows are now; the few of them are read again.
        let restored = try repository.entries(ids: ids + effects.companionIds)
          .filter { !$0.transaction.isDeleted }
        write = Self.laid(
          back,
          over: StoreWrite(
            upserted: restored, partStatuses: Self.statuses(effects.reopenedPartIds, .returned)))
      case .planned(let undo):
        guard let planning else { return }
        let counts = try planning.revert(undo)
        let back = Self.broughtBack(by: undo)
        var readBack: [TransactionEntry] = []
        if !back.isEmpty { readBack = try repository.entries(ids: back) }
        write = Self.reverted(undo, readBack: readBack, counts: counts)
      case .moneyBack(let recorded):
        let counts = try repository.revertMoneyBack(recorded)
        let readBack = try repository.entries(ids: Self.broughtBack(by: recorded))
        write = Self.laid(counts, over: Self.revertedMoneyBack(recorded, readBack: readBack))
      case .spending(let undo):
        guard let spending else { return }
        write = try undo.revert(spending: spending, transactions: repository)
      case .later(let undo):
        write = try undo.revert(
          year: year, subscriptions: subscriptions, savedViews: savedViews, imports: imports)
      }
      // Nothing else runs on the main actor meanwhile: the step is still the last one.
      undoStack.removeLast()
      finishWrite(write)
    } catch {
      failed(.undo, error, file: file)
    }
  }

  /// The undo of a bulk step too large for the main thread: the same rules, awaited. Only
  /// the steps of many operations ever get here; the others go the way `undo` takes them.
  private nonisolated static func undoInBackground(
    _ step: UndoStep, repository: TransactionRepository, planning: PlanningRepository?,
    spending: SpendingRulesRepository?
  ) async throws -> StoreWrite {
    switch step {
    case .created(let id, let counts):
      let back = try repository.purge(id: id, templates: counts.operationsBefore)
      return laid(back, over: StoreWrite(removed: [id]))
    case .edited(let change):
      let back = try repository.revert(change)
      return laid(back, over: revertedEdit(change))
    case .editedMany(let before, let counts):
      let snapshots = byId(before)
      let batch = try await repository.modifyReportingInBackground(
        ids: before.map(\.id), checkingCharges: false, templates: counts.operationsBefore
      ) { fresh in
        snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
      }
      return laid(batch.counts, over: StoreWrite(upserted: batch.modified.map(\.after)))
    case .editedManySettling(let before, let transfers, let counts):
      let snapshots = byId(before)
      let batch = try await repository.modifyReportingInBackground(
        ids: before.map(\.id), checkingCharges: false, removingTransfers: transfers,
        templates: counts.operationsBefore
      ) { fresh in
        snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
      }
      return laid(
        batch.counts,
        over: StoreWrite(upserted: batch.modified.map(\.after), planningChanged: true))
    case .deletedMany(let ids, let effects):
      let back = try await repository.restoreInBackground(ids: ids, effects: effects)
      let restored = try await repository.entriesInBackground(ids: ids + effects.companionIds)
        .filter { !$0.transaction.isDeleted }
      return laid(
        back,
        over: StoreWrite(
          upserted: restored, partStatuses: statuses(effects.reopenedPartIds, .returned)))
    case .planned(let undo):
      // A change of planning that deleted or rewrote many operations: taken back off the main
      // thread like any bulk step.
      guard let planning else { throw PlanningUndoUnavailable() }
      let counts = try await planning.revertInBackground(undo)
      let back = broughtBack(by: undo)
      var readBack: [TransactionEntry] = []
      if !back.isEmpty { readBack = try await repository.entriesInBackground(ids: back) }
      return reverted(undo, readBack: readBack, counts: counts)
    case .moneyBack(let recorded):
      let counts = try repository.revertMoneyBack(recorded)
      let readBack = try await repository.entriesInBackground(ids: broughtBack(by: recorded))
      return laid(counts, over: revertedMoneyBack(recorded, readBack: readBack))
    case .spending(let undo):
      guard let spending else { throw PlanningUndoUnavailable() }
      return try undo.revert(spending: spending, transactions: repository)
    case .later:
      // Its steps are single small writes (`LaterUndo.size`), so they never take this path.
      throw PlanningUndoUnavailable()
    }
  }

  /// What the undo of an edit wrote: the operation as it was. A difference of a count given back
  /// may have taken the place of the one made again under its count's id, so planning is read
  /// again then too.
  private nonisolated static func revertedEdit(_ change: EditedEntry) -> StoreWrite {
    StoreWrite(
      upserted: [change.before],
      planningChanged: change.reachesBeyondTheOperation
        || OperationEditRule.isReconcileDifference(change.before.transaction))
  }

  /// The operations the undo of a money back writes back: the purchases repriced, their
  /// refunds, and the surpluses and the owner's own spending balanced again.
  private nonisolated static func broughtBack(by write: MoneyBackWrite) -> [UUID] {
    write.repricedBefore.map(\.id) + write.refundsBefore.map(\.id)
      + write.settlement.operationsBefore.map(\.id)
  }

  /// What the undo of a money back wrote: the money back, its surplus and shortfalls and the
  /// surpluses balanced anew are gone, the purchases and what hangs on them are as they are
  /// read back, the parts it closed wait again, and planning is read again.
  private nonisolated static func revertedMoneyBack(
    _ write: MoneyBackWrite, readBack: [TransactionEntry]
  ) -> StoreWrite {
    StoreWrite(
      upserted: readBack.filter { !$0.transaction.isDeleted },
      removed: write.created + write.settlement.createdOperations
        + readBack.filter(\.transaction.isDeleted).map(\.id),
      partStatuses: statuses(write.closedPartIds, .expected), planningChanged: true)
  }

  // MARK: Money back

  /// Money back recorded by a sheet — the line's confirmation or the parts of a person —, with
  /// everything `TransactionRepository.apply` wrote for it: one step of ⌘Z that takes all of it
  /// back (`revertMoneyBack`). What the counts its money reached wrote is laid over the lists.
  public func recordedMoneyBack(_ write: MoneyBackWrite, file: String = #fileID) {
    guard !refuses("recordedMoneyBack", file) else { return }
    push(.moneyBack(write))
    if !write.counts.isEmpty { finishWrite(Self.laid(write.counts, over: StoreWrite())) }
  }

  /// A write with what the counts it reached wrote laid over it (`StoreWrite.laying`); the
  /// journal gets how many counts moved and what became of their operations — counts only.
  nonisolated static func laid(_ counts: CountsSettled, over write: StoreWrite) -> StoreWrite {
    if counts.waitingForRate > 0 {
      AppLog.warning(
        "reconcile.waitsForRate", .db, "a difference in another currency waits for a rate",
        [LogPair("counts", .count(counts.waitingForRate))])
    }
    guard !counts.isEmpty else { return write }
    AppLog.info(
      "reconcile.settled", .db, "a write moved the differences of counts",
      [
        LogPair("counts", .count(counts.countsChanged)), LogPair("created", .count(counts.created)),
        LogPair("rewritten", .count(counts.rewritten)), LogPair("purged", .count(counts.purged)),
        LogPair("modeChanged", .count(counts.modeChanged)),
      ])
    return write.laying(counts)
  }

  /// The planning repository is gone — the store let go of its database — while an undo of
  /// planning was asked for.
  private struct PlanningUndoUnavailable: Error {}

  // MARK: Helpers

  /// Keeps the step of a write that has just been made and reports the write.
  func record(_ landed: Landed) {
    record(landed, at: undoStack.count, epoch: undoEpoch)
  }

  /// Keeps the step of a write where it was asked for — at `slot`, under the steps taken
  /// while it was on its way — unless the history was forgotten since, and reports the
  /// write either way: it happened, and the backup and the lists must follow it.
  private func record(_ landed: Landed, at slot: Int, epoch: Int) {
    if let step = landed.step { keep(step, at: slot, epoch: epoch) }
    finishWrite(landed.write)
  }

  /// Puts a step at `slot`, unless the history was forgotten since.
  private func keep(_ step: UndoStep, at slot: Int, epoch: Int) {
    guard epoch == undoEpoch else { return }
    // Nothing is popped or trimmed while a bulk write is on its way, and forgetting moves
    // the epoch, so the slot is still inside the stack; `min` only keeps it so.
    undoStack.insert(step, at: min(slot, undoStack.count))
    trimUndoHistory()
  }

  /// Keeps the step of a write that has just landed on the main thread.
  private func push(_ step: UndoStep) {
    undoStack.append(step)
    trimUndoHistory()
  }

  /// Lets the oldest steps go once the history reaches further back than `undoDepth`
  /// allows; the newest always stays. Not while a bulk write is on its way: its step goes
  /// in at the place it was asked for, counted from the bottom of the stack, and a step
  /// taken off the bottom meanwhile would put it above a line saved after it. The history
  /// is trimmed when that write has landed.
  private func trimUndoHistory() {
    guard !isWritingInBackground else { return }
    var operations = undoStack.reduce(0) { $0 + $1.size }
    var dropped = 0
    while undoStack.count - dropped > 1,
      undoStack.count - dropped > undoDepth.levels || operations > undoDepth.operations
    {
      operations -= undoStack[dropped].size
      dropped += 1
    }
    undoStack.removeFirst(dropped)
  }

  /// A write that did not land. The journal gets what was being done, the type of the error
  /// and the file that asked («тип, категория, место в коде»); `lastError` the type; and
  /// `failure` — what the screen shows — a write whose caller has no words of its own for it,
  /// unless it was a write on a database the screen no longer shows (`onScreen: false`).
  func failed(
    _ action: StoreFailure.Action, _ error: any Error, file: String, onScreen: Bool = true
  ) {
    let type = String(describing: Swift.type(of: error))
    lastError = type
    AppLog.error(
      "store.writeFailed", .db, "a write of the store did not land",
      [
        LogPair("action", .token(action.rawValue)), LogPair("error", .typeName(type)),
        LogPair("from", .file(file)),
      ])
    if onScreen, action.isShownByTheScreen {
      failure = StoreFailure(action: action, cause: WriteFailureCause(of: error))
    }
  }

  private func finishWrite(_ write: StoreWrite) {
    didWrite?(write)
  }

  private nonisolated static func statuses(
    _ parts: [UUID], _ status: ReimbursementStatus
  ) -> [UUID: ReimbursementStatus] {
    Dictionary(parts.map { ($0, status) }, uniquingKeysWith: { first, _ in first })
  }

  private nonisolated static func byId(_ entries: [TransactionEntry]) -> [UUID: TransactionEntry] {
    Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// My ratings by description as the database has them now: rule 2 of the qualities decides
  /// what a changed category rates a part as. The repository keeps them until a write,
  /// so a plan and the change that follows it do not read them twice.
  private func qualityHistory() -> ManualQualityHistory {
    (try? repository?.manualQualityHistory()) ?? .empty
  }
}
