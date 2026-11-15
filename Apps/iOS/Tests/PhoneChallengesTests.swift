import AppCore
import XCTest

@testable import OhMyMoney

/// The tile of Overview and the picture to share of the challenges, in both languages and with
/// the amounts hidden. The rules of the challenges are tested in the core.
@MainActor
final class PhoneChallengesTests: XCTestCase {
  private let day = DateOnly(year: 2026, month: 11, day: 2)

  private func english() -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = .english
    return environment
  }

  private func progress(
    _ state: ChallengeState, saved: Int64?, remaining: Int64? = nil, elapsed: Int = 7
  ) -> ChallengeProgress {
    ChallengeProgress(
      state: state, spent: .zero, elapsedDays: elapsed, dayCount: 7, keptDays: elapsed,
      currentStreak: elapsed, bestStreak: 7, brokenOn: nil,
      remaining: remaining.map { AmountE4(whole: $0) },
      baseline: saved.map { AmountE4(whole: $0) }, baselineSource: saved == nil ? nil : .owner,
      saved: saved.map { AmountE4(whole: $0) }, newSubscriptionIds: [])
  }

  private let challenge = Challenge(
    title: "No delivery", kind: .avoid, start: DateOnly(year: 2026, month: 11, day: 2),
    end: DateOnly(year: 2026, month: 11, day: 8))

  func testTheTileSaysNothingWithoutAChallenge() {
    XCTAssertNil(ChallengeTileFigure.make(nil, english()))
  }

  func testARunningChallengeShowsItsDayStreakAndWhatIsLeft() throws {
    let pick = ChallengeTile.Pick(
      challenge: challenge, progress: progress(.running, saved: nil, remaining: 1_200, elapsed: 3))
    let figure = try XCTUnwrap(ChallengeTileFigure.make(pick, english()))
    XCTAssertEqual(figure.title, "No delivery")
    XCTAssertEqual(figure.caption, "Day 3 of 7")
    XCTAssertTrue(figure.details.contains { $0.contains("3 days") })
    XCTAssertTrue(figure.details.contains { $0.contains("1,200") })
  }

  func testAFinishedChallengeShowsItsStateAndSaving() throws {
    let pick = ChallengeTile.Pick(
      challenge: challenge, progress: progress(.succeeded, saved: 2_500))
    let figure = try XCTUnwrap(ChallengeTileFigure.make(pick, english()))
    XCTAssertNotEqual(figure.caption, "challenges.state.succeeded")
    XCTAssertTrue(figure.details.contains { $0.contains("2,500") })
  }

  func testThePictureCardHasTheSumOnlyWhenAmountsAreShown() {
    let environment = english()
    let done = progress(.succeeded, saved: 2_500)
    let shown = ChallengeText.shareCard(challenge, done, environment)
    XCTAssertTrue(shown.lines.contains { $0.contains("2,500") })
    environment.amounts.toggle()
    let hidden = ChallengeText.shareCard(challenge, done, environment)
    XCTAssertFalse(hidden.lines.contains { $0.contains("2,500") }, "\(hidden.lines)")
    XCTAssertFalse(hidden.lines.contains { $0.lowercased().contains("saved") })
    XCTAssertEqual(hidden.lines.count, shown.lines.count - 1)
  }

  func testThePictureIsAPngFile() throws {
    let environment = english()
    let url = try XCTUnwrap(
      ChallengeText.sharePicture(challenge, progress(.succeeded, saved: 2_500), environment))
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(url.pathExtension, "png")
    XCTAssertGreaterThan((try? Data(contentsOf: url).count) ?? 0, 1_000)
  }

  func testTheTileIsHiddenUntilAdded() {
    XCTAssertFalse(OverviewTile.challenges.isShownUnnamed)
    XCTAssertEqual(OverviewTile.challenges.defaultGroup, .plan)
    XCTAssertFalse(OverviewTiles.standard.contains(.challenges))
  }
}
