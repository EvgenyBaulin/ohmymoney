import Foundation
import Testing

@testable import CoreKit

/// The limit of a «small purchase» as the table `settings` keeps it.
@Suite("The settings of the tiles of Overview")
struct OverviewSettingsTests {
  @Test func theKeyIsStable() {
    #expect(OverviewSettings.smallPurchaseLimitKey == "overview.smallPurchaseLimit")
  }

  @Test func aStoredLimitIsWholeRubles() {
    #expect(OverviewSettings.smallPurchaseLimit(from: "300") == AmountE4(whole: 300))
    #expect(OverviewSettings.smallPurchaseLimit(from: " 1500 ") == AmountE4(whole: 1_500))
  }

  @Test func noLimitIsNotASmallPurchase() {
    #expect(OverviewSettings.smallPurchaseLimit(from: nil) == nil)
    #expect(OverviewSettings.smallPurchaseLimit(from: "") == nil)
    #expect(OverviewSettings.smallPurchaseLimit(from: "0") == nil)
    #expect(OverviewSettings.smallPurchaseLimit(from: "-5") == nil)
    #expect(OverviewSettings.smallPurchaseLimit(from: "ten") == nil)
    #expect(OverviewSettings.smallPurchaseLimit(from: "12.5") == nil)
  }

  @Test func aTypingSlipIsNoLimit() {
    #expect(OverviewSettings.smallPurchaseLimit(from: "1000000") != nil)
    #expect(OverviewSettings.smallPurchaseLimit(from: "1000001") == nil)
  }

  @Test func theTextToStoreRoundTrips() {
    #expect(OverviewSettings.text(forSmallPurchaseLimit: 450) == "450")
    #expect(OverviewSettings.text(forSmallPurchaseLimit: nil) == "")
    #expect(OverviewSettings.text(forSmallPurchaseLimit: 0) == "")
    #expect(OverviewSettings.text(forSmallPurchaseLimit: 2_000_000) == "")
    for whole in [1, 99, 500, 25_000] as [Int64] {
      let text = OverviewSettings.text(forSmallPurchaseLimit: whole)
      #expect(OverviewSettings.smallPurchaseLimit(from: text) == AmountE4(whole: whole))
    }
  }
}
