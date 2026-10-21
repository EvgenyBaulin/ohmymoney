import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// Provisional rates are refined by compare and set: only an operation still carrying what
/// was read takes the new rate, and its rubles and its parts' rubles are worked out again —
/// the parts' in proportion, the last one taking the rest.
@Suite("Provisional rates are refined in place, and only in place")
struct RateRefinementTests {
  private let calendar = CalendarContext.utc

  private func day(_ number: Int) -> DateOnly { DateOnly(year: 2026, month: 9, day: number) }

  private func usd(_ number: Int, _ rubles: String) -> Rate {
    Rate(date: day(number), currency: .usd, rubPerUnit: Decimal(string: rubles)!, source: .cbr)
  }

  /// The bank's rates for September 2026. Saturday the 19th is published, Sunday the 20th
  /// and Monday the 21st are not: Saturday's rate holds until Tuesday's.
  private var rates: [Int: Rate] {
    [
      5: usd(5, "79.0000"), 8: usd(8, "79.6000"),
      15: usd(15, "80.1000"), 16: usd(16, "81.4321"), 17: usd(17, "82.0000"),
      18: usd(18, "82.3000"), 19: usd(19, "82.7700"), 22: usd(22, "83.9000"),
    ]
  }

  private func table(through last: Int) -> RateTable {
    table(of: rates.keys.filter { $0 <= last })
  }

  private func table(of days: [Int], unpublished: [Int: Int] = [:]) -> RateTable {
    RateTable(
      rates: days.compactMap { rates[$0] },
      unpublishedDays: Dictionary(
        uniqueKeysWithValues: unpublished.map { (day($0.key), day($0.value)) }))
  }

