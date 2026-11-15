import CoreAnalytics
import CoreKit
import Foundation

extension Dataset {
  public static let challengesKey = "planning.challenges"

  /// The challenges of the owner, as the database holds them.
  public var challenges: ChallengeBook {
    get { extras.value(Self.challengesKey) ?? ChallengeBook() }
    set { extras.set(newValue, for: Self.challengesKey) }
  }
}
