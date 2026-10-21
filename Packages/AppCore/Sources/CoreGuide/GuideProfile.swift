import Foundation

/// A way of living as the starter set asks it. The raw values are the starter set's own, so the
/// app hands its choice over by name; a name the guide does not know is left out.
public enum GuideLifestyle: String, CaseIterable, Hashable, Sendable, Codable {
  case student
  case working
  case freelance
  case family
  case alone
  case partner
  case kids
}

/// What the owner told the starter set, as the tutorial reads it: the ways of living and the
/// four questions after them. Kept in the guide's memory on this Mac, never in the database.
public struct GuideProfile: Hashable, Sendable, Codable {
  public var lifestyles: Set<GuideLifestyle>
  public var hasLoans: Bool
  public var hasSubscriptions: Bool
  public var tracksCashback: Bool
  public var wantsACushion: Bool

  public init(
    lifestyles: Set<GuideLifestyle> = [], hasLoans: Bool = false, hasSubscriptions: Bool = false,
    tracksCashback: Bool = false, wantsACushion: Bool = false
  ) {
    self.lifestyles = lifestyles
    self.hasLoans = hasLoans
    self.hasSubscriptions = hasSubscriptions
    self.tracksCashback = tracksCashback
    self.wantsACushion = wantsACushion
  }

  /// The ways of living by the starter set's names; unknown names are dropped.
  public init(
    lifestyleNames: some Sequence<String>, hasLoans: Bool, hasSubscriptions: Bool,
    tracksCashback: Bool, wantsACushion: Bool
  ) {
    self.init(
      lifestyles: Set(lifestyleNames.compactMap(GuideLifestyle.init(rawValue:))),
      hasLoans: hasLoans, hasSubscriptions: hasSubscriptions, tracksCashback: tracksCashback,
      wantsACushion: wantsACushion)
  }

  /// Whether the answers say this about the owner.
  public func has(_ trait: GuideTrait) -> Bool {
    switch trait {
    case .lifestyle(let lifestyle): lifestyles.contains(lifestyle)
    case .loans: hasLoans
    case .subscriptions: hasSubscriptions
    case .cashback: tracksCashback
    case .cushion: wantsACushion
    }
  }
}

/// One thing the starter set may say about the owner.
public enum GuideTrait: Hashable, Sendable {
  case lifestyle(GuideLifestyle)
  case loans
  case subscriptions
  case cashback
  case cushion
}

/// Whose tutorial a task is in.
public enum GuideAudience: Hashable, Sendable {
  /// Everyone's.
  case everyone
  /// Only an owner whose starter set says so: without a set the task is not asked — the
  /// guide does not know it is his.
  case only(GuideTrait)
  /// Everyone's, except an owner whose starter set says it is not about him: without a set the
  /// task stays, as it was before the set was remembered.
  case unlessNot(GuideTrait)

  /// Whether the tutorial of `profile` has the task; nil is an owner who chose no set.
  public func includes(_ profile: GuideProfile?) -> Bool {
    switch self {
    case .everyone: return true
    case .only(let trait): return profile?.has(trait) ?? false
    case .unlessNot(let trait): return profile?.has(trait) ?? true
    }
  }
}
