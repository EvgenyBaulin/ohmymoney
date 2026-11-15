import AppCore
import XCTest

@testable import OhMyMoney

/// The words and the shared text of the challenges. The rules themselves are tested in the core
/// (`ChallengesTests` of CorePlanning) and the storage in the database tests.
@MainActor
final class ChallengesTests: XCTestCase {
  private let day = DateOnly(year: 2026, month: 11, day: 2)

  private var keys: [String] {
    var keys = [
      "challenges.title", "challenges.subtitle", "challenges.saved.total",
      "challenges.section.active", "challenges.section.done", "challenges.empty", "challenges.new",
      "challenges.new.presets", "challenges.preset.hint", "challenges.custom", "challenges.day",
      "challenges.period", "challenges.streak", "challenges.keptDays", "challenges.spent",
      "challenges.left", "challenges.saved", "challenges.saved.none", "challenges.baseline.owner",
      "challenges.baseline.median", "challenges.brokenOn", "challenges.newSubscriptions",
      "challenges.stop", "challenges.remove", "challenges.share", "challenges.share.kept",
      "challenges.share.saved", "challenges.form.name", "challenges.form.kind",
      "challenges.form.days", "challenges.form.start", "challenges.form.words",
      "challenges.form.category", "challenges.form.category.none", "challenges.form.limit",
      "challenges.form.baseline", "challenges.form.baselineHint", "challenges.start",
      "challenges.form.everything", "challenges.tile.none", "why.challenges.none",
      "why.challenges.ends",
    ]
    keys += ChallengePreset.allCases.map { "challenges.preset.\($0.rawValue)" }
    keys += ChallengeKind.allCases.map { "challenges.kind.\($0.rawValue)" }
    keys += ["upcoming", "running", "succeeded", "failed", "stopped"].map {
      "challenges.state.\($0)"
    }
    return keys
  }

  func testEveryKeyHasWordsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let words = AppEnvironment()
      words.language.choice = choice
      for key in keys {
        let value = words.language(key, table: ChallengeText.table)
        XCTAssertNotEqual(value, key, "\(choice) \(key)")
        XCTAssertFalse(value.isEmpty, key)
      }
    }
  }

  private func finished(saved: Int64) -> (Challenge, ChallengeProgress) {
    let challenge = Challenge(
      title: "No delivery", kind: .avoid, start: day, end: day.adding(days: 6))
    let progress = ChallengeProgress(
      state: .succeeded, spent: .zero, elapsedDays: 7, dayCount: 7, keptDays: 7,
      currentStreak: 7, bestStreak: 7, brokenOn: nil, remaining: nil,
      baseline: AmountE4(whole: saved), baselineSource: .owner, saved: AmountE4(whole: saved),
      newSubscriptionIds: [])
    return (challenge, progress)
  }

  func testTheSharedTextTellsTheSavingOnlyWhenAmountsAreShown() {
    let (challenge, progress) = finished(saved: 2_500)
    let environment = AppEnvironment()
    environment.language.choice = .english
    let shown = ChallengeText.shareText(challenge, progress, environment)
    XCTAssertTrue(shown.contains("7 of 7"), shown)
    XCTAssertTrue(shown.contains("2,500"), shown)
    environment.amounts.toggle()
    let hidden = ChallengeText.shareText(challenge, progress, environment)
    XCTAssertTrue(hidden.contains("7 of 7"), hidden)
    XCTAssertFalse(hidden.contains("2,500"), hidden)
    XCTAssertFalse(hidden.lowercased().contains("saved"), hidden)
  }

  func testNoSavingIsToldWhenThereIsNone() {
    let (challenge, progress) = finished(saved: 0)
    let environment = AppEnvironment()
    environment.language.choice = .english
    XCTAssertFalse(
      ChallengeText.shareText(challenge, progress, environment).lowercased().contains("saved"))
  }
}
