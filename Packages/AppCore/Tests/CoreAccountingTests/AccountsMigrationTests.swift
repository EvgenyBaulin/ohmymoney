import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The accounts of an older database get exactly one live main account, and the operations
/// without an account get one — decided here, written by the storage.
@Suite("The main account of an older database")
struct AccountsMigrationTests {
  private func account(
    _ number: Int, main: Bool = false, archived: Bool = false, rowid: Int64? = nil,
    inSummary: Bool = true
  ) -> MigratingAccount {
    MigratingAccount(
      id: id(number), name: "Account \(number)", archived: archived, isDefault: main,
      rowid: rowid ?? Int64(number), inSummary: inSummary)
  }

  private func plan(
    _ accounts: [MigratingAccount], live: [UUID: Int] = [:], unassigned: Int = 0,
    operations: Int? = nil
  ) -> AccountsMigrationPlan {
    AccountsMigration.plan(
      accounts: accounts, liveOperations: live, unassigned: unassigned,
      operations: operations ?? (live.values.reduce(0, +) + unassigned),
      mainAccountName: "Main account", makeId: { id(99) })
  }

  // MARK: Rule 1: one live main account

  @Test func theOneLiveMainAccountStaysMain() {
    let result = plan([account(1), account(2, main: true)], live: [id(1): 40, id(2): 3])
    #expect(result.mainId == id(2))
    #expect(result.created == nil)
    #expect(result.clearDefault.isEmpty)
    #expect(result.assignUnassignedTo == nil)
  }

  /// An archived account flagged main is not main: the flag goes, and the live one keeps it.
  @Test func anArchivedMainAccountLosesTheFlagToTheLiveOne() {
    let result = plan(
      [account(1, main: true, archived: true), account(2, main: true)], live: [id(1): 90])
    #expect(result.mainId == id(2))
    #expect(result.clearDefault == [id(1)])
  }

  // MARK: Rule 2: several live main accounts

  @Test func ofSeveralMainAccountsTheMostUsedStays() {
    let result = plan(
      [account(1, main: true), account(2, main: true), account(3, main: true, archived: true)],
      live: [id(1): 5, id(2): 12, id(3): 100])
    #expect(result.mainId == id(2))
    #expect(result.clearDefault == [id(1), id(3)])
    #expect(result.created == nil)
  }

  /// Used equally, the one written first stays main: the order of the rows decides, not the
  /// order the list was read in.
  @Test func aTieGoesToTheAccountWrittenFirst() {
    let result = plan(
      [account(1, main: true, rowid: 7), account(2, main: true, rowid: 3)],
      live: [id(1): 4, id(2): 4])
    #expect(result.mainId == id(2))
    #expect(result.clearDefault == [id(1)])
  }

  // MARK: Rule 3: no main account, every operation has an account

  @Test func withoutAMainAccountTheMostUsedLiveOneBecomesMain() {
    let result = plan(
      [account(1), account(2), account(3, archived: true)],
      live: [id(1): 2, id(2): 30, id(3): 99])
    #expect(result.mainId == id(2))
    #expect(result.created == nil)
    #expect(result.clearDefault.isEmpty)
    #expect(result.assignUnassignedTo == nil)
  }

  @Test func unusedAccountsGiveTheFlagToTheOneWrittenFirst() {
    let result = plan([account(1, rowid: 9), account(2, rowid: 4)], operations: 0)
    #expect(result.mainId == id(2))
  }

  // MARK: Rule 4: a main account is made

  /// With no main account, operations without one go to an account of their own — never
  /// mixed into a card by guess — and every other account keeps what it had.
  @Test func operationsWithoutAnAccountGetANewMainAccount() {
    let result = plan([account(1), account(2)], live: [id(1): 10, id(2): 20], unassigned: 4)
    let created = result.created
    #expect(created?.id == id(99))
    #expect(created?.name == "Main account")
    #expect(created?.kind == .account)
    #expect(created?.currency == .rub)
    #expect(created?.isDefault == true)
    #expect(created?.archived == false)
    #expect(result.mainId == id(99))
    #expect(result.assignUnassignedTo == id(99))
    #expect(result.clearDefault.isEmpty)
  }

  /// An archived main account cannot stay main, and there is no live account to take over.
  @Test func onlyArchivedAccountsGetANewMainAccount() {
    let result = plan([account(1, main: true, archived: true)], live: [id(1): 3])
    #expect(result.mainId == id(99))
    #expect(result.created?.name == "Main account")
    #expect(result.clearDefault == [id(1)])
    #expect(result.assignUnassignedTo == nil)
  }

  @Test func operationsWithNoAccountAtAllGetANewMainAccount() {
    let result = plan([], unassigned: 6)
    #expect(result.mainId == id(99))
    #expect(result.created != nil)
    #expect(result.assignUnassignedTo == id(99))
  }

