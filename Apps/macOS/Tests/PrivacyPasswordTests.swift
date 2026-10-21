import AppCore
import AppKit
import Security
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Answers every request with the answer a test set, and counts them.
private final class ProofAnswers: LockAuthenticator, @unchecked Sendable {
  private let guardLock = NSLock()
  private var _answer: LockAuthentication
  private var _requests = 0

  init(_ answer: LockAuthentication) { _answer = answer }

  var answer: LockAuthentication {
    get { guardLock.withLock { _answer } }
    set { guardLock.withLock { _answer = newValue } }
  }
  var requests: Int { guardLock.withLock { _requests } }

  func authenticate(reason: String) async -> LockAuthentication {
    guardLock.withLock {
      _requests += 1
      return _answer
    }
  }
}

/// A store that counts how often it is read.
private final class CountingStore: LockPasswordStore, @unchecked Sendable {
  private let guardLock = NSLock()
  private var _reads = 0
  var reads: Int { guardLock.withLock { _reads } }
  func read() throws -> Data? {
    guardLock.withLock { _reads += 1 }
    return nil
  }
  func write(_ data: Data) throws {}
  func delete() throws {}
}

/// The record of the password: a salted PBKDF2 of the NFC password, never the password; the
/// rules of a new password typed twice.
final class LockPasswordRecordTests: XCTestCase {
  private let salt = [UInt8](repeating: 7, count: 16)

  func testTheRecordMatchesItsPasswordOnly() {
    let record = LockPassword.make("1234", salt: salt, iterations: 100)
    XCTAssertTrue(record.matches("1234"))
    XCTAssertFalse(record.matches("1235"))
    XCTAssertFalse(record.matches(""))
    XCTAssertFalse(record.matches("1234 "), "a space is a character of the password")
  }

  /// The hash is PBKDF2-HMAC-SHA256 of the project's own implementation, over the UTF-8 of the
  /// password in NFC: the same bytes the primitive gives.
  func testTheHashIsPBKDF2OfThePasswordInNFC() {
    let record = LockPassword.make("пароль", salt: salt, iterations: 100)
    XCTAssertEqual(
      record.hash,
      PBKDF2.deriveKey(password: "пароль", salt: salt, iterations: 100, keyByteCount: 32))
    XCTAssertEqual(record.salt, salt)
    XCTAssertEqual(record.iterations, 100)

    // «й» typed, and «и» with a combining breve pasted: one password.
    let typed = LockPassword.make("мой\u{0439}", salt: salt, iterations: 100)
    XCTAssertTrue(typed.matches("мой\u{0438}\u{0306}"))
  }

  func testEveryRecordHasASaltOfItsOwn() {
    let first = LockPassword.make("1234", iterations: 100)
    let second = LockPassword.make("1234", iterations: 100)
    XCTAssertEqual(first.salt.count, LockPassword.saltByteCount)
    XCTAssertNotEqual(first.salt, second.salt)
    XCTAssertNotEqual(first.hash, second.hash)
    XCTAssertTrue(first.matches("1234"))
    XCTAssertTrue(second.matches("1234"))
  }

  /// What is kept is the record, in which the password itself is nowhere.
  func testTheKeptBytesHoldNoPassword() throws {
    let record = LockPassword.make("тайна-секрет", salt: salt, iterations: 100)
    let bytes = record.encoded()
    XCTAssertNil(bytes.range(of: Data("тайна-секрет".utf8)))
    XCTAssertNil(bytes.range(of: Data("тайна".utf8)))
    XCTAssertEqual(LockPassword.decoded(bytes), record)
    XCTAssertNil(LockPassword.decoded(Data("1234".utf8)), "bytes that are no record")
  }

  /// A record that cannot be right never opens: another format, no hash, a count out of range.
  func testABrokenRecordMatchesNothing() {
    var record = LockPassword.make("1234", salt: salt, iterations: 100)
    record.version = 2
    XCTAssertFalse(record.matches("1234"))
    record = LockPassword.make("1234", salt: salt, iterations: 100)
    record.hash = []
    XCTAssertFalse(record.matches("1234"))
    record = LockPassword.make("1234", salt: salt, iterations: 100)
    record.iterations = 0
    XCTAssertFalse(record.matches("1234"))
  }

