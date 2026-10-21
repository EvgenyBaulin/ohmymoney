import AppCore
import Observation
import SwiftUI

/// The setup of the accounts, asked by the main window of a database that has not been
/// through it: a fresh install, and a database of the first version once it is updated. It is
/// the first question of the window — the other questions wait for it — and it is never asked
/// of a set of synthetic data (which the UI tests always open) or in the host of the unit tests.
///
/// The sheet goes only through its two answers, «Готово» and «Позже» (Esc): either one writes
/// `accounts.setup`, and the question is over. After «Позже» a card of Overview leads back: it
/// asks through `AccountSetupRequest`, and the sheet still hangs here, on the root of the
/// window — never on a row of the list, which may be gone while the sheet is open.
struct AccountSetupOffer: ViewModifier {
  let deps: AppDependencies

  func body(content: Content) -> some View {
    content
      // The starter set first on a new database — after the cards of the guide —, then the
      // accounts: one flow of questions, one sheet at a time.
      // Neither waits over the cover of the locked app (`PrivacyLock.presenting`).
      .sheet(
        isPresented: deps.environment.lock.presenting(
          Binding(
            get: {
              StarterSetOffer.shared.isRequested
                || StarterSetOffer.isDue(deps.environment, guide: GuideStore.shared)
            },
            set: { if !$0 { StarterSetOffer.shared.isRequested = false } }))
      ) {
        StarterSetSheet().appDependencies(deps)
      }
      .sheet(
        isPresented: deps.environment.lock.presenting(
          Binding(
            get: { Self.isUp(deps.environment) },
            set: { if !$0 { AccountSetupRequest.shared.isRequested = false } }))
      ) {
        // A sheet is laid out by a host of its own: the dependencies are handed over.
        AccountSetupSheet().appDependencies(deps)
      }
  }

  /// Whether the window asks now.
  @MainActor
  static func asks(
    _ environment: AppEnvironment, isTestHost: Bool = AppEnvironment.isTestHost
  ) -> Bool {
    asks(
      setup: environment.accountSetup, isOpen: environment.state == .ready,
      isTestHost: isTestHost, dataSet: AppPaths.dataSet,
      archiveWaits: environment.pendingArchiveImport != nil)
  }

  /// Whether the sheet is on screen: the window asks, or the card of Overview asked for it.
  /// Every other question of the window waits while it is — the reminders and the notice of
  /// currencies too, which would otherwise be spent under the sheet opened from the card.
  @MainActor
  static func isUp(
    _ environment: AppEnvironment, isTestHost: Bool = AppEnvironment.isTestHost,
    request: AccountSetupRequest = .shared
  ) -> Bool {
    (asks(environment, isTestHost: isTestHost) || request.isRequested)
      && !StarterSetOffer.shared.isRequested
      && !StarterSetOffer.isDue(environment, guide: GuideStore.shared)
      && GuideStore.shared.cards == nil
  }

  /// Whether the offer of a report after a crash may be raised in this window now.
  @MainActor
  static func letsReportOffer(_ environment: AppEnvironment, setupIsUp: Bool) -> Bool {
    letsReportOffer(
      isStarting: environment.state == .starting,
      archiveWaits: environment.pendingArchiveImport != nil, setupIsUp: setupIsUp)
  }

  /// The offer of a report is raised only once the window knows whether the setup comes: not
  /// while the database opens, not while an archive handed over by Finder is about to be taken
  /// up, and not while the setup is on screen. Raised earlier, it would be taken down a moment
  /// later by the setup, with the report it led to already open. A database that failed to
  /// open is no start any more: the offer comes there.
  static func letsReportOffer(isStarting: Bool, archiveWaits: Bool, setupIsUp: Bool) -> Bool {
    !isStarting && !archiveWaits && !setupIsUp
  }

  /// The rule: an open database whose setup is still due, outside the unit tests' host and
  /// outside every set of synthetic data — and not while an archive double-clicked in Finder
  /// waits to replace the database: the setup would be asked of data about to go.
  static func asks(
    setup: AccountSettings.Setup?, isOpen: Bool, isTestHost: Bool, dataSet: AppPaths.DataSet?,
    archiveWaits: Bool = false
  ) -> Bool {
    isOpen && setup == nil && !isTestHost && dataSet == nil && !archiveWaits
  }

  /// A question of the window that comes after the setup: it waits while the setup is asked.
  static func lets(_ question: Bool, asksSetup: Bool) -> Bool {
    question && !asksSetup
  }
}

/// «Настроить счета…» pressed on the card of Overview: the window root opens the sheet.
@MainActor @Observable
final class AccountSetupRequest {
  static let shared = AccountSetupRequest()

  var isRequested = false
}
