import AppCore
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The three notes the screens take from the core: the mortgage limit counted without earlier
/// years, a limit challenge without a limit, and a reading below the last one. Each has its words
/// in both languages; the rules themselves are tested in the core.
@MainActor
final class PhoneFlagsTests: XCTestCase {
  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  func testTheNewWordsExistInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let env = environment(choice)
      XCTAssertNotEqual(
        DeductionsText.t("deductions.mortgage.priorUnknown", env), "deductions.mortgage.priorUnknown")
      for key in [
        "challenges.limit.missing", "challenges.limit.set", "challenges.limit.title",
        "challenges.limit.hint",
      ] {
        XCTAssertNotEqual(ChallengeText.t(key, env), key, "\(key) \(choice)")
      }
      for key in [
        "utilities.reading.ask.title", "utilities.reading.ask.message",
        "utilities.reading.ask.replaced", "utilities.reading.ask.fix",
      ] {
        XCTAssertNotEqual(UtilitiesText.t(key, env), key, "\(key) \(choice)")
      }
      let line = env.format(
        "utilities.reading.checkOne", table: UtilitiesText.table, "100 m³", "5 Nov")
      XCTAssertTrue(line.contains("100 m³") && line.contains("5 Nov"), line)
    }
    XCTAssertEqual(
      ChallengeText.t("challenges.limit.missing", environment(.russian)), "Лимит не задан")
  }

  func testTheTileOfAChallengeWithoutALimitSaysSo() throws {
    let challenge = Challenge(
      title: "Cafe", kind: .cap, start: DateOnly(year: 2026, month: 11, day: 2),
      end: DateOnly(year: 2026, month: 11, day: 8))
    let progress = ChallengeProgress(
      state: .running, spent: .zero, elapsedDays: 3, dayCount: 7, keptDays: 3, currentStreak: 3,
      bestStreak: 3, brokenOn: nil, remaining: nil, baseline: nil, baselineSource: nil,
      saved: nil, newSubscriptionIds: [], limitIsMissing: true)
    let figure = try XCTUnwrap(
      ChallengeTileFigure.make(
        ChallengeTile.Pick(challenge: challenge, progress: progress), environment(.english)))
    XCTAssertEqual(figure.caption, "Limit not set")
    XCTAssertTrue(figure.details.isEmpty)
  }
}