  func testANewPasswordHasFourCharactersAndIsTypedTwiceAlike() {
    XCTAssertEqual(LockPassword.issue("123", repeated: "123"), .tooShort)
    XCTAssertEqual(LockPassword.issue("", repeated: ""), .tooShort)
    XCTAssertEqual(LockPassword.issue("1234", repeated: "1243"), .mismatch)
    XCTAssertNil(LockPassword.issue("1234", repeated: "1234"))
    XCTAssertNil(LockPassword.issue("ёжик", repeated: "ёжик"), "letters count as characters")
    XCTAssertEqual(LockPassword.issue("ab", repeated: "abcd"), .tooShort, "too short first")
  }

  /// The archive's figure in the optimised build; fewer in Debug, whose code runs unoptimised.
  func testTheIterationCount() {
    #if DEBUG
      XCTAssertEqual(LockPassword.iterations, 20_000)
    #else
      XCTAssertEqual(LockPassword.iterations, 600_000)
    #endif
    XCTAssertEqual(EncryptionHeader.recommendedIterations, 600_000)
  }
}

/// The lock with the app's own password: turned on with Touch ID and a password, opened by the
/// password or by Touch ID, paused after five wrong passwords, reset by «Забыли пароль?».
@MainActor
final class PrivacyPasswordTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var store = InMemoryLockPasswordStore()
  private var moment = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUp() async throws {
    suite = "ohmymoney.tests.lockPassword.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    store = InMemoryLockPasswordStore()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeLock(_ proof: ProofAnswers, applies: Bool = true) -> PrivacyLock {
    PrivacyLock(
      applies: applies, defaults: defaults, authenticator: proof, passwords: store,
      iterations: 200, now: { [unowned self] in moment })
  }

  /// Turned on as Settings does it: the proof, then the password.
  private func enabledLock(_ proof: ProofAnswers, password: String = "1234") async -> PrivacyLock {
    let lock = makeLock(proof)
    let proven = await lock.beginEnabling(reason: "test")
    XCTAssertTrue(proven)
    let enabled = await lock.enable(password: password)
    XCTAssertTrue(enabled)
    return lock
  }

  private func advance(seconds: TimeInterval) { moment = moment.addingTimeInterval(seconds) }

  // MARK: Turning on

  func testTurningOnAsksTheProofThenThePassword() async {
    let proof = ProofAnswers(.failed)
    let lock = makeLock(proof)
    let refused = await lock.beginEnabling(reason: "test")
    XCTAssertFalse(refused)
    XCTAssertFalse(lock.isChoosingFirstPassword, "the password is asked only after the proof")
    XCTAssertEqual(lock.lastRefusal, .failed)
    let early = await lock.enable(password: "1234")
    XCTAssertFalse(early, "a password without the proof turned the lock on")
    XCTAssertFalse(lock.isEnabled)

    proof.answer = .passed
    let proven = await lock.beginEnabling(reason: "test")
    XCTAssertTrue(proven)
    XCTAssertTrue(lock.isChoosingFirstPassword)
    XCTAssertFalse(lock.isEnabled, "on before the password was chosen")
    let short = await lock.enable(password: "123")
    XCTAssertFalse(short)
    XCTAssertEqual(lock.passwordProblem, .tooShort)
    let enabled = await lock.enable(password: "1234")
    XCTAssertTrue(enabled)
    XCTAssertTrue(lock.isEnabled)
    XCTAssertTrue(lock.hasPassword)
    XCTAssertFalse(lock.isChoosingFirstPassword)
    XCTAssertFalse(lock.isLocked, "turning on does not lock at once")
    let kept = try? XCTUnwrap(store.read())
    XCTAssertTrue(kept.flatMap(LockPassword.decoded)?.matches("1234") == true)
    XCTAssertNil(kept?.range(of: Data("1234".utf8)), "the password itself was kept")
  }

  func testAPasswordNotChosenLeavesTheLockOff() async {
    let lock = makeLock(ProofAnswers(.passed))
    _ = await lock.beginEnabling(reason: "test")
    lock.cancelEnabling()
    XCTAssertFalse(lock.isChoosingFirstPassword)
    let late = await lock.enable(password: "1234")
    XCTAssertFalse(late)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertNil(try store.read())
  }

  func testAKeychainThatRefusesLeavesTheLockOff() async {
    let lock = makeLock(ProofAnswers(.passed))
    _ = await lock.beginEnabling(reason: "test")
    store.failure = KeychainFailure(status: errSecInteractionNotAllowed)
    let enabled = await lock.enable(password: "1234")
    XCTAssertFalse(enabled)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(lock.hasPassword)
    XCTAssertEqual(lock.passwordProblem, .keychain)
  }

  // MARK: Unlocking

  func testThePasswordOpensTheNextLaunch() async {
    _ = await enabledLock(ProofAnswers(.passed), password: "сова1")
    let proof = ProofAnswers(.failed)
    let next = makeLock(proof)
    XCTAssertTrue(next.isLocked)
    XCTAssertTrue(next.hasPassword)

    let wrong = await next.unlock(password: "сова2")
    XCTAssertEqual(wrong, .wrong(attemptsLeft: 4))
    XCTAssertTrue(next.isLocked)
    XCTAssertEqual(next.passwordProblem, .wrong(attemptsLeft: 4))

    let right = await next.unlock(password: "сова1")
    XCTAssertEqual(right, .unlocked)
    XCTAssertFalse(next.isLocked)
    XCTAssertNil(next.passwordProblem)
    XCTAssertEqual(next.wrongAttempts, 0)
    XCTAssertEqual(proof.requests, 0, "the password asked for Touch ID")
  }

  /// Five wrong passwords pause the field for thirty seconds: while it waits, even the right
  /// one is not checked; the seconds count down; then the right one opens.
  func testFiveWrongPasswordsPauseTheFieldForThirtySeconds() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.lock(because: .menu)
    for left in [4, 3, 2, 1] {
      let attempt = await lock.unlock(password: "0000")
      XCTAssertEqual(attempt, .wrong(attemptsLeft: left))
    }
    let fifth = await lock.unlock(password: "0000")
    XCTAssertEqual(fifth, .paused(until: moment.addingTimeInterval(30)))
    XCTAssertTrue(lock.isPaused(at: moment))
    XCTAssertEqual(lock.secondsOfPauseLeft(at: moment), 30)
    XCTAssertEqual(lock.passwordProblem, .paused)

    let rightButPaused = await lock.unlock(password: "1234")
    XCTAssertEqual(rightButPaused, .paused(until: moment.addingTimeInterval(30)))
    XCTAssertTrue(lock.isLocked, "the right password opened during the pause")

    advance(seconds: 10.4)
    XCTAssertEqual(lock.secondsOfPauseLeft(at: moment), 20, "rounded up")
    advance(seconds: 19.6)
    XCTAssertEqual(lock.secondsOfPauseLeft(at: moment), 0)
    XCTAssertFalse(lock.isPaused(at: moment))

    let afterThePause = await lock.unlock(password: "1234")
    XCTAssertEqual(afterThePause, .unlocked)
    XCTAssertNil(lock.pausedUntil)
  }

  /// A quit and a relaunch do not shorten the pause.
  func testThePauseOutlivesARelaunch() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.lock(because: .menu)
    for _ in 0..<5 { _ = await lock.unlock(password: "0000") }
    advance(seconds: 5)

    let next = makeLock(ProofAnswers(.passed))
    XCTAssertEqual(next.secondsOfPauseLeft(at: moment), 25)
    let attempt = await next.unlock(password: "1234")
    XCTAssertEqual(attempt, .paused(until: moment.addingTimeInterval(25)))
    advance(seconds: 25)
    let later = await next.unlock(password: "1234")
    XCTAssertEqual(later, .unlocked)
    XCTAssertNil(defaults.object(forKey: PrivacyLock.pausedUntilKey), "the pause is forgotten")
  }

  /// Touch ID opens beside the password, and ends a pause: the owner is here.
  func testTouchIDOpensBesideThePasswordAndEndsAPause() async {
    let proof = ProofAnswers(.passed)
    let lock = await enabledLock(proof)
    lock.lock(because: .menu)
    for _ in 0..<5 { _ = await lock.unlock(password: "0000") }
    XCTAssertTrue(lock.isPaused(at: moment))

    let opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)
    XCTAssertFalse(lock.isLocked)
    XCTAssertNil(lock.pausedUntil)
    XCTAssertEqual(lock.wrongAttempts, 0)
  }

  // MARK: Forgot the password

  func testAForgottenPasswordIsReplacedAfterTheProof() async {
    let proof = ProofAnswers(.passed)
    let lock = await enabledLock(proof, password: "старый")
    lock.lock(because: .menu)

    proof.answer = .failed
    let refused = await lock.forgotPassword(reason: "test")
    XCTAssertFalse(refused)
    XCTAssertFalse(lock.isChoosingNewPassword)
    XCTAssertTrue(lock.isLocked)

    proof.answer = .passed
    let proven = await lock.forgotPassword(reason: "test")
    XCTAssertTrue(proven)
    XCTAssertTrue(lock.isChoosingNewPassword)
    XCTAssertTrue(lock.isLocked, "the proof alone uncovered the windows")
    let ignored = await lock.unlock(password: "старый")
    XCTAssertEqual(ignored, .ignored, "the old password is not asked while a new one is chosen")

    let short = await lock.chooseNewPassword("123")
    XCTAssertFalse(short)
    XCTAssertTrue(lock.isLocked)
    let chosen = await lock.chooseNewPassword("новый1")
    XCTAssertTrue(chosen)
    XCTAssertFalse(lock.isLocked)
    XCTAssertFalse(lock.isChoosingNewPassword)

    lock.lock(because: .menu)
    let old = await lock.unlock(password: "старый")
    XCTAssertEqual(old, .wrong(attemptsLeft: 4))
    let new = await lock.unlock(password: "новый1")
    XCTAssertEqual(new, .unlocked)
  }

  /// «Позже»: the forgotten password goes, Touch ID opens until a new one is set.
  func testAForgottenPasswordPutOffLeavesTouchIDAlone() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.lock(because: .menu)
    _ = await lock.forgotPassword(reason: "test")
    lock.putOffNewPassword()
    XCTAssertFalse(lock.isLocked)
    XCTAssertFalse(lock.hasPassword)
    XCTAssertTrue(lock.isEnabled, "putting the password off turned the lock off")
    XCTAssertNil(try store.read())

    lock.lock(because: .menu)
    let attempt = await lock.unlock(password: "1234")
    XCTAssertEqual(attempt, .noPassword)
    let opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)
  }

  /// The proof of «Забыли пароль?» does not last: two minutes later neither «Позже» nor a new
  /// password uncovers the windows, and the cover asks for the password again.
  func testTheProofOfAForgottenPasswordExpires() async {
    let lock = await enabledLock(ProofAnswers(.passed), password: "старый")
    lock.lock(because: .menu)
    _ = await lock.forgotPassword(reason: "test")
    XCTAssertTrue(lock.isChoosingNewPassword)

    advance(seconds: PrivacyLock.resetGrantSeconds + 1)
    lock.putOffNewPassword()
    XCTAssertTrue(lock.isLocked, "«Позже» uncovered the windows after the proof expired")
    XCTAssertTrue(lock.hasPassword, "an expired proof removed the password")
    XCTAssertFalse(lock.isChoosingNewPassword, "the cover still asks for a new password")
    let chosen = await lock.chooseNewPassword("новый1")
    XCTAssertFalse(chosen, "a new password was chosen on an expired proof")
    XCTAssertTrue(lock.isLocked)
    let old = await lock.unlock(password: "старый")
    XCTAssertEqual(old, .unlocked, "the old password stopped working")
  }

  /// The clock of the app ends an expired proof by itself: the cover is back to the password.
  func testTheTimerEndsAnExpiredProof() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.lock(because: .menu)
    _ = await lock.forgotPassword(reason: "test")
    advance(seconds: PrivacyLock.resetGrantSeconds - 1)
    lock.checkIdle()
    XCTAssertTrue(lock.isChoosingNewPassword, "the proof ended early")
    advance(seconds: 2)
    lock.checkIdle()
    XCTAssertFalse(lock.isChoosingNewPassword)
    XCTAssertTrue(lock.isLocked)
  }

  /// The sleep of the Mac or the lock of its screen end the proof at once.
  func testSleepAndTheLockOfTheScreenEndTheProof() async {
    for reason in [PrivacyLock.Reason.sleep, .screen, .idle] {
      defaults.removePersistentDomain(forName: suite)
      store = InMemoryLockPasswordStore()
      let lock = await enabledLock(ProofAnswers(.passed))
      lock.lock(because: .menu)
      _ = await lock.forgotPassword(reason: "test")
      lock.lock(because: reason)
      XCTAssertFalse(lock.isChoosingNewPassword, "\(reason)")
      lock.putOffNewPassword()
      XCTAssertTrue(lock.isLocked, "\(reason)")
      XCTAssertTrue(lock.hasPassword, "\(reason)")
    }
  }

  /// A quit and a relaunch do not forget the wrong passwords: the fifth pauses the field even
  /// across launches. Only the count is kept, nothing about what was typed.
  func testWrongPasswordsOutliveARelaunch() async {
    let lock = await enabledLock(ProofAnswers(.passed), password: "сова1")
    lock.lock(because: .menu)
    for _ in 0..<3 { _ = await lock.unlock(password: "0000") }
    XCTAssertEqual(defaults.integer(forKey: PrivacyLock.wrongAttemptsKey), 3)

    let next = makeLock(ProofAnswers(.failed))
    XCTAssertEqual(next.wrongAttempts, 3)
    let fourth = await next.unlock(password: "0000")
    XCTAssertEqual(fourth, .wrong(attemptsLeft: 1))
    let third = makeLock(ProofAnswers(.failed))
    let fifth = await third.unlock(password: "0000")
    XCTAssertEqual(fifth, .paused(until: moment.addingTimeInterval(30)))
    XCTAssertNil(defaults.object(forKey: PrivacyLock.wrongAttemptsKey), "the pause starts a count")

    advance(seconds: 30)
    _ = await third.unlock(password: "0000")
    XCTAssertEqual(defaults.integer(forKey: PrivacyLock.wrongAttemptsKey), 1)
    let right = await third.unlock(password: "сова1")
    XCTAssertEqual(right, .unlocked)
    XCTAssertNil(defaults.object(forKey: PrivacyLock.wrongAttemptsKey), "a right one forgets")
  }

  /// Touch ID forgets the kept count of wrong passwords too.
  func testTouchIDForgetsTheKeptWrongPasswords() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.lock(because: .menu)
    _ = await lock.unlock(password: "0000")
    XCTAssertEqual(defaults.integer(forKey: PrivacyLock.wrongAttemptsKey), 1)
    _ = await lock.unlock(reason: "test")
    XCTAssertNil(defaults.object(forKey: PrivacyLock.wrongAttemptsKey))
    XCTAssertEqual(makeLock(ProofAnswers(.failed)).wrongAttempts, 0)
  }

  /// Waits, on the main actor, until the lock is making a record; fails when it never does.
  private func waitUntilMakingTheRecord(_ lock: PrivacyLock) async {
    for _ in 0..<10_000 where !lock.isCheckingPassword { await Task.yield() }
    XCTAssertTrue(lock.isCheckingPassword, "the record was never being made")
  }

  /// «Отмена» while the record of the first password is being made wins: the lock stays off and
  /// nothing is kept.
  func testCancellingTheFirstPasswordWhileItIsMadeLeavesTheLockOff() async {
    let lock = PrivacyLock(
      applies: true, defaults: defaults, authenticator: ProofAnswers(.passed), passwords: store,
      iterations: 60_000, now: { [unowned self] in moment })
    _ = await lock.beginEnabling(reason: "test")
    let enabling = Task { await lock.enable(password: "1234") }
    await waitUntilMakingTheRecord(lock)
    lock.cancelEnabling()
    XCTAssertFalse(lock.isCheckingPassword, "the fields still wait after «Отмена»")
    let enabled = await enabling.value
    XCTAssertFalse(enabled, "the lock was turned on after «Отмена»")
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(lock.hasPassword)
    XCTAssertNil(try store.read(), "a password was kept after «Отмена»")
    XCTAssertFalse(defaults.bool(forKey: PrivacyLock.enabledKey))
  }

  /// «Отмена» while a changed password is being made: the old password still opens.
  func testCancellingAChangeWhileItIsMadeKeepsTheOldPassword() async {
    let lock = PrivacyLock(
      applies: true, defaults: defaults, authenticator: ProofAnswers(.passed), passwords: store,
      iterations: 60_000, now: { [unowned self] in moment })
    _ = await lock.beginEnabling(reason: "test")
    _ = await lock.enable(password: "1234")
    let changing = Task { await lock.setPassword("второй") }
    await waitUntilMakingTheRecord(lock)
    lock.cancelPasswordChange()
    let changed = await changing.value
    XCTAssertFalse(changed, "the password was changed after «Отмена»")
    lock.lock(because: .menu)
    let old = await lock.unlock(password: "1234")
    XCTAssertEqual(old, .unlocked, "the old password stopped working after «Отмена»")
  }

  // MARK: Settings

  func testThePasswordIsChangedAndRemovedInSettings() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    let changed = await lock.setPassword("второй")
    XCTAssertTrue(changed)
    lock.lock(because: .menu)
    let old = await lock.unlock(password: "1234")
    XCTAssertEqual(old, .wrong(attemptsLeft: 4))
    let new = await lock.unlock(password: "второй")
    XCTAssertEqual(new, .unlocked)

    XCTAssertTrue(lock.removePassword())
    XCTAssertFalse(lock.hasPassword)
    XCTAssertTrue(lock.isEnabled)
    XCTAssertNil(try store.read())
  }

  /// Nothing about the password changes while the windows are covered.
  func testThePasswordIsNotChangedWhileLocked() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.lock(because: .menu)
    let changed = await lock.setPassword("второй")
    XCTAssertFalse(changed)
  }

  func testTurningTheLockOffForgetsThePassword() async {
    let lock = await enabledLock(ProofAnswers(.passed))
    lock.disable()
    XCTAssertFalse(lock.hasPassword)
    XCTAssertNil(try store.read())
    XCTAssertFalse(makeLock(ProofAnswers(.passed)).isLocked)
  }

  // MARK: A lock turned on before the password

  /// The lock was on before the app had a password of its own: it keeps opening by Touch ID and
  /// the password of the Mac, the cover asks for no password, and Settings can set one.
  func testALockWithoutAPasswordKeepsOpeningByTouchID() async {
    defaults.set(true, forKey: PrivacyLock.enabledKey)
    let proof = ProofAnswers(.passed)
    let lock = makeLock(proof)
    XCTAssertTrue(lock.isEnabled)
    XCTAssertTrue(lock.isLocked)
    XCTAssertFalse(lock.hasPassword)

    let typed = await lock.unlock(password: "1234")
    XCTAssertEqual(typed, .noPassword)
    XCTAssertNil(lock.passwordProblem, "no password is no problem")
    let opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)

    let set = await lock.setPassword("1234")
    XCTAssertTrue(set)
    XCTAssertTrue(makeLock(proof).hasPassword, "the password set in Settings is not kept")
  }

  /// Where the lock does not apply — a data set, the test host — the Keychain is never read.
  func testWhereTheLockDoesNotApplyTheKeychainIsNotRead() {
    defaults.set(true, forKey: PrivacyLock.enabledKey)
    let counting = CountingStore()
    let lock = PrivacyLock(
      applies: false, defaults: defaults, authenticator: ProofAnswers(.passed),
      passwords: counting)
    XCTAssertFalse(lock.isLocked)
    XCTAssertEqual(counting.reads, 0)
  }

  /// The app's environment in the test host keeps the password in memory, never in the
  /// owner's Keychain.
  func testTheTestHostKeepsNoPasswordInTheKeychain() async {
    let environment = AppEnvironment()
    XCTAssertFalse(environment.lock.applies)
    XCTAssertFalse(environment.lock.hasPassword)
  }

  /// Every word of the password, in both languages.
  func testTheWordsOfThePasswordAreTranslated() {
    let keys = [
      "privacy.password", "privacy.password.new", "privacy.password.repeat",
      "privacy.password.rule", "privacy.password.tooShort", "privacy.password.mismatch",
      "privacy.password.paused", "privacy.password.keychain", "privacy.password.forgot",
      "privacy.forgot.reason", "privacy.password.chooseNew", "privacy.password.saveAndUnlock",
      "privacy.password.later", "privacy.unlock.touchID", "privacy.locked.passwordHint",
      "privacy.password.title", "privacy.password.change", "privacy.password.explain",
      "privacy.password.turnOn", "privacy.password.save", "privacy.password.cancel",
    ]
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys { XCTAssertNotEqual(language(key), key, "\(key): \(choice)") }
      for key in [
        "settings.privacy.password", "settings.privacy.passwordSet", "settings.privacy.noPassword",
        "settings.privacy.changePassword", "settings.privacy.removePassword",
        "settings.privacy.setPassword",
      ] {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key): \(choice)")
      }
    }
    language.choice = .russian
    XCTAssertEqual(
      language.format("privacy.password.wrong", counts: 3), "Неверный пароль. Осталось попыток: 3")
    XCTAssertEqual(
      language.format("privacy.password.pausedFor", counts: 21),
      "Слишком много попыток. Повторите через 21 секунду.")
    XCTAssertEqual(
      language.format("privacy.password.pausedFor", counts: 30),
      "Слишком много попыток. Повторите через 30 секунд.")
    language.choice = .english
    XCTAssertEqual(
      language.format("privacy.password.pausedFor", counts: 1),
      "Too many attempts. Try again in 1 second.")
  }
}

