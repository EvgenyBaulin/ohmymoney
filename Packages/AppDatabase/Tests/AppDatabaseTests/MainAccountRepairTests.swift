import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Every open leaves exactly one live main account, whatever a write cut short left behind:
/// two flagged, an archived one flagged, or none.
@Suite("The main account is put right on every open")
struct MainAccountRepairTests {
  /// Accounts written as they are, flags and all — the way a write cut short leaves them —
  /// with `operations` live operations on each.
  private func stack(
    _ accounts: [(PaymentMethod, operations: Int)], groups: [AccountGroup] = []
  ) throws -> DatabaseStack {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      for group in groups { try LegacyWriter.insert(group, db: db) }
      for (account, operations) in accounts {
        try LegacyWriter.insert(account, db: db)
        for index in 0..<operations {
          var entry = try TestSupport.makeEntry(
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 60))
          entry.transaction.paymentMethodId = account.id
          try LegacyWriter.insert(entry.transaction, db: db)
          for part in entry.parts { try LegacyWriter.insert(part, db: db) }
        }
      }
    }
    return stack
  }

  private func mains(_ stack: DatabaseStack) throws -> [UUID] {
    try stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT id FROM payment_methods WHERE is_default = 1 ORDER BY rowid"
      ).compactMap(UUID.init(uuidString:))
    }
  }

  @Test func twoMainAccountsLeaveTheMostUsedOne() throws {
    let quiet = PaymentMethod(name: "Quiet", isDefault: true)
    let busy = PaymentMethod(name: "Busy", isDefault: true)
    let stack = try stack([(quiet, 1), (busy, 3)])
    let accounts = AccountRepository(writer: stack.writer)

    let repair = try accounts.ensureMainAccount()

    #expect(repair == MainAccountRepair(mainId: busy.id, madeMain: false, cleared: 1))
    #expect(try mains(stack) == [busy.id])
    // Put right once, it stays right: the next open changes nothing.
    #expect(try accounts.ensureMainAccount() == nil)
  }

  @Test func noMainAccountMakesTheMostUsedLiveOneMain() throws {
    let archived = PaymentMethod(name: "Old", isDefault: true, archived: true)
    let card = PaymentMethod(name: "Card")
    let cash = PaymentMethod(name: "Cash")
    let stack = try stack([(archived, 9), (card, 1), (cash, 2)])

    let repair = try AccountRepository(writer: stack.writer).ensureMainAccount()

    #expect(repair == MainAccountRepair(mainId: cash.id, madeMain: true, cleared: 1))
    #expect(try mains(stack) == [cash.id])
  }

  /// No live account: nothing to choose, and nothing is made — the setup of the accounts makes
  /// the first one.
  @Test func withoutALiveAccountNothingIsWritten() throws {
    let archived = PaymentMethod(name: "Old", isDefault: true, archived: true)
    let stack = try stack([(archived, 1)])

    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil)
    #expect(try mains(stack) == [archived.id])
    #expect(try ReferenceRepository(writer: stack.writer).paymentMethods().isEmpty)
  }

  /// No account is main, and the busiest one sits in a group kept out of the summary: the main
  /// account is chosen among those whose money counts in «Всего».
  @Test func theMainAccountIsNeverChosenOutOfTheSummary() throws {
    let kazakhstan = AccountGroup(name: "Kazakhstan", inSummary: false)
    let russia = AccountGroup(name: "Russia")
    let kaspi = PaymentMethod(name: "Kaspi", groupId: kazakhstan.id)
    let sber = PaymentMethod(name: "Sber")
    let tinkoff = PaymentMethod(name: "Tinkoff", groupId: russia.id)
    let stack = try stack([(kaspi, 5), (sber, 1), (tinkoff, 2)], groups: [kazakhstan, russia])

    let repair = try AccountRepository(writer: stack.writer).ensureMainAccount()

    #expect(repair == MainAccountRepair(mainId: tinkoff.id, madeMain: true, cleared: 0))
    #expect(try mains(stack) == [tinkoff.id])
  }

  /// A main account left in a group out of the summary hands the flag to an account in it.
  @Test func aMainAccountOutOfTheSummaryHandsTheFlagOn() throws {
    let kazakhstan = AccountGroup(name: "Kazakhstan", inSummary: false)
    let kaspi = PaymentMethod(name: "Kaspi", isDefault: true, groupId: kazakhstan.id)
    let sber = PaymentMethod(name: "Sber")
    let stack = try stack([(kaspi, 5), (sber, 1)], groups: [kazakhstan])
    let accounts = AccountRepository(writer: stack.writer)

    #expect(
      try accounts.ensureMainAccount()
        == MainAccountRepair(mainId: sber.id, madeMain: true, cleared: 1))
    #expect(try mains(stack) == [sber.id])
    #expect(try accounts.ensureMainAccount() == nil)
  }

  /// With every live account out of the summary there is no better place: the flag stays.
  @Test func withEveryAccountOutOfTheSummaryTheFlagStays() throws {
    let kazakhstan = AccountGroup(name: "Kazakhstan", inSummary: false)
    let kaspi = PaymentMethod(name: "Kaspi", isDefault: true, groupId: kazakhstan.id)
    let halyk = PaymentMethod(name: "Halyk", groupId: kazakhstan.id)
    let stack = try stack([(kaspi, 1), (halyk, 5)], groups: [kazakhstan])

    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil)
    #expect(try mains(stack) == [kaspi.id])
  }

  @Test func aSoundBookIsLeftAlone() throws {
    let main = PaymentMethod(name: "Main", isDefault: true)
    let stack = try stack([(main, 0), (PaymentMethod(name: "Other"), 5)])

    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil)
    #expect(try mains(stack) == [main.id])
  }
}
