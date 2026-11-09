import Foundation
import Testing

@testable import CoreKit

@Suite("Free sum horizon settings compatibility")
struct FreeMoneyHorizonTests {
  @Test func olderEncodedSettingsKeepTheNewDefault() throws {
    let data = try JSONEncoder().encode(PlanningSettings())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "freeMoneyHorizonChoice")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(
      try JSONDecoder().decode(PlanningSettings.self, from: legacy).freeMoneyHorizon == .thirtyDays)
  }

  @Test(arguments: FreeMoneyHorizon.allCases)
  func theChoiceSurvivesEncoding(_ horizon: FreeMoneyHorizon) throws {
    let settings = PlanningSettings(freeMoneyHorizon: horizon)
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(PlanningSettings.self, from: data) == settings)
  }
}
