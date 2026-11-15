import CoreAnalytics
import CoreKit
import Foundation

/// The challenge the tile of Overview speaks of: the one running (the one that ends first), else
/// the next one to begin, else the one that finished a short while ago.
public enum ChallengeTile {
  /// How many days after its last day a finished challenge stays on the tile.
  public static let finishedStaysDays = 14

  public struct Pick: Hashable, Sendable {
    public var challenge: Challenge
    public var progress: ChallengeProgress

    public init(challenge: Challenge, progress: ChallengeProgress) {
      self.challenge = challenge
      self.progress = progress
    }

    public var isRunning: Bool { progress.state == .running }
  }

  public static func pick(
    _ book: ChallengeBook, ledger: Ledger, planning: PlanningBook, today: DateOnly
  ) -> Pick? {
    let items = ChallengeLists.ordered(book, ledger: ledger, planning: planning, today: today)
    let open = items.filter { !$0.progress.isFinished }
    let chosen =
      open.first { $0.progress.state == .running } ?? open.first
      ?? items.first {
        today.days(to: $0.challenge.stoppedOn ?? $0.challenge.end) >= -finishedStaysDays
      }
    return chosen.map { Pick(challenge: $0.challenge, progress: $0.progress) }
  }
}
