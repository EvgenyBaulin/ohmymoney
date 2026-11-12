/// How many controls under 44 × 44 pt each screen of the phone has today (402 pt wide, usual
/// text size). The count may only go down: a screen that gains a small control fails
/// `PhoneScreenTouchTargetTests`; one that loses them should have its number lowered here. The
/// frame is what accessibility reports, the drawn control: a small icon with a larger hit area
/// is counted too, so the numbers are an upper bound of the real misses.
enum PhoneTouchTargetBaseline {
  static let counts: [String: Int] = [
    "more.analytics": 15,
    "more.calendar": 49,
    "more.capital": 15,
    "more.debts": 1,
    "more.purchases": 1,
    "more.reports": 5,
    "more.settings": 1,
    "more.summaries": 4,
    "more.whatIf": 1,
    "settings.accounts": 2,
    "settings.appearance": 3,
    "settings.attachments": 2,
    "settings.backups": 1,
    "settings.categories": 24,
    "settings.entry": 7,
    "settings.general": 1,
    "settings.purchases": 2,
    "settings.references": 5,
    "settings.rules": 3,
    "settings.templates": 1,
    "sheet.problemReport": 1,
    "sheet.reconciliation": 6,
    "sheet.tabsEditor": 10,
    "sheet.trip": 2,
    "tab.accounts": 5,
    "tab.more": 7,
    "tab.operations": 7,
    "tab.overview": 5,
    "tab.planning": 54,
  ]
}
