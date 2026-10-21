import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A later count's difference follows the books; the first count is the truth.
@Suite("Live counts")
struct LiveCountsTests {
  let reconcile = ReconcileCategories(expense: id(900), income: id(901))
  let groceries = id(110)
  let salary = id(119)
  let kzt = CurrencyCode("KZT")

  var card: PaymentMethod {
    PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  }
  var kaspi: PaymentMethod { PaymentMethod(id: id(3), name: "Kaspi", currency: kzt) }
  var cardKey: BalanceKey { BalanceKey(accountId: id(1), currency: .rub) }
  var kaspiKey: BalanceKey { BalanceKey(accountId: id(3), currency: kzt) }

  func at(_ iso: String, hour: Int = 12) -> Date {
    moment(iso).addingTimeInterval(TimeInterval(hour * 3600))
  }

  func book() -> CountBook {
    CountBook(accounts: [card, kaspi], tree: liveCountsTree, categories: reconcile)
  }

  func operation(
    _ number: Int, _ amount: Int, _ kind: TransactionKind = .expense, on iso: String,
    hour: Int = 12, key: BalanceKey? = nil, note: String? = nil
  ) -> TransactionEntry {
    let key = key ?? cardKey
    let transaction = Transaction(
      id: id(number), kind: kind, occurredAt: at(iso, hour: hour), currency: key.currency,
      amountE4: money(amount), note: note, paymentMethodId: key.accountId)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          id: id(number * 10 + 7), transactionId: id(number),
          categoryId: kind == .expense ? groceries : salary, amountE4: money(amount))
      ])
  }

  /// «Т-Банк»: first counted 01.09 09:00 at 50,000; +100,000 on 03.09 and −12,000 on 05.09
  /// recorded on time; counted 130,000 on 20.09 10:00 with «Записать разницу».
  func theOwnersSeptember(records: Bool = true) -> (CountBook, UUID) {
    var book = book()
    book.addCount(10, at: at("2026-09-01", hour: 9), [(cardKey, money(50_000))])
    book.entries += [
      operation(1, 100_000, .income, on: "2026-09-03"), operation(2, 12_000, on: "2026-09-05"),
    ]
    let later = book.addCount(
      11, at: at("2026-09-20", hour: 10), records: records, [(cardKey, money(130_000))])
    return (book, later[0])
  }

  // MARK: The first count is the truth

  @Test func aFirstCountIsNeverCompared() {
    var book = book()
    let first = book.addCount(10, at: at("2026-09-26", hour: 12), [(cardKey, money(50_000))])
    book.entries += [
      operation(1, 100_000, .income, on: "2026-09-05"), operation(2, 60_000, on: "2026-09-10"),
      operation(3, 4_000, on: "2026-09-20"),
    ]
    book.settle()
    #expect(book.count(first[0])?.expectedE4 == nil)
    #expect(book.engine().expected(forCount: first[0]) == nil)
    #expect(!book.liveIds.contains(first[0]))
    #expect(book.engine()[cardKey]?.amountE4 == money(50_000))
    #expect(book.entries.allSatisfy { $0.transaction.externalId == nil })
  }

  // MARK: A later count follows the books

  @Test func theCountRecordsItsDifferenceOnce() throws {
    let (book, later) = theOwnersSeptember()
    let count = try #require(book.count(later))
    #expect(count.expectedE4 == money(138_000))
    #expect(count.differenceE4 == money(-8_000))
    let difference = try #require(book.operation(ofCount: later))
    #expect(difference.id == ReconcileDifferenceIds.operation(forCount: later))
    #expect(difference.parts.map(\.id) == [ReconcileDifferenceIds.part(forCount: later)])
    #expect(difference.transaction.kind == .expense)
    #expect(difference.transaction.amountE4 == money(8_000))
    #expect(difference.parts[0].categoryId == reconcile.expense)
    #expect(count.transactionId == difference.id)
  }

  @Test func aBackdatedExpenseGrowsTheMissingDifference() throws {
    var (book, later) = theOwnersSeptember()
    book.entries.append(operation(3, 3_000, on: "2026-09-10"))
    book.settle()
    let count = try #require(book.count(later))
    #expect(count.expectedE4 == money(135_000))
    #expect(count.differenceE4 == money(-5_000))
    let difference = try #require(book.operation(ofCount: later))
    #expect(difference.id == ReconcileDifferenceIds.operation(forCount: later))
    #expect(difference.transaction.amountE4 == money(5_000))
    #expect(difference.transaction.amountRubE4 == money(5_000))
    #expect(difference.parts[0].amountE4 == money(5_000))
  }

  @Test func atZeroTheOperationIsPurged() throws {
    var (book, later) = theOwnersSeptember()
    book.entries += [operation(3, 3_000, on: "2026-09-10"), operation(4, 5_000, on: "2026-09-12")]
    let results = book.settle()
    #expect(
      results.contains { $0.operation == .purge(ReconcileDifferenceIds.operation(forCount: later)) }
    )
    let count = try #require(book.count(later))
    #expect(count.differenceE4 == .zero)
    #expect(count.transactionId == nil)
    #expect(count.recordsDifference == true)
    #expect(book.operation(ofCount: later) == nil)
  }

  @Test func aSignChangeWritesTheIncomeTwin() throws {
    var (book, later) = theOwnersSeptember()
    book.entries += [
      operation(3, 3_000, on: "2026-09-10"), operation(4, 5_000, on: "2026-09-12"),
      operation(5, 1_500, on: "2026-09-15"),
    ]
    book.settle()
    let found = try #require(book.operation(ofCount: later))
    #expect(found.transaction.kind == .income)
    #expect(found.transaction.amountE4 == money(1_500))
    #expect(found.parts[0].categoryId == reconcile.income)
    #expect(found.parts[0].quality == nil)
    #expect(book.count(later)?.differenceE4 == money(1_500))
  }

  @Test func aSignChangeOfALiveOperationSwitchesItInPlace() throws {
    var (book, later) = theOwnersSeptember()
    book.entries.append(operation(3, 9_500, .income, on: "2026-09-10"))
    book.settle()
    let switched = try #require(book.operation(ofCount: later))
    #expect(switched.id == ReconcileDifferenceIds.operation(forCount: later))
    #expect(switched.parts[0].id == ReconcileDifferenceIds.part(forCount: later))
    #expect(switched.transaction.kind == .expense)
    #expect(switched.transaction.amountE4 == money(17_500))
    book.entries.append(operation(4, 20_000, on: "2026-09-11"))
    book.settle()
    let income = try #require(book.operation(ofCount: later))
    #expect(income.id == switched.id)
    #expect(income.transaction.kind == .income)
    #expect(income.transaction.amountE4 == money(2_500))
    #expect(income.parts[0].categoryId == reconcile.income)
    #expect(income.parts[0].quality == nil)
    #expect(income.parts[0].qualitySource == nil)
  }

  @Test func aRewriteKeepsTheOwnersCategoryNoteAndPartId() throws {
    var (book, later) = theOwnersSeptember()
    let index = try #require(
      book.entries.firstIndex { $0.id == ReconcileDifferenceIds.operation(forCount: later) })
    book.entries[index].transaction.note = "cash I lost"
    book.entries[index].parts[0].categoryId = groceries
    book.entries[index].parts[0].quality = .bad
    book.entries[index].parts[0].qualitySource = .manual
    let owners = book.entries[index]
    book.entries.append(operation(3, 3_000, on: "2026-09-10"))
    book.settle(now: at("2026-09-22"))
    let rewritten = try #require(book.operation(ofCount: later))
    #expect(rewritten.transaction.amountE4 == money(5_000))
    #expect(rewritten.transaction.note == "cash I lost")
    #expect(rewritten.parts[0].id == owners.parts[0].id)
    #expect(rewritten.parts[0].categoryId == groceries)
    #expect(rewritten.parts[0].quality == .bad)
    #expect(rewritten.parts[0].qualitySource == .manual)
    #expect(rewritten.transaction.updatedAt == at("2026-09-22"))
    #expect(rewritten.transaction.createdAt == owners.transaction.createdAt)
  }

  /// ⌘Z of a write that purged a difference at zero hands its operation as it was: the new one
  /// is that operation — its ids, the owner's category, comment and rating, the moment it was
  /// made —, as it was when the difference is the same, resized or turned over otherwise. One
  /// in the bin is no template: the derived operation is written.
  @Test func aPurgedDifferenceComesBackFromItsTemplate() throws {
    let (book, later) = theOwnersSeptember()
    var owners = try #require(book.operation(ofCount: later))
    owners.transaction.note = "for mum"
    owners.transaction.updatedAt = at("2026-09-21")
    owners.parts[0].categoryId = groceries
    owners.parts[0].quality = .bad
    owners.parts[0].qualitySource = .manual
    var count = try #require(book.count(later))
    count.transactionId = nil
    count.differenceE4 = .zero
    count.expectedE4 = money(130_000)
    let state = CountState(count: count, countAt: at("2026-09-20", hour: 10))
    let now = at("2026-09-23")
    func settled(_ expected: Int, template: TransactionEntry?) -> CountSettlement {
      LiveCounts.settle(
        state, expected: money(expected), rate: nil, categories: reconcile, tree: liveCountsTree,
        now: now, template: template)
    }

    let same = settled(138_000, template: owners)
    #expect(same.operation == .create(owners))
    #expect(same.count.transactionId == owners.id)
    #expect(same.count.differenceE4 == money(-8_000))

    guard case .create(let resized) = settled(135_000, template: owners).operation else {
      Issue.record("no operation for a smaller difference")
      return
    }
    #expect(resized.id == owners.id)
    #expect(resized.parts.map(\.id) == owners.parts.map(\.id))
    #expect(resized.transaction.amountE4 == money(5_000))
    #expect(resized.transaction.note == "for mum")
    #expect(resized.parts[0].categoryId == groceries)
    #expect(resized.parts[0].quality == .bad)
    #expect(resized.transaction.createdAt == owners.transaction.createdAt)
    #expect(resized.transaction.updatedAt == now)

    guard case .create(let income) = settled(125_000, template: owners).operation else {
      Issue.record("no operation for a difference of the other sign")
      return
    }
    #expect(income.id == owners.id)
    #expect(income.transaction.kind == .income)
    #expect(income.transaction.amountE4 == money(5_000))
    #expect(income.transaction.note == "for mum")
    #expect(income.parts[0].categoryId == reconcile.income)
    #expect(income.parts[0].quality == nil)

    var binned = owners
    binned.transaction.deletedAt = at("2026-09-21")
    guard case .create(let derived) = settled(138_000, template: binned).operation else {
      Issue.record("no operation next to a template in the bin")
      return
    }
    #expect(derived.id == ReconcileDifferenceIds.operation(forCount: later))
    #expect(derived.transaction.note == nil)
    #expect(derived.parts[0].categoryId == reconcile.expense)
  }

  /// A foreign difference brought back from its template keeps the template's own rate, so it
  /// never waits for the bank's.
  @Test func aForeignTemplateNeedsNoRate() throws {
    var book = book()
    book.rates = [kzt: Decimal(string: "0.19")!]
    book.addCount(10, at: at("2026-09-01", hour: 9), [(kaspiKey, money(200_000))])
    let later = book.addCount(11, at: at("2026-09-20", hour: 10), [(kaspiKey, money(198_000))])
    let template = try #require(book.operation(ofCount: later[0]))
    var count = try #require(book.count(later[0]))
    count.transactionId = nil
    let result = LiveCounts.settle(
      CountState(count: count, countAt: at("2026-09-20", hour: 10)), expected: money(200_000),
      rate: nil, categories: nil, tree: liveCountsTree, now: at("2026-09-23"), template: template)
    #expect(!result.waitsForRate)
    #expect(!result.needsCategories)
    #expect(result.operation == .create(template))
    #expect(template.transaction.amountRubE4 == money(380))
  }

  @Test func anUnchangedDifferenceWritesNothing() {
    var (book, _) = theOwnersSeptember()
    let before = book
    let results = book.settle()
    #expect(results.allSatisfy { !$0.countChanged && $0.operation == .none })
    #expect(book.entries == before.entries)
  }

  @Test func keepModeFollowsTheNumbersOnly() throws {
    var (book, later) = theOwnersSeptember(records: false)
    #expect(book.operation(ofCount: later) == nil)
    #expect(book.count(later)?.differenceE4 == money(-8_000))
    book.entries.append(operation(3, 8_000, on: "2026-09-12"))
    book.settle()
    let count = try #require(book.count(later))
    #expect(count.differenceE4 == .zero)
    #expect(count.recordsDifference == false)
    book.entries.append(operation(4, 1_000, on: "2026-09-13"))
    book.settle()
    #expect(book.count(later)?.differenceE4 == money(1_000))
    #expect(book.operation(ofCount: later) == nil)
  }

  @Test func anOperationTheOwnerDeletedSwitchesToKeep() throws {
    var (book, later) = theOwnersSeptember()
    let index = try #require(
      book.entries.firstIndex { $0.id == ReconcileDifferenceIds.operation(forCount: later) })
    book.entries[index].transaction.deletedAt = at("2026-09-21")
    let results = book.settle()
    let count = try #require(book.count(later))
    #expect(count.recordsDifference == false)
    #expect(count.transactionId == nil)
    #expect(count.differenceE4 == money(-8_000))
    #expect(results.contains { $0.modeChanged })
    #expect(book.operation(ofCount: later)?.transaction.isDeleted == true)
  }

  @Test func aRestoredOperationSwitchesBackToRecord() throws {
    var (book, later) = theOwnersSeptember()
    let index = try #require(
      book.entries.firstIndex { $0.id == ReconcileDifferenceIds.operation(forCount: later) })
    book.entries[index].transaction.deletedAt = at("2026-09-21")
    book.settle()
    book.entries[index].transaction.deletedAt = nil
    book.settle()
    let count = try #require(book.count(later))
    #expect(count.recordsDifference == true)
    #expect(count.transactionId == book.entries[index].id)
  }

  /// «Записывать разницу» of the history: the owner asks a count kept without an operation to
  /// record again, by its mode alone with no operation linked. The operation in the bin does
  /// not turn it back: a new one is written over it, with the count's own ids.
  @Test func askingToRecordAgainWritesTheDifferenceOverTheBin() throws {
    var (book, later) = theOwnersSeptember()
    let index = try #require(
      book.entries.firstIndex { $0.id == ReconcileDifferenceIds.operation(forCount: later) })
    book.entries[index].transaction.deletedAt = at("2026-09-21")
    book.settle()
    #expect(book.count(later)?.recordsDifference == false)

    let countIndex = try #require(book.balances.firstIndex { $0.id == later })
    book.balances[countIndex].recordsDifference = true
    book.balances[countIndex].transactionId = nil
    book.settle()
    let count = try #require(book.count(later))
    #expect(count.recordsDifference == true)
    let operation = try #require(book.operation(ofCount: later))
    #expect(operation.transaction.isDeleted == false)
    #expect(operation.transaction.amountE4 == money(8_000))
    #expect(count.transactionId == operation.id)
    #expect(book.entries.filter { $0.id == operation.id }.count == 1)
  }

  @Test func aForeignDifferenceKeepsItsOwnRate() throws {
    var book = book()
    book.rates = [kzt: Decimal(string: "0.19")!]
    book.addCount(10, at: at("2026-09-01", hour: 9), [(kaspiKey, money(200_000))])
    book.entries.append(operation(1, 50_000, on: "2026-09-05", key: kaspiKey))
    let later = book.addCount(11, at: at("2026-09-20", hour: 10), [(kaspiKey, money(148_000))])
    let created = try #require(book.operation(ofCount: later[0]))
    #expect(created.transaction.amountE4 == money(2_000))
    #expect(created.transaction.amountRubE4 == money(380))
    #expect(created.transaction.rate == Decimal(string: "0.19"))
    // The bank's rate moves; the operation keeps its own.
    book.rates = [kzt: Decimal(string: "0.25")!]
    book.entries.append(operation(2, 1_200, on: "2026-09-12", key: kaspiKey))
    book.settle()
    let rewritten = try #require(book.operation(ofCount: later[0]))
    #expect(rewritten.transaction.amountE4 == money(800))
    #expect(rewritten.transaction.amountRubE4 == money(152))
    #expect(rewritten.parts[0].amountRubE4 == money(152))
  }

  @Test func aNewForeignDifferenceWithoutARateWaits() throws {
    var book = book()
    book.addCount(10, at: at("2026-09-01", hour: 9), [(kaspiKey, money(200_000))])
    let later = book.addCount(11, at: at("2026-09-20", hour: 10), [(kaspiKey, money(198_000))])
    let count = try #require(book.count(later[0]))
    #expect(count.differenceE4 == money(-2_000))
    #expect(count.transactionId == nil)
    #expect(book.operation(ofCount: later[0]) == nil)
    let state = CountState(count: count, countAt: at("2026-09-20", hour: 10))
    let waiting = LiveCounts.settle(
      state, expected: money(200_000), rate: nil, categories: reconcile, tree: liveCountsTree,
      now: .now)
    #expect(waiting.waitsForRate)
    book.rates = [kzt: Decimal(string: "0.19")!]
    book.settle()
    #expect(book.operation(ofCount: later[0])?.transaction.amountRubE4 == money(380))
  }

  @Test func aNewDifferenceAsksForTheCategories() throws {
    let (book, later) = theOwnersSeptember(records: false)
    var count = try #require(book.count(later))
    count.recordsDifference = true
    let result = LiveCounts.settle(
      CountState(count: count, countAt: at("2026-09-20", hour: 10)), expected: money(138_000),
      rate: nil, categories: nil, tree: liveCountsTree, now: .now)
    #expect(result.needsCategories)
    #expect(result.operation == .none)
    #expect(result.count.transactionId == nil)
  }

  // MARK: Which counts follow

  @Test func countsBeforeALaterOpeningAreFrozen() throws {
    var (book, later) = theOwnersSeptember()
    book.addCount(
      12, at: at("2026-09-25", hour: 9), kind: .opening, origin: .merge, [(cardKey, money(1_000))])
    #expect(!book.liveIds.contains(later))
    book.entries.append(operation(3, 3_000, on: "2026-09-10"))
    book.settle()
    #expect(book.count(later)?.differenceE4 == money(-8_000))
    #expect(book.operation(ofCount: later)?.transaction.amountE4 == money(8_000))
  }

  @Test func openingsAndTotalsAreNeverLive() {
    var book = book()
    let opening = book.addCount(
      10, at: at("2026-09-01", hour: 9), kind: .opening, origin: .setup,
      [(cardKey, money(1_000))])
    book.reconciliations.append(
      Reconciliation(
        id: id(20), date: day("2026-09-02"), reconciledAt: at("2026-09-02"),
        actualTotalRubE4: money(5_000), expectedTotalRubE4: money(4_000),
        differenceE4: money(1_000), kind: .total))
    let live = book.liveIds
    #expect(!live.contains(opening[0]))
    #expect(live.isEmpty)
  }

  @Test func aFirstCountCandidateIsFrozenUntilKept() throws {
    var book = book()
    // A zero opening of the time before 1.2: an empty field of the setup.
    book.addCount(
      10, at: at("2026-09-20", hour: 9), kind: .opening, [(cardKey, .zero)])
    let candidate = book.addCount(11, at: at("2026-09-26", hour: 12), [(cardKey, money(120_000))])
    #expect(book.count(candidate[0])?.differenceE4 == money(120_000))
    #expect(!book.liveIds.contains(candidate[0]))
    let frozen = book.count(candidate[0])
    book.entries += [
      operation(1, 100_000, .income, on: "2026-09-25"), operation(2, 4_000, on: "2026-09-22"),
    ]
    book.settle()
    #expect(book.count(candidate[0]) == frozen)
    book.kept = [candidate[0]]
    book.settle()
    #expect(book.count(candidate[0])?.expectedE4 == money(96_000))
    #expect(book.count(candidate[0])?.differenceE4 == money(24_000))
  }

  @Test func aTypedZeroOfOneTwoIsACount() {
    var book = book()
    book.addCount(
      10, at: at("2026-09-20", hour: 9), kind: .opening, origin: .setup, [(cardKey, .zero)])
    let later = book.addCount(11, at: at("2026-09-26", hour: 12), [(cardKey, money(500))])
    #expect(book.liveIds.contains(later[0]))
    #expect(book.operation(ofCount: later[0])?.transaction.amountE4 == money(500))
  }

  // MARK: What moves inside a window

  @Test func aLinkedRefundMovesAtItsOwnMoment() throws {
    var (book, later) = theOwnersSeptember()
    book.entries.append(operation(3, 10_000, on: "2026-09-10"))
    book.settle()
    #expect(book.count(later)?.differenceE4 == money(2_000))
    var refund = operation(4, 4_000, .refund, on: "2026-09-22")
    refund.parts[0].refundOfPartId = id(37)
    book.entries.append(refund)
    book.settle()
    // After the count: the balance rises, the count stays.
    #expect(book.count(later)?.differenceE4 == money(2_000))
    #expect(book.engine()[cardKey]?.amountE4 == money(134_000))
    let index = try #require(book.entries.firstIndex { $0.id == id(4) })
    book.entries[index].transaction.occurredAt = at("2026-09-18")
    book.settle()
    #expect(book.count(later)?.differenceE4 == money(-2_000))
  }

  @Test func aChargedLegMovesTheRubleWindow() throws {
    var (book, later) = theOwnersSeptember()
    var purchase = operation(3, 100, on: "2026-09-12")
    purchase.transaction.currency = .usd
    purchase.transaction.accountCurrency = .rub
    purchase.transaction.accountAmountE4 = money(9_200)
    book.entries.append(purchase)
    book.settle()
    #expect(book.count(later)?.differenceE4 == money(1_200))
    let index = try #require(book.entries.firstIndex { $0.id == id(3) })
    book.entries[index].transaction.accountAmountE4 = money(9_235)
    book.settle()
    #expect(book.count(later)?.differenceE4 == money(1_235))
    #expect(book.operation(ofCount: later)?.transaction.amountE4 == money(1_235))
  }

  @Test func anEditMovingTheDaySettlesBothCounts() throws {
    var book = book()
    book.addCount(10, at: at("2026-09-01", hour: 9), [(cardKey, money(110_000))])
    book.entries += [operation(1, 2_000, on: "2026-09-05"), operation(2, 8_000, on: "2026-09-25")]
    let first = book.addCount(11, at: at("2026-09-20", hour: 10), [(cardKey, money(108_000))])
    let second = book.addCount(12, at: at("2026-09-30", hour: 10), [(cardKey, money(100_000))])
    #expect(book.count(first[0])?.differenceE4 == .zero)
    #expect(book.count(second[0])?.differenceE4 == .zero)
    let index = try #require(book.entries.firstIndex { $0.id == id(1) })
    book.entries[index].transaction.occurredAt = at("2026-09-25")
    book.settle()
    #expect(book.count(first[0])?.differenceE4 == money(-2_000))
    #expect(book.count(second[0])?.differenceE4 == money(2_000))
    #expect(book.operation(ofCount: first[0])?.transaction.kind == .expense)
    #expect(book.operation(ofCount: second[0])?.transaction.kind == .income)
  }
}