/// The cover of a lock with a password: the field, «Touch ID» beside it, «Забыли пароль?»; the
/// countdown of a pause; the fields of a new password after the proof.
@MainActor
final class LockCoverPasswordWindowTests: XCTestCase {
  private var window: NSWindow?
  private var moment = Date(timeIntervalSince1970: 1_800_000_000)

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
  }

  private func show(_ lock: PrivacyLock) -> NSWindow {
    let language = AppLanguage()
    language.choice = .english
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the content reads only the lock and the language it is handed.
    window.contentView = NSHostingView(
      rootView: Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        .privacyCurtain(lock, language: language))
    window.orderFront(nil)
    self.window = window
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    return window
  }

  /// Lets SwiftUI draw what changed.
  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func identifiers(in window: NSWindow) -> Set<String> {
    Set(
      WindowAccessibility.elements(in: window).compactMap {
        WindowAccessibility.attribute($0, "accessibilityIdentifier") as? String
      })
  }

  private func lockedWithPassword() async -> PrivacyLock {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: ProofAnswers(.passed),
      passwords: InMemoryLockPasswordStore(), iterations: 200,
      now: { [unowned self] in moment })
    _ = await lock.beginEnabling(reason: "test")
    _ = await lock.enable(password: "1234")
    lock.lock(because: .menu)
    return lock
  }

  func testTheCoverOffersThePasswordAndTouchID() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let lock = await lockedWithPassword()
    let window = show(lock)
    let found = identifiers(in: window)
    for identifier in [
      "privacy.password", "privacy.unlock.password", "privacy.unlock.touchID",
      "privacy.password.forgot",
    ] {
      XCTAssertTrue(found.contains(identifier), "\(identifier) missing: \(found)")
    }
    XCTAssertFalse(found.contains("privacy.password.pause"))

    for _ in 0..<5 { _ = await lock.unlock(password: "0000") }
    spin(0.4)
    XCTAssertTrue(identifiers(in: window).contains("privacy.password.pause"), "no countdown")

    _ = await lock.forgotPassword(reason: "test")
    spin(0.4)
    let choosing = identifiers(in: window)
    for identifier in [
      "privacy.password.new", "privacy.password.repeat", "privacy.password.save",
      "privacy.password.later",
    ] {
      XCTAssertTrue(choosing.contains(identifier), "\(identifier) missing: \(choosing)")
    }
    XCTAssertFalse(choosing.contains("privacy.password"), "the old field is still offered")
  }

  /// A lock without a password of the app: the cover of before, Touch ID alone.
  func testWithoutAPasswordTheCoverOffersTouchIDAlone() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: ProofAnswers(.passed),
      passwords: InMemoryLockPasswordStore())
    _ = await lock.enable(reason: "test")
    lock.lock(because: .menu)
    let found = identifiers(in: show(lock))
    XCTAssertTrue(found.contains("privacy.unlock"), "\(found)")
    XCTAssertFalse(found.contains("privacy.password"))
    XCTAssertFalse(found.contains("privacy.password.forgot"))
  }
}

