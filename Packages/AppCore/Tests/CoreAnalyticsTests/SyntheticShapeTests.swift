import CoreAccounting
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// A two-year synthetic history carries every case the rules of Overview, Analytics and
/// Reports have, and writes the reimbursements the way the app writes them.
@Suite("Synthetic history: every case the rules need is there")
struct SyntheticShapeTests {
  let set: SampleDataSet
  let ledger: Ledger
  let tree: CategoryTree
  let alive: [TransactionEntry]
  let parts: [(part: TransactionPart, entry: TransactionEntry)]

  init() throws {
    (set, ledger) = try Synthetic.load(.twoYears)
    tree = CategoryTree(set.categories)
    alive = set.entries.filter { !$0.transaction.isDeleted }
    parts = alive.flatMap { entry in entry.parts.map { ($0, entry) } }
  }

  private func category(_ english: String, _ kind: CategoryKind = .expense) -> UUID? {
    guard
      let index = SampleCatalog.categorySeeds.firstIndex(where: {
        $0.english == english && $0.kind == kind
      })
    else { return nil }
    return set.categories[index].id
  }

  private func row(of partId: UUID) -> LedgerRow? {
    ledger.rows.first { $0.partId == partId }
  }

  @Test func theWholeStarterTreeWithItsSystemCategories() {
    for (index, seed) in SampleCatalog.categorySeeds.enumerated() {
      #expect(set.categories[index].systemRole == seed.systemRole)
      #expect(set.categories[index].kind == seed.kind)
    }
    for role in SystemRole.allCases {
      #expect(set.categories.filter { $0.systemRole == role }.count >= 1, "\(role)")
    }
    for kind in CategoryKind.allCases {
      let roles = set.categories.filter { $0.kind == kind }.compactMap(\.systemRole)
      #expect(roles.count == Set(roles).count, "one category per system role and kind")
    }
  }

  @Test func operationsComeOldestFirst() {
    let moments = set.entries.map(\.transaction.occurredAt)
    #expect(moments == moments.sorted())
  }

  /// Fines and fees are bad by their category; bars sit in a neutral category and every
  /// evening there is rated bad by hand.
  @Test func badSpending() {
    let fines = parts.filter { $0.part.categoryId == category("Fines") }
    #expect(fines.contains { $0.part.quality == .bad && $0.part.qualitySource == .category })
    let fees = parts.filter { $0.part.categoryId == category("Fees") && $0.part.quality != nil }
    #expect(fees.contains { $0.part.quality == .bad })
    let bars = parts.filter { $0.part.categoryId == category("Bars") }
    #expect(!bars.isEmpty)
    #expect(bars.allSatisfy { $0.part.quality == .bad && $0.part.qualitySource == .manual })
    #expect(tree.effectiveQuality(of: category("Bars")) != .bad)
  }

  /// A second part of a split with no stored quality: the rules rate it, and one in
  /// Other → Fees comes out bad.
  @Test func splitPartsWithoutAStoredQuality() throws {
    let unrated = alive.filter { $0.parts.count > 1 }
      .flatMap { $0.parts.dropFirst() }
      .filter { $0.quality == nil }
    #expect(!unrated.isEmpty)
    let fee = try #require(unrated.first { $0.categoryId == category("Fees") })
    #expect(row(of: fee.id)?.quality == .bad)
    #expect(unrated.contains { $0.categoryId == category("Household") })
  }

  @Test func purchasesForMyPartnerMyFamilyAndParticularPeople() {
    let others = parts.map(\.part).filter { !$0.reimbursable }
    #expect(others.contains { $0.forWhom == .partner && $0.forPersonId != nil })
    #expect(others.contains { $0.forWhom == .family && $0.forPersonId != nil })
    #expect(others.contains { $0.forWhom == .family && $0.forPersonId == nil })
    #expect(others.contains { $0.forWhom == .friends && $0.forPersonId != nil })
  }

