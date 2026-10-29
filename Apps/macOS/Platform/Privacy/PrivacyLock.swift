import AppCore
import Foundation
import LocalAuthentication
import Observation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

/// What an attempt to prove the owner is at the Mac came to.
enum LockAuthentication: Sendable, Equatable {
  case passed
  /// Touch ID or the password was refused.
  case failed
  /// The owner, or the system, closed the request: nothing to say about it.
  case cancelled
  /// This Mac can prove nothing — no Touch ID and no login password.
  case unavailable
}

/// Proves the owner is at the Mac. The app asks the system (`DeviceOwnerAuthenticator`); a test
/// hands in an answer of its own, so no test ever waits for a finger.
protocol LockAuthenticator: Sendable {
  func authenticate(reason: String) async -> LockAuthentication
}

/// Touch ID, and the password of the Mac where there is no Touch ID or it is not accepted
/// (`.deviceOwnerAuthentication`). No entitlement and no key of the Info.plist is needed for it
/// on macOS.
struct DeviceOwnerAuthenticator: LockAuthenticator {
  func authenticate(reason: String) async -> LockAuthentication {
    let context = LAContext()
    var problem: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
      return .unavailable
    }
    do {
      let passed = try await context.evaluatePolicy(
        .deviceOwnerAuthentication, localizedReason: reason)
      return passed ? .passed : .failed
    } catch let error as LAError {
      switch error.code {
      case .userCancel, .systemCancel, .appCancel: return .cancelled
      case .passcodeNotSet, .biometryNotAvailable: return .unavailable
      default: return .failed
      }
    } catch {
      return .failed
    }
  }
}

/// «Блокировать OhMyMoney»: off until the owner turns it on; then every window is covered when the
/// app opens, after a few minutes without a key press or a click in it, and when the Mac goes to
/// sleep or locks its screen — until Touch ID or the password of the Mac says it is the owner.
///
/// Only what is shown is locked: the pipeline, the backups and the bank's rates go on behind the
/// cover. Turning the lock on asks for the proof first, so it is never switched on by somebody
/// who could not switch it off. The data sets of a build and the tests are never locked
/// (`applies`): synthetic books have nothing to hide, and a test must never wait for a finger.
///
/// The app has a password of its own, chosen when the lock is turned on: the cover takes it, and
/// Touch ID or the password of the Mac open it as well. Only a salted hash of it is kept, in the
/// Keychain of this Mac (`LockPassword`). Five wrong passwords in a row pause the field for
/// thirty seconds. «Забыли пароль?» asks Touch ID or the password of the Mac, then for a new
/// password — within two minutes, and not past the sleep of the Mac or the lock of its screen. A lock turned on before the app had a password of its own keeps opening by Touch ID
/// and the password of the Mac alone, until a password is chosen in Settings.
///
/// Kept in `UserDefaults` of this Mac (`privacy.lock.enabled`, `privacy.lock.idleMinutes`,
/// `privacy.lock.pausedUntil`, `privacy.lock.wrongAttempts`) and its Keychain, never in the archive: another Mac may have no
/// Touch ID.
@MainActor
@Observable
final class PrivacyLock {
  nonisolated static let enabledKey = "privacy.lock.enabled"
  nonisolated static let idleMinutesKey = "privacy.lock.idleMinutes"
  /// The end of a pause after wrong passwords: a quit and a relaunch do not shorten it.
  nonisolated static let pausedUntilKey = "privacy.lock.pausedUntil"
  /// Wrong passwords in a row, so a quit and a relaunch do not start the count again. Only the
  /// count: nothing about what was typed.
  nonisolated static let wrongAttemptsKey = "privacy.lock.wrongAttempts"
  /// How long the proof of «Забыли пароль?» lets a new password be chosen, or put off, before
  /// the cover asks for the password again: the owner may have walked away.
  static let resetGrantSeconds: TimeInterval = 120
  /// Wrong passwords in a row before the field pauses.
  static let attemptsBeforePause = 5
  /// How long the field pauses, in seconds.
  static let pauseSeconds: TimeInterval = 30
  /// The idle times Settings offers, in minutes.
  static let idleChoices = [1, 5, 15, 60]
  static let defaultIdleMinutes = 5

