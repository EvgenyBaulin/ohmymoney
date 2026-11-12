import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Namesakes offer choices without changing either record")
struct NamesakeTests {
  private let first = SchedFx.id(1)
  private let second = SchedFx.id(2)
  private let third = SchedFx.id(3)

  @Test func comparisonUsesNameKeyAndExcludesSelfAndOtherKinds() {
    let own = NamesakeRecord(kind: .expectedIncome, id: first, name: "Ёлка")
    let other = NamesakeRecord(kind: .expectedIncome, id: second, name: " елка ")
    let payment = NamesakeRecord(kind: .scheduledPayment, id: third, name: "Ёлка")
    #expect(Namesakes.proposals(for: own, among: [own, other, payment]).map(\.existing) == [other])
    let income = ExpectedIncome(id: first, name: own.name, totalE4: .zero)
    let advance = ExpectedIncome(id: second, name: other.name, totalE4: .zero)
    #expect(ExpectedIncomeRules.namesakes(among: [income, advance]) == [first, second])
    #expect(
      ExpectedIncomeRules.namesakes(among: [
        ExpectedIncome(id: first, name: " ", totalE4: .zero),
        ExpectedIncome(id: second, name: "", totalE4: .zero),
      ]).isEmpty)
    #expect(
      Namesakes.proposals(
        for: NamesakeRecord(kind: .goal, id: first, name: "  "),
        among: [NamesakeRecord(kind: .goal, id: second, name: "")]
      ).isEmpty)
    #expect(
      Namesakes.proposals(
        for: NamesakeRecord(kind: .goal, id: first, name: "A B"),
        among: [NamesakeRecord(kind: .goal, id: second, name: "A  B")]
      ).isEmpty)
  }

  @Test func liveNamesakesOfferRenamingEitherRecordAndNeverMutateThem() throws {
    let own = NamesakeRecord(kind: .goal, id: first, name: "Trip")
    let other = NamesakeRecord(kind: .goal, id: second, name: "trip")
    let proposal = try #require(Namesakes.proposals(for: own, among: [other]).first)
    #expect(proposal.choices == [.renameNew, .renameExisting])
    #expect(proposal.archivedName(locale: Locale(identifier: "en")) == nil)
    #expect(proposal.existing == other)
  }

  @Test func archivedNamesakesUseOnlyTheFirstAndLastHistoryMonths() throws {
    let own = NamesakeRecord(kind: .expectedIncome, id: first, name: "Project")
    let history = ["2026-03", "2024-11", "2026-03", "2025-01"].compactMap(MonthKey.init(iso:))
    let other = NamesakeRecord(
      kind: .expectedIncome, id: second, name: "Project",
      archived: true, history: history)
    let proposal = try #require(Namesakes.proposals(for: own, among: [other]).first)
    #expect(proposal.choices == [.renameArchived, .restoreArchived])
    #expect(
      proposal.archivedName(locale: Locale(identifier: "en"))
        == "Project (Nov 2024 – Mar 2026)")
    #expect(
      proposal.archivedName(locale: Locale(identifier: "ru"))
        == "Project (нояб. 2024 – март 2026)")
  }

  @Test func oneHistoryMonthIsWrittenOnceAndNoHistoryDoesNotInventADate() throws {
    let month = MonthKey(year: 2026, month: 5)
    #expect(
      NameHistoryPeriod(months: [month, month])?.title(locale: Locale(identifier: "en"))
        == "May 2026")
    #expect(
      NameHistoryPeriod(months: [month])?.title(locale: Locale(identifier: "ru"))
        == "май 2026")
    let own = NamesakeRecord(kind: .person, id: first, name: "Alex")
    let other = NamesakeRecord(kind: .person, id: second, name: "Alex", archived: true)
    let proposal = try #require(Namesakes.proposals(for: own, among: [other]).first)
    #expect(proposal.archivedName(locale: Locale(identifier: "en")) == nil)
    #expect(proposal.choices == [.renameArchived, .restoreArchived])
  }

  @Test func dismissalIsSymmetricPersistentAndSpecificToTwoIdentities() throws {
    let own = NamesakeRecord(kind: .expectedIncome, id: first, name: "Salary")
    let other = NamesakeRecord(kind: .expectedIncome, id: second, name: "Salary")
    let another = NamesakeRecord(kind: .expectedIncome, id: third, name: "Salary")
    let pair = Namesakes.pairKey(own, other)
    #expect(pair == Namesakes.pairKey(other, own))
    let stored = Namesakes.hiding(pair, in: "")
    #expect(Namesakes.hiding(pair, in: stored) == stored)
    #expect(
      Namesakes.proposals(for: own, among: [other, another], hidden: stored)
        .map(\.existing.id) == [third])
    #expect(Namesakes.proposals(for: other, among: [own], hidden: stored).isEmpty)
    let both = Namesakes.hiding(Namesakes.pairKey(own, another), in: stored)
    #expect(Namesakes.proposals(for: own, among: [other, another], hidden: both).isEmpty)
    let goal = NamesakeRecord(kind: .goal, id: first, name: "Salary")
    let goalOther = NamesakeRecord(kind: .goal, id: second, name: "Salary")
    #expect(Namesakes.proposals(for: goal, among: [goalOther], hidden: stored).count == 1)
  }
}

