import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Many operations at once: one write, one undo")
struct BatchTests {
  private let instant = Date(timeIntervalSince1970: 1_790_000_000)

  private func makeRepository() throws -> (DatabaseStack, TransactionRepository) {
    let stack = try TestSupport.makeStack()
    return (stack, TransactionRepository(writer: stack.writer))
  }

  /// Thousands of operations in one write, the way an import would land them.
  private func insert(_ count: Int, into stack: DatabaseStack) throws -> [UUID] {
    let entries = try (0..<count).map { number in
      try TestSupport.makeEntry(amount: 1_000_000, note: "row \(number)")
    }
    try stack.writer.write { db in
      for entry in entries {
        try entry.transaction.insert(db)
        for part in entry.parts { try part.insert(db) }
      }
    }
    return entries.map(\.id)
  }

  private func renamed(_ entry: TransactionEntry, _ note: String) -> TransactionEntry {
    var changed = entry
    changed.transaction.note = note
    return changed
  }

  // MARK: modify

  @Test func aChangeReturnsTheOperationsAsTheyWereBefore() throws {
    let (_, repository) = try makeRepository()
    let first = try TestSupport.makeEntry(note: "coffee")
    let second = try TestSupport.makeEntry(note: "tea")
    let untouched = try TestSupport.makeEntry(note: "water")
    for entry in [first, second, untouched] { try repository.save(entry) }
    // SQLite keeps dates to the millisecond, so the stored row is the one to compare with.
    let stored = try #require(try repository.entry(id: first.id))

    let before = try repository.modify(ids: [first.id, second.id, first.id], at: instant) {
      self.renamed($0, "changed")
    }

    #expect(Set(before.map(\.transaction.note)) == ["coffee", "tea"])
    let after = try repository.entries(ids: [first.id, second.id, untouched.id])
    let byId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byId[first.id]?.transaction.note == "changed")
    #expect(byId[first.id]?.transaction.updatedAt == instant)
    #expect(byId[first.id]?.transaction.createdAt == stored.transaction.createdAt)
    #expect(byId[untouched.id]?.transaction.note == "water")
  }

  /// All or nothing: one operation that no longer adds up stops the whole change, even when
  /// it sits in the third chunk of ids.
  @Test func aChangeThatFailsAnywhereLeavesEverythingAsItWas() throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(1_200, into: stack)
    let broken = ids[1_100]

    #expect(throws: DatabaseError.unbalancedParts) {
      try repository.modify(ids: ids, at: instant) { entry in
        var changed = self.renamed(entry, "changed")
        if entry.id == broken { changed.parts[0].amountE4 = AmountE4(raw: 1) }
        return changed
      }
    }
    let notes = try repository.entries(ids: ids).map(\.transaction.note)
    #expect(!notes.contains("changed"))
  }

  /// The list the change was chosen from can lag behind the database. A part written off
  /// after the list was read stays written off when the category of its operation changes.
  @Test func aPartWrittenOffAfterTheListWasReadStaysWrittenOff() throws {
    let (stack, repository) = try makeRepository()
    let references = ReferenceRepository(writer: stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let fuel = CoreKit.Category(kind: .expense, name: "Fuel", quality: .neutral)
    try references.save(groceries)
    try references.save(fuel)
    var dinner = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600), reimbursable: true),
    ]
    let saved = try dinner.materialize()
    try repository.save(saved)
    let listed = try repository.entries(ids: [saved.id])

    try repository.writeOffPart(id: saved.parts[1].id)
    let tree = CategoryTree([groceries, fuel])
    let before = try repository.modify(ids: listed.map(\.id), at: instant) { fresh in
      BulkEditRule.apply(.category(fuel.id), to: fresh, tree: tree).changedEntry
    }

    let stored = try #require(try repository.entry(id: saved.id))
    #expect(stored.parts.map(\.categoryId) == [fuel.id, fuel.id])
    #expect(stored.parts[1].reimbursementStatus == .writtenOff)
    // The snapshot for undo is the row as it was inside the write, not the stale copy.
    #expect(before.first?.parts[1].reimbursementStatus == .writtenOff)
  }

  // MARK: 40 000 ids

  /// Far past the limit on bound parameters: every method sends ids in chunks.
  @Test func fortyThousandOperationsAreChangedDeletedAndRestored() throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(40_000, into: stack)

    #expect(try repository.entries(ids: ids).count == 40_000)
    let before = try repository.modify(ids: ids, at: instant) { self.renamed($0, "changed") }
    #expect(before.count == 40_000)

    let effects = try repository.softDelete(ids: ids, at: instant)
    #expect(effects.deletedIds.count == 40_000)
    #expect(try repository.count() == 0)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try repository.count() == 40_000)
  }

  // MARK: Off the calling thread

  /// The twins that await do the work of the synchronous calls: a change hands back both
  /// sides of every operation it rewrote, and deleting and restoring land the same way.
  @Test func theBackgroundTwinsChangeDeleteAndRestoreLikeTheOthers() async throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(1_200, into: stack)

    let modified = try await repository.modifyInBackground(
      ids: ids + [ids[0]], at: instant
    ) { entry in
      var changed = entry
      changed.transaction.note = "changed"
      return changed
    }

    #expect(modified.count == 1_200)
    #expect(modified.allSatisfy { $0.before.transaction.note?.hasPrefix("row ") == true })
    #expect(modified.allSatisfy { $0.after.transaction.note == "changed" })
    #expect(modified.allSatisfy { $0.after.transaction.updatedAt == instant })
    let read = try await repository.entriesInBackground(ids: ids)
    #expect(read.count == 1_200)
    #expect(read.allSatisfy { $0.transaction.note == "changed" })

    let effects = try await repository.softDeleteInBackground(ids: ids, at: instant)
    #expect(effects.deletedIds.count == 1_200)
    #expect(try repository.count() == 0)

    try await repository.restoreInBackground(
      ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try repository.count() == 1_200)
  }

  /// A deletion off the calling thread chooses what goes inside its own write, from the
  /// rows as the database holds them then: the caller's rule sees a change made after the
  /// list was read, and what the rule leaves out stays. Reading and deleting in one write
  /// also queues the whole deletion at once, so nothing lands between the choice and it.
  @Test func aBackgroundDeletionChoosesWhatGoesInsideItsWrite() async throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(3, into: stack)
    try repository.modify(ids: [ids[2]], at: instant) { renamed($0, "keep") }

    let effects = try await repository.softDeleteInBackground(ids: ids, at: instant) { rows in
      rows.filter { $0.transaction.note != "keep" }.map(\.id)
    }

    #expect(Set(effects.deletedIds) == [ids[0], ids[1]])
    #expect(try repository.count() == 1)
    #expect(try repository.entry(id: ids[2])?.transaction.isDeleted == false)
  }

  /// The same on the calling thread: the app deletes up to a thousand operations there, and
  /// its choice is made inside the write as well — never on rows read in a transaction of
  /// their own, which a write landing in between could have changed.
  @Test func aDeletionChoosesWhatGoesInsideItsWrite() throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(3, into: stack)
    try repository.modify(ids: [ids[2]], at: instant) { renamed($0, "keep") }
    var seen: [UUID] = []

    let effects = try repository.softDelete(ids: ids, at: instant) { rows in
      seen = rows.map(\.id)
      return rows.filter { $0.transaction.note != "keep" }.map(\.id)
    }

    #expect(Set(seen) == Set(ids))
    #expect(Set(effects.deletedIds) == [ids[0], ids[1]])
    #expect(try repository.entry(id: ids[2])?.transaction.isDeleted == false)
  }

  // MARK: Deleting a reimbursement

  private struct Ledger {
    var income: AmountE4
    var mine: AmountE4
    var owed: AmountE4
  }

  private func ledger(_ repository: TransactionRepository) throws -> Ledger {
    let all = try repository.entries(from: .distantPast, to: .distantFuture)
    let totals = RowTotals(entries: all)
    return Ledger(
      income: totals.income, mine: totals.myExpenses,
      owed: MyExpensesRule.totalOwedToMe(entries: all))
  }

  /// A dinner: 400 mine, 600 for a friend, plus a salary so income is not empty.
  private func dinnerForAFriend(
    _ stack: DatabaseStack, _ repository: TransactionRepository
  ) throws -> (groceries: CoreKit.Category, surcharges: CoreKit.Category, owed: [OwedPart]) {
    let references = ReferenceRepository(writer: stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.save(groceries)
    try references.save(surcharges)

    var salary = TransactionDraft(kind: .income, amount: AmountE4(whole: 5_000), note: "salary")
    salary.normalizeSinglePart()
    try repository.save(try salary.materialize())
    var dinner = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600), reimbursable: true),
    ]
    try repository.save(try dinner.materialize())
    return (groceries, surcharges, try repository.owedParts())
  }

  /// Records a reimbursement the way the sheet does: the operation, the links and the
  /// surplus or shortfall with the key that points back at it.
  private func reimburse(
    _ received: Int64, closing owed: [OwedPart], surcharges: UUID,
    repository: TransactionRepository, at instant: Date = Date()
  ) throws -> UUID {
    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: received),
      closing: owed.map(\.inRubles))
    var draft = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: received))
    draft.normalizeSinglePart()
    var extra: [TransactionEntry] = []
    if let surplus = outcome.surplus {
      var income = TransactionDraft(kind: .income, amount: surplus.amountE4)
      income.parts = [PartDraft(categoryId: surcharges, amount: surplus.amountE4)]
      var entry = try income.materialize()
      entry.transaction.externalId = ReimbursementCompanions.surplusKey(of: reimbursementId)
      extra.append(entry)
    }
    for shortfall in outcome.shortfalls {
      var expense = TransactionDraft(amount: shortfall.amountE4)
      expense.parts = [PartDraft(categoryId: shortfall.categoryId, amount: shortfall.amountE4)]
      var entry = try expense.materialize()
      entry.transaction.externalId = ReimbursementCompanions.shortfallKey(
        of: reimbursementId, partId: shortfall.partId)
      extra.append(entry)
    }
    try repository.apply(
      outcome, reimbursement: try draft.materialize(id: reimbursementId), extra: extra,
      at: instant)
    return reimbursementId
  }

  /// How far a part has come back is a fact about its operation: closing it, reopening it
  /// by deleting the reimbursement and writing it off all stamp the purchase's `updated_at`,
  /// which the export and the transfer archive carry; closing it again by ⌘Z gives back the
  /// moment the purchase had before the deletion.
  @Test func aPartsStatusStampsItsOperationAsUpdated() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    func updated() throws -> Date? {
      try repository.entry(id: part.transactionId)?.transaction.updatedAt
    }

    let reimbursementId = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository,
      at: instant)
    #expect(try updated() == instant)

    let deletedAt = instant.addingTimeInterval(60)
    let effects = try repository.softDelete(ids: [reimbursementId], at: deletedAt)
    #expect(try updated() == deletedAt)

    let restoredAt = instant.addingTimeInterval(120)
    try repository.restore(ids: effects.deletedIds, at: restoredAt, effects: effects)
    #expect(try updated() == instant)

    try repository.softDelete(ids: [reimbursementId], at: instant.addingTimeInterval(180))
    let writtenOffAt = instant.addingTimeInterval(240)
    try repository.writeOffPart(id: part.partId, at: writtenOffAt)
    #expect(try updated() == writtenOffAt)
  }

  @Test func deletingAReimbursementWithASurplusPutsEverythingBack() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let original = try ledger(repository)
    #expect(original.income == AmountE4(whole: 5_000))
    #expect(original.mine == AmountE4(whole: 400))
    #expect(original.owed == AmountE4(whole: 600))

    let reimbursementId = try reimburse(
      700, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let reimbursed = try ledger(repository)
    #expect(reimbursed.income == AmountE4(whole: 5_100))
    #expect(reimbursed.owed == .zero)

    let effects = try repository.softDelete(ids: [reimbursementId], at: instant)
    #expect(effects.deletedIds == [reimbursementId])
    #expect(effects.companionIds.count == 1)
    #expect(effects.reopenedPartIds == setup.owed.map(\.partId))
    let deleted = try ledger(repository)
    #expect(deleted.income == original.income)
    #expect(deleted.mine == original.mine)
    #expect(deleted.owed == original.owed)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    let restored = try ledger(repository)
    #expect(restored.income == reimbursed.income)
    #expect(restored.mine == reimbursed.mine)
    #expect(restored.owed == .zero)
  }

  @Test func deletingAReimbursementWithAShortfallPutsEverythingBack() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let original = try ledger(repository)

    let reimbursementId = try reimburse(
      500, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let reimbursed = try ledger(repository)
    // The 100 that never came back is my spending now.
    #expect(reimbursed.mine == AmountE4(whole: 500))
    #expect(reimbursed.owed == .zero)

    let effects = try repository.softDelete(ids: [reimbursementId], at: instant)
    #expect(effects.companionIds.count == 1)
    let deleted = try ledger(repository)
    #expect(deleted.income == original.income)
    #expect(deleted.mine == original.mine)
    #expect(deleted.owed == original.owed)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    let restored = try ledger(repository)
    #expect(restored.mine == reimbursed.mine)
    #expect(restored.owed == .zero)
    #expect(try repository.owedParts().isEmpty)
  }

  /// A part two reimbursements closed together stays closed while the live one still covers
  /// it: its link gives back all of the part.
  @Test func aPartStaysClosedWhileLiveMoneyBackStillCoversIt() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let first = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let second = try TestSupport.makeEntry(amount: 6_000_000, kind: .reimbursement, note: nil)
    try repository.save(second)
    try stack.writer.write { db in
      try ReimbursementLink(
        reimbursementTxId: second.id, partId: setup.owed[0].partId,
        amountE4: AmountE4(whole: 600)
      ).insert(db)
    }

    let effects = try repository.softDelete(ids: [first], at: instant)
    #expect(effects.reopenedPartIds.isEmpty)
    #expect(try repository.owedParts().isEmpty)

    let both = try repository.softDelete(ids: [second.id], at: instant)
    #expect(both.reopenedPartIds == [setup.owed[0].partId])
    #expect(try repository.owedParts().map(\.partId) == [setup.owed[0].partId])
  }

  // MARK: A reimbursement against a part that stopped waiting

  /// The sheet reads the parts once, when it opens. The purchase can be deleted meanwhile —
  /// from the Transactions window, which the sheet does not block — and a link to its part
  /// would count the money as returned with nothing behind it.
  @Test func aReimbursementIsRefusedForAPartOfADeletedPurchase() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    try repository.softDelete(ids: [part.transactionId], at: instant)
    let count = try repository.count()

    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }
    #expect(try repository.count() == count)
    #expect(try stack.writer.read { try ReimbursementLink.fetchCount($0) } == 0)
    #expect(
      try stack.writer.read { try TransactionPart.fetchOne($0, key: part.partId.uuidString) }?
        .reimbursementStatus != .returned)
  }

  /// ⌘Z of the purchase's save purges it: the reimbursement is refused in words of its own,
  /// not by the foreign key of the link.
  @Test func aReimbursementIsRefusedForAPartOfAPurgedPurchase() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    try repository.purge(id: part.transactionId)
    let count = try repository.count()

    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }
    #expect(try repository.count() == count)
  }

  /// Written off, or closed by a reimbursement recorded in another sheet: the part is not
  /// closed a second time.
  @Test func aReimbursementIsRefusedForAPartWrittenOffOrClosedMeanwhile() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    try repository.writeOffPart(id: part.partId)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }

    try stack.writer.write { db in
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [ReimbursementStatus.expected.rawValue, part.partId.uuidString])
    }
    _ = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let count = try repository.count()
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }
    #expect(try repository.count() == count)
    #expect(try stack.writer.read { try ReimbursementLink.fetchCount($0) } == 1)
  }

  /// «Write off» in the sheet acts on the list read when the sheet opened. A part closed by
  /// a reimbursement since keeps its status — flipping it would leave the link counting
  /// money for a part given up on — and so does one written off, or one whose purchase went.
  @Test func aPartNoLongerWaitingIsNotWrittenOff() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    func status() throws -> ReimbursementStatus? {
      try stack.writer.read { try TransactionPart.fetchOne($0, key: part.partId.uuidString) }?
        .reimbursementStatus
    }

    let reimbursementId = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try repository.writeOffPart(id: part.partId)
    }
    #expect(try status() == .returned)

    try repository.softDelete(ids: [reimbursementId], at: instant)
    try repository.writeOffPart(id: part.partId)
    #expect(try status() == .writtenOff)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try repository.writeOffPart(id: part.partId)
    }

    try repository.softDelete(ids: [part.transactionId], at: instant)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try repository.writeOffPart(id: part.partId)
    }
  }

  // MARK: Why a write failed

  /// An undo that would take away a category an operation was filed under since fails on the
  /// schema's `RESTRICT`: the owner is told that rows are tied, not that the database broke.
  @Test func aForeignKeyRefusalIsTiedToOtherRows() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    var thrown: (any Error)?
    do {
      try stack.writer.write { db in
        _ = try CoreKit.Category.deleteOne(db, key: setup.groceries.id.uuidString)
      }
    } catch {
      thrown = error
    }
    let error = try #require(thrown)
    #expect(WriteFailureCause(of: error) == .tiedToOtherRows)
    #expect(
      WriteFailureCause(of: PlanningWriteError.referencedByOperations(UUID()))
        == .tiedToOtherRows)
    #expect(WriteFailureCause(of: DatabaseError.unbalancedParts) == .other)
  }

  /// A bulk change whose transfers were worked out on operations that changed since is no
  /// failure of the database: the owner is told to make the change again.
  @Test func anOutdatedPlanIsSaidAsSuch() {
    #expect(
      WriteFailureCause(of: SettlingPlanOutdated(operationIds: [UUID()])) == .planOutdated)
  }

  // MARK: Deleting a debt payment

  @Test func deletingADebtPaymentTakesItsMovementOffTheDebtAndUndoPutsItBack() throws {
    let (stack, repository) = try makeRepository()
    let references = ReferenceRepository(writer: stack.writer)
    let loan = Debt(direction: .iOwe, type: .loan, name: "Bank loan", paymentsAreExpenses: true)
    try references.save(loan)
    var draft = TransactionDraft(amount: AmountE4(whole: 7_000), note: "loan", debtId: loan.id)
    draft.normalizeSinglePart()
    let payment = try draft.materialize()
    try repository.save(payment)
    let movement = DebtEntry(
      debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 1),
      amountE4: AmountE4(whole: -7_000), kind: .payment, transactionId: payment.id)
    try references.save(movement)

    let effects = try repository.softDelete(ids: [payment.id], at: instant)
    #expect(effects.removedDebtEntries == [movement])
    #expect(try references.debtEntries(debtId: loan.id).isEmpty)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try references.debtEntries(debtId: loan.id) == [movement])
    #expect(try repository.count() == 1)
  }

  /// Undo brings back what the deletion deleted — not an operation that had been deleted
  /// before and was only named again.
  @Test func anOperationDeletedEarlierIsNotBroughtBackByALaterUndo() throws {
    let (_, repository) = try makeRepository()
    let old = try TestSupport.makeEntry(note: "old")
    let new = try TestSupport.makeEntry(note: "new")
    try repository.save(old)
    try repository.save(new)
    try repository.softDelete(id: old.id)

    let effects = try repository.softDelete(ids: [old.id, new.id], at: instant)
    #expect(effects.deletedIds == [new.id])
    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try repository.entry(id: old.id)?.transaction.isDeleted == true)
    #expect(try repository.entry(id: new.id)?.transaction.isDeleted == false)
  }

  /// ⌘Z of a deletion gives each operation back the moment it was last written, its
  /// companions' too: bringing it back is not a new write of it. «coffee 250» rated bad on 01.09
  /// and «coffee 300» rated good on 10.09; the first deleted on 15.09 and brought back — the
  /// owner's latest rating of «coffee» is still the good one.
  @Test func undoOfADeletionGivesBackTheUpdateMoment() throws {
    let (_, repository) = try makeRepository()
    let first = Date(timeIntervalSince1970: 1_788_220_800)
    func coffee(_ amount: Int64, _ quality: Quality, at moment: Date) throws -> TransactionEntry {
      var entry = try TestSupport.makeEntry(amount: amount, occurredAt: moment, note: "coffee")
      entry.transaction.createdAt = moment
      entry.transaction.updatedAt = moment
      entry.parts[0].quality = quality
      entry.parts[0].qualitySource = .manual
      return entry
    }
    let bad = try repository.save(try coffee(2_500_000, .bad, at: first))
    try repository.save(try coffee(3_000_000, .good, at: first.addingTimeInterval(9 * 86_400)))
    let deletedAt = first.addingTimeInterval(14 * 86_400)
    let effects = try repository.softDelete(ids: [bad.id], at: deletedAt)
    #expect(effects.updatedAtBefore == [bad.id: first])
    #expect(try repository.entry(id: bad.id)?.transaction.updatedAt == deletedAt)
    try repository.restore(
      ids: effects.deletedIds, at: deletedAt.addingTimeInterval(60), effects: effects)
    let back = try #require(try repository.entry(id: bad.id))
    #expect(!back.transaction.isDeleted)
    #expect(back.transaction.updatedAt == first)
    #expect(try repository.manualQualityHistory().quality(for: "coffee") == .good)
  }

  /// A reimbursement deleted with its surplus: ⌘Z gives both their moments back.
  @Test func undoOfADeletionGivesTheCompanionsTheirMomentsBack() throws {
    let (stack, repository) = try makeRepository()
    let (_, surcharges, owed) = try dinnerForAFriend(stack, repository)
    let money = try reimburse(
      700, closing: owed, surcharges: surcharges.id, repository: repository,
      at: instant.addingTimeInterval(-3_600))
    let stamps = try repository.entries(from: .distantPast, to: .distantFuture)
      .reduce(into: [UUID: Date]()) { $0[$1.id] = $1.transaction.updatedAt }
    let effects = try repository.softDelete(ids: [money], at: instant)
    #expect(!effects.companionIds.isEmpty)
    try repository.restore(
      ids: effects.deletedIds, at: instant.addingTimeInterval(60), effects: effects)
    for id in [money] + effects.companionIds {
      #expect(try repository.entry(id: id)?.transaction.updatedAt == stamps[id])
    }
  }

  /// A money back that closed the part of a dinner, deleted and brought back by ⌘Z: the
  /// deletion stamps the dinner — its part waits again —, and ⌘Z gives the dinner back the
  /// moment it had before, not the moment of the ⌘Z: its rating stays as old as it is.
  @Test func undoOfDeletingAMoneyBackGivesItsPurchasesTheirMomentsBack() throws {
    let (stack, repository) = try makeRepository()
    let (_, surcharges, owed) = try dinnerForAFriend(stack, repository)
    let dinner = try #require(owed.first?.transactionId)
    let money = try reimburse(
      600, closing: owed, surcharges: surcharges.id, repository: repository,
      at: instant.addingTimeInterval(-3_600))
    let before = try #require(try repository.entry(id: dinner)?.transaction.updatedAt)
    let effects = try repository.softDelete(ids: [money], at: instant)
    #expect(effects.reopenedPartIds == owed.map(\.partId))
    #expect(try repository.entry(id: dinner)?.transaction.updatedAt == instant)
    try repository.restore(
      ids: effects.deletedIds, at: instant.addingTimeInterval(60), effects: effects)
    let back = try #require(try repository.entry(id: dinner))
    #expect(back.transaction.updatedAt == before)
    #expect(back.parts.first { $0.id == owed[0].partId }?.reimbursementStatus == .returned)
  }

  // MARK: The card of an operation, and money left on an account in the archive

  /// Five purchases paid with the card of «T-Bank», one with 35 rubles of cashback typed for
  /// it, moved to «Sber» in one bulk change: the card stays behind with its account. ⌘Z puts
  /// them back on «T-Bank» with the card and the cashback.
  @Test func undoOfAMoveToAnotherAccountBringsTheCardBack() throws {
    let (stack, repository) = try makeRepository()
    let tbank = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, isDefault: true)
    let sber = PaymentMethod(name: "Sber", kind: .card, currency: .rub)
    let card = PaymentCard(accountId: tbank.id, name: "T-Bank")
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [tbank, sber], cards: [card])))
    var ids: [UUID] = []
    for number in 0..<5 {
      var draft = TransactionDraft(
        occurredAt: instant, amount: AmountE4(whole: 100 * Int64(number + 1)),
        note: "purchase \(number)", paymentMethodId: tbank.id, cardId: card.id,
        cashback: number == 0 ? Money(amount: AmountE4(whole: 35), currency: .rub) : nil)
      draft.normalizeSinglePart()
      let entry = try draft.materialize()
      try repository.save(entry)
      ids.append(entry.id)
    }
    let stored = try repository.entries(ids: ids)
    let tree = CategoryTree([])
    let accounts = [tbank, sber]

    let before = try repository.modify(ids: ids, at: instant) { entry in
      BulkEditRule.apply(.paymentMethod(sber.id), to: entry, tree: tree, accounts: accounts)
        .changedEntry
    }
    #expect(before.count == 5)
    let moved = try repository.entries(ids: ids)
    #expect(moved.allSatisfy { $0.transaction.paymentMethodId == sber.id })
    #expect(moved.allSatisfy { $0.transaction.cardId == nil })
    #expect(moved.compactMap(\.transaction.cashback).count == 1)

    let snapshots = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
    try repository.modify(ids: ids, at: instant, checkingCharges: false) { current in
      snapshots[current.id].map { BulkEditRule.revert(current, to: $0) }
    }
    let back = Dictionary(
      uniqueKeysWithValues: try repository.entries(ids: ids).map { ($0.id, $0) })
    for entry in stored {
      #expect(back[entry.id]?.transaction.paymentMethodId == tbank.id)
      #expect(back[entry.id]?.transaction.cardId == card.id)
      #expect(back[entry.id]?.transaction.cashback == entry.transaction.cashback)
    }
  }

  /// Two purchases on cash in the archive made cheaper in one bulk change: the money they leave
  /// on the cash goes to the live card in the same write. One the rules refuse leaves all of it
  /// as it was, and the undo of the change takes its transfer away with the operations.
  @Test func aBulkEditWritesItsSettlingTransfersInOneWrite() async throws {
    let (stack, repository) = try makeRepository()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Sber", kind: .card, currency: .rub, isDefault: true)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try references.save(card)
    try references.save(cash)
    var ids: [UUID] = []
    for amount: Int64 in [1_000, 2_000] {
      var draft = TransactionDraft(
        occurredAt: instant, amount: AmountE4(whole: amount), note: "market",
        paymentMethodId: cash.id)
      draft.normalizeSinglePart()
      let entry = try draft.materialize()
      try repository.save(entry)
      ids.append(entry.id)
    }
    cash.archived = true
    try references.save(cash)
    let stored = try repository.entries(ids: ids)
    let halved: @Sendable (TransactionEntry) -> TransactionEntry? = { entry in
      var changed = entry
      let half = AmountE4(raw: entry.transaction.amountE4.raw / 2)
      changed.transaction.amountE4 = half
      changed.transaction.amountRubE4 = half
      changed.parts[0].amountE4 = half
      changed.parts[0].amountRubE4 = half
      return changed
    }
    let settling = Transfer(
      occurredAt: instant, fromAccountId: cash.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_500), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_500), createdAt: instant, updatedAt: instant)
    func transfers() throws -> [Transfer] {
      try stack.writer.read { db in try Transfer.fetchAll(db) }
    }

    var wrong = settling
    wrong.toAmountE4 = AmountE4(whole: 1_400)
    #expect(throws: SettlingTransferRefusal(transferId: wrong.id, issue: .amountsDiffer)) {
      try repository.modify(ids: ids, at: instant, settlingTransfers: [wrong], transform: halved)
    }
    #expect(
      try repository.entries(ids: ids).sorted { $0.id.uuidString < $1.id.uuidString }
        == stored.sorted { $0.id.uuidString < $1.id.uuidString })
    #expect(try transfers().isEmpty)

    let modified = try await repository.modifyInBackground(
      ids: ids, at: instant, settlingTransfers: [settling], transform: halved)
    #expect(modified.count == 2)
    #expect(try transfers() == [settling])

    let snapshots: [UUID: TransactionEntry] = Dictionary(
      uniqueKeysWithValues: modified.map { ($0.before.id, $0.before) })
    try repository.modify(
      ids: ids, at: instant, checkingCharges: false, removingTransfers: [settling.id]
    ) { current in snapshots[current.id] }
    #expect(try transfers().isEmpty)
    #expect(
      try repository.entries(ids: ids).map(\.transaction.amountE4).sorted()
        == [AmountE4(whole: 1_000), AmountE4(whole: 2_000)])
  }

  /// Two purchases of 1,000 and 2,000 on cash that went to the archive after them, the live
  /// card the main account.
  private struct ArchivedCash {
    let stack: DatabaseStack
    let repository: TransactionRepository
    let card: PaymentMethod
    let cash: PaymentMethod
    let ids: [UUID]

    func transfers() throws -> [Transfer] {
      try stack.writer.read { db in try Transfer.fetchAll(db) }
    }

    func amounts() throws -> [UUID: AmountE4] {
      Dictionary(
        uniqueKeysWithValues: try repository.entries(ids: ids).map {
          ($0.id, $0.transaction.amountE4)
        })
    }

    /// The money `amount` moved from the cash to the card.
    func settling(_ amount: Int64, at instant: Date) -> Transfer {
      Transfer(
        occurredAt: instant, fromAccountId: cash.id, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: amount), toAccountId: card.id, toCurrency: .rub,
        toAmountE4: AmountE4(whole: amount), createdAt: instant, updatedAt: instant)
    }
  }

  private func archivedCash() throws -> ArchivedCash {
    let (stack, repository) = try makeRepository()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Sber", kind: .card, currency: .rub, isDefault: true)
    var cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try references.save(card)
    try references.save(cash)
    var ids: [UUID] = []
    for amount: Int64 in [1_000, 2_000] {
      var draft = TransactionDraft(
        occurredAt: instant, amount: AmountE4(whole: amount), note: "market",
        paymentMethodId: cash.id)
      draft.normalizeSinglePart()
      let entry = try draft.materialize()
      try repository.save(entry)
      ids.append(entry.id)
    }
    cash.archived = true
    try references.save(cash)
    return ArchivedCash(
      stack: stack, repository: repository, card: card, cash: cash, ids: ids)
  }

  /// The planned change of the purchases: each one priced at `amounts[id]`, the rest left.
  private func priced(
    _ amounts: [UUID: AmountE4]
  ) -> @Sendable (TransactionEntry) -> TransactionEntry? {
    { entry in
      guard let amount = amounts[entry.id] else { return nil }
      var changed = entry
      changed.transaction.amountE4 = amount
      changed.transaction.amountRubE4 = amount
      changed.parts[0].amountE4 = amount
      changed.parts[0].amountRubE4 = amount
      return changed
    }
  }

  /// Another window made both purchases cheaper while the change that planned the same was
  /// waiting: nothing changes in the write, so the transfer worked out for the plan is not
  /// written — and the change is not refused for naming the archived cash either.
  @Test func aBulkEditThatChangesNothingWritesNoTransfer() async throws {
    let setup = try archivedCash()
    let (first, second) = (setup.ids[0], setup.ids[1])
    let cheaper = priced([first: AmountE4(whole: 500), second: AmountE4(whole: 1_000)])
    try setup.repository.modify(ids: setup.ids, at: instant, transform: cheaper)
    let settling = setup.settling(1_500, at: instant)

    let before = try setup.repository.modify(
      ids: setup.ids, at: instant, settlingTransfers: [settling], transform: cheaper)
    #expect(before.isEmpty)
    #expect(try setup.transfers().isEmpty)

    let planned = Set(setup.ids)
    let modified = try await setup.repository.modifyInBackground(
      ids: setup.ids, at: instant, settlingTransfers: [settling], planned: planned,
      transform: cheaper)
    #expect(modified.isEmpty)
    #expect(try setup.transfers().isEmpty)
  }

  /// One of the two purchases was made cheaper elsewhere meanwhile; the transfer of the plan
  /// counts both. Written, it would leave 500 below zero on the archived cash, so nothing of
  /// the change is written and the caller is told which operation left the plan. Planned
  /// again, the change of the other purchase lands with its own transfer.
  @Test func aBulkEditWhoseOperationNoLongerChangesWritesNothing() async throws {
    let setup = try archivedCash()
    let (first, second) = (setup.ids[0], setup.ids[1])
    let cheaper = priced([first: AmountE4(whole: 500), second: AmountE4(whole: 1_000)])
    try setup.repository.modify(ids: [first], at: instant, transform: cheaper)
    let stored = try setup.amounts()
    let outdated = SettlingPlanOutdated(operationIds: [first])

    #expect(throws: outdated) {
      try setup.repository.modify(
        ids: setup.ids, at: instant, settlingTransfers: [setup.settling(1_500, at: instant)],
        planned: [first, second], transform: cheaper)
    }
    #expect(try setup.amounts() == stored)
    #expect(try setup.transfers().isEmpty)
    await #expect(throws: outdated) {
      try await setup.repository.modifyInBackground(
        ids: setup.ids, at: instant, settlingTransfers: [setup.settling(1_500, at: instant)],
        planned: [first, second], transform: cheaper)
    }
    #expect(try setup.amounts() == stored)
    #expect(try setup.transfers().isEmpty)

    // An operation the plan left alone that changes is no less a change the transfer does not
    // count.
    #expect(throws: SettlingPlanOutdated(operationIds: [second])) {
      try setup.repository.modify(
        ids: setup.ids, at: instant, settlingTransfers: [setup.settling(1_000, at: instant)],
        planned: [], transform: cheaper)
    }
    #expect(try setup.amounts() == stored)
    #expect(try setup.transfers().isEmpty)

    let settling = setup.settling(1_000, at: instant)
    let before = try setup.repository.modify(
      ids: setup.ids, at: instant, settlingTransfers: [settling], planned: [second],
      transform: cheaper)
    #expect(before.map(\.id) == [second])
    #expect(try setup.amounts()[second] == AmountE4(whole: 1_000))
    #expect(try setup.transfers() == [settling])
  }
}
