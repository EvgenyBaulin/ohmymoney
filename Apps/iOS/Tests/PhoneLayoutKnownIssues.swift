import CoreGraphics

@testable import OhMyMoney

/// Screens the layout walk found wider than the window, or with the bar's items on top of each
/// other, that nobody has fixed yet: `screen@width`, with `+xl` for the largest text size. A
/// listed screen must still fail — the walk complains once it fits, so the line comes out with
/// the fix — and an unlisted one must fit. Nothing here is skipped: each entry is a defect with
/// its reproduction.
enum PhoneLayoutKnownIssues {
  private static let known: Set<String> = [
    // The sheet «Сверка» is the Mac's table (account, currency, expected, counted, difference),
    // about 520 pt wide in a window of 375 to 440.
    "sheet.reconciliation@375", "sheet.reconciliation@402", "sheet.reconciliation@440",
    "sheet.reconciliation@375+xl", "sheet.reconciliation@402+xl",
    "sheet.reconciliation@440+xl",
    // «Итоги» is some 8 pt wider than the narrowest phone.
    "more.summaries@375", "more.summaries@375+xl",
    // At the largest text the bar's items stand on each other on this page.
    "more.calendar@402+xl",
    // iPad Pro 12.9: a window of a third of the landscape width lays the pages out by the
    // phone's rules and they are too wide; «Счета» has a control half off the left edge.
    "tab.accounts@1024", "tab.accounts@1366", "tab.accounts@678",
    "more.calendar@438", "more.analytics@438", "more.reports@438", "more.purchases@438",
    "sheet.reconciliation@438",
  ]

  @MainActor
  static func contains(
    _ screen: PhoneScreen, width: CGFloat, idiom: LayoutIdiom, largestText: Bool = false
  ) -> Bool {
    known.contains("\(screen.description)@\(Int(width))\(largestText ? "+xl" : "")")
  }
}
