import AppCore
import Foundation
import Observation

/// «Блокировать OhMyMoney» on the phone: Face ID, or the passcode of the phone where Face ID is
/// not there or not accepted, asked at the launch and after the app has been away for a few
/// minutes. Off until the owner turns it on, and turning it on asks for the proof first, so it
/// is never switched on by somebody who could not switch it off.
///
/// The state machine knows nothing of the system: the proof comes through a `LockAuthenticator`
/// and the time through a clock, so a test drives every path without a finger or a wait. The
/// cover of the app switcher is another matter and does not live here — it is drawn whenever the
/// scene is not active, locked or not (`ShieldedRoot`).
@MainActor
@Observable
final class AppLock {
  nonisolated static let enabledKey = "ios.lock.enabled"
  nonisolated static let minutesKey = "ios.lock.minutes"
  /// The minutes in the background Settings offers.
  static let minuteChoices = [1, 5, 15, 60]
  static let defaultMinutes = 5

  private(set) var isEnabled: Bool
  private(set) var isLocked: Bool
  private(set) var isAuthenticating = false
  /// How many times the app has locked, the launch included: the root is made again at each, so
  /// no sheet or pushed screen of the books stays over the cover.
  private(set) var lockCount = 0
  /// What the last attempt came to, when it did not pass; the cover says it in words.
  private(set) var lastRefusal: LockAuthentication?
  var minutes: Int {
    didSet {
      let sane = Self.sanitized(minutes)
      if sane != minutes { minutes = sane }
      defaults.set(sane, forKey: Self.minutesKey)
    }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let authenticator: any LockAuthenticator
  @ObservationIgnored private let now: () -> Date
  /// When the app went to the background; `nil` while it is in front.
  @ObservationIgnored private(set) var leftAt: Date?

  init(
    defaults: UserDefaults = .standard,
    authenticator: any LockAuthenticator = DeviceOwnerAuthenticator(),
    now: @escaping () -> Date = { Date() }
  ) {
    self.defaults = defaults
    self.authenticator = authenticator
    self.now = now
    let enabled = defaults.bool(forKey: Self.enabledKey)
    isEnabled = enabled
    // Locked from the first frame: the books are never drawn before the proof.
    isLocked = enabled
    lockCount = enabled ? 1 : 0
    minutes = Self.sanitized(
      defaults.object(forKey: Self.minutesKey) as? Int ?? Self.defaultMinutes)
  }

  static func sanitized(_ minutes: Int) -> Int {
    minuteChoices.min { abs($0 - minutes) < abs($1 - minutes) } ?? defaultMinutes
  }

  /// The app left the front. Only the first call counts, so a second notice does not move the
  /// moment the minutes are counted from.
  func didEnterBackground() {
    if leftAt == nil { leftAt = now() }
  }

  /// The app came back. It locks when it was away for at least the chosen minutes.
  func didBecomeActive() {
    defer { leftAt = nil }
    guard isEnabled, !isLocked, let leftAt else { return }
    if now().timeIntervalSince(leftAt) >= TimeInterval(minutes * 60) {
      isLocked = true
      lockCount += 1
    }
  }

  /// Face ID or the passcode; takes the cover away when it passes.
  @discardableResult
  func unlock(reason: String) async -> Bool {
    guard isLocked, !isAuthenticating else { return !isLocked }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      return false
    }
    isLocked = false
    return true
  }

  /// Turns the lock on after the proof; refused when the phone can prove nothing.
  @discardableResult
  func enable(reason: String) async -> Bool {
    guard !isEnabled, !isAuthenticating else { return isEnabled }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      return false
    }
    isEnabled = true
    defaults.set(true, forKey: Self.enabledKey)
    return true
  }

  /// Turns the lock off. Only an open app can: a locked one has nothing to turn off.
  func disable() {
    guard isEnabled, !isLocked else { return }
    isEnabled = false
    defaults.set(false, forKey: Self.enabledKey)
    lastRefusal = nil
  }
}