  /// Why the windows were covered — a token for the journal.
  enum Reason: String {
    case launch, idle, sleep, screen, menu
  }

  /// Whether the lock can lock at all here: never in a data set or in the test host.
  let applies: Bool
  /// The owner turned the lock on (and proved it was the owner when doing so).
  private(set) var isEnabled: Bool
  /// How long the app may stay untouched before it locks; one of `idleChoices`.
  var idleMinutes: Int {
    didSet {
      let sane = Self.sanitized(idleMinutes)
      if sane != idleMinutes { idleMinutes = sane }
      defaults?.set(sane, forKey: Self.idleMinutesKey)
    }
  }
  /// The windows are covered.
  private(set) var isLocked: Bool
  /// A host with a lock of its own (the phone's `AppLock`) says its cover is up: the questions
  /// the app raises by itself wait, and the ones on screen go, exactly as under this lock.
  var hostCovers = false
  /// Covered by this lock or by the host's: what the questions the app raises by itself ask.
  var isCovered: Bool { isLocked || hostCovers }
  /// A request for Touch ID or the password is on screen: a second one is not made.
  private(set) var isAuthenticating = false
  /// What the last attempt to unlock or to turn the lock on came to, when it did not pass; the
  /// cover and Settings say it in words. Cleared by the next attempt.
  private(set) var lastRefusal: LockAuthentication?

  /// The app has a password of its own.
  private(set) var hasPassword: Bool
  /// A typed password is being checked: the field waits.
  private(set) var isCheckingPassword = false
  /// Wrong passwords since the last right one or the last pause.
  private(set) var wrongAttempts = 0
  /// The field takes no password until then.
  private(set) var pausedUntil: Date?
  /// What went wrong with the password last, for the cover and Settings. Cleared by the next
  /// attempt.
  private(set) var passwordProblem: PasswordProblem?
  /// «Забыли пароль?» passed: the cover asks for a new password, until `resetGrantUntil`.
  private(set) var isChoosingNewPassword = false
  /// The end of the proof of «Забыли пароль?».
  @ObservationIgnored private var resetGrantUntil: Date?
  /// Raised by every record started and by every «Отмена»: a record whose number is no longer
  /// the latest was cancelled while it was made, and is not kept.
  @ObservationIgnored private var passwordRequest = 0
  /// The owner proved who they are on the way to the first password (`beginEnabling`).
  private(set) var isChoosingFirstPassword = false

  /// Called whenever the windows get covered (the journal of openings, and the hidden accounts
  /// going back under cover). Set once by the app after the lock is made.
  @ObservationIgnored var onLocked: (() -> Void)?
  /// Called whenever the cover is taken away, with what proved the owner: the password of the
  /// app, or the system's Touch ID / password of the Mac.
  @ObservationIgnored var onUnlocked: ((PrivacyJournalEntry.UnlockMethod) -> Void)?

  /// What went wrong with a password.
  enum PasswordProblem: Equatable, Sendable {
    case wrong(attemptsLeft: Int)
    case paused
    /// The Keychain did not keep or give the record.
    case keychain
    /// Fewer than `LockPassword.minimumLength` characters.
    case tooShort
  }

  /// What a typed password came to.
  enum PasswordAttempt: Equatable, Sendable {
    case unlocked
    case wrong(attemptsLeft: Int)
    case paused(until: Date)
    /// No password is kept (or the Keychain gave none): Touch ID opens.
    case noPassword
    /// Not locked, or a check is under way.
    case ignored
  }

  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private let authenticator: any LockAuthenticator
  @ObservationIgnored private let passwords: any LockPasswordStore
  @ObservationIgnored private let iterations: Int
  @ObservationIgnored private let now: () -> Date
  /// The last key press, click or scroll in the app. Not observed: it changes with every event,
  /// and nothing on screen shows it.
  @ObservationIgnored private(set) var lastActivity: Date
  @ObservationIgnored private var watch: PrivacyLockWatch?

