import AppCore
import Foundation
import Observation

/// The mechanics of the privacy features that sit on top of the lock: the hidden accounts and
/// «Только просмотр». One object, read by the screens and by the places the data is presented.
///
/// **Hidden accounts.** While the app is covered the accounts the owner marked hidden are not in
/// the sidebar, the lists of accounts, the pickers or the operations; the totals still hold all
/// the money and say «часть скрыта». «Показать скрытые» asks Touch ID or the password of the
/// Mac, and shows them until the lock covers the app again or «Скрыть» is pressed. The state is
/// in memory only: a restart is a cover.
///
/// **Read-only.** The data can be looked at and nothing can change. It is switched on freely;
/// switching it off asks Touch ID or the password of the Mac. The setting is kept in the
/// database (`privacy.readOnly`), so a restart does not leave it.
@MainActor
@Observable
final class PrivacyShield {
  // MARK: Hidden accounts

  private(set) var visibility: PrivacyVisibility = .covered
  /// The accounts marked hidden, as the data last said.
  private(set) var allHidden = HiddenAccounts(ids: [UUID]())
  private(set) var allHiddenCards: Set<UUID> = []
  /// Changes whenever what the lists leave out changes, so a screen that cut a listing off
  /// the main thread knows to cut it again.
  private(set) var revision = 0

  /// The accounts the lists leave out right now: all the hidden ones while covered, none once
  /// revealed.
  var covering: HiddenAccounts {
    visibility == .covered ? allHidden : HiddenAccounts(ids: [UUID]())
  }
  var coveredCardIds: Set<UUID> { visibility == .covered ? allHiddenCards : [] }
  /// There is something to reveal.
  var hasHiddenAccounts: Bool { !allHidden.isEmpty }
  var isRevealed: Bool { visibility == .revealed && hasHiddenAccounts }

  /// Learns which accounts are hidden from the data the pipeline just read.
  func learn(accounts: [PaymentMethod], cards: [PaymentCard]) {
    let hidden = HiddenAccounts(accounts: accounts)
    let cardIds = hidden.cardIds(in: cards)
    guard hidden != allHidden || cardIds != allHiddenCards else { return }
    allHidden = hidden
    allHiddenCards = cardIds
    revision &+= 1
  }

  /// The accounts a picker offers: the hidden ones are left out while covered.
  func offered(_ accounts: [PaymentMethod]) -> [PaymentMethod] {
    allHidden.offered(accounts, visibility: visibility)
  }

  /// Puts the hidden accounts back under cover: «Скрыть», and the lock taking hold.
  func cover() {
    guard visibility != .covered else { return }
    visibility = .covered
    revision &+= 1
  }

  /// Asks Touch ID or the password of the Mac and shows the hidden accounts. `true` once shown.
  @discardableResult
  func reveal(reason: String) async -> Bool {
    guard hasHiddenAccounts else { return false }
    guard visibility == .covered else { return true }
    guard await prove(reason: reason) else { return false }
    visibility = .revealed
    revision &+= 1
    record(.hiddenShown)
    AppLog.info("privacy.hiddenShown", .ui, "the hidden accounts were shown")
    return true
  }

  // MARK: Read-only

  private(set) var readOnly = ReadOnlyMode()

  var isReadOnly: Bool { readOnly.isOn }

  /// Whether `action` may run now. Looking, searching and exporting a report are not actions.
  func allows(_ action: ReadOnlyAction) -> Bool { readOnly.allows(action) }

  /// Takes the saved choice at start or after the settings were read again; nothing is
  /// journaled, since the owner did not switch anything.
  func adopt(readOnly on: Bool) {
    guard on != readOnly.isOn else { return }
    readOnly = ReadOnlyMode(isOn: on)
    onReadOnlyChange?(on)
  }

  /// Switches the mode on. Free: the owner proves nothing to make the app safer.
  func turnReadOnlyOn() {
    guard !readOnly.isOn else { return }
    readOnly = readOnly.turnedOn()
    persistReadOnly?(true)
    onReadOnlyChange?(true)
    record(.readOnlyOn)
    AppLog.info("privacy.readOnlyOn", .ui, "the app was put in read-only mode")
  }

  /// Switches the mode off after Touch ID or the password of the Mac. `true` once it is off.
  @discardableResult
  func leaveReadOnly(reason: String) async -> Bool {
    guard readOnly.isOn else { return true }
    let proven = await prove(reason: reason)
    let after = readOnly.leaving(unlockedByAuthentication: proven)
    guard !after.isOn else { return false }
    readOnly = after
    persistReadOnly?(false)
    onReadOnlyChange?(false)
    record(.readOnlyOff)
    AppLog.info("privacy.readOnlyOff", .ui, "the app left read-only mode")
    return true
  }

  /// What the last attempt to prove the owner came to, when it did not pass.
  private(set) var lastRefusal: LockAuthentication?
  private(set) var isAuthenticating = false

  // MARK: Wiring

  /// Where the events go (the journal of openings); `nil` where nothing is written: the test
  /// host and the data sets.
  @ObservationIgnored var journal: ((PrivacyJournalEntry.Event) -> Void)?
  /// Saves the choice of read-only (`privacy.readOnly`).
  @ObservationIgnored var persistReadOnly: ((Bool) -> Void)?
  /// Tells the database layer to refuse writes, or to take them again.
  @ObservationIgnored var onReadOnlyChange: ((Bool) -> Void)?

  @ObservationIgnored private let authenticator: any LockAuthenticator

  init(authenticator: any LockAuthenticator = DeviceOwnerAuthenticator()) {
    self.authenticator = authenticator
  }

  private func record(_ event: PrivacyJournalEntry.Event) {
    journal?(event)
  }

  /// Touch ID or the password of the Mac. A Mac that can prove nothing (no Touch ID, no login
  /// password) has nothing to ask, so it lets the owner through.
  private func prove(reason: String) async -> Bool {
    guard !isAuthenticating else { return false }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    switch answer {
    case .passed, .unavailable:
      return true
    case .failed, .cancelled:
      lastRefusal = answer
      return false
    }
  }
}

/// The read-only switch for the flows that have no environment in hand -- a restore and an
/// import are static steps of their own. The shield sets it; they only ask.
enum ReadOnlyGate {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var on = false

  static var isOn: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return on
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      on = newValue
    }
  }
}
