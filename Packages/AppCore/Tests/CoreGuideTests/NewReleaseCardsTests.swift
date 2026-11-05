import Foundation
import Testing

@testable import CoreGuide

@Suite("What is new in 2.9 to 2.13.1")
struct NewReleaseCardsTests {
  @Test func everyVersionOfTheReleaseHasCards() {
    for (scenario, minor) in [
      (GuideCatalog.whatsNew29, 9), (GuideCatalog.whatsNew211, 11), (GuideCatalog.whatsNew213, 13),
    ] {
      #expect(scenario.kind == .whatsNew(version: GuideVersion(major: 2, minor: minor)))
      #expect(!scenario.cards.isEmpty)
      #expect(GuideCatalog.whatsNew.contains { $0.id == scenario.id })
      for card in scenario.cards {
        #expect(card.title.isComplete && card.body.isComplete, "\(card.id)")
        #expect(!card.symbol.isEmpty, "\(card.id)")
      }
    }
  }

  @Test func theNewNavigationHasACard() {
    #expect(GuideCatalog.whatsNew213.cards.contains { $0.id == "new213.navigation" })
  }

  @Test func ownerUpdatingFrom27SeesEachVersionOnce() {
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "2.8.0")
    let due = progress.whatsNewDue(current: "2.13.1", catalog: GuideCatalog.whatsNew).map(\.id)
    #expect(due == ["whatsNew.2.9", "whatsNew.2.11", "whatsNew.2.13"])
  }

  @Test func theWalkReachesTheLastThreeSectionsWithTheirKeys() throws {
    let steps = try #require(GuideWalkthrough.whereToClick()).steps
    let keys = Dictionary(uniqueKeysWithValues: steps.map { ($0.target, $0.keys) })
    #expect(keys[GuideTarget.sidebarPurchases] == "⌘7")
    #expect(keys[GuideTarget.sidebarAnalytics] == "⌘8")
    #expect(keys[GuideTarget.sidebarReports] == "⌘9")
  }
}
