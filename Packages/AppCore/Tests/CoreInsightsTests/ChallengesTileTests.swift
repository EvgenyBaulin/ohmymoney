import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// The breakdown of the tile «Челленджи». Synthetic challenges and no operations.
@Suite("Challenges tile breakdown")
struct ChallengesTileTests {
  let today = DateOnly(year: 2026, month: 11, day: 4)

  private func ledger(_ challenges: [Challenge]) -> Ledger {
    var dataset = Dataset()
    dataset.challenges = ChallengeBook(items: challenges)
    return Ledger(dataset: dataset, calendar: .utc)
  }

  @Test func withoutChallengesTheTileSaysSo() {
    let explanation = TileExplanations.challenges(ledger: ledger([]), today: today)
    #expect(explanation.tile == .challenges)
    #expect(explanation.state == .empty(TilePhrase("why.challenges.none", table: "Challenges")))
  }

  @Test func eachOpenChallengeIsALineAndFinishedOnesAreLeftOut() {
    let open = Challenge(
      title: "No delivery", kind: .avoid, start: today.adding(days: -1),
      end: today.adding(days: 5), keywords: ["x"])
    let done = Challenge(
      title: "Old", kind: .avoid, start: today.adding(days: -30), end: today.adding(days: -20),
      keywords: ["x"])
    let explanation = TileExplanations.challenges(ledger: ledger([open, done]), today: today)
    #expect(explanation.sections.first?.rows.count == 1)
    #expect(explanation.sections.first?.rows.first?.label.arguments == [.text("No delivery")])
    #expect(explanation.sections.first?.addsUp != false)
  }
}
