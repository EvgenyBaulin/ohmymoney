import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The settings of an account's cashback in the database: how it rounds, when its bank pays,
/// where the points go. They read and write with the account, the file refuses what does not
/// belong together, an account that is the points account of another is not deleted, and a merge
/// takes the points to the account that stays.
@Suite("The cashback settings of an account in the database")
struct CashbackSettingsStorageTests {
  private func stack() throws -> DatabaseStack { try TestSupport.makeStack() }

  private func insert(_ account: PaymentMethod, into stack: DatabaseStack) throws {
    try stack.writer.write { db in try account.insert(db) }
  }

  private func stored(_ id: UUID, in stack: DatabaseStack) throws -> PaymentMethod? {
    try stack.writer.read { db in try PaymentMethod.fetchOne(db, key: id.uuidString) }
  }

  // MARK: Rows

  @Test func theSettingsRoundTripWithTheAccount() throws {
    let stack = try stack()
    let points = PaymentMethod(name: "Bonus", kind: .other)
    let account = PaymentMethod(
      name: "Black", cashbackRounding: CashbackRounding(precision: .cents, direction: .up),
      cashbackPayout: CashbackPayout.later(day: 10), cashbackPointsAccountId: points.id)
    try insert(points, into: stack)
    try insert(account, into: stack)
    #expect(try stored(account.id, in: stack) == account)
    let immediate = PaymentMethod(name: "Cash", cashbackPayout: .immediately)
    try insert(immediate, into: stack)
    #expect(try stored(immediate.id, in: stack)?.cashbackPayout == .immediately)
    #expect(try stored(points.id, in: stack)?.cashbackRounding == .standard)
  }

  /// A value the app never writes, left by a hand edit, reads as the default: one damaged cell
  /// must not stop the history from being read.
  @Test func aDamagedValueReadsAsTheDefault() throws {
    let stack = try stack()
    let account = PaymentMethod(name: "Black")
    try insert(account, into: stack)
    try stack.writer.write { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: """
          UPDATE payment_methods
          SET cashback_precision = 'nonsense', cashback_direction = '', cashback_payout = 'sometimes',
              cashback_payout_day = 99
          WHERE id = ?
          """, arguments: [account.id.uuidString])
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    let read = try #require(try stored(account.id, in: stack))
    #expect(read.cashbackRounding == .standard)
    #expect(read.cashbackPayout == nil)
  }

  // MARK: What the file refuses

  private func refuses(
    _ sql: String, _ arguments: StatementArguments = [], _ stack: DatabaseStack
  )
    -> Bool
  {
    do {
      try stack.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
      return false
    } catch {
      return true
    }
  }