  /// A live main account takes the operations without an account: nothing new is made.
  @Test func aMainAccountTakesTheOperationsWithoutOne() {
    let result = plan([account(1, main: true), account(2)], live: [id(2): 8], unassigned: 3)
    #expect(result.mainId == id(1))
    #expect(result.created == nil)
    #expect(result.assignUnassignedTo == id(1))
  }

  // MARK: Rule 5: nothing to do

  @Test func anEmptyDatabaseGetsNoAccount() {
    let result = plan([], operations: 0)
    #expect(result == AccountsMigrationPlan())
  }

  @Test func theIdIsAskedForOnlyWhenAnAccountIsMade() {
    var asked = 0
    let makeId = {
      asked += 1
      return id(99)
    }
    _ = AccountsMigration.plan(
      accounts: [account(1, main: true)], liveOperations: [:], unassigned: 2, operations: 2,
      mainAccountName: "Main account", makeId: makeId)
    #expect(asked == 0)
  }

  // MARK: Repair on open

  @Test func aSoundBookNeedsNoRepair() {
    let sound = [account(1, main: true), account(2)]
    #expect(AccountsMigration.repair(accounts: sound, liveOperations: [id(1): 3]) == nil)
    #expect(AccountsMigration.repair(accounts: [], liveOperations: [:]) == nil)
  }

  @Test func twoMainAccountsAreRepairedToTheMostUsed() {
    let repair = AccountsMigration.repair(
      accounts: [account(1, main: true), account(2, main: true), account(3)],
      liveOperations: [id(1): 1, id(2): 5])
    #expect(repair?.mainId == id(2))
    #expect(repair?.clear == [id(1)])
  }

  @Test func anArchivedMainAccountIsRepairedAway() {
    let repair = AccountsMigration.repair(
      accounts: [account(1, main: true), account(2, main: true, archived: true)],
      liveOperations: [:])
    #expect(repair?.mainId == id(1))
    #expect(repair?.clear == [id(2)])
  }

  @Test func noMainAccountIsRepairedToTheMostUsedLiveOne() {
    let repair = AccountsMigration.repair(
      accounts: [account(1), account(2), account(3, main: true, archived: true)],
      liveOperations: [id(1): 3, id(3): 50])
    #expect(repair?.mainId == id(1))
    #expect(repair?.clear == [id(3)])
  }

  /// No live account: nothing is made on open — the setup of the accounts makes the first one.
  @Test func withoutALiveAccountTheRepairMakesNothing() {
    #expect(
      AccountsMigration.repair(
        accounts: [account(1, main: true, archived: true)], liveOperations: [id(1): 2]) == nil)
  }

  // MARK: Repair: the money of the main account counts in the summary

  /// No account is main, and the busiest one sits in a group kept out of the summary: the main
  /// account is the busiest of those whose money counts in «Всего».
  @Test func theRepairChoosesAnAccountInTheSummary() {
    let repair = AccountsMigration.repair(
      accounts: [account(1, inSummary: false), account(2), account(3)],
      liveOperations: [id(1): 300, id(2): 100, id(3): 20])
    #expect(repair?.mainId == id(2))
    #expect(repair?.clear == [])
  }

  /// A main account left in a group out of the summary hands the flag to the busiest account in
  /// the summary.
  @Test func aMainAccountOutOfTheSummaryHandsTheFlagOn() {
    let repair = AccountsMigration.repair(
      accounts: [account(1, main: true, inSummary: false), account(2), account(3)],
      liveOperations: [id(1): 300, id(2): 1, id(3): 7])
    #expect(repair?.mainId == id(3))
    #expect(repair?.clear == [id(1)])
  }

  /// Of two accounts flagged main, the one in the summary stays, however busy the other is.
  @Test func ofTwoMainAccountsTheOneInTheSummaryStays() {
    let repair = AccountsMigration.repair(
      accounts: [account(1, main: true, inSummary: false), account(2, main: true)],
      liveOperations: [id(1): 300, id(2): 1])
    #expect(repair?.mainId == id(2))
    #expect(repair?.clear == [id(1)])
  }

  /// Every live account is out of the summary: none is better placed, so the flag stays where
  /// it is, and with no flag the old rule chooses.
  @Test func withEveryAccountOutOfTheSummaryTheOldRuleHolds() {
    #expect(
      AccountsMigration.repair(
        accounts: [account(1, main: true, inSummary: false), account(2, inSummary: false)],
        liveOperations: [id(2): 50]) == nil)
    let repair = AccountsMigration.repair(
      accounts: [account(1, inSummary: false), account(2, inSummary: false)],
      liveOperations: [id(2): 50])
    #expect(repair?.mainId == id(2))
  }

  /// An archived account in the summary is no candidate: the live one out of it keeps the flag.
  @Test func anArchivedAccountInTheSummaryDoesNotTakeTheFlag() {
    #expect(
      AccountsMigration.repair(
        accounts: [account(1, main: true, inSummary: false), account(2, archived: true)],
        liveOperations: [id(2): 50]) == nil)
  }
}
