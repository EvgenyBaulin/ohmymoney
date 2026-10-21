import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What the «money back from a person» sheet writes. Money comes back in rubles, so a part
/// paid in dollars is owed — and closed — in the rubles it cost; the surplus, the shortfall
/// and every link are rubles too.
final class ReimbursementRecordingTests: XCTestCase {
  private let reimbursementId = UUID()
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  private let fees = CoreKit.Category(kind: .expense, name: "Fees", quality: .bad)
  private let surcharges = CoreKit.Category(
    kind: .income, name: "Surcharges", systemRole: .surcharges)

  /// 50 dollars for a friend's dinner, 4 750 rubles on the day.
  private func dollarPart(
    _ partId: UUID = UUID(), category: UUID? = nil, provisional: Bool = false,
    debtor: UUID? = nil, forPerson: UUID? = nil, event: UUID? = nil
  ) -> OwedPart {
    OwedPart(
      partId: partId, transactionId: UUID(),
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 12)),
      debtorPersonId: debtor, categoryId: category ?? groceries.id, forWhom: .friends,
      forPersonId: forPerson, eventId: event,
      amountE4: AmountE4(whole: 50), amountRubE4: AmountE4(whole: 4_750),
      currency: .usd, rateProvisional: provisional, note: "dinner")
  }

  private func setting(history: ManualQualityHistory = .empty) -> ReimbursementRecording.Setting {
    ReimbursementRecording.Setting(
      surchargesCategoryId: surcharges.id,
      categories: CategoryTree([groceries, fees, surcharges]),
      history: history,
      surplusNote: "Surplus of a reimbursement",
      shortfallNote: "Shortfall of a reimbursement")
  }

  private func record(
    _ received: Int64, closing parts: [OwedPart],
    distribution: ReimbursementDistribution = ReimbursementDistribution(),
    history: ManualQualityHistory = .empty, personId: UUID? = nil
  ) throws -> ReimbursementRecording {
    try ReimbursementRecording.make(
      id: reimbursementId, received: AmountE4(whole: received), closing: parts,
      distribution: distribution, personId: personId, setting: setting(history: history))
  }

  func testAPartPaidInDollarsIsClosedByTheRublesItCost() throws {
    let part = dollarPart()
    let recorded = try record(4_750, closing: [part])

    XCTAssertEqual(recorded.outcome.closedPartIds, [part.partId])
    XCTAssertEqual(recorded.outcome.links.map(\.amountE4), [AmountE4(whole: 4_750)])
    XCTAssertNil(recorded.outcome.surplus)
    XCTAssertTrue(recorded.extra.isEmpty)
    XCTAssertEqual(recorded.reimbursement.transaction.kind, .reimbursement)
    XCTAssertEqual(recorded.reimbursement.transaction.currency, .rub)
    XCTAssertEqual(recorded.reimbursement.transaction.amountRubE4, AmountE4(whole: 4_750))
  }

  func testMoreRublesThanThePartCostAreASurplusInRubles() throws {
    let recorded = try record(5_000, closing: [dollarPart()])

    XCTAssertEqual(recorded.extra.count, 1)
    let surplus = try XCTUnwrap(recorded.extra.first)
    XCTAssertEqual(surplus.transaction.kind, .income)
    XCTAssertEqual(surplus.transaction.currency, .rub)
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 250))
    XCTAssertEqual(surplus.parts.first?.categoryId, surcharges.id)
    XCTAssertEqual(
      surplus.transaction.externalId, "reimb:\(reimbursementId.uuidString.lowercased()):surplus")
    XCTAssertEqual(recorded.outcome.links.map(\.amountE4), [AmountE4(whole: 4_750)])
  }

  /// The surplus is income in Surcharges and nowhere else. A database without that category
  /// gets no uncategorised income: the recording is refused, and money that matches the parts
  /// or falls short of them still goes in.
  func testASurplusWithNoSurchargesCategoryIsRefused() throws {
    var noSurcharges = setting()
    noSurcharges.surchargesCategoryId = nil
    func record(_ received: Int64) throws -> ReimbursementRecording {
      try ReimbursementRecording.make(
        id: reimbursementId, received: AmountE4(whole: received), closing: [dollarPart()],
        distribution: ReimbursementDistribution(), personId: nil, setting: noSurcharges)
    }

    XCTAssertThrowsError(try record(5_000)) { error in
      XCTAssertEqual(error as? ReimbursementRecording.Failure, .noSurchargesCategory)
    }
    XCTAssertTrue(try record(4_750).extra.isEmpty)
    XCTAssertEqual(try record(4_000).extra.map(\.transaction.kind), [.expense])
  }

  func testFewerRublesLeaveAShortfallInRublesWithItsOwnQuality() throws {
    let part = dollarPart(category: fees.id)
    let recorded = try record(4_000, closing: [part])

    let shortfall = try XCTUnwrap(recorded.extra.first)
    XCTAssertEqual(shortfall.transaction.kind, .expense)
    XCTAssertEqual(shortfall.transaction.currency, .rub)
    XCTAssertEqual(shortfall.transaction.amountE4, AmountE4(whole: 750))
    XCTAssertEqual(shortfall.parts.first?.categoryId, fees.id)
    XCTAssertEqual(shortfall.parts.first?.quality, .bad)
    XCTAssertEqual(shortfall.parts.first?.qualitySource, .category)
    XCTAssertEqual(
      shortfall.transaction.externalId,
      "reimb:\(reimbursementId.uuidString.lowercased()):shortfall:"
        + part.partId.uuidString.lowercased())
  }

  /// Rule 2 of the qualities: a description I rated by hand keeps my rating. The shortfall
  /// is what is left of the original purchase, so it carries that purchase's description —
  /// the same in every interface language — and my rating of it.
  func testTheShortfallFollowsARatingIGaveThePurchaseByHand() throws {
    let history = ManualQualityHistory(latest: ["Dinner": .good])
    let recorded = try record(4_000, closing: [dollarPart(category: fees.id)], history: history)

    let shortfall = try XCTUnwrap(recorded.extra.first)
    XCTAssertEqual(shortfall.transaction.note, "dinner")
    XCTAssertEqual(shortfall.parts.first?.quality, .good)
    XCTAssertEqual(shortfall.parts.first?.qualitySource, .history)
  }

  /// The shortfall is my loss on that very purchase, so it stays with the person and the
  /// event of the purchase: «for whom → people» and the event's total include it.
  /// The person is whom the part was for, and the debtor when it names nobody else.
  func testTheShortfallStaysWithThePersonAndTheEventOfThePurchase() throws {
    let anna = UUID()
    let trip = UUID()
    let recorded = try record(
      4_000, closing: [dollarPart(category: fees.id, debtor: anna, event: trip)])

    let part = try XCTUnwrap(recorded.extra.first?.parts.first)
    XCTAssertEqual(part.forWhom, .friends)
    XCTAssertEqual(part.forPersonId, anna)
    XCTAssertEqual(part.eventId, trip)
    XCTAssertFalse(part.reimbursable)
    XCTAssertNil(part.debtorPersonId)
  }

  /// A ticket bought for Boris that Anna pays back: the loss is on Boris's ticket.
  func testTheShortfallNamesWhomThePartWasForBeforeTheDebtor() throws {
    let anna = UUID()
    let boris = UUID()
    let recorded = try record(
      4_000, closing: [dollarPart(category: fees.id, debtor: anna, forPerson: boris)])

    let part = try XCTUnwrap(recorded.extra.first?.parts.first)
    XCTAssertEqual(part.forPersonId, boris)
    XCTAssertNil(part.eventId)
  }

  /// A rating given to the words the interface happens to use for a shortfall says nothing
  /// about the purchase: it would follow the language instead of the money.
  func testTheShortfallIgnoresARatingOfTheInterfaceWording() throws {
    let history = ManualQualityHistory(latest: ["Shortfall of a reimbursement": .good])
    let recorded = try record(4_000, closing: [dollarPart(category: fees.id)], history: history)

    XCTAssertEqual(recorded.extra.first?.parts.first?.quality, .bad)
    XCTAssertEqual(recorded.extra.first?.parts.first?.qualitySource, .category)
  }

  /// Ticking a part fills «Received» with what it cost and spreads that. Typing less
  /// afterwards is the usual way to record a shortfall: the part is closed short, and the
  /// spread made for the old amount is not sent as a distribution larger than the money.
  func testTypingLessAfterTickingAPartLeavesAShortfall() throws {
    let part = dollarPart(category: fees.id)
    var distribution = ReimbursementDistribution()
    distribution.spread(AmountE4(whole: 4_750), over: [part])

    let recorded = try record(4_000, closing: [part], distribution: distribution)

    XCTAssertEqual(recorded.outcome.links.map(\.amountE4), [AmountE4(whole: 4_000)])
    XCTAssertNil(recorded.outcome.surplus)
    let shortfall = try XCTUnwrap(recorded.extra.first)
    XCTAssertEqual(recorded.extra.count, 1)
    XCTAssertEqual(shortfall.transaction.amountE4, AmountE4(whole: 750))
    XCTAssertEqual(shortfall.parts.first?.categoryId, fees.id)
    XCTAssertEqual(shortfall.parts.first?.quality, .bad)
  }

  /// The shares the sheet shows follow the amount: a new amount spreads anew, oldest first,
  /// and forgets a correction made for the old one.
  func testTheSharesFollowTheAmountUntilOneIsCorrectedByHand() {
    let older = dollarPart()
    var newer = dollarPart()
    newer.occurredAt = older.occurredAt.addingTimeInterval(3_600)
    var distribution = ReimbursementDistribution()

    distribution.spread(AmountE4(whole: 6_000), over: [newer, older])
    XCTAssertEqual(distribution.share(of: older.partId), AmountE4(whole: 4_750))
    XCTAssertEqual(distribution.share(of: newer.partId), AmountE4(whole: 1_250))
    XCTAssertFalse(distribution.isCorrectedByHand)

    // The field writes back what it was shown; that is not a correction.
    distribution.correct(newer.partId, to: AmountE4(whole: 1_250))
    XCTAssertFalse(distribution.isCorrectedByHand)
    XCTAssertNil(distribution.allocation(over: [older, newer].map(\.inRubles)))

    distribution.correct(newer.partId, to: AmountE4(whole: 1_000))
    XCTAssertTrue(distribution.isCorrectedByHand)

    distribution.spread(AmountE4(whole: 4_000), over: [newer, older])
    XCTAssertFalse(distribution.isCorrectedByHand)
    XCTAssertEqual(distribution.share(of: older.partId), AmountE4(whole: 4_000))
    XCTAssertEqual(distribution.share(of: newer.partId), .zero)

    // With nothing typed, every part shows what it cost.
    distribution.spread(nil, over: [older])
    XCTAssertEqual(distribution.shares, [older.partId: AmountE4(whole: 4_750)])
  }

  /// A distribution corrected by hand is what gets written: money left aside on purpose is
  /// a surplus, and the part it did not reach is closed short.
  func testADistributionCorrectedByHandIsWrittenAsItIs() throws {
    let part = dollarPart(category: fees.id)
    var distribution = ReimbursementDistribution()
    distribution.spread(AmountE4(whole: 5_000), over: [part])
    distribution.correct(part.partId, to: AmountE4(whole: 4_500))

    let recorded = try record(5_000, closing: [part], distribution: distribution)

    XCTAssertEqual(recorded.outcome.links.map(\.amountE4), [AmountE4(whole: 4_500)])
    XCTAssertEqual(recorded.outcome.surplus?.amountE4, AmountE4(whole: 500))
    XCTAssertEqual(recorded.outcome.shortfalls.map(\.amountE4), [AmountE4(whole: 250)])
  }

  func testAPartWhoseRateIsStillProvisionalIsNotClosed() {
    let waiting = dollarPart(provisional: true)
    XCTAssertThrowsError(try record(4_750, closing: [waiting])) { error in
      XCTAssertEqual(error as? ReimbursementError, .provisionalRate(waiting.partId))
    }
  }

  // MARK: Whose money came back

  /// Money back is money from one person, and it closes what that person owes (spec,
  /// «Возврат денег от человека»: «выбираются человек и … части»). With «—» in the picker the
  /// sheet lists everybody's parts; ticking Anya's two names Anya, not nobody.
  func testWithNoPersonChosenTheReimbursementNamesTheDebtorOfItsParts() throws {
    let anya = UUID()
    let parts = [dollarPart(debtor: anya), dollarPart(debtor: anya)]

    let recorded = try record(9_500, closing: parts)

    XCTAssertEqual(recorded.reimbursement.parts.first?.forPersonId, anya)
    XCTAssertEqual(ReimbursementRecording.payer(chosen: nil, closing: parts), .person(anya))
  }

  /// Anya and Boris each owe: one reimbursement for both would be money from nobody, closing
  /// two people's parts, invisible to the person filter. Save stays off and the core refuses.
  @MainActor
  func testPartsOfDifferentPeopleAreNotClosedByOneReimbursement() {
    let anya = UUID()
    let boris = UUID()
    let parts = [dollarPart(debtor: anya), dollarPart(debtor: boris)]

    XCTAssertEqual(ReimbursementRecording.payer(chosen: nil, closing: parts), .differentPeople)
    XCTAssertFalse(
      ReimbursementSheet.canRecord(
        closing: parts, chosen: nil, received: AmountE4(whole: 9_500)))
    XCTAssertThrowsError(try record(9_500, closing: parts)) { error in
      XCTAssertEqual(error as? ReimbursementRecording.Failure, .partsOfDifferentPeople)
    }

    XCTAssertTrue(
      ReimbursementSheet.canRecord(
        closing: [parts[0]], chosen: anya, received: AmountE4(whole: 4_750)))
    XCTAssertFalse(
      ReimbursementSheet.canRecord(closing: [], chosen: anya, received: AmountE4(whole: 1)))
    XCTAssertFalse(ReimbursementSheet.canRecord(closing: [parts[0]], chosen: anya, received: nil))
  }

  /// The person chosen in the sheet gives the money back only for what they owe.
  func testAChosenPersonClosesOnlyTheirOwnParts() {
    let anya = UUID()
    let boris = UUID()
    let borisPart = dollarPart(debtor: boris)

    XCTAssertEqual(
      ReimbursementRecording.payer(chosen: anya, closing: [borisPart]), .differentPeople)
    XCTAssertThrowsError(try record(4_750, closing: [borisPart], personId: anya)) { error in
      XCTAssertEqual(error as? ReimbursementRecording.Failure, .partsOfDifferentPeople)
    }
    XCTAssertEqual(
      try record(4_750, closing: [borisPart], personId: boris)
        .reimbursement.parts.first?.forPersonId, boris)
  }

  /// A part entered before a part paid for someone had to name its debtor is listed
  /// under nobody, and no person in the picker lists it: money back for it names nobody too.
  func testPartsThatNameNobodyAreClosedByMoneyFromNobody() throws {
    let parts = [dollarPart(), dollarPart()]

    XCTAssertEqual(ReimbursementRecording.payer(chosen: nil, closing: parts), .nobody)
    XCTAssertNil(try record(9_500, closing: parts).reimbursement.parts.first?.forPersonId)
    XCTAssertEqual(
      ReimbursementRecording.payer(chosen: nil, closing: [dollarPart(debtor: UUID()), parts[0]]),
      .differentPeople)
  }

  /// «Write off» forgets ⌘Z and asks for a backup only when the write landed. A part that
  /// stopped waiting while the sheet was open is not written off, and ⌘Z still takes back
  /// what it took back before; the sheet says the part is gone.
  @MainActor
  func testAWriteOffThatDidNotLandKeepsUndoAndAsksForNoBackup() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    for category in [groceries, fees, surcharges] { try references.save(category) }
    let store = TransactionsStore(repository: transactions, references: references)
    var dinner = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 1_000), reimbursable: true)
    ]
    XCTAssertTrue(store.save(try dinner.materialize()))
    let part = try XCTUnwrap(try transactions.owedParts().first)
    var backups = 0

    let first = ReimbursementSheet.writeOff(
      part.partId, repository: transactions, store: store, scheduleBackup: { backups += 1 })
    XCTAssertEqual(first, .writtenOff)
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(backups, 1)

    var coffee = TransactionDraft(amount: AmountE4(whole: 200), note: "coffee")
    coffee.normalizeSinglePart()
    XCTAssertTrue(store.save(try coffee.materialize()))
    let again = ReimbursementSheet.writeOff(
      part.partId, repository: transactions, store: store, scheduleBackup: { backups += 1 })
    XCTAssertEqual(again, .gone)
    XCTAssertTrue(store.canUndo, "a refused write-off forgot ⌘Z")
    XCTAssertEqual(backups, 1)

    XCTAssertEqual(
      ReimbursementSheet.writeOff(
        part.partId, repository: nil, store: store, scheduleBackup: { backups += 1 }),
      .failed)
    XCTAssertTrue(store.canUndo)
    XCTAssertEqual(backups, 1)
  }

  /// Two shortfalls from one reimbursement: each gets a key of its own, so the unique index
  /// on `external_id` lets both in, and the links land in rubles.
  func testWhatTheSheetWritesLandsInTheDatabaseInRubles() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    for category in [groceries, fees, surcharges] { try references.save(category) }

    var dinner = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 12)),
      currency: .usd, amount: AmountE4(whole: 100), rate: 95, rateSource: .manual,
      note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 50), reimbursable: true),
      PartDraft(categoryId: fees.id, amount: AmountE4(whole: 50), reimbursable: true),
    ]
    try transactions.save(
      try dinner.materialize(rublesConverter: { AmountE4(raw: $0.raw * 95) }))

    let owed = try transactions.owedParts()
    XCTAssertEqual(owed.map(\.amountRubE4), [AmountE4(whole: 4_750), AmountE4(whole: 4_750)])
    var distribution = ReimbursementDistribution()
    distribution.spread(AmountE4(whole: 9_000), over: owed)
    distribution.correct(owed[0].partId, to: AmountE4(whole: 4_500))
    distribution.correct(owed[1].partId, to: AmountE4(whole: 4_500))
    let recorded = try ReimbursementRecording.make(
      id: reimbursementId, received: AmountE4(whole: 9_000), closing: owed,
      distribution: distribution, personId: nil, setting: setting())
    try transactions.apply(
      recorded.outcome, reimbursement: recorded.reimbursement, extra: recorded.extra)

    XCTAssertTrue(try transactions.owedParts().isEmpty)
    let links = try XCTUnwrap(
      ExportRepository(writer: stack.writer).tables()
        .first { $0.name == "reimbursement_links" })
    let rows = try CSVReader.dictionaries(from: links.data)
    XCTAssertEqual(rows.compactMap { $0["amount"] }.sorted(), ["4500", "4500"])
    let shortfalls = try transactions.entries(from: .distantPast, to: .distantFuture)
      .filter { $0.transaction.externalId?.contains(":shortfall:") == true }
    XCTAssertEqual(shortfalls.count, 2)
    XCTAssertEqual(
      shortfalls.map(\.transaction.amountE4), [AmountE4(whole: 250), AmountE4(whole: 250)])
  }
}