  /// `passwords` is where the record of the password lives: the Keychain in the app
  /// (`AppEnvironment`), memory in a test. `iterations` of a new record: fewer in a test.
  init(
    applies: Bool, defaults: UserDefaults?,
    authenticator: any LockAuthenticator = DeviceOwnerAuthenticator(),
    passwords: any LockPasswordStore = InMemoryLockPasswordStore(),
    iterations: Int = LockPassword.iterations,
    now: @escaping () -> Date = { Date() }
  ) {
    self.applies = applies
    self.defaults = defaults
    self.authenticator = authenticator
    self.passwords = passwords
    self.iterations = iterations
    self.now = now
    let enabled = applies && (defaults?.bool(forKey: Self.enabledKey) ?? false)
    isEnabled = enabled
    // Where the lock does not apply the Keychain is not even read.
    hasPassword = enabled && Self.record(in: passwords) != nil
    if enabled, let until = defaults?.object(forKey: Self.pausedUntilKey) as? Date,
      until > now()
    {
      pausedUntil = until
    }
    if enabled, let kept = defaults?.object(forKey: Self.wrongAttemptsKey) as? Int {
      wrongAttempts = min(max(0, kept), Self.attemptsBeforePause - 1)
    }
    idleMinutes = Self.sanitized(
      defaults?.object(forKey: Self.idleMinutesKey) as? Int ?? Self.defaultIdleMinutes)
    // Locked from the first frame: the window is never drawn with the books open first.
    isLocked = enabled
    lastActivity = now()
    if enabled { Self.journal(locked: .launch) }
  }

  /// The nearest choice to a stored number of minutes: a number written by hand, or by a build
  /// that offered other choices, still gives one of the four.
  static func sanitized(_ minutes: Int) -> Int {
    idleChoices.min { abs($0 - minutes) < abs($1 - minutes) } ?? defaultIdleMinutes
  }

  /// A key press, a click or a scroll in any window of the app.
  func noteActivity() {
    lastActivity = now()
  }

  /// Locks when the app has been left alone for `idleMinutes`. Called by a timer; returns
  /// whether it locked now.
  @discardableResult
  func checkIdle() -> Bool {
    expireResetGrantIfDue()
    guard isEnabled, !isLocked, !isAuthenticating else { return false }
    guard now().timeIntervalSince(lastActivity) >= TimeInterval(idleMinutes * 60) else {
      return false
    }
    lock(because: .idle)
    return true
  }

  /// Covers every window now.
  func lock(because reason: Reason) {
    // Covered already while a new password is chosen: any reason to lock — the Mac sleeping,
    // its screen locking — ends the proof, and the cover asks for the password again.
    if isLocked, isChoosingNewPassword { endResetGrant() }
    guard isEnabled, !isLocked else { return }
    isLocked = true
    lastRefusal = nil
    Self.journal(locked: reason)
    onLocked?()
  }