@Suite("Dictionary records are namesake candidates with real history")
struct ReferenceNamesakeTests {
  private func entry(_ n: Int, _ day: String, goalCategory: UUID? = nil, place: UUID? = nil)
    -> TransactionEntry
  {
    SchedFx.operation(n, day, "10", category: goalCategory, place: place)
  }

  @Test func goalsAndPlacesTakeHistoryFromOperationsAndNeverFromToday() {
    let category = SchedFx.id(50)
    let goal = Goal(name: "Trip", targetE4: .zero, subcategoryId: category, archived: true)
    let bare = Goal(name: "Trip", targetE4: .zero)
    let records = Namesakes.goals(
      [goal, bare],
      entries: [entry(1, "2024-02-03", goalCategory: category), entry(2, "2025-05-01", goalCategory: category)],
      calendar: .utc)
    #expect(records[0].archived)
    #expect(records[0].period?.first == SchedFx.day("2024-02-03").monthKey)
    #expect(records[0].period?.last == SchedFx.day("2025-05-01").monthKey)
    #expect(records[1].period == nil)
    let place = Place(name: "Cafe")
    let places = Namesakes.places(
      [place], entries: [entry(3, "2026-01-01", place: place.id)], calendar: .utc)
    #expect(places[0].kind == .place)
    #expect(places[0].period?.first == SchedFx.day("2026-01-01").monthKey)
  }

  @Test func eventsUseTheirDaysAndDeletedOperationsAreIgnored() {
    let event = Event(
      name: "Trip", startDate: SchedFx.day("2025-03-30"), endDate: SchedFx.day("2025-04-02"),
      archived: true)
    let record = Namesakes.events([event])[0]
    #expect(record.period?.first == SchedFx.day("2025-03-30").monthKey)
    #expect(record.period?.last == SchedFx.day("2025-04-02").monthKey)
    let place = Place(name: "Cafe")
    let gone = SchedFx.operation(4, "2024-01-01", "10", place: place.id, deleted: true)
    #expect(Namesakes.places([place], entries: [gone], calendar: .utc)[0].period == nil)
  }

  @Test func twoLiveRecordsOfAnyKindProposeRenamingAndArchivedOnesRestoring() throws {
    let live = NamesakeRecord(kind: .person, id: SchedFx.id(1), name: "Anna")
    let archived = NamesakeRecord(
      kind: .person, id: SchedFx.id(2), name: "anna", archived: true,
      history: [SchedFx.day("2024-01-01").monthKey])
    let proposals = Namesakes.proposals(
      for: NamesakeRecord(kind: .person, id: SchedFx.id(3), name: "ANNA"), among: [live, archived])
    #expect(proposals.count == 2)
    #expect(proposals.map(\.choices) == [[.renameNew, .renameExisting], [.renameArchived, .restoreArchived]])
  }
}
