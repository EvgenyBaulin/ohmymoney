import Foundation
import Observation

/// «Скрыть суммы»: one switch hides every figure of money on every screen — lists, cards, the
/// sidebar, charts — behind `MoneyFormatter.mask`, while the shapes of the charts stay drawn.
///
/// Every money text of the interface is written by `AppEnvironment.money`, and that formatter
/// reads this switch, so nothing else needs to know about it. What the owner types — the entry
/// line, the fields of a form — is not money text and stays as typed; counts, shares and rates
/// stay too, since none of them tells how much there is. Files leave untouched: CSV, reports
/// and archives are written from the numbers, never from the interface.
///
/// A habit of this Mac, not data of the books: kept in `UserDefaults` (`privacy.hideAmounts`),
/// never in the archive, and it lasts from one launch to the next — a figure hidden before
/// quitting does not show up at the next start. The test host keeps nothing (`defaults` nil),
/// so a test that hides the amounts never hides them for the owner.
@MainActor
@Observable
public final class AmountPrivacy {
  /// The key in `UserDefaults`; this Mac only.
  nonisolated static let key = "privacy.hideAmounts"

  public var hidesAmounts: Bool {
    didSet {
      guard hidesAmounts != oldValue else { return }
      defaults?.set(hidesAmounts, forKey: Self.key)
      AppLog.info(
        hidesAmounts ? "privacy.amountsHidden" : "privacy.amountsShown", .ui,
        "the owner switched the amounts of the interface")
    }
  }

  @ObservationIgnored private let defaults: UserDefaults?

  init(defaults: UserDefaults?) {
    self.defaults = defaults
    hidesAmounts = defaults?.bool(forKey: Self.key) ?? false
  }

  func toggle() { hidesAmounts.toggle() }
}

/// The words of the switch in the View menu and on the toolbar: what a click will do.
@MainActor
enum PrivacyCommands {
  static func amountsTitle(_ environment: AppEnvironment) -> String {
    environment.language(
      environment.amounts.hidesAmounts ? "privacy.showAmounts" : "privacy.hideAmounts")
  }

  /// «Вид → Заблокировать Итого» is in the menu only while the lock is on: without it there is
  /// nothing to lock with.
  static func offersLockNow(_ lock: PrivacyLock) -> Bool { lock.isEnabled }
}
