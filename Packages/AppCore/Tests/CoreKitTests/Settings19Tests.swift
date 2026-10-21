import Foundation
import Testing

@testable import CoreKit

/// The settings of self-employment, of the allocation of income and of the debts: what is
/// written reads back, nothing written is the default, and a value only a hand edit leaves
/// keeps the default.
@Suite("The settings the credits and the allocation keep in the database")
struct Settings19Tests {
  /// Turns the rows to write into the rows the table keeps: a `nil` deletes its key.
  private func stored(_ values: [String: String?]) -> [String: String] {
    values.compactMapValues { $0 }
  }

  @Test func nothingWrittenIsTheDefault() {
    #expect(SelfEmploymentSettings(storedValues: [:]) == .standard)
    #expect(AllocationSettings(storedValues: [:]) == .standard)
    #expect(DebtSettings(storedValues: [:]) == .standard)
    #expect(SelfEmploymentSettings.standard.reference == .law)
    #expect(stored(SelfEmploymentSettings.standard.storedValues).isEmpty)
    #expect(stored(AllocationSettings.standard.storedValues).isEmpty)
    #expect(stored(DebtSettings.standard.storedValues).isEmpty)
  }

  @Test func theLawAsTheAppKnowsIt() {
    let law = NPDReference.law
    #expect(law.individualsRate == 4 && law.organizationsRate == 6)
    #expect(law.individualsCut == 1 && law.organizationsCut == 2)
    #expect(law.deductionTotalE4 == AmountE4(whole: 10_000))
    #expect(law.yearLimitE4 == AmountE4(whole: 2_400_000))
    #expect(law.dueDay == 28 && law.remindDaysBefore == 3)
    #expect(law.minimumTaxE4 == AmountE4(whole: 100))
  }

  @Test func selfEmploymentReadsBackWhatIsWritten() {
    let settings = SelfEmploymentSettings(
      enabled: true, offered: true, deductionLeftE4: AmountE4(raw: 73_451_234),
      deductionLeftOn: DateOnly(year: 2026, month: 10, day: 12), taxAccountId: UUID(),
      taxCategoryId: UUID(), returnCategoryId: UUID(),
      overrides: NPDOverrides(
        individualsRate: Decimal(string: "3.5"), dueDay: 25, minimumTaxE4: AmountE4(whole: 50)))
    let back = SelfEmploymentSettings(storedValues: stored(settings.storedValues))
    #expect(back == settings)
    #expect(back.reference.individualsRate == Decimal(string: "3.5"))
    #expect(back.reference.organizationsRate == 6)
    #expect(back.reference.dueDay == 25)
    #expect(Set(settings.storedValues.keys) == Set(SelfEmploymentSettings.storageKeys))
  }

  @Test func aDamagedValueKeepsTheDefault() {
    let settings = SelfEmploymentSettings(storedValues: [
      SelfEmploymentSettings.enabledKey: "maybe",
      SelfEmploymentSettings.deductionLeftKey: "-5",
      SelfEmploymentSettings.deductionLeftOnKey: "2026-02-30",
      SelfEmploymentSettings.taxAccountKey: "not an id",
      SelfEmploymentSettings.individualsRateKey: "150",
      SelfEmploymentSettings.dueDayKey: "40",
    ])
    #expect(settings == .standard)
    let debts = DebtSettings(storedValues: [
      DebtSettings.ladderExtraKey: "lots", DebtSettings.nudgeTemplateKey: "  \n",
      DebtSettings.ladderAccountsOutKey: "x, 00000000-0000-0000-0000-000000000000",
    ])
    #expect(debts.ladderExtraE4 == nil && debts.nudgeTemplate == nil)
    #expect(debts.ladderAccountsOut == [UUID(uuidString: "00000000-0000-0000-0000-000000000000")!])
    let allocation = AllocationSettings(storedValues: [
      AllocationSettings.monthRestTargetKey: "goal:nothing",
      AllocationSettings.monthRestDoneKey: "2026-10-01",
    ])
    #expect(allocation == .standard)
  }

  @Test func theAllocationAndTheDebtsReadBackWhatIsWritten() {
    let goal = UUID()
    let allocation = AllocationSettings(
      earningsCategoryId: UUID(), cushionAccountId: UUID(), monthRestTarget: .goal(goal),
      monthRestDone: MonthKey(year: 2026, month: 9), declined: [UUID(), UUID()])
    #expect(AllocationSettings(storedValues: stored(allocation.storedValues)) == allocation)
    #expect(
      allocation.storedValues[AllocationSettings.monthRestTargetKey] == "goal:\(goal.uuidString)")
    #expect(MonthRestTarget(storedValue: "cushion") == .cushion)
    let debts = DebtSettings(
      ladderExtraE4: AmountE4(whole: 15_000), ladderAccountsOut: [UUID()],
      nudgeTemplate: "{имя}, верни {сумма}", creditInterestCategoryId: UUID())
    #expect(DebtSettings(storedValues: stored(debts.storedValues)) == debts)
    #expect(debts.storedValues[DebtSettings.ladderExtraKey] == "15000")
  }

  /// A debt of the older kind has no dues every few days: what it says of its dues is as before;
  /// with steps it has dues.
  @Test func stepsGiveADebtDues() {
    let old = Debt(direction: .iOwe, type: .loan, name: "Old")
    #expect(!old.hasDues)
    #expect(!old.isInstalmentPlan && old.prepayAnyDay && !old.pledge && !old.termsReviewed)
    var plan = Debt(direction: .iOwe, type: .installment, name: "Phone", origin: .purchase)
    plan.parts = 4
    plan.steps = DebtSteps(everyDays: 14, firstDue: DateOnly(year: 2026, month: 10, day: 12))
    #expect(plan.isInstalmentPlan && plan.hasDues)
  }
}
