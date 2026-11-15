import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Monthly income and money already on accounts have different meanings")
struct CanSaveMessageTests {
  private func savings() -> CanSave {
    CanSave(
      CanSaveInputs(
        income: MonthIncomeEstimate(
          month: MonthKey(year: 2026, month: 11), received: AmountE4(whole: 64_066),
          expectedRemaining: .zero, median3: nil, monthsInMedian: 0,
          value: AmountE4(whole: 64_066), source: .receivedOnly, lowData: false),
        spentWithoutGoals: AmountE4(whole: 152_269), plannedStillDue: .zero,
        remainder: ForecastFx.noSpending, alreadySaved: .zero))
  }

  @Test func positiveFreeMoneyExplainsPreviousMoney() {
    let message = savings().message(freeNow: AmountE4(whole: 64_415))
    #expect(
      message
        == .incomeDeficit(
          month: MonthKey(year: 2026, month: 11), amount: AmountE4(whole: 88_203),
          previousMoney: AmountE4(whole: 64_415)))
  }

  @Test func zeroFreeMoneyDoesNotClaimThereArePreviousMoney() {
    #expect(
      savings().message(freeNow: .zero)
        == .incomeDeficit(
          month: MonthKey(year: 2026, month: 11), amount: AmountE4(whole: 88_203),
          previousMoney: nil))
  }

  @Test func negativeOrUnknownFreeMoneyKeepsTheShortageExplanation() {
    #expect(savings().message(freeNow: AmountE4(whole: -1)) == .forecast)
    #expect(savings().message(freeNow: nil) == .forecast)
  }

  @Test func forecastDeficitDoesNotPretendToBeRecordedOverspending() {
    var savings = savings()
    savings.spentWithoutGoals = .zero
    #expect(
      savings.message(freeNow: .zero)
        == .projectedDeficit(
          month: MonthKey(year: 2026, month: 11), amount: AmountE4(whole: 88_203),
          previousMoney: nil))
  }

  @Test(arguments: ["ru", "en"])
  func monthlyDeficitCatalogWordsAreExact(_ language: String) throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let catalog = root.appendingPathComponent("Apps/macOS/Resources/Strings/Planning.xcstrings")
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: catalog))
        as? [String: Any])
    let strings = try #require(json["strings"] as? [String: Any])
    func words(_ key: String) throws -> String {
      let entry = try #require(strings[key] as? [String: Any])
      let localizations = try #require(entry["localizations"] as? [String: Any])
      let localized = try #require(localizations[language] as? [String: Any])
      let unit = try #require(localized["stringUnit"] as? [String: Any])
      return try #require(unit["value"] as? String)
    }
    for available in [Int64(64_415), 0, -1] {
      switch savings().message(freeNow: AmountE4(whole: available)) {
      case .incomeDeficit(let month, let amount, let previous):
        #expect(amount == AmountE4(whole: 88_203))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        let monthName = formatter.monthSymbols[month.month - 1]
        let text = String(
          format: try words("overview.canSave.incomeDeficit"), monthName, "88 203 ₽")
        #expect(
          text
            == (language == "ru"
              ? "Из дохода ноября отложить не получится: траты больше дохода на 88 203 ₽"
              : "You cannot save from November income: spending exceeds income by 88 203 ₽"))
        if previous != nil {
          let detail = String(format: try words("overview.canSave.previousMoney"), "64 415 ₽")
          #expect(
            detail
              == (language == "ru"
                ? "на счетах свободно 64 415 ₽ — это прошлые деньги"
                : "64 415 ₽ is free on your accounts — this is money from earlier months"))
        }
      case .forecast:
        #expect(available < 0)
        let shortage = try words("overview.canSave.shortfall")
        #expect(shortage.contains(language == "ru" ? "Не хватает" : "Short by"))
      default:
        Issue.record("Expected a recorded income deficit or a true money shortage")
      }
    }
  }
}