  /// Asks for Touch ID or the password, and takes the cover away when it passes. `reason` is
  /// the end of the system's sentence: «“OhMyMoney” пытается <reason>».
  @discardableResult
  func unlock(reason: String) async -> Bool {
    guard isLocked, !isAuthenticating else { return !isLocked }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      AppLog.info(
        "privacy.unlockFailed", .ui, "the windows stay covered",
        [LogPair("answer", .token(Self.token(answer)))])
      return false
    }
    uncover()
    AppLog.info("privacy.unlocked", .ui, "the windows were uncovered")
    return true
  }

  /// Takes the cover away and forgets the wrong passwords and the pause: the owner is here.
  private func uncover(by method: PrivacyJournalEntry.UnlockMethod = .touchID) {
    let wasLocked = isLocked
    defer { if wasLocked { onUnlocked?(method) } }
    isLocked = false
    isChoosingNewPassword = false
    resetGrantUntil = nil
    passwordProblem = nil
    endPause()
    lastActivity = now()
  }

  private func endPause() {
    wrongAttempts = 0
    pausedUntil = nil
    defaults?.removeObject(forKey: Self.pausedUntilKey)
    defaults?.removeObject(forKey: Self.wrongAttemptsKey)
  }

  /// Whether the proof of «Забыли пароль?» still holds now.
  private var hasLiveResetGrant: Bool {
    guard isChoosingNewPassword, let resetGrantUntil else { return false }
    return now() < resetGrantUntil
  }

  /// Ends the proof of «Забыли пароль?» when its time is up.
  func expireResetGrantIfDue() {
    guard isChoosingNewPassword, !hasLiveResetGrant else { return }
    endResetGrant()
  }

  /// The cover goes back to asking for the password; a record being made is not kept.
  private func endResetGrant() {
    guard isChoosingNewPassword else { return }
    isChoosingNewPassword = false
    resetGrantUntil = nil
    passwordProblem = nil
    cancelRecord()
    AppLog.info("privacy.resetEnded", .ui, "the proof of a forgotten password ended")
  }

  /// A record being made is not kept: the fields stop waiting at once.
  private func cancelRecord() {
    passwordRequest += 1
    isCheckingPassword = false
  }

  // MARK: - The password

  /// Whether the field is paused at a moment.
  func isPaused(at date: Date) -> Bool {
    guard let pausedUntil else { return false }
    return date < pausedUntil
  }

  /// Whole seconds left of the pause at a moment, rounded up; 0 when there is none.
  func secondsOfPauseLeft(at date: Date) -> Int {
    guard let pausedUntil, date < pausedUntil else { return 0 }
    return Int(pausedUntil.timeIntervalSince(date).rounded(.up))
  }

  /// The moment the lock reads its clock: the cover counts the pause down by it.
  var currentDate: Date { now() }

  /// Takes the cover away when `password` is the app's password. Wrong five times in a row,
  /// the field pauses for thirty seconds; while it does, nothing is checked.
  @discardableResult
  func unlock(password: String) async -> PasswordAttempt {
    guard isLocked, !isCheckingPassword, !isChoosingNewPassword else { return .ignored }
    if let pausedUntil, isPaused(at: now()) {
      passwordProblem = .paused
      return .paused(until: pausedUntil)
    }
    guard let record = Self.record(in: passwords) else {
      passwordProblem = hasPassword ? .keychain : nil
      return .noPassword
    }
    isCheckingPassword = true
    passwordProblem = nil
    let matches = await Task.detached(priority: .userInitiated) {
      record.matches(password)
    }.value
    isCheckingPassword = false
    guard isLocked else { return .ignored }
    guard matches else {
      wrongAttempts += 1
      defaults?.set(wrongAttempts, forKey: Self.wrongAttemptsKey)
      let left = Self.attemptsBeforePause - wrongAttempts
      guard left <= 0 else {
        passwordProblem = .wrong(attemptsLeft: left)
        AppLog.info(
          "privacy.passwordWrong", .ui, "a wrong password was typed",
          [LogPair("attempts", .count(wrongAttempts))])
        return .wrong(attemptsLeft: left)
      }
      let until = now().addingTimeInterval(Self.pauseSeconds)
      wrongAttempts = 0
      defaults?.removeObject(forKey: Self.wrongAttemptsKey)
      pausedUntil = until
      defaults?.set(until, forKey: Self.pausedUntilKey)
      passwordProblem = .paused
      AppLog.info(
        "privacy.passwordPaused", .ui, "too many wrong passwords: the field pauses",
        [LogPair("seconds", .count(Int(Self.pauseSeconds)))])
      return .paused(until: until)
    }
    uncover(by: .password)
    AppLog.info("privacy.passwordUnlock", .ui, "the windows were uncovered")
    return .unlocked
  }

  /// The first step of turning the lock on from Settings: Touch ID or the password of the Mac,
  /// then the app's own password (`enable(password:)`). Refused, the lock stays off.
  @discardableResult
  func beginEnabling(reason: String) async -> Bool {
    guard applies, !isEnabled, !isAuthenticating else { return false }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      AppLog.info(
        "privacy.enableRefused", .ui, "the lock stays off",
        [LogPair("answer", .token(Self.token(answer)))])
      return false
    }
    isChoosingFirstPassword = true
    passwordProblem = nil
    return true
  }

  /// The password was not chosen: the lock stays off.
  func cancelEnabling() {
    isChoosingFirstPassword = false
    passwordProblem = nil
    cancelRecord()
  }

  /// «Отмена» of a changed password in Settings: a record being made is not kept, and the old
  /// password keeps opening.
  func cancelPasswordChange() {
    passwordProblem = nil
    cancelRecord()
  }

  /// Turns the lock on with the app's own password, once `beginEnabling` has had the proof.
  /// The Keychain refusing the record leaves the lock off.
  @discardableResult
  func enable(password: String) async -> Bool {
    guard applies, !isEnabled, isChoosingFirstPassword else { return false }
    guard await keep(password) else { return false }
    isChoosingFirstPassword = false
    isEnabled = true
    lastActivity = now()
    defaults?.set(true, forKey: Self.enabledKey)
    AppLog.info("privacy.lockEnabled", .ui, "the lock was turned on")
    return true
  }

  /// Sets or changes the app's password from Settings, while the lock is on and open.
  @discardableResult
  func setPassword(_ password: String) async -> Bool {
    guard isEnabled, !isLocked else { return false }
    return await keep(password)
  }

  /// Removes the app's password: Touch ID and the password of the Mac open the lock alone.
  @discardableResult
  func removePassword() -> Bool {
    guard hasPassword else { return true }
    do {
      try passwords.delete()
    } catch {
      passwordProblem = .keychain
      Self.journal(keychain: error)
      return false
    }
    hasPassword = false
    passwordProblem = nil
    AppLog.info("privacy.passwordRemoved", .ui, "the app's password was removed")
    return true
  }

  /// «Забыли пароль?»: Touch ID or the password of the Mac, then the cover asks for a new
  /// password (`chooseNewPassword`). The windows stay covered until it is chosen or put off.
  @discardableResult
  func forgotPassword(reason: String) async -> Bool {
    guard isLocked, !isAuthenticating else { return false }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      return false
    }
    endPause()
    passwordProblem = nil
    isChoosingNewPassword = true
    resetGrantUntil = now().addingTimeInterval(Self.resetGrantSeconds)
    // Ends the proof on time even when no timer of the lock is watching.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.resetGrantSeconds))
      self?.expireResetGrantIfDue()
    }
    AppLog.info("privacy.passwordReset", .ui, "the owner proved who they are")
    return true
  }

  /// The new password after «Забыли пароль?»: kept, and the windows uncovered.
  @discardableResult
  func chooseNewPassword(_ password: String) async -> Bool {
    expireResetGrantIfDue()
    guard hasLiveResetGrant else { return false }
    guard await keep(password) else { return false }
    uncover()
    return true
  }

  /// «Позже» after «Забыли пароль?»: the forgotten password goes, the windows are uncovered,
  /// and Touch ID and the password of the Mac open the lock until a new one is chosen.
  func putOffNewPassword() {
    expireResetGrantIfDue()
    guard hasLiveResetGrant else { return }
    _ = removePassword()
    uncover()
  }

  /// Writes the record of a new password to the store. Slow part away from the main actor.
  private func keep(_ password: String) async -> Bool {
    guard password.precomposedStringWithCanonicalMapping.count >= LockPassword.minimumLength
    else {
      passwordProblem = .tooShort
      return false
    }
    passwordRequest += 1
    let request = passwordRequest
    isCheckingPassword = true
    let iterations = self.iterations
    let record = await Task.detached(priority: .userInitiated) {
      LockPassword.make(password, iterations: iterations)
    }.value
    // «Отмена», or the end of the proof, came while the record was made: it wins.
    guard request == passwordRequest else { return false }
    isCheckingPassword = false
    do {
      try passwords.write(record.encoded())
    } catch {
      passwordProblem = .keychain
      Self.journal(keychain: error)
      return false
    }
    hasPassword = true
    passwordProblem = nil
    AppLog.info("privacy.passwordSet", .ui, "the app's password was kept")
    return true
  }

  /// The record kept in a store, if it reads.
  private static func record(in store: any LockPasswordStore) -> LockPassword? {
    guard let data = try? store.read() else { return nil }
    return LockPassword.decoded(data)
  }

  private static func journal(keychain error: any Error) {
    let status = (error as? KeychainFailure)?.status ?? 0
    AppLog.warning(
      "privacy.keychainFailed", .ui, "the Keychain refused the record of the password",
      [LogPair("status", .count(Int(status)))])
  }

  /// Turns the lock on, once the owner has proved who they are; refused, it stays off.
  @discardableResult
  func enable(reason: String) async -> Bool {
    guard applies, !isEnabled, !isAuthenticating else { return isEnabled }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      AppLog.info(
        "privacy.enableRefused", .ui, "the lock stays off",
        [LogPair("answer", .token(Self.token(answer)))])
      return false
    }
    isEnabled = true
    lastActivity = now()
    defaults?.set(true, forKey: Self.enabledKey)
    AppLog.info("privacy.lockEnabled", .ui, "the lock was turned on")
    return true
  }

  /// Turns the lock off and forgets the app's password. Only reachable from Settings, which the
  /// cover hides while locked.
  func disable() {
    guard isEnabled else { return }
    _ = removePassword()
    isEnabled = false
    isLocked = false
    isChoosingNewPassword = false
    resetGrantUntil = nil
    passwordProblem = nil
    endPause()
    lastRefusal = nil
    defaults?.set(false, forKey: Self.enabledKey)
    AppLog.info("privacy.lockDisabled", .ui, "the lock was turned off")
  }

  /// Starts to watch the events of the app, the clock, the sleep of the Mac and the lock of its
  /// screen. Once; never where the lock does not apply.
  func startWatching() {
    guard applies, watch == nil, !AppEnvironment.isTestHost else { return }
    watch = PrivacyLockWatch(lock: self)
  }

  private static func journal(locked reason: Reason) {
    AppLog.info(
      "privacy.locked", .ui, "the windows were covered",
      [LogPair("reason", .token(reason.rawValue))])
  }

  private static func token(_ answer: LockAuthentication) -> String {
    switch answer {
    case .passed: "passed"
    case .failed: "failed"
    case .cancelled: "cancelled"
    case .unavailable: "unavailable"
    }
  }
}

