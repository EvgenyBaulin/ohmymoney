import AppCore
import Foundation
import Observation

/// The way to «Итоги» from anywhere: the card above the tiles, the settings, a notification. On
/// the Mac and a tablet «Итоги» is the tab «По периодам» of Reports, on a phone the page «Итоги»
/// of «Ещё». A request is kept until the tab or the page takes it, so it survives a window that
/// is not built yet.
@MainActor
@Observable
final class SummariesRoute {
  static let shared = SummariesRoute()

  /// The summary asked for and not yet shown; `nil` once the tab has taken it.
  var pending: SummaryID?
  /// Bumped by every request, so a tab already on screen goes to the period asked even when it
  /// is the same as the last one.
  private(set) var requests = 0

  init() {}

  /// Shows «Итоги»: Reports on its tab «По периодам» (`summary` chosen when given), or the page of
  /// a phone. The main window comes forward on the Mac.
  static func open(_ summary: SummaryID? = nil, defaults: UserDefaults = .standard) {
    shared.ask(summary, defaults: defaults)
    NotificationCenter.default.post(name: .openSummaries, object: summary)
    #if os(macOS)
      // The main window takes Reports; the settings or a notification may be in front of it.
      NotificationCenter.default.post(
        name: .openSidebarItem, object: SidebarItem.section(.reports))
      _ = AppWindows.bringForward(.main)
    #endif
  }

  /// Keeps the request and marks Reports to open on «По периодам».
  func ask(_ summary: SummaryID?, defaults: UserDefaults = .standard) {
    pending = summary
    requests += 1
    defaults.set(true, forKey: ReportsSelection.byPeriodsKey)
  }

  /// The summary asked for, once: the tab calls this when it shows.
  func take() -> SummaryID? {
    defer { pending = nil }
    return pending
  }
}

extension Notification.Name {
  /// «Итоги» asked for; the object is the `SummaryID` to show, or `nil` for the latest.
  static let openSummaries = Notification.Name("io.github.EvgenyBaulin.ohmymoney.openSummaries")
}