  @Test func theFileRefusesAWordItDoesNotKnow() throws {
    let stack = try stack()
    let account = PaymentMethod(name: "Black")
    try insert(account, into: stack)
    let id = account.id.uuidString
    #expect(
      refuses("UPDATE payment_methods SET cashback_precision = 'x' WHERE id = ?", [id], stack))
    #expect(
      refuses("UPDATE payment_methods SET cashback_direction = 'x' WHERE id = ?", [id], stack))
    #expect(refuses("UPDATE payment_methods SET cashback_payout = 'x' WHERE id = ?", [id], stack))
    #expect(
      !refuses("UPDATE payment_methods SET cashback_direction = 'down' WHERE id = ?", [id], stack))
  }

  /// A day goes with «later» and with nothing else, and is a day of a month.
  @Test func aPayoutDayGoesWithLaterOnly() throws {
    let stack = try stack()
    let account = PaymentMethod(name: "Black")
    try insert(account, into: stack)
    let id = account.id.uuidString
    #expect(
      refuses("UPDATE payment_methods SET cashback_payout = 'later' WHERE id = ?", [id], stack))
    #expect(
      refuses(
        "UPDATE payment_methods SET cashback_payout = 'immediately', cashback_payout_day = 5 WHERE id = ?",
        [id], stack))
    #expect(
      refuses("UPDATE payment_methods SET cashback_payout_day = 5 WHERE id = ?", [id], stack))
    #expect(
      refuses(
        "UPDATE payment_methods SET cashback_payout = 'later', cashback_payout_day = 32 WHERE id = ?",
        [id], stack))
    #expect(
      refuses(
        "UPDATE payment_methods SET cashback_payout = 'later', cashback_payout_day = 0 WHERE id = ?",
        [id], stack))
    #expect(
      !refuses(
        "UPDATE payment_methods SET cashback_payout = 'later', cashback_payout_day = 31 WHERE id = ?",
        [id], stack))
  }

  @Test func thePointsAccountIsAnotherAccountThatIsThere() throws {
    let stack = try stack()
    let account = PaymentMethod(name: "Black")
    try insert(account, into: stack)
    let id = account.id.uuidString
    #expect(
      refuses(
        "UPDATE payment_methods SET cashback_points_account_id = id WHERE id = ?", [id], stack))
    #expect(
      refuses(
        "UPDATE payment_methods SET cashback_points_account_id = ? WHERE id = ?",
        [UUID().uuidString, id], stack))
  }

  // MARK: Deleting and merging

  @Test func anAccountThatIsAPointsAccountIsUsed() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let main = PaymentMethod(name: "Main", isDefault: true)
    let points = PaymentMethod(name: "Bonus")
    let account = PaymentMethod(name: "Black", cashbackPointsAccountId: points.id)
    try insert(main, into: stack)
    try insert(points, into: stack)
    try insert(account, into: stack)
    let usage = try repository.usage(of: points.id)
    #expect(usage.cashbackPoints == 1 && usage.isUsed)
    #expect(try repository.usage(of: account.id).cashbackPoints == 0)
    #expect(throws: AccountWriteError.inUse(usage)) { try repository.delete(points.id) }
    // The account that holds the link can go, and then the points account can too.
    try repository.delete(account.id)
    try repository.delete(points.id)
  }

  @Test func theUndoableDeleteRefusesAPointsAccountToo() throws {
    let stack = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let main = PaymentMethod(name: "Main", isDefault: true)
    let points = PaymentMethod(name: "Bonus")
    let account = PaymentMethod(name: "Black", cashbackPointsAccountId: points.id)
    try insert(main, into: stack)
    try insert(points, into: stack)
    try insert(account, into: stack)
    #expect(throws: PlanningWriteError.referencedByOperations(points.id)) {
      try planning.apply(PlanningChange(delete: PlanningRowIDs(paymentMethods: [points.id])))
    }
  }

  /// Two accounts are merged: whatever pointed at the one merged away points at the one that
  /// stays — the points account too.
  @Test func aMergeTakesThePointsToTheAccountThatStays() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let main = PaymentMethod(name: "Main", isDefault: true)
    let source = PaymentMethod(name: "Old bonus")
    let target = PaymentMethod(name: "Bonus")
    let account = PaymentMethod(name: "Black", cashbackPointsAccountId: source.id)
    for row in [main, source, target, account] { try insert(row, into: stack) }
    try TestSupport.fileUnderOneBank([source.id, target.id], stack: stack)
    let plan = AccountMergePlan(sourceId: source.id, target: target, at: Date())
    try repository.merge(plan, calendar: .utc)
    #expect(try stored(account.id, in: stack)?.cashbackPointsAccountId == target.id)
  }

  /// The account that stays pointed at the one merged away: it cannot be its own points account,
  /// so the link goes.
  @Test func aMergeNeverLeavesAnAccountItsOwnPointsAccount() throws {
    let stack = try stack()
    let repository = AccountRepository(writer: stack.writer)
    let main = PaymentMethod(name: "Main", isDefault: true)
    let source = PaymentMethod(name: "Bonus")
    let target = PaymentMethod(name: "Black", cashbackPointsAccountId: source.id)
    for row in [main, source, target] { try insert(row, into: stack) }
    try TestSupport.fileUnderOneBank([source.id, target.id], stack: stack)
    let plan = AccountMergePlan(sourceId: source.id, target: target, at: Date())
    try repository.merge(plan, calendar: .utc)
    #expect(try stored(target.id, in: stack)?.cashbackPointsAccountId == nil)
  }
}
