import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A refund taken back from a purchase in the lists: the purchase says what came back, the
/// refund names its purchase, and every total — a side of a day in the table, a day of
/// Overview, the question before a deletion — counts the refund in the purchase, on its day,
/// the way Overview and the analytics do.
@MainActor
final class RefundRowsTests: XCTestCase {
  private let tree = CategoryTree()
  private let purchaseDay = DateOnly(year: 2026, month: 9, day: 1)
  private let refundDay = DateOnly(year: 2026, month: 9, day: 5)

  private func moment(_ day: DateOnly, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600))
  }

  /// Sneakers for 3 000 ₽ on the 1st.
  private func sneakers() throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment(purchaseDay), amount: AmountE4(whole: 3_000), note: "Sneakers")
    draft.normalizeSinglePart()
    return try draft.materialize(now: moment(purchaseDay))
  }

  /// `amount` of the part taken back on the 5th, as the refund picker makes it.
  private func refund(
    of purchase: TransactionEntry, part: Int = 0, amount: AmountE4, others: [TransactionEntry] = []
  ) throws -> TransactionEntry {
    let index = RefundIndex(entries: [purchase] + others, debts: [:])
    let draft = try RefundRules.draft(
      refunding: purchase.parts[part], of: purchase, amount: amount,
      occurredAt: moment(refundDay), accountId: nil, index: index, tree: tree)
    return try draft.materialize(now: moment(refundDay))
  }

  private func ledger(_ entries: [TransactionEntry], links: [ReimbursementLink] = []) -> Ledger {
    Ledger(dataset: Dataset(entries: entries, links: links), calendar: .utc)
  }

  // MARK: The rows

  func testThePurchaseSaysWhatCameBackAndTheRefundNamesItsPurchase() throws {
    let purchase = try sneakers()
    let refund = try refund(of: purchase, amount: AmountE4(whole: 1_000))
    let ledger = ledger([purchase, refund])

    let listing = TransactionListing.build([refund.id, purchase.id], ledger: ledger)
    let rows = listing.sections.flatMap(\.rows)
    let purchaseRow = try XCTUnwrap(rows.first { $0.transactionId == purchase.id })
    let refundRow = try XCTUnwrap(rows.first { $0.transactionId == refund.id })

    XCTAssertEqual(purchaseRow.refund, .refunded(AmountE4(whole: 1_000), .rub))
    XCTAssertEqual(
      refundRow.refund,
      .refundOf(purchaseId: purchase.id, title: .note("Sneakers"), day: purchaseDay))
  }

  func testTheSidesOfTheDaysCountTheRefundInThePurchase() throws {
    let purchase = try sneakers()
    let refund = try refund(of: purchase, amount: AmountE4(whole: 1_000))
    let ledger = ledger([purchase, refund])

    let listing = TransactionListing.build([refund.id, purchase.id], ledger: ledger)
    let byDay = Dictionary(
      listing.sections.filter { $0.side == .expenses }.map { ($0.day, $0.totals) },
      uniquingKeysWith: { first, _ in first })
    // The purchase came in cheaper on its own day, and the refund adds nothing on its day —
    // not −1 000 there and 3 000 here.
    XCTAssertEqual(byDay[purchaseDay]?.myExpenses, AmountE4(whole: 2_000))
    XCTAssertEqual(byDay[refundDay]?.myExpenses, .zero)
    // The same numbers as the selection and Overview.
    XCTAssertEqual(ledger.rowTotals(of: [purchase.id]).myExpenses, AmountE4(whole: 2_000))
    XCTAssertEqual(ledger.rowTotals(of: [refund.id]).myExpenses, .zero)
  }

  func testTheDaysOfOverviewCountTheRefundInThePurchase() throws {
    let purchase = try sneakers()
    let refund = try refund(of: purchase, amount: AmountE4(whole: 1_000))
    let ledger = ledger([purchase, refund])

    let groups = TransactionsStore.group(
      [refund, purchase], calendar: .utc, refunds: ledger.refundIndex)
    let byDay = Dictionary(groups.map { ($0.day, $0.totals) }, uniquingKeysWith: { a, _ in a })
    XCTAssertEqual(byDay[purchaseDay]?.myExpenses, AmountE4(whole: 2_000))
    XCTAssertEqual(byDay[refundDay]?.myExpenses, .zero)
  }

  func testAPurchaseRefundedWholeComesToNothingOnItsDay() throws {
    let purchase = try sneakers()
    let refund = try refund(of: purchase, amount: AmountE4(whole: 3_000))
    let ledger = ledger([purchase, refund])

    let listing = TransactionListing.build([refund.id, purchase.id], ledger: ledger)
    XCTAssertTrue(listing.sections.allSatisfy { $0.totals.myExpenses.isZero })
    XCTAssertEqual(
      listing.sections.flatMap(\.rows).first { $0.transactionId == purchase.id }?.refund,
      .refunded(AmountE4(whole: 3_000), .rub))
  }

  func testTheRefundedPartOfASplitSaysItOnItsOwnRow() throws {
    var draft = TransactionDraft(
      occurredAt: moment(purchaseDay), amount: AmountE4(whole: 3_000), note: "Market")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_000), note: "Cheese"),
      PartDraft(amount: AmountE4(whole: 2_000), note: "Wine"),
    ]
    let purchase = try draft.materialize(now: moment(purchaseDay))
    let refund = try refund(of: purchase, part: 1, amount: AmountE4(whole: 500))
    let ledger = ledger([purchase, refund])

    let listing = TransactionListing.build([refund.id, purchase.id], ledger: ledger)
    let purchaseRow = try XCTUnwrap(
      listing.sections.flatMap(\.rows).first { $0.transactionId == purchase.id })
    XCTAssertEqual(purchaseRow.refund, .refunded(AmountE4(whole: 500), .rub))
    XCTAssertEqual(purchaseRow.parts?.map(\.refund), [nil, .refunded(AmountE4(whole: 500), .rub)])
    // The refund names the part it took back from, as its row does.
    let refundRow = try XCTUnwrap(
      listing.sections.flatMap(\.rows).first { $0.transactionId == refund.id })
    XCTAssertEqual(
      refundRow.refund, .refundOf(purchaseId: purchase.id, title: .note("Wine"), day: purchaseDay))
  }

  func testARefundWhosePurchaseIsGoneCountsOnItsOwnAndNamesNothing() throws {
    let purchase = try sneakers()
    let refund = try refund(of: purchase, amount: AmountE4(whole: 1_000))
    var deleted = purchase
    deleted.transaction.deletedAt = moment(refundDay)
    let ledger = ledger([deleted, refund])

    let listing = TransactionListing.build([refund.id], ledger: ledger)
    let row = try XCTUnwrap(listing.sections.first?.rows.first)
    XCTAssertNil(row.refund)
    XCTAssertEqual(listing.sections.first?.totals.myExpenses, AmountE4(whole: -1_000))
  }

  func testOperationsWithoutRefundsCarryNoMark() throws {
    let purchase = try sneakers()
    let ledger = ledger([purchase])
    let listing = TransactionListing.build([purchase.id], ledger: ledger)
    XCTAssertNil(listing.sections.first?.rows.first?.refund)
  }

  func testTheMarksAreSaidInBothLanguages() throws {
    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }

    let refunded = RefundMark.refunded(AmountE4(whole: 1_000), .rub)
    let of = RefundMark.refundOf(purchaseId: UUID(), title: .note("Sneakers"), day: purchaseDay)
    environment.language.choice = .english
    let english = RefundMarkText.text(refunded, environment: environment)
    XCTAssertTrue(english.contains("1,000"), english)
    XCTAssertTrue(english.contains("refunded"), english)
    XCTAssertTrue(RefundMarkText.text(of, environment: environment).contains("Sneakers"))

    environment.language.choice = .russian
    let russian = RefundMarkText.text(refunded, environment: environment)
    XCTAssertTrue(russian.contains("вернули"), russian)
    XCTAssertTrue(russian.contains("1,000"), russian)
    let purchase = RefundMarkText.text(of, environment: environment)
    XCTAssertTrue(purchase.contains("к покупке «Sneakers»"), purchase)
  }

  /// A purchase of another year, refunded through «Показать раньше»: «1 сентября» alone would
  /// not say which, so the day of the purchase carries its year then — and only then.
  func testARefundOfAPurchaseOfAnotherYearNamesTheYearOfThePurchase() throws {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let lastYear = DateOnly(year: 2025, month: 9, day: 1)
    var draft = TransactionDraft(
      occurredAt: moment(lastYear), amount: AmountE4(whole: 3_000), note: "Sneakers")
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(now: moment(lastYear))
    let refund = try refund(of: purchase, amount: AmountE4(whole: 1_000))
    let ledger = ledger([purchase, refund])
    let listing = TransactionListing.build([refund.id, purchase.id], ledger: ledger)
    let mark = try XCTUnwrap(
      listing.sections.flatMap(\.rows).first { $0.transactionId == refund.id }?.refund)

    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let words = RefundMarkText.text(mark, environment: environment)
      XCTAssertTrue(words.contains("2025"), "\(choice): \(words)")
    }

    // A purchase of the refund's own year is named by its day and month.
    let thisYear = try sneakers()
    let sameYear = try self.refund(of: thisYear, amount: AmountE4(whole: 1_000))
    let near = TransactionListing.build(
      [sameYear.id, thisYear.id], ledger: self.ledger([thisYear, sameYear]))
    let nearMark = try XCTUnwrap(
      near.sections.flatMap(\.rows).first { $0.transactionId == sameYear.id }?.refund)
    environment.language.choice = .english
    XCTAssertFalse(
      RefundMarkText.text(nearMark, environment: environment).contains("2026"),
      RefundMarkText.text(nearMark, environment: environment))
  }

  /// In English the refund's row reads as a refund of the purchase, not as something bought
  /// for it.
  func testTheRefundNamesItsPurchaseAsARefundOfItInEnglish() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .english
    let of = RefundMark.refundOf(purchaseId: UUID(), title: .note("Sneakers"), day: purchaseDay)
    let words = RefundMarkText.text(of, environment: environment)
    XCTAssertTrue(words.hasPrefix("refund of “Sneakers”"), words)
  }

  /// 100 $ bought at 90 ₽, 40 $ of it refunded: the purchase says what came back in dollars,
  /// and its day comes to the 60 $ left of it, 5 400 ₽.
  func testAPurchaseInDollarsSaysWhatCameBackInDollars() throws {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    var draft = TransactionDraft(
      occurredAt: moment(purchaseDay), currency: .usd, amount: AmountE4(whole: 100), rate: 90,
      rateDate: purchaseDay, rateSource: .cbr, note: "Jacket")
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(
      now: moment(purchaseDay), rublesConverter: { try AmountE4(decimal: $0.decimal * 90) })
    XCTAssertEqual(purchase.transaction.amountRubE4, AmountE4(whole: 9_000))
    let refundDraft = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 40),
      occurredAt: moment(refundDay), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: tree)
    let rubles = RefundRules.rubles(
      refundAmount: AmountE4(whole: 40), part: purchase.parts[0], refundedBefore: (.zero, .zero))
    let refund = try refundDraft.materialize(
      now: moment(refundDay), rublesConverter: { _ in rubles })
    let ledger = ledger([purchase, refund])

    let listing = TransactionListing.build([refund.id, purchase.id], ledger: ledger)
    let purchaseRow = try XCTUnwrap(
      listing.sections.flatMap(\.rows).first { $0.transactionId == purchase.id })
    XCTAssertEqual(purchaseRow.refund, .refunded(AmountE4(whole: 40), .usd))
    let byDay = Dictionary(
      listing.sections.filter { $0.side == .expenses }.map { ($0.day, $0.totals) },
      uniquingKeysWith: { first, _ in first })
    XCTAssertEqual(byDay[purchaseDay]?.myExpenses, AmountE4(whole: 5_400))
    XCTAssertEqual(byDay[refundDay]?.myExpenses, .zero)

    environment.language.choice = .english
    let words = RefundMarkText.text(try XCTUnwrap(purchaseRow.refund), environment: environment)
    // «40 $ refunded», the space before the sign a non-breaking one.
    XCTAssertTrue(words.hasPrefix("40") && words.contains("$ refunded"), words)
  }

  /// A part of a split without a note of its own is named as its row names it: by the note of
  /// the purchase.
  func testARefundOfAPartWithoutANoteNamesThePurchase() throws {
    var draft = TransactionDraft(
      occurredAt: moment(purchaseDay), amount: AmountE4(whole: 3_000), note: "Market")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_000), note: "Cheese"),
      PartDraft(amount: AmountE4(whole: 2_000)),
    ]
    let purchase = try draft.materialize(now: moment(purchaseDay))
    let refund = try refund(of: purchase, part: 1, amount: AmountE4(whole: 500))
    let listing = TransactionListing.build(
      [refund.id, purchase.id], ledger: ledger([purchase, refund]))
    let refundRow = try XCTUnwrap(
      listing.sections.flatMap(\.rows).first { $0.transactionId == refund.id })
    XCTAssertEqual(
      refundRow.refund,
      .refundOf(purchaseId: purchase.id, title: .note("Market"), day: purchaseDay))
  }

  // MARK: The question before a deletion

  func testTheDeletionCountsTheRefundInItsPurchaseAndKeepsAPurchaseWhoseRefundStays() throws {
    let purchase = try sneakers()
    let refund = try refund(of: purchase, amount: AmountE4(whole: 1_000))
    let ledger = ledger([purchase, refund])

    // The purchase alone stays: its refund would take back from nothing.
    let alone = try XCTUnwrap(
      BulkConfirmation.deletion(of: [purchase], refunds: ledger.refundIndex, debts: [:]))
    guard case .delete(let ids, let plan, _, _, _) = alone else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(ids, [])
    XCTAssertEqual(plan.skipped.map(\.reason), [.hasRefunds])

    // With its refund both go, and they come to what the purchase counted: 2 000.
    let both = try XCTUnwrap(
      BulkConfirmation.deletion(of: [refund, purchase], refunds: ledger.refundIndex, debts: [:]))
    guard case .delete(let bothIds, _, let totals, _, _) = both else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(Set(bothIds), [purchase.id, refund.id])
    XCTAssertEqual(totals.myExpenses, AmountE4(whole: 2_000))

    // The refund alone comes to nothing: it counted in the purchase.
    let refundOnly = try XCTUnwrap(
      BulkConfirmation.deletion(of: [refund], refunds: ledger.refundIndex, debts: [:]))
    guard case .delete(_, _, let refundTotals, _, _) = refundOnly else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(refundTotals.myExpenses, .zero)
  }

  // MARK: Overview: money owed that came back in part

  func testTheOwedCardSaysWhatCameBackOfAPartThatWaitsForTheRest() throws {
    let alex = Person(name: "Alex")
    var draft = TransactionDraft(
      occurredAt: moment(purchaseDay), amount: AmountE4(whole: 3_000), note: "Dinner")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_500)),
      PartDraft(
        amount: AmountE4(whole: 1_500), forWhom: .friends, reimbursable: true,
        debtorPersonId: alex.id),
    ]
    let dinner = try draft.materialize(now: moment(purchaseDay))
    var back = TransactionDraft(
      kind: .reimbursement, occurredAt: moment(refundDay), amount: AmountE4(whole: 700))
    back.normalizeSinglePart()
    back.parts[0].forPersonId = alex.id
    let moneyBack = try back.materialize(now: moment(refundDay))
    let link = ReimbursementLink(
      reimbursementTxId: moneyBack.id, partId: dinner.parts[1].id, amountE4: AmountE4(whole: 700))
    let ledger = ledger([dinner, moneyBack], links: [link])

    let partly = OwedPartly(ledger)
    XCTAssertEqual(partly.count, 1)
    XCTAssertEqual(partly.returnedRub, AmountE4(whole: 700))
    XCTAssertEqual(partly.remainingRub, AmountE4(whole: 800))
    // The card's figure is the summary's: what is left, not the whole part.
    XCTAssertEqual(OverviewSummary(ledger: ledger, today: refundDay).owedToMe, AmountE4(whole: 800))

    // Nothing back yet: nothing to say under the figure.
    XCTAssertEqual(OwedPartly(self.ledger([dinner])).count, 0)
  }

  /// The figure of the card comes from the step that counts what is owed; the line under it
  /// from the ledger on screen. While the two are of different data — a step counted from an
  /// older read — the line is not said: «800 ₽» would stand over words of another story.
  func testTheLineUnderTheOwedFigureIsSaidOnlyForTheSameData() throws {
    let alex = Person(name: "Alex")
    var draft = TransactionDraft(
      occurredAt: moment(purchaseDay), amount: AmountE4(whole: 3_000), note: "Dinner")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_500)),
      PartDraft(
        amount: AmountE4(whole: 1_500), forWhom: .friends, reimbursable: true,
        debtorPersonId: alex.id),
    ]
    let dinner = try draft.materialize(now: moment(purchaseDay))
    var back = TransactionDraft(
      kind: .reimbursement, occurredAt: moment(refundDay), amount: AmountE4(whole: 700))
    back.normalizeSinglePart()
    back.parts[0].forPersonId = alex.id
    let moneyBack = try back.materialize(now: moment(refundDay))
    let link = ReimbursementLink(
      reimbursementTxId: moneyBack.id, partId: dinner.parts[1].id, amountE4: AmountE4(whole: 700))
    let partly = OwedPartly(ledger([dinner, moneyBack], links: [link]))

    XCTAssertEqual(
      partly.returned(under: OwedSummary(amount: AmountE4(whole: 800), count: 1)),
      AmountE4(whole: 700))
    // The figure of the data before the money came back: nothing is said under it.
    XCTAssertNil(partly.returned(under: OwedSummary(amount: AmountE4(whole: 1_500), count: 1)))
  }

  func testTheOwedCardHasWordsInBothLanguages() {
    let language = AppLanguage()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = language.choice
    defer { language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let key = "overview.owedPartlyReturned"
      XCTAssertNotEqual(language(key, table: "Overview"), key, "\(choice)")
    }
  }
}
