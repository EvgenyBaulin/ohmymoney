import CoreGraphics

@testable import OhMyMoney

/// Screens the layout walk found wider than the window, or with the bar's items on top of each
/// other, that nobody has fixed yet: `screen@width`, with `+xl` for the largest text size and
/// `+ax5` for the largest accessibility size of «Как в системе». A listed screen must still
/// fail — the walk complains once it fits, so the line comes out with the fix — and an unlisted
/// one must fit. Nothing here is skipped: each entry is a defect with its reproduction. Nothing
/// is listed now.
enum PhoneLayoutKnownIssues {
  private static let known: Set<String> = []

  @MainActor
  static func contains(
    _ screen: PhoneScreen, width: CGFloat, idiom: LayoutIdiom, largestText: Bool = false,
    accessibility5: Bool = false
  ) -> Bool {
    let suffix = accessibility5 ? "+ax5" : largestText ? "+xl" : ""
    return known.contains("\(screen.description)@\(Int(width))\(suffix)")
  }
}