/// Settings: turning the lock on asks Touch ID, then shows the sheet of the password; with the
/// lock on and a password, «Сменить…» and «Убрать»; with none, «Задать пароль…».
@MainActor
final class PrivacySettingsPasswordWindowTests: XCTestCase {
  private var window: NSWindow?

  override func tearDown() async throws {
    if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
    window?.contentView = nil
    window?.close()
    window = nil
  }

  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func showSettings(with lock: PrivacyLock) -> NSWindow {
    let environment = AppEnvironment()
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: ComputeStore(calendar: .utc))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Form { PrivacySettingsSection(lockShown: lock) }
        .formStyle(.grouped)
        .appDependencies(deps))
    window.orderFront(nil)
    self.window = window
    spin(0.4)
    return window
  }

  private func identifiers(in window: NSWindow) -> Set<String> {
    Set(
      WindowAccessibility.elements(in: window).compactMap {
        WindowAccessibility.attribute($0, "accessibilityIdentifier") as? String
      })
  }

  func testTurningOnShowsThePasswordSheetAfterTheProof() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: ProofAnswers(.passed),
      passwords: InMemoryLockPasswordStore(), iterations: 200)
    let window = showSettings(with: lock)
    let toggle = try XCTUnwrap(
      WindowAccessibility.element(identified: "settings.privacy.lock", in: window))
    WindowAccessibility.press(toggle)
    for _ in 0..<40 where window.attachedSheet == nil {
      try await Task.sleep(for: .milliseconds(50))
      spin(0.02)
    }
    spin(0.3)
    XCTAssertTrue(lock.isChoosingFirstPassword)
    XCTAssertFalse(lock.isEnabled, "on before the password was chosen")
    let sheet = try XCTUnwrap(window.attachedSheet, "no sheet of the password")
    let found = identifiers(in: sheet)
    for identifier in ["privacy.password.new", "privacy.password.repeat", "privacy.password.save"] {
      XCTAssertTrue(found.contains(identifier), "\(identifier) missing: \(found)")
    }
  }

  func testTheRowOfThePasswordFollowsWhetherThereIsOne() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: ProofAnswers(.passed),
      passwords: InMemoryLockPasswordStore(), iterations: 200)
    _ = await lock.enable(reason: "test")
    let window = showSettings(with: lock)
    var found = identifiers(in: window)
    XCTAssertTrue(found.contains("settings.privacy.setPassword"), "\(found)")
    XCTAssertFalse(found.contains("settings.privacy.removePassword"))

    _ = await lock.setPassword("1234")
    spin(0.4)
    found = identifiers(in: window)
    XCTAssertTrue(found.contains("settings.privacy.changePassword"), "\(found)")
    XCTAssertTrue(found.contains("settings.privacy.removePassword"), "\(found)")
    XCTAssertFalse(found.contains("settings.privacy.setPassword"))
  }
}

/// The real Keychain of this Mac, from the sandboxed and locally signed test host: an item of a
/// service of the test's own is written, read, replaced and removed. Not on CI, whose login
/// Keychain is locked.
final class KeychainLockPasswordStoreTests: XCTestCase {
  func testTheSandboxedAppKeepsItsItemInTheLoginKeychain() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["OHMYMONEY_CI"] != nil, "the runner's Keychain is locked")
    let store = KeychainLockPasswordStore(
      service: "io.github.EvgenyBaulin.ohmymoney.tests.lock.\(UUID().uuidString)", account: "test")
    defer { try? store.delete() }
    do {
      XCTAssertNil(try store.read())
      try store.write(Data("first".utf8))
    } catch let failure as KeychainFailure where failure.status == errSecInteractionNotAllowed {
      throw XCTSkip("the login Keychain is locked")
    }
    XCTAssertEqual(try store.read(), Data("first".utf8))
    try store.write(Data("second".utf8))
    XCTAssertEqual(try store.read(), Data("second".utf8), "the item was not replaced")
    try store.delete()
    XCTAssertNil(try store.read())
    try store.delete()
  }
}