/// The eyes and the clock of `PrivacyLock`: a key press, a click or a scroll in any window of the
/// app keeps it awake; a timer looks at the idle time twice a minute; the sleep of the Mac and the
/// lock of its screen lock at once. Lives as long as the app. The centers the system posts to are
/// handed in, so a test can post the sleep and the lock of the screen itself.
@MainActor
final class PrivacyLockWatch {
  /// What the system posts when the screen of the Mac is locked (⌃⌘Q, the lid, the screen saver).
  nonisolated static let screenLocked = Notification.Name("com.apple.screenIsLocked")
  /// What the system posts before the Mac sleeps and when its displays go dark.
  #if os(macOS)
    nonisolated static let sleeps = [
      NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
    ]
    static var systemWorkspaceCenter: NotificationCenter { NSWorkspace.shared.notificationCenter }
    static var systemDistributedCenter: NotificationCenter {
      DistributedNotificationCenter.default()
    }
  #else
    /// On iPhone the app going to the background is the sleep of the Mac.
    nonisolated static let sleeps = [UIApplication.didEnterBackgroundNotification]
    static var systemWorkspaceCenter: NotificationCenter { .default }
    static var systemDistributedCenter: NotificationCenter { .default }
  #endif

  private var monitor: Any?
  private var timer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(
    lock: PrivacyLock, workspace: NotificationCenter = PrivacyLockWatch.systemWorkspaceCenter,
    distributed: NotificationCenter = PrivacyLockWatch.systemDistributedCenter,
    watchesActivity: Bool = true
  ) {
    #if os(macOS)
      if watchesActivity {
        monitor = NSEvent.addLocalMonitorForEvents(
          matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved,
          ]
        ) { [weak lock] event in
          MainActor.assumeIsolated { lock?.noteActivity() }
          return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak lock] _ in
          MainActor.assumeIsolated { _ = lock?.checkIdle() }
        }
      }
    #endif
    for name in Self.sleeps {
      observe(workspace, name) { [weak lock] in lock?.lock(because: .sleep) }
    }
    observe(distributed, Self.screenLocked) { [weak lock] in lock?.lock(because: .screen) }
  }

  /// Stops watching: the observers, the monitor of events and the timer go.
  func stop() {
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    #if os(macOS)
      if let monitor { NSEvent.removeMonitor(monitor) }
    #endif
    monitor = nil
    timer?.invalidate()
    timer = nil
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    _ action: @escaping @MainActor () -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { action() }
    }
    observers.append((center, token))
  }
}
