import AppCore
import SwiftUI

/// The windows of the app, by the names the journal gives them.
enum AppWindow: String, Sendable {
  case main, analytics, reports, whatIf, settings
}

/// What was on screen, for the journal: a window opening and closing, a section shown in it.
/// «Это нужно, чтобы понять, на каком экране случилась ошибка». Every value is a word of the
/// code — the name of a window, the raw value of a section — never anything the owner typed.
enum ScreenJournal {
  static func opened(_ window: AppWindow) {
    AppLog.info("window.opened", .ui, "a window appeared", [pair(window)])
  }

  static func closed(_ window: AppWindow) {
    AppLog.info("window.closed", .ui, "a window went", [pair(window)])
  }

  /// A section on screen: the one a window opened on, and every one switched to after it.
  static func shown(_ section: String, in window: AppWindow) {
    AppLog.info(
      "section.shown", .ui, "a section is on screen",
      [pair(window), LogPair("section", .token(section))])
  }

  private static func pair(_ window: AppWindow) -> LogPair {
    LogPair("window", .token(window.rawValue))
  }
}

extension View {
  /// Writes the section of a window into the journal when the window shows it and whenever
  /// it changes. `section` is a word of the code: the raw value of the section.
  func journalsSection(_ section: String, in window: AppWindow) -> some View {
    onAppear { ScreenJournal.shown(section, in: window) }
      .onChange(of: section) { _, now in ScreenJournal.shown(now, in: window) }
  }
}
