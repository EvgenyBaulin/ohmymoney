import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Getting the money back from a person")
struct ReimbursementResolverTests {
  let categories = StartingCategories()
  let debtor = id(50)

  /// Two parts paid for the same person: 250 in February, 400 in March.
  func owedParts() -> [OwedPart] {
    let february = entry(
      id(2), on: "2026-02-02",
      parts: [
        part(
          id(21), amount: money(250), category: categories.health, reimbursable: true,
          debtor: debtor)
      ])
    let march = entry(
      id(1), on: "2026-03-10",
      parts: [
        part(
          id(11), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: debtor)
      ])
    return MyExpensesRule.owedToMe(entries: [march, february])
  }

  func sequentialIds() -> () -> UUID {
    var next = 900
    return {
      next += 1
      return id(next)
    }
  }

  @Test func theMoneyIsSpreadOldestFirst() {
    let allocations = ReimbursementResolver.allocate(amountE4: money(300), over: owedParts())
    #expect(allocations.map(\.partId) == [id(21), id(11)])
    #expect(allocations.map(\.amountE4) == [money(250), money(50)])
  }

  @Test func aReimbursementClosesTheSelectedParts() throws {
    let parts = owedParts()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(650), closing: parts,
      makeId: sequentialIds())

    #expect(outcome.closedPartIds == [id(21), id(11)])
    #expect(outcome.links.count == 2)
    #expect(outcome.links.map(\.partId) == [id(21), id(11)])
    #expect(outcome.links.allSatisfy { $0.reimbursementTxId == id(9) })
    #expect(outcome.links.map(\.id) == [id(901), id(902)])
    #expect(outcome.allocatedE4 == money(650))
    #expect(outcome.surplus == nil)
    #expect(outcome.shortfalls.isEmpty)
    #expect(outcome.receivedE4 == money(650))
  }

  @Test func moreMoneyThanIPaidIsIncomeInSurcharges() throws {
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(700), closing: owedParts())
    let surplus = try #require(outcome.surplus)
    #expect(surplus.amountE4 == money(50))
    #expect(surplus.systemRole == .surcharges)
    #expect(outcome.allocatedE4 == money(650))
    #expect(outcome.shortfalls.isEmpty)
    #expect(outcome.receivedE4 == money(700))
  }

  @Test func lessMoneyThanIPaidBecomesMyExpenseInTheCategoryOfThePart() throws {
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(600), closing: owedParts())

    #expect(outcome.closedPartIds.count == 2)
    #expect(outcome.surplus == nil)
    #expect(outcome.shortfalls.count == 1)
    let shortfall = try #require(outcome.shortfalls.first)
    #expect(shortfall.partId == id(11))
    #expect(shortfall.categoryId == categories.groceries)
    #expect(shortfall.amountE4 == money(50))
    #expect(outcome.shortfallTotalE4 == money(50))
  }

  @Test func aPartThatGotNothingIsStillClosedAndFullyMissing() throws {
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(250), closing: owedParts())
    #expect(outcome.closedPartIds == [id(21), id(11)])
    #expect(outcome.links.map(\.amountE4) == [money(250), .zero])
    #expect(outcome.shortfalls.map(\.amountE4) == [money(400)])
  }

  @Test func theShortfallIsSpendingOfMineOnceItIsRecorded() throws {
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(600), closing: owedParts())
    let shortfall = try #require(outcome.shortfalls.first)
    let recorded = entry(
      id(8), on: "2026-03-20",
      parts: [part(id(81), amount: shortfall.amountE4, category: shortfall.categoryId)])
    #expect(MyExpensesRule.total(entries: [recorded]) == money(50))
    #expect(
      MyExpensesRule.byCategory(entries: [recorded])[categories.groceries] == money(50))
  }

  @Test func theDistributionCanBeCorrectedByHand() throws {
    let parts = owedParts()
    let byHand = [
      ReimbursementAllocation(partId: id(11), amountE4: money(400)),
      ReimbursementAllocation(partId: id(21), amountE4: money(100)),
    ]
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(500), closing: parts, allocation: byHand)

    #expect(outcome.allocations.map(\.partId) == [id(21), id(11)])
    #expect(outcome.allocations.map(\.amountE4) == [money(100), money(400)])
    #expect(outcome.shortfalls.map(\.partId) == [id(21)])
    #expect(outcome.shortfalls.map(\.amountE4) == [money(150)])
    #expect(outcome.surplus == nil)
  }

  @Test func aHandMadeDistributionThatLeavesMoneyOverStillProducesASurplus() throws {
    let byHand = [ReimbursementAllocation(partId: id(21), amountE4: money(250))]
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(300), closing: owedParts(),
      allocation: byHand)
    #expect(outcome.surplusE4 == money(50))
    #expect(outcome.shortfalls.map(\.partId) == [id(11)])
  }

  @Test func aPartCannotBeGivenMoreThanIPaidForIt() {
    let byHand = [ReimbursementAllocation(partId: id(21), amountE4: money(300))]
    #expect(throws: ReimbursementError.allocationExceedsPart(id(21))) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(650), closing: owedParts(),
        allocation: byHand)
    }
  }

  @Test func theDistributionCannotBeLargerThanTheMoneyReturned() {
    let byHand = [
      ReimbursementAllocation(partId: id(21), amountE4: money(250)),
      ReimbursementAllocation(partId: id(11), amountE4: money(400)),
    ]
    #expect(throws: ReimbursementError.allocationExceedsAmount) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(500), closing: owedParts(),
        allocation: byHand)
    }
  }

  @Test func theDistributionCannotNameAPartThatWasNotSelected() {
    let byHand = [ReimbursementAllocation(partId: id(77), amountE4: money(10))]
    #expect(throws: ReimbursementError.unknownPart(id(77))) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(650), closing: owedParts(),
        allocation: byHand)
    }
  }

  @Test func negativeSharesAndAmountsAreRefused() {
    let byHand = [ReimbursementAllocation(partId: id(21), amountE4: money(-10))]
    #expect(throws: ReimbursementError.negativeAllocation(id(21))) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(650), closing: owedParts(),
        allocation: byHand)
    }
    #expect(throws: ReimbursementError.negativeAmount) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(-1), closing: owedParts())
    }
  }

  @Test func aReimbursementHasToCloseSomething() {
    #expect(throws: ReimbursementError.noPartsSelected) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(650), closing: [])
    }
  }

  @Test func theSamePartCannotBeSelectedTwice() {
    let twice = owedParts() + [owedParts()[0]]
    #expect(throws: ReimbursementError.duplicatePart(id(21))) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(650), closing: twice)
    }
  }

  @Test func aClosedPartIsNoLongerMySpendingAndLeavesTheOwedList() throws {
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(650), closing: owedParts())
    let closed = Set(outcome.closedPartIds)

    var march = entry(
      id(1), on: "2026-03-10",
      parts: [
        part(
          id(11), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: debtor)
      ])
    for index in march.parts.indices where closed.contains(march.parts[index].id) {
      march.parts[index].reimbursementStatus = .returned
    }
    #expect(MyExpensesRule.total(entries: [march]) == .zero)
    #expect(MyExpensesRule.owedToMe(entries: [march]).isEmpty)
  }

  /// 50 dollars paid for a friend, 4 750 rubles on the day. The friend pays back in
  /// rubles, so the part is owed in rubles: matched against 50 it would turn 4 700 of the
  /// money into a «surplus» that never existed.
  func dollarPart(provisional: Bool = false) -> OwedPart {
    var dinner = entry(
      id(3), on: "2026-03-12",
      parts: [
        part(
          id(31), amount: money(50), category: categories.groceries, reimbursable: true,
          debtor: debtor)
      ])
    dinner.transaction.currency = .usd
    dinner.transaction.rateProvisional = provisional
    dinner.transaction.amountRubE4 = money(4750)
    dinner.parts[0].amountRubE4 = money(4750)
    return MyExpensesRule.owedToMe(entries: [dinner])[0]
  }

  @Test func anOwedPartRemembersItsCurrencyAndWhetherItsRateIsFinal() {
    let owed = dollarPart(provisional: true)
    #expect(owed.currency == .usd)
    #expect(owed.amountE4 == money(50))
    #expect(owed.amountRubE4 == money(4750))
    #expect(owed.rateProvisional)
  }

  @Test func aForeignPartIsClosedInRubles() throws {
    let rubles = dollarPart().inRubles
    #expect(rubles.currency == .rub)
    #expect(rubles.amountE4 == money(4750))
    #expect(rubles.amountRubE4 == money(4750))

    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(4750), closing: [rubles])
    #expect(outcome.links.map(\.amountE4) == [money(4750)])
    #expect(outcome.surplus == nil)
    #expect(outcome.shortfalls.isEmpty)
  }

  /// The rubles a link fixes would drift away from the refined ones once the pipeline
  /// settles the rate, so such a part waits for ⌘R instead of being closed now.
  @Test func aPartWhoseRateIsStillProvisionalCannotBeClosed() {
    let waiting = dollarPart(provisional: true).inRubles
    #expect(throws: ReimbursementError.provisionalRate(id(31))) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(4750), closing: owedParts() + [waiting])
    }
  }
}