  @Test func partsPaidForOthersInEveryState() {
    let owed = parts.filter { $0.entry.transaction.kind == .expense && $0.part.reimbursable }
    for status in ReimbursementStatus.allCases {
      #expect(owed.contains { $0.part.reimbursementStatus == status }, "\(status)")
    }
    // In dollars, for a friend abroad, and returned.
    #expect(
      owed.contains {
        $0.entry.transaction.currency == .usd && $0.part.reimbursementStatus == .returned
          && $0.part.eventId != nil
      })
    // Several parts closed by one reimbursement.
    let linksPerReimbursement = Dictionary(grouping: set.links, by: \.reimbursementTxId)
    #expect(linksPerReimbursement.values.contains { $0.count > 1 })
    // Every returned part is linked, never for more than it cost in rubles.
    let linked = Dictionary(grouping: set.links, by: \.partId)
    for (part, _) in owed where part.reimbursementStatus == .returned {
      let links = linked[part.id] ?? []
      #expect(!links.isEmpty)
      #expect(AmountE4.sum(links.map(\.amountE4)) <= part.amountRubE4)
    }
  }

  /// What a reimbursement leaves behind is what `ReimbursementResolver` makes of it — the
  /// core the app's sheet (`ReimbursementRecording`) runs — spread oldest first over the
  /// rubles of the parts: the links, a surplus in Surcharges and a shortfall per part, both
  /// keyed back to the reimbursement; the shortfall with the purchase's category,
  /// description, «for whom», person and event, rated by the usual rules.
  @Test func reimbursementsAreWrittenTheWayTheAppWritesThem() throws {
    let history = ManualQualityHistory(entries: set.entries)
    let partsById = Dictionary(parts.map { ($0.part.id, $0) }, uniquingKeysWith: { a, _ in a })
    let byKey = Dictionary(
      alive.compactMap { entry in entry.transaction.externalId.map { ($0, entry) } },
      uniquingKeysWith: { a, _ in a })
    let reimbursements = alive.filter { $0.transaction.kind == .reimbursement }
    #expect(reimbursements.count > 10)
    var surpluses = 0
    var shortfalls = 0

    for reimbursement in reimbursements {
      let transaction = reimbursement.transaction
      #expect(transaction.currency == .rub)
      #expect(transaction.placeId == nil && transaction.paymentMethodId == nil)
      let payback = try #require(reimbursement.parts.first)
      #expect(reimbursement.parts.count == 1)
      #expect(payback.categoryId == nil && payback.quality == nil)

      let links = set.links.filter { $0.reimbursementTxId == transaction.id }
      let owed = try links.map { link in
        let found = try #require(partsById[link.partId])
        return OwedPart(part: found.part, in: found.entry.transaction).inRubles
      }
      #expect(Set(owed.map(\.debtorPersonId)) == [payback.forPersonId])
      let outcome = try ReimbursementResolver.resolve(
        reimbursementTxId: transaction.id, amountE4: transaction.amountE4, closing: owed)
      #expect(
        Set(outcome.links.map { "\($0.partId) \($0.amountE4.raw)" })
          == Set(links.map { "\($0.partId) \($0.amountE4.raw)" }))

      let surplus = byKey[ReimbursementCompanions.surplusKey(of: transaction.id)]
      #expect(surplus?.transaction.amountE4 == outcome.surplus?.amountE4)
      if let surplus {
        surpluses += 1
        #expect(surplus.transaction.kind == .income)
        #expect(surplus.transaction.occurredAt == transaction.occurredAt)
        #expect(tree.systemRole(of: surplus.parts.first?.categoryId) == .surcharges)
      }

      let prefix = ReimbursementCompanions.keyPrefix(of: transaction.id)
      let companions = byKey.keys.filter { $0.hasPrefix(prefix) }
      #expect(companions.count == outcome.shortfalls.count + (outcome.surplus == nil ? 0 : 1))
      for expected in outcome.shortfalls {
        let key = ReimbursementCompanions.shortfallKey(of: transaction.id, partId: expected.partId)
        let entry = try #require(byKey[key])
        let part = try #require(entry.parts.first)
        let purchase = try #require(owed.first { $0.partId == expected.partId })
        shortfalls += 1
        #expect(entry.transaction.kind == .expense && entry.transaction.currency == .rub)
        #expect(entry.transaction.amountE4 == expected.amountE4)
        #expect(entry.transaction.occurredAt == transaction.occurredAt)
        #expect(entry.transaction.note == purchase.note)
        #expect(part.categoryId == expected.categoryId && part.categorySource == .system)
        #expect(part.forWhom == expected.forWhom)
        #expect(part.forPersonId == (purchase.forPersonId ?? purchase.debtorPersonId))
        #expect(part.eventId == purchase.eventId)
        #expect(!part.reimbursable && part.debtorPersonId == nil)
        let rated = QualityResolver.resolve(
          categoryId: expected.categoryId, description: purchase.note, categories: tree,
          history: history)
        #expect(part.quality == rated.quality && part.qualitySource == rated.source)
      }
    }
    #expect(surpluses > 0)
    #expect(shortfalls > 0)
  }

  /// The loss on a dinner abroad stays with the friend and with the trip.
  @Test func aShortfallStaysWithTheFriendAndTheTrip() throws {
    let trips = Set(set.events.filter { $0.kind == .trip }.map(\.id))
    let shortfalls = alive.filter { $0.transaction.externalId?.contains(":shortfall:") == true }
    let abroad = try #require(shortfalls.first { trips.contains($0.parts[0].eventId ?? UUID()) })
    #expect(abroad.parts[0].forPersonId != nil)
    let people = ForWhomReport(
      ledger: ledger, period: .days(DayRange(set.firstDay, set.lastDay))
    ).people
    let person = try #require(abroad.parts[0].forPersonId)
    #expect(people.contains { $0.key == .person(person) })
  }

  @Test func aRefundOfABadPurchase() {
    let refunds = parts.filter { $0.entry.transaction.kind == .refund }
    #expect(
      refunds.contains {
        row(of: $0.part.id)?.quality == .bad
          && (row(of: $0.part.id)?.contribution.isNegative ?? false)
      })
  }

  /// Tickets for a friend and me that the friend paid back, then the concert is cancelled
  /// and both come back to my card. My ticket's refund takes my spending back; the friend's
  /// is a part paid for somebody else, whose refund takes nothing off it.
  @Test func aRefundOfAPartPaidForSomebodyElse() throws {
    let theirs = try #require(
      parts.first { $0.entry.transaction.kind == .refund && $0.part.reimbursable })
    let debtor = try #require(theirs.part.debtorPersonId)
    #expect(row(of: theirs.part.id)?.contribution == .zero)
    let mine = try #require(theirs.entry.parts.first { !$0.reimbursable })
    #expect(row(of: mine.id)?.contribution == -mine.amountRubE4)
    // The purchase it takes back, whose part for the friend was paid back before.
    #expect(
      parts.contains {
        $0.entry.transaction.kind == .expense && $0.part.debtorPersonId == debtor
          && $0.part.reimbursementStatus == .returned
          && $0.part.amountRubE4 == theirs.part.amountRubE4
          && $0.part.categoryId == theirs.part.categoryId
          && $0.entry.transaction.occurredAt < theirs.entry.transaction.occurredAt
      })
  }

  @Test func cashbackOnTwoCards() {
    let cashback = alive.filter {
      $0.transaction.kind == .income && $0.parts.first?.categoryId == set.cashbackCategoryId
    }
    #expect(Set(cashback.compactMap(\.transaction.paymentMethodId)).count >= 2)
  }

  /// Salary paid on the 1st–3rd belongs to the month before.
  @Test func incomeForThePreviousMonth() {
    #expect(
      alive.contains { entry in
        let day = Synthetic.calendar.day(of: entry.transaction.occurredAt)
        return entry.transaction.kind == .income && day.day <= 3
          && entry.transaction.periodMonth == day.monthKey.previous
      })
  }

  /// A loan whose payments are my expenses in Loans, each with its line in the journal; and
  /// a phone bought in instalments: the purchase is the expense, the payments are not.
  @Test func aLoanAndAnInstalmentPurchase() throws {
    let loan = try #require(set.debts.first { $0.origin == .existing })
    #expect(DebtRules.paymentIsExpense(on: loan))
    let loanPayments = alive.filter { $0.transaction.debtId == loan.id }
    #expect(loanPayments.count >= 20)
    for payment in loanPayments {
      #expect((row(of: payment.parts[0].id)?.contribution.raw ?? 0) > 0)
      #expect(tree.isLoanCategory(payment.parts[0].categoryId))
      #expect(set.debtEntries.contains { $0.transactionId == payment.id && $0.kind == .payment })
    }

    let phone = try #require(set.debts.first { $0.origin == .purchase })
    #expect(!DebtRules.paymentIsExpense(on: phone))
    let purchase = try #require(alive.first { $0.transaction.creditDebtId == phone.id })
    #expect(row(of: purchase.parts[0].id)?.contribution == purchase.transaction.amountRubE4)
    let instalments = alive.filter { $0.transaction.debtId == phone.id }
    #expect(instalments.count == 6)
    #expect(instalments.allSatisfy { row(of: $0.parts[0].id)?.contribution == .zero })
    let journal = set.debtEntries.filter { $0.debtId == phone.id }
    #expect(DebtRules.balance(entries: journal) == .zero)
  }

  @Test func goalContributions() throws {
    let goal = try #require(set.goals.first)
    let contributions = parts.map(\.part).filter { $0.goalId == goal.id }
    #expect(contributions.count >= 12)
    #expect(contributions.allSatisfy { $0.categoryId == goal.subcategoryId })
    #expect(contributions.allSatisfy { $0.quality == .good && $0.qualitySource == .system })
  }

  /// Birthdays and New Year every year, each kind in one series, each with its operations;
  /// and the same event last year is found through the series.
  @Test func eventsEveryYearInOneSeries() throws {
    for kind in [EventKind.birthday, .newYear] {
      let events = set.events.filter { $0.kind == kind }
      #expect(events.count >= 2, "\(kind)")
      #expect(Set(events.compactMap(\.seriesId)).count == 1, "\(kind)")
      #expect(Set(events.map(\.startDate.year)).count == events.count, "\(kind)")
      for event in events {
        #expect(parts.contains { $0.part.eventId == event.id }, "\(event.name)")
      }
      let last = try #require(events.max { $0.startDate < $1.startDate })
      let report = EventsReport(
        ledger: ledger, period: .days(DayRange(last.startDate, last.endDate)))
      let item = try #require(report.events.first { $0.eventId == last.id })
      #expect(item.lastYearEventId != nil, "\(kind)")
    }
    #expect(set.events.contains { $0.kind == .trip })
  }

  /// About 1 % of the parts of purchases without a category, 0.5 % of all operations
  /// deleted — and the deleted ones never reach a figure.
  @Test func edgeCasesInProportion() {
    let purchases = parts.filter { $0.entry.transaction.kind.hasQuality }
    let uncategorized = purchases.filter { $0.part.categoryId == nil }.count
    #expect(uncategorized * 1_000 >= purchases.count * 5)
    #expect(uncategorized * 1_000 <= purchases.count * 20)
    let deleted = set.entries.filter(\.transaction.isDeleted)
    #expect(deleted.count * 1_000 >= set.entries.count * 4)
    #expect(deleted.count * 1_000 <= set.entries.count * 6)
    let ids = Set(ledger.rows.map(\.transactionId))
    #expect(deleted.allSatisfy { !ids.contains($0.id) })
  }

  /// The cases every history must have are written on fixed days at its start, so the month
  /// `make sample` opens on — the last one — is an ordinary month. The first live run (on
  /// 18 September, the sample of this very seed) showed «Uncategorized» at 10.9 % of that
  /// month; the sample's own part of it is a fraction of a percent, the rest was typed by hand
  /// into the entry line, which files a description it does not know without a category.
  @Test func theMonthTheSampleOpensOnIsAnOrdinaryOne() throws {
    let (set, ledger) = try Synthetic.load(SyntheticCase(seed: 20_260_918, months: 6))
    let firstMonth = set.firstDay.monthKey
    let concert = try #require(
      set.entries.first { $0.transaction.note == "Concert cancelled" }, "the fixed-day refund")
    #expect(Synthetic.calendar.day(of: concert.transaction.occurredAt).monthKey == firstMonth)
    let written = set.entries.filter { entry in
      entry.parts.contains { $0.reimbursementStatus == .writtenOff }
    }
    #expect(
      written.contains {
        Synthetic.calendar.day(of: $0.transaction.occurredAt).monthKey == firstMonth
      })

    let span = Period.monthToDate(today: set.lastDay).range
    let spending = ledger.rows(in: span).filter { !$0.contribution.isZero }
    let total = AmountE4.sum(spending.map(\.contribution))
    let uncategorized = AmountE4.sum(
      spending.filter { $0.rootCategoryId == nil }.map(\.contribution))
    #expect(total.raw > 0)
    #expect(uncategorized.raw * 100 < total.raw, "under 1 % of the month without a category")
  }
}