  /// A 10 $ dinner on the 17th split in three, entered when the cache only went up to the
  /// 15th: the rate is the 15th's, marked provisional — what the entry panel does offline.
  private func dinner(
    on number: Int = 17, cachedThrough cached: Int = 15,
    parts: [Int64] = [33_300, 33_300, 33_400], reimbursable: Int? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: Date(timeIntervalSince1970: 1_789_560_000 + Double(number - 16) * 86_400),
      currency: .usd, amount: AmountE4(whole: 10), note: "dinner")
    draft.parts = parts.enumerated().map { index, raw in
      PartDraft(amount: AmountE4(raw: raw), reimbursable: index == reimbursable)
    }
    let resolution = try #require(table(through: cached).resolve(.usd, on: day(number)))
    #expect(resolution.isProvisional)
    draft.rate = resolution.rate.perUnit
    draft.rateDate = resolution.rate.date
    draft.rateSource = resolution.rate.source
    draft.rateProvisional = resolution.isProvisional
    return try draft.materialize(rublesConverter: { try resolution.rate.toRubles($0) })
  }

  private func makeRepository() throws -> TransactionRepository {
    TransactionRepository(writer: try TestSupport.makeStack().writer)
  }

  private func refine(
    _ repository: TransactionRepository, through last: Int
  ) throws -> Int {
    try refine(repository, with: table(through: last))
  }

  private func refine(_ repository: TransactionRepository, with table: RateTable) throws -> Int {
    let usages = try repository.provisionalUsages(calendar: calendar)
    return try repository.applyRefinements(
      RateTable.refinement(for: usages, with: table), of: usages, calendar: calendar)
  }

  /// The day's own rate is not published yet: the operation takes the newer rate of the
  /// 16th but stays provisional, and the next run, with the 17th's rate, settles it.
  @Test func aRateStillNotOnTheDayKeepsTheFlagUntilTheDaysRateArrives() throws {
    let repository = try makeRepository()
    let entry = try dinner()
    try repository.save(entry)
    #expect(entry.transaction.rateDate == day(15))

    let usages = try repository.provisionalUsages(calendar: calendar)
    #expect(usages.map(\.id) == [entry.id])
    #expect(usages.first?.day == day(17))
    #expect(usages.first?.appliedRateDate == day(15))

    #expect(try refine(repository, through: 16) == 1)
    var stored = try #require(try repository.entry(id: entry.id))
    #expect(stored.transaction.rateDate == day(16))
    #expect(stored.transaction.rate == Decimal(string: "81.4321"))
    #expect(stored.transaction.rateProvisional)
    #expect(stored.transaction.amountRubE4 == AmountE4(raw: 8_143_210))

    // Nothing new in the table: running again changes nothing.
    #expect(try refine(repository, through: 16) == 0)

    #expect(try refine(repository, through: 17) == 1)
    stored = try #require(try repository.entry(id: entry.id))
    #expect(stored.transaction.rateDate == day(17))
    #expect(!stored.transaction.rateProvisional)
    #expect(stored.transaction.amountRubE4 == AmountE4(whole: 820))
    #expect(try repository.provisionalUsages(calendar: calendar).isEmpty)
  }

  /// A day the bank never publishes. A dinner on Sunday the 20th, entered while the cache
  /// ended on Saturday, takes Saturday's rate — already the right one — but nothing says so
  /// yet, and the flag goes up. Tuesday's rate says nothing about Sunday either. The rate
  /// never moves; once the bank, asked for the 20th, answers with the 19th, the flag comes
  /// down and the rubles stay as they were.
  @Test func aDayOffKeepsItsRateAndLosesTheFlagOnceTheBankAnswersForIt() throws {
    let repository = try makeRepository()
    let entry = try dinner(on: 20, cachedThrough: 19)
    try repository.save(entry)
    #expect(entry.transaction.rateDate == day(19))

    #expect(try refine(repository, through: 21) == 0)
    #expect(try refine(repository, through: 22) == 0)
    #expect(try repository.entry(id: entry.id)?.transaction.rateProvisional == true)

    let answered = table(of: [15, 16, 17, 18, 19, 22], unpublished: [20: 19])
    #expect(try refine(repository, with: answered) == 1)
    let stored = try #require(try repository.entry(id: entry.id))
    #expect(!stored.transaction.rateProvisional)
    #expect(stored.transaction.rateDate == day(19))
    #expect(stored.transaction.rate == entry.transaction.rate)
    #expect(stored.transaction.amountRubE4 == AmountE4(raw: 8_277_000))
    #expect(stored.parts.map(\.amountRubE4) == entry.parts.map(\.amountRubE4))
    #expect(try repository.provisionalUsages(calendar: calendar).isEmpty)
    #expect(try refine(repository, with: answered) == 0)
  }

  /// A weekday refined to the day before keeps the flag, because its own rate may still
  /// come — also once the next business day is published without it, which only says nobody
  /// asked. When the bank, asked for the day, answers with the day before, the day was a
  /// holiday: the operation keeps the rate it carries and the flag comes down.
  @Test func aWeekdayThatTurnsOutAHolidayIsSettledWithTheRateBeforeIt() throws {
    let repository = try makeRepository()
    let entry = try dinner()
    try repository.save(entry)

    #expect(try refine(repository, with: table(of: [15, 16])) == 1)
    #expect(try repository.entry(id: entry.id)?.transaction.rateProvisional == true)
    #expect(try refine(repository, with: table(of: [15, 16, 18])) == 0)
    #expect(try repository.entry(id: entry.id)?.transaction.rateProvisional == true)

    #expect(try refine(repository, with: table(of: [15, 16, 18], unpublished: [17: 16])) == 1)
    let stored = try #require(try repository.entry(id: entry.id))
    #expect(!stored.transaction.rateProvisional)
    #expect(stored.transaction.rateDate == day(16))
    #expect(stored.transaction.amountRubE4 == AmountE4(raw: 8_143_210))
    #expect(try repository.provisionalUsages(calendar: calendar).isEmpty)
  }

  /// Entered offline on Tuesday the 8th while the cache ended on Saturday the 5th; a later
  /// run brings the 15th. The 8th had its own rate, and a hole in the cache is no holiday:
  /// the operation stays provisional until the 8th's rate arrives, and then takes it.
  @Test func aBusinessDayInAHoleOfTheCacheWaitsForItsOwnRate() throws {
    let repository = try makeRepository()
    let entry = try dinner(on: 8, cachedThrough: 5)
    try repository.save(entry)
    #expect(entry.transaction.rateDate == day(5))

    #expect(try refine(repository, with: table(of: [5, 15])) == 0)
    #expect(try repository.entry(id: entry.id)?.transaction.rateProvisional == true)

    #expect(try refine(repository, with: table(of: [5, 8, 15])) == 1)
    let stored = try #require(try repository.entry(id: entry.id))
    #expect(stored.transaction.rateDate == day(8))
    #expect(!stored.transaction.rateProvisional)
    #expect(stored.transaction.amountRubE4 == AmountE4(whole: 796))
  }

  /// The parts' rubles add up to the operation's to the unit, split exactly as saving a draft
  /// splits them; the link of a part that came back keeps its rubles. The part came back whole
  /// at the provisional 266.73 ₽ and costs 271.17 ₽ at the newer rate: 4.44 ₽ is more than the
  /// drift of 2.71 ₽, and nothing came back over it, so the part waits for the rest again.
  @Test func thePartsAreSplitAgainAndTheLinksKeepTheirRubles() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try dinner(reimbursable: 1)
    try repository.save(entry)
    // The money back covers the part's rubles of the day it was bought: a link never comes to
    // more than what is left of its part.
    let returned = entry.parts[1].amountRubE4
    var money = TransactionDraft(kind: .reimbursement, amount: returned)
    money.normalizeSinglePart()
    let reimbursement = try money.materialize()
    let link = ReimbursementLink(
      reimbursementTxId: reimbursement.id, partId: entry.parts[1].id, amountE4: returned)
    try repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: reimbursement.id, allocations: [], links: [link],
        closedPartIds: [entry.parts[1].id]),
      reimbursement: reimbursement)

    #expect(try refine(repository, through: 16) == 1)

    let stored = try #require(try repository.entry(id: entry.id))
    let rubles = stored.transaction.amountRubE4
    #expect(AmountE4.sum(stored.parts.map(\.amountRubE4)) == rubles)
    #expect(stored.parts.map(\.id) == entry.parts.map(\.id))
    // 8 143.21 ₽: the first two parts rounded, the last one takes the rest.
    #expect(stored.parts.map(\.amountRubE4.raw) == [2_711_689, 2_711_689, 2_719_832])
    #expect(
      stored.parts.map(\.amountRubE4)
        == rubles.allocated(
          proportionallyTo: entry.parts.map(\.amountE4), outOf: entry.transaction.amountE4))
    #expect(stored.parts[1].reimbursementStatus == .expected)

    let links = try stack.writer.read { db in try ReimbursementLink.fetchAll(db) }
    #expect(links == [link])
  }

  /// Money back typed part by part can reach a part still on a provisional rate. The day's own
  /// rate turns out lower: 3.33 $ were 266.73 ₽ at the 15th's 80.10 and are 265.07 ₽ at the
  /// 17th's 79.60. A part 266 ₽ already came back for has nothing more to wait for — it is
  /// settled, not left waiting for less than nothing, where nobody could close or write it off;
  /// its link is the part's rubles now, and the 0.93 ₽ over it would be income in «Доплаты» —
  /// this book has no such category, so it stays drift. A part 200 ₽ came back for keeps
  /// waiting for the rest, 65.07 ₽, its link untouched.
  @Test func aPartTheDaysRateLeavesNothingToWaitForIsSettled() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let covered = try dinner(reimbursable: 1)
    let waiting = try dinner(reimbursable: 1)
    try repository.save(covered)
    try repository.save(waiting)
    #expect(covered.parts[1].amountRubE4 == AmountE4(raw: 2_667_330))

    var links: [ReimbursementLink] = []
    for (entry, rubles) in [(covered, 266), (waiting, 200)] {
      var money = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: Int64(rubles)))
      money.normalizeSinglePart()
      let reimbursement = try money.materialize()
      let link = ReimbursementLink(
        reimbursementTxId: reimbursement.id, partId: entry.parts[1].id,
        amountE4: AmountE4(whole: Int64(rubles)))
      links.append(link)
      try repository.apply(
        ReimbursementOutcome(
          reimbursementTxId: reimbursement.id, allocations: [], links: [link],
          closedPartIds: []),
        reimbursement: reimbursement)
    }

    let lower = RateTable(rates: [usd(15, "80.1000"), usd(17, "79.6000")])
    #expect(try refine(repository, with: lower) == 2)

    let settled = try #require(try repository.entry(id: covered.id))
    #expect(settled.parts[1].amountRubE4 == AmountE4(raw: 2_650_680))
    #expect(settled.parts[1].reimbursementStatus == .returned)
    let open = try #require(try repository.entry(id: waiting.id))
    #expect(open.parts[1].reimbursementStatus == .expected)
    let left = try stack.writer.read { db in
      try TransactionRepository.remainingRub(ofPart: waiting.parts[1].id, db: db)
    }
    #expect(left == AmountE4(raw: 650_680))
    // Only the part that came back is touched: the others were never anybody's to return.
    #expect(settled.parts[0].reimbursementStatus == nil)
    var expected = links
    expected[0].amountE4 = AmountE4(raw: 2_650_680)
    #expect(
      try stack.writer.read { db in try ReimbursementLink.fetchAll(db) }.sorted {
        $0.id.uuidString < $1.id.uuidString
      } == expected.sorted { $0.id.uuidString < $1.id.uuidString })

    // The money back deleted, the part waits for all of its rubles again.
    let effects = try repository.softDelete(ids: [links[0].reimbursementTxId])
    #expect(effects.reopenedPartIds == [covered.parts[1].id])
    let reopened = try #require(try repository.entry(id: covered.id))
    #expect(reopened.parts[1].reimbursementStatus == .expected)
  }

  /// A book with the system «Доплаты».
  private func seedSurcharges(_ stack: DatabaseStack) throws -> UUID {
    let surcharges = CoreKit.Category(
      kind: .income, name: "Surcharges", systemRole: .surcharges)
    try ReferenceRepository(writer: stack.writer).seedCategoriesIfEmpty([surcharges])
    return surcharges.id
  }

  /// 266 ₽ back for the 3.33 $ part while it was 266.73 ₽ at a provisional 80.10: it waits for
  /// 0.73 ₽. The day's rate of 79.60 makes it 265.07 ₽ — the money covers it: the part closes,
  /// the link is its rubles, and the 0.93 ₽ over it is income in «Доплаты» on the money back's
  /// moment, with the note given.
  @Test func refinementClosingAPartWritesTheOverToSurcharges() throws {
    let stack = try TestSupport.makeStack()
    let surcharges = try seedSurcharges(stack)
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try dinner(reimbursable: 1)
    try repository.save(entry)
    var money = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 266))
    money.normalizeSinglePart()
    let back = try money.materialize()
    let link = ReimbursementLink(
      reimbursementTxId: back.id, partId: entry.parts[1].id, amountE4: AmountE4(whole: 266))
    try repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: back.id, allocations: [], links: [link], closedPartIds: []),
      reimbursement: back)

    let usages = try repository.provisionalUsages(calendar: calendar)
    let lower = RateTable(rates: [usd(15, "80.1000"), usd(17, "79.6000")])
    var counts = SettlementCounts()
    #expect(
      try repository.applyRefinements(
        RateTable.refinement(for: usages, with: lower), of: usages, calendar: calendar,
        surplusNote: "Surplus", settled: { counts = $0 }) == 1)
    #expect(counts == SettlementCounts(parts: 1, surpluses: 1))

    let settled = try #require(try repository.entry(id: entry.id))
    #expect(settled.parts[1].reimbursementStatus == .returned)
    let links = try stack.writer.read { db in try ReimbursementLink.fetchAll(db) }
    #expect(links.map(\.amountE4) == [AmountE4(raw: 2_650_680)])
    let surplus = try stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT id FROM transactions WHERE external_id = ?",
        arguments: [ReimbursementCompanions.surplusKey(of: back.id)])
    }
    let surplusId = try #require(surplus.flatMap(UUID.init(uuidString:)))
    let income = try #require(try repository.entry(id: surplusId))
    #expect(income.transaction.kind == .income)
    #expect(income.transaction.amountE4 == AmountE4(raw: 9_320))
    #expect(income.transaction.amountRubE4 == AmountE4(raw: 9_320))
    #expect(income.transaction.note == "Surplus")
    #expect(
      income.transaction.occurredAt == (try repository.entry(id: back.id))?.transaction.occurredAt)
    #expect(income.parts.first?.categoryId == surcharges)

    // Deleting the money back takes its surplus along and opens the part again.
    _ = try repository.softDelete(ids: [back.id])
    #expect(try repository.entry(id: income.id)?.transaction.isDeleted == true)
    #expect(try repository.entry(id: entry.id)?.parts[1].reimbursementStatus == .expected)
  }

  /// The day's rate of 79.95 makes the part 266.23 ₽: 0.23 ₽ short of it is within the
  /// tolerance of the drift (2.66 ₽) — the part closes and nothing else is written.
  @Test func refinementWithinTheToleranceClosesThePart() throws {
    let stack = try TestSupport.makeStack()
    _ = try seedSurcharges(stack)
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try dinner(reimbursable: 1)
    try repository.save(entry)
    var money = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 266))
    money.normalizeSinglePart()
    let back = try money.materialize()
    let link = ReimbursementLink(
      reimbursementTxId: back.id, partId: entry.parts[1].id, amountE4: AmountE4(whole: 266))
    try repository.apply(
      ReimbursementOutcome(
        reimbursementTxId: back.id, allocations: [], links: [link], closedPartIds: []),
      reimbursement: back)

    #expect(
      try refine(repository, with: RateTable(rates: [usd(15, "80.1000"), usd(17, "79.9500")]))
        == 1)
    let settled = try #require(try repository.entry(id: entry.id))
    #expect(settled.parts[1].amountRubE4 == AmountE4(raw: 2_662_335))
    #expect(settled.parts[1].reimbursementStatus == .returned)
    #expect(try stack.writer.read { db in try ReimbursementLink.fetchAll(db) } == [link])
    #expect(
      try stack.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE kind = 'income'")
      } == 0)
  }

  /// What was read is what gets compared. Between reading the usages and writing the
  /// refinements — the network sits in between — an operation is given a rate by hand,
  /// another is moved to a different day, and a third is refined by another run: none of
  /// them is written over.
  @Test func anOperationChangedAfterTheReadIsLeftAsItIs() throws {
    let repository = try makeRepository()
    let byHand = try dinner()
    let moved = try dinner()
    let twice = try dinner()
    for entry in [byHand, moved, twice] { try repository.save(entry) }
    let usages = try repository.provisionalUsages(calendar: calendar)
    #expect(usages.count == 3)
    let table = table(through: 16)
    let refinements = RateTable.refinement(for: usages, with: table)
    #expect(refinements.count == 3)

    var manual = byHand
    manual.transaction.rate = Decimal(90)
    manual.transaction.rateSource = .manual
    manual.transaction.amountRubE4 = AmountE4(whole: 900)
    manual.parts = zip(manual.parts, [2_997_000, 2_997_000, 3_006_000] as [Int64]).map {
      var part = $0
      part.amountRubE4 = AmountE4(raw: $1)
      return part
    }
    try repository.save(manual)
    var elsewhere = moved
    elsewhere.transaction.occurredAt = moved.transaction.occurredAt.addingTimeInterval(-86_400)
    try repository.save(elsewhere)
    _ = try repository.applyRefinements(
      refinements.filter { $0.usageId == twice.id }, of: usages, calendar: calendar)
    let refinedOnce = try #require(try repository.entry(id: twice.id))

    #expect(try repository.applyRefinements(refinements, of: usages, calendar: calendar) == 0)

    let keptByHand = try #require(try repository.entry(id: byHand.id))
    #expect(keptByHand.transaction.rate == Decimal(90))
    #expect(keptByHand.transaction.rateSource == .manual)
    #expect(keptByHand.transaction.amountRubE4 == AmountE4(whole: 900))
    #expect(keptByHand.parts.map(\.amountRubE4.raw) == [2_997_000, 2_997_000, 3_006_000])
    let keptMoved = try #require(try repository.entry(id: moved.id))
    #expect(keptMoved.transaction.rateDate == day(15))
    #expect(keptMoved.transaction.amountRubE4 == moved.transaction.amountRubE4)
    #expect(try repository.entry(id: twice.id) == refinedOnce)
  }

  /// Rates that are never refined automatically never show up as usages: the ruble, a
  /// rate entered by hand, a rate that came with an import, a deleted operation.
  @Test func onlyWhatTheRuleMayRefineIsRead() throws {
    let repository = try makeRepository()
    let refinable = try dinner()
    var manual = try dinner()
    manual.transaction.rateSource = .manual
    var imported = try dinner()
    imported.transaction.rateSource = .imported
    let deleted = try dinner()
    var rubles = try TestSupport.makeEntry()
    rubles.transaction.rateProvisional = true
    for entry in [refinable, manual, imported, deleted, rubles] { try repository.save(entry) }
    try repository.softDelete(id: deleted.id)

    #expect(try repository.provisionalUsages(calendar: calendar).map(\.id) == [refinable.id])
  }

  // MARK: Charges and refunds

  /// What a ruble card was charged is the operation's rubles: refined with the rate, it stays
  /// them. A charge typed from the statement gave a rate of its own and is never refined.
  @Test func aRubleChargeFollowsTheRate() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    try ReferenceRepository(writer: stack.writer).save(card)
    let repository = TransactionRepository(writer: stack.writer)
    var entry = try dinner()
    entry.transaction.paymentMethodId = card.id
    entry.transaction.accountCurrency = .rub
    entry.transaction.accountAmountE4 = entry.transaction.amountRubE4
    try repository.save(entry)

    #expect(try refine(repository, through: 17) == 1)
    let stored = try #require(try repository.entry(id: entry.id))
    #expect(stored.transaction.amountRubE4 == AmountE4(whole: 820))
    #expect(stored.transaction.accountCurrency == .rub)
    #expect(stored.transaction.accountAmountE4 == AmountE4(whole: 820))
  }

  /// A refund taken back from a purchase keeps the purchase's rate: it is never refined by the
  /// rate of its own day, and follows the purchase when that is refined.
  @Test func aRefundFollowsItsPurchase() throws {
    let repository = try makeRepository()
    let purchase = try dinner()
    try repository.save(purchase)
    let jacket = purchase.parts[0]
    var draft = TransactionDraft(
      kind: .refund, occurredAt: purchase.transaction.occurredAt.addingTimeInterval(86_400),
      currency: .usd, amount: jacket.amountE4, rate: purchase.transaction.rate,
      rateDate: purchase.transaction.rateDate, rateSource: purchase.transaction.rateSource,
      rateProvisional: true)
    draft.parts = [PartDraft(amount: jacket.amountE4, refundOfPartId: jacket.id)]
    let refund = try draft.materialize(rublesConverter: { _ in jacket.amountRubE4 })
    try repository.save(refund)
    #expect(try repository.provisionalUsages(calendar: calendar).map(\.id) == [purchase.id])

    #expect(try refine(repository, through: 17) == 1)
    let refinedPurchase = try #require(try repository.entry(id: purchase.id))
    let refinedRefund = try #require(try repository.entry(id: refund.id))
    #expect(refinedRefund.transaction.rate == refinedPurchase.transaction.rate)
    #expect(refinedRefund.transaction.rateDate == day(17))
    #expect(!refinedRefund.transaction.rateProvisional)
    #expect(refinedRefund.parts[0].amountRubE4 == refinedPurchase.parts[0].amountRubE4)
    #expect(refinedRefund.transaction.amountRubE4 == refinedPurchase.parts[0].amountRubE4)
  }
}
