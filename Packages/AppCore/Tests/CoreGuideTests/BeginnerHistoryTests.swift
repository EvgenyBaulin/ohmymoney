import CoreGuide
import CoreKit
import Testing

@Suite("Beginner mode with imported history")
struct BeginnerHistoryTests {
  @Test func importedDaysUnlockAnalysisWithoutChangingTheHabitCount() {
    let facts = BeginnerFacts(
      entryDays: 0, counts: 0, debts: 0, hasLoans: false,
      today: DateOnly(year: 2026, month: 11, day: 17),
      analysisEntryDays: 30, analysisFirstEntry: DateOnly(year: 2026, month: 1, day: 1))
    #expect(BeginnerMode.unlock(.analytics, facts: facts) == nil)
    #expect(BeginnerMode.unlock(.reports, facts: facts) == nil)
    #expect(BeginnerMode.unlock(.debts, facts: facts) == .entryDays(needed: 7, have: 0))
    #expect(BeginnerMode.unlock(.capital, facts: facts) == .firstCount)
  }

  @Test func onlyAnEmptyBookStartsInBeginnerMode() {
    #expect(BeginnerMode.startsEnabled(hasOperations: false))
    #expect(!BeginnerMode.startsEnabled(hasOperations: true))
  }
}
