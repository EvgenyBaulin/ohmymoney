import CoreGraphics

@testable import OhMyMoney

/// Screens the layout walk found wider than the window, or with the bar's items on top of each
/// other, that nobody has fixed yet: `screen@width`, with `+xl` for the largest text size. A
/// listed screen must still fail — the walk complains once it fits, so the line comes out with
/// the fix — and an unlisted one must fit. Nothing here is skipped: each entry is a defect with
/// its reproduction.
enum PhoneLayoutKnownIssues {
  private static let known: Set<String> = [
    // «Планирование»: the round «…» of the header still ends past the edge of the narrowest
    // phone; something in the page is a little wider than the window.
    "tab.planning@375", "tab.planning@375+xl",
    // iPad Pro 12.9 full screen: «Счета» still has a control past the left edge.
    "tab.accounts@1024", "tab.accounts@1366",
  ]

  @MainActor
  static func contains(
    _ screen: PhoneScreen, width: CGFloat, idiom: LayoutIdiom, largestText: Bool = false
  ) -> Bool {
    known.contains("\(screen.description)@\(Int(width))\(largestText ? "+xl" : "")")
  }
}
