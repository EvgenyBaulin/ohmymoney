import AppCore
import SwiftUI

/// What the tile «Челленджи» shows, apart from the view so a test reads it in both languages.
struct ChallengeTileFigure: Equatable {
  var title: String
  var symbol: String
  var caption: String
  var details: [String]

  /// `nil` when there is no challenge to speak of: the tile says so instead of an empty card.
  @MainActor
  static func make(_ pick: ChallengeTile.Pick?, _ environment: AppEnvironment) -> Self? {
    guard let pick else { return nil }
    let progress = pick.progress
    var details: [String] = []
    if progress.elapsedDays > 0 && !progress.limitIsMissing {
      details.append(
        environment.format(
          "challenges.streak", table: ChallengeText.table, counts: progress.currentStreak))
    }
    if let remaining = progress.remaining {
      details.append(
        environment.format(
          "challenges.left", table: ChallengeText.table, environment.money.rounded(remaining)))
    }
    if progress.isFinished, let saved = progress.saved, !saved.isZero {
      details.append(
        environment.format(
          "challenges.saved", table: ChallengeText.table, environment.money.rounded(saved)))
    }
    // A limit that is not set leaves nothing to count a day against: the tile says so instead.
    let caption =
      progress.limitIsMissing
      ? ChallengeText.t("challenges.limit.missing", environment)
      : pick.isRunning
        ? environment.format(
          "challenges.day", table: ChallengeText.table, progress.elapsedDays,
          progress.dayCount)
        : ChallengeText.t("challenges.state.\(stateKey(progress.state))", environment)
    return Self(
      title: pick.challenge.title, symbol: ChallengeText.symbol(progress.state),
      caption: caption, details: details)
  }

  static func stateKey(_ state: ChallengeState) -> String {
    switch state {
    case .upcoming: "upcoming"
    case .running: "running"
    case .succeeded: "succeeded"
    case .failed: "failed"
    case .stopped: "stopped"
    }
  }
}

/// «Челленджи» on Overview: the challenge running now with its day, streak and what is left of
/// a limit, or the one finished a short while ago with what it saved. Hidden until the owner
/// adds it in «Изменить».
struct ChallengesTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  var compact = false

  private var pick: ChallengeTile.Pick? {
    guard let snapshot = compute.snapshot else { return nil }
    let ledger = snapshot.ledger
    return ChallengeTile.pick(
      ledger.dataset.challenges, ledger: ledger, planning: ledger.dataset.planning,
      today: snapshot.today)
  }

  var body: some View {
    let figure = ChallengeTileFigure.make(pick, environment)
    ComputedBlock(
      title: OverviewTileText.name(of: .challenges, environment), state: state(figure),
      fillsHeight: true, emptyReason: ChallengeText.t("challenges.tile.none", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { figure in
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: figure.symbol)
            .secondaryInk()
            .accessibilityHidden(true)
          Text(verbatim: figure.title)
            .appFont(compact ? .headline : .title3)
            .lineLimit(1)
            .shrinksToFit(0.7)
            .accessibilityIdentifier("overview.challenges.title")
        }
        Text(verbatim: figure.caption)
          .appFont(.caption.monospacedDigit())
          .secondaryInk()
        if !compact {
          ForEach(figure.details, id: \.self) { line in
            Text(verbatim: line)
              .appFont(.caption.monospacedDigit())
              .secondaryInk()
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func state(_ figure: ChallengeTileFigure?) -> BlockState<ChallengeTileFigure> {
    if let waiting = compute.states.data.waiting { return waiting.never() }
    guard compute.snapshot != nil else { return .calculating }
    return figure.map { .ready($0, at: .distantPast) } ?? .notEnoughData
  }
}
