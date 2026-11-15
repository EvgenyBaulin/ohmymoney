import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Which challenge the tile of Overview speaks of.
@Suite("Challenges: the tile of Overview")
struct ChallengeTileTests {
  typealias F = ChallengeFixture

  private func pick(_ challenges: [Challenge], today: DateOnly) -> ChallengeTile.Pick? {
    let ledger = F.ledger([])
    return ChallengeTile.pick(
      ChallengeBook(items: challenges), ledger: ledger, planning: .empty, today: today)
  }

  private func challenge(_ title: String, _ start: DateOnly, days: Int) -> Challenge {
    Challenge(
      title: title, kind: .avoid, start: start, end: start.adding(days: days - 1),
      keywords: ["x"])
  }

  @Test("a running challenge wins over one that has not begun")
  func runningFirst() {
    let running = challenge("Now", F.day(11, 2), days: 7)
    let later = challenge("Later", F.day(11, 20), days: 7)
    let found = pick([later, running], today: F.day(11, 4))
    #expect(found?.challenge.title == "Now")
    #expect(found?.isRunning == true)
  }

  @Test("of two running, the one that ends first")
  func soonestEnd() {
    let long = challenge("Long", F.day(11, 1), days: 30)
    let short = challenge("Short", F.day(11, 1), days: 7)
    #expect(pick([long, short], today: F.day(11, 3))?.challenge.title == "Short")
  }

  @Test("with nothing open, the one finished a short while ago")
  func recentlyFinished() {
    let done = challenge("Done", F.day(11, 1), days: 7)
    let found = pick([done], today: F.day(11, 10))
    #expect(found?.challenge.title == "Done")
    #expect(found?.isRunning == false)
  }

  @Test("a challenge finished long ago is not on the tile")
  func staleFinished() {
    let done = challenge("Done", F.day(11, 1), days: 7)
    #expect(pick([done], today: F.day(11, 7).adding(days: ChallengeTile.finishedStaysDays + 1)) == nil)
  }

  @Test("no challenges: nothing to show")
  func none() {
    #expect(pick([], today: F.day(11, 4)) == nil)
  }
}
