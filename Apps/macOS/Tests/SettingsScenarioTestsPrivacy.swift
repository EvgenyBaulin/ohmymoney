import AppCore
import XCTest

@testable import OhMyMoney

/// Answers every proof the way a test set, and counts the requests.
private final class ScenarioProof: LockAuthenticator, @unchecked Sendable {
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

/// The record of the app's password as it is kept: a salted PBKDF2 of the password in NFC, never
/// the password. These scenarios type passwords in Cyrillic, with combining marks, emoji and
/// spaces, and hand the record broken versions of itself.
final class SettingsScenarioPasswordRecordTests: XCTestCase {
  private let salt: [UInt8] = Array(0..<16)

  private func record(_ password: String) -> LockPassword {
    LockPassword.make(password, salt: salt, iterations: 50)
  }

  func testACyrillicPasswordMatchesOnlyItself() {
    let kept = record("пароль")
    XCTAssertTrue(kept.matches("пароль"))
    XCTAssertFalse(kept.matches("Пароль"))
    XCTAssertFalse(kept.matches("parol"))
    XCTAssertFalse(kept.matches("пароль "))
  }

  /// «ё» typed and «е» with a combining diaeresis pasted are one password.
  func testEitherNormalFormOfTheSameLettersMatches() {
    let kept = record("ёжик")
    XCTAssertTrue(kept.matches("е\u{0308}жик"))
    let decomposed = record("и\u{0306}ога")
    XCTAssertTrue(decomposed.matches("йога"))
  }

  /// «ё» and «е» are two letters for the password, though the search folds them.
  func testYoAndYeAreDifferentLettersOfAPassword() {
    XCTAssertFalse(record("ёлка").matches("елка"))
  }

  func testEmojiAndSpacesArePartOfThePassword() {
    let kept = record("🐈 кот 🐈")
    XCTAssertTrue(kept.matches("🐈 кот 🐈"))
    XCTAssertFalse(kept.matches("🐈кот🐈"))
  }

  func testTheEmptyStringMatchesNoRealPassword() {
    XCTAssertFalse(record("1234").matches(""))
  }

  func testTheSameSaltGivesTheSameHashAndAnotherSaltAnother() {
    XCTAssertEqual(record("1234").hash, record("1234").hash)
    let other = LockPassword.make("1234", salt: Array(repeating: 7, count: 16), iterations: 50)
    XCTAssertNotEqual(other.hash, record("1234").hash)
    XCTAssertTrue(other.matches("1234"))
  }

  func testTheHashHasTheLengthOfAKey() {
    XCTAssertEqual(record("1234").hash.count, LockPassword.keyByteCount)
    let fresh = LockPassword.make("1234", iterations: 10)
    XCTAssertEqual(fresh.salt.count, LockPassword.saltByteCount)
  }

  /// The iteration count travels in the record: a record of another count still opens.
  func testARecordOfAnotherCountStillOpens() {
    let older = LockPassword.make("1234", salt: salt, iterations: 7)
    XCTAssertEqual(older.iterations, 7)
    XCTAssertTrue(older.matches("1234"))
  }

  func testTheKeptBytesReadBackAsTheSameRecord() throws {
    let kept = record("секрет")
    let back = try XCTUnwrap(LockPassword.decoded(kept.encoded()))
    XCTAssertEqual(back, kept)
    XCTAssertTrue(back.matches("секрет"))
    let text = String(decoding: kept.encoded(), as: UTF8.self)
    XCTAssertFalse(text.contains("секрет"))
  }

  func testBytesThatAreNoRecordGiveNone() {
    XCTAssertNil(LockPassword.decoded(Data()))
    XCTAssertNil(LockPassword.decoded(Data("{}".utf8)))
    XCTAssertNil(LockPassword.decoded(Data("password=1234".utf8)))
  }

  /// A record of a later format, of no iterations, of too many, or without a hash matches
  /// nothing — not even the password it was made of.
  func testARecordThisBuildCannotReadMatchesNothing() {
    var later = record("1234")
    later.version = 2
    XCTAssertFalse(later.matches("1234"))
    var none = record("1234")
    none.iterations = 0
    XCTAssertFalse(none.matches("1234"))
    var tooMany = record("1234")
    tooMany.iterations = EncryptionHeader.iterationBounds.upperBound + 1
    XCTAssertFalse(tooMany.matches("1234"))
    var empty = record("1234")
    empty.hash = []
    XCTAssertFalse(empty.matches("1234"))
    var short = record("1234")
    short.hash = Array(short.hash.prefix(16))
    XCTAssertFalse(short.matches("1234"))
  }

  /// Four letters are counted as the owner sees them: «йййй» pasted with combining marks is
  /// four letters, three of them are too few.
  func testTheLengthIsCountedInLettersAsSeen() {
    let three = String(repeating: "и\u{0306}", count: 3)
    let four = String(repeating: "и\u{0306}", count: 4)
    XCTAssertEqual(LockPassword.issue(three, repeated: three), .tooShort)
    XCTAssertNil(LockPassword.issue(four, repeated: String(repeating: "й", count: 4)))
  }

  func testTooShortIsSaidBeforeADifference() {
    XCTAssertEqual(LockPassword.issue("12", repeated: "34"), .tooShort)
    XCTAssertEqual(LockPassword.issue("", repeated: ""), .tooShort)
    XCTAssertEqual(LockPassword.issue("12345", repeated: "12346"), .mismatch)
    XCTAssertNil(LockPassword.issue("🐈🐈🐈🐈", repeated: "🐈🐈🐈🐈"))
  }

  /// A store in memory that refuses, as a Keychain may: every call throws its status.
  func testAStoreThatRefusesThrowsItsStatus() {
    let store = InMemoryLockPasswordStore(Data("x".utf8))
    store.failure = KeychainFailure(status: -25_308)
    XCTAssertThrowsError(try store.read()) {
      XCTAssertEqual($0 as? KeychainFailure, KeychainFailure(status: -25_308))
    }
    XCTAssertThrowsError(try store.write(Data()))
    XCTAssertThrowsError(try store.delete())
    store.failure = nil
    XCTAssertEqual(try store.read(), Data("x".utf8))
    XCTAssertNoThrow(try store.delete())
    XCTAssertNil(try store.read())
  }
}

/// The lock of the windows through a day of use: idle times of every choice and of stored
/// numbers that are none, the moment the idle time ends exactly, activity, the proof refused or
/// cancelled, a password in Cyrillic, a right password that resets the count of wrong ones.
@MainActor
final class SettingsScenarioLockTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var store = InMemoryLockPasswordStore()
  private var moment = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUp() async throws {
    suite = "ohmymoney.tests.f.lock.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    store = InMemoryLockPasswordStore()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeLock(_ proof: ScenarioProof, applies: Bool = true) -> PrivacyLock {
    PrivacyLock(
      applies: applies, defaults: defaults, authenticator: proof, passwords: store,
      iterations: 50, now: { [unowned self] in moment })
  }

  private func enabledLock(
    _ proof: ScenarioProof = ScenarioProof(.passed), password: String = "1234"
  ) async -> PrivacyLock {
    let lock = makeLock(proof)
    let proven = await lock.beginEnabling(reason: "test")
    XCTAssertTrue(proven)
    let enabled = await lock.enable(password: password)
    XCTAssertTrue(enabled)
    return lock
  }

  private func advance(seconds: TimeInterval) { moment = moment.addingTimeInterval(seconds) }

  func testEveryNumberOfMinutesBecomesTheNearestChoice() {
    let expected = [
      -10: 1, 0: 1, 1: 1, 2: 1, 3: 1, 4: 5, 5: 5, 9: 5, 10: 5, 11: 15, 15: 15, 30: 15,
      37: 15, 38: 60, 40: 60, 60: 60, 1_000: 60,
    ]
    for (minutes, choice) in expected {
      XCTAssertEqual(PrivacyLock.sanitized(minutes), choice, "\(minutes)")
    }
  }

  func testAStoredNumberThatIsNoChoiceIsReadAsTheNearest() {
    defaults.set(42, forKey: PrivacyLock.idleMinutesKey)
    XCTAssertEqual(makeLock(ScenarioProof(.passed)).idleMinutes, 60)
    defaults.set("five", forKey: PrivacyLock.idleMinutesKey)
    XCTAssertEqual(makeLock(ScenarioProof(.passed)).idleMinutes, 5)
  }

  func testAChoiceSetToANumberThatIsNoneIsKeptAsTheNearest() {
    let lock = makeLock(ScenarioProof(.passed))
    lock.idleMinutes = 14
    XCTAssertEqual(lock.idleMinutes, 15)
    XCTAssertEqual(defaults.integer(forKey: PrivacyLock.idleMinutesKey), 15)
  }

  /// One second before the idle time ends the books stay open; at its end they close.
  func testTheIdleTimeEndsOnItsSecond() async {
    for minutes in PrivacyLock.idleChoices {
      let lock = await enabledLock()
      lock.idleMinutes = minutes
      lock.noteActivity()
      advance(seconds: TimeInterval(minutes * 60) - 1)
      XCTAssertFalse(lock.checkIdle(), "\(minutes)")
      advance(seconds: 1)
      XCTAssertTrue(lock.checkIdle(), "\(minutes)")
      XCTAssertTrue(lock.isLocked)
      lock.disable()
    }
  }

  /// Every key press starts the idle time anew.
  func testActivityKeepsTheBooksOpenAllDay() async {
    let lock = await enabledLock()
    for _ in 0..<20 {
      advance(seconds: 4 * 60)
      lock.noteActivity()
      XCTAssertFalse(lock.checkIdle())
    }
    XCTAssertFalse(lock.isLocked)
  }

  /// A lock already covering the windows does not lock again.
  func testALockedLockDoesNotLockAgain() async {
    let lock = await enabledLock()
    lock.lock(because: .menu)
    advance(seconds: 3_600)
    XCTAssertFalse(lock.checkIdle())
    XCTAssertTrue(lock.isLocked)
  }

  /// Where the lock does not apply — the test host, a data set — it never turns on.
  func testWhereTheLockDoesNotApplyItCannotBeTurnedOn() async {
    let proof = ScenarioProof(.passed)
    let lock = makeLock(proof, applies: false)
    let proven = await lock.beginEnabling(reason: "test")
    XCTAssertFalse(proven)
    XCTAssertEqual(proof.requests, 0)
    XCTAssertFalse(lock.isEnabled)
  }

  func testEveryRefusedProofLeavesTheLockOff() async {
    for answer in [LockAuthentication.failed, .cancelled, .unavailable] {
      let lock = makeLock(ScenarioProof(answer))
      let proven = await lock.beginEnabling(reason: "test")
      XCTAssertFalse(proven)
      XCTAssertEqual(lock.lastRefusal, answer)
      let enabled = await lock.enable(password: "1234")
      XCTAssertFalse(enabled, "a password without the proof turned the lock on")
      XCTAssertFalse(defaults.bool(forKey: PrivacyLock.enabledKey))
    }
  }

  func testACyrillicPasswordOpensTheNextLaunch() async {
    _ = await enabledLock(password: "ёжик-в-тумане")
    let next = makeLock(ScenarioProof(.failed))
    XCTAssertTrue(next.isLocked)
    let answer1 = await next.unlock(password: "ежик-в-тумане")
    XCTAssertEqual(answer1, .wrong(attemptsLeft: 4))
    let answer2 = await next.unlock(password: "е\u{0308}жик-в-тумане")
    XCTAssertEqual(answer2, .unlocked)
    XCTAssertFalse(next.isLocked)
  }

  /// A right password forgives the wrong ones before it: the next wrong one has four tries
  /// left again.
  func testARightPasswordForgivesTheWrongOnes() async {
    let lock = await enabledLock()
    lock.lock(because: .menu)
    _ = await lock.unlock(password: "0000")
    _ = await lock.unlock(password: "0001")
    let answer3 = await lock.unlock(password: "1234")
    XCTAssertEqual(answer3, .unlocked)
    lock.lock(because: .menu)
    let answer4 = await lock.unlock(password: "0002")
    XCTAssertEqual(answer4, .wrong(attemptsLeft: 4))
  }

  /// An open lock takes no password at all.
  func testAPasswordTypedIntoAnOpenLockIsIgnored() async {
    let lock = await enabledLock()
    let answer5 = await lock.unlock(password: "1234")
    XCTAssertEqual(answer5, .ignored)
    let answer6 = await lock.unlock(password: "0000")
    XCTAssertEqual(answer6, .ignored)
    XCTAssertEqual(lock.wrongAttempts, 0)
  }

  /// A count of wrong passwords written by hand is held to the tries there are.
  func testAKeptCountOutOfRangeIsHeldInside() {
    defaults.set(true, forKey: PrivacyLock.enabledKey)
    defaults.set(99, forKey: PrivacyLock.wrongAttemptsKey)
    XCTAssertEqual(makeLock(ScenarioProof(.passed)).wrongAttempts, 4)
    defaults.set(-3, forKey: PrivacyLock.wrongAttemptsKey)
    XCTAssertEqual(makeLock(ScenarioProof(.passed)).wrongAttempts, 0)
  }

  /// A pause kept from before that has already ended is no pause.
  func testAPauseThatEndedBeforeTheLaunchIsNoPause() {
    defaults.set(true, forKey: PrivacyLock.enabledKey)
    defaults.set(moment.addingTimeInterval(-1), forKey: PrivacyLock.pausedUntilKey)
    let lock = makeLock(ScenarioProof(.passed))
    XCTAssertNil(lock.pausedUntil)
    XCTAssertFalse(lock.isPaused(at: moment))
    XCTAssertEqual(lock.secondsOfPauseLeft(at: moment), 0)
  }

  /// Five wrong passwords at the turn of a year pause the field across midnight as any other.
  func testAPauseCrossesMidnight() async {
    moment = Date(timeIntervalSince1970: 1_798_761_590)  // 31.12.2026 23:59:50 UTC
    let lock = await enabledLock()
    lock.lock(because: .menu)
    for _ in 0..<5 { _ = await lock.unlock(password: "9999") }
    XCTAssertTrue(lock.isPaused(at: moment.addingTimeInterval(29)))
    XCTAssertFalse(lock.isPaused(at: moment.addingTimeInterval(30)))
  }

  /// Touch ID opens the lock beside the password.
  func testTouchIDOpensALockWithAPassword() async {
    let lock = await enabledLock()
    lock.lock(because: .sleep)
    let opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)
    XCTAssertFalse(lock.isLocked)
  }

  /// The proof refused at the cover keeps it on, and says why.
  func testARefusedProofAtTheCoverKeepsItOn() async {
    let proof = ScenarioProof(.passed)
    let lock = await enabledLock(proof)
    lock.lock(because: .screen)
    proof.answer = .failed
    let opened = await lock.unlock(reason: "test")
    XCTAssertFalse(opened)
    XCTAssertTrue(lock.isLocked)
    XCTAssertEqual(lock.lastRefusal, .failed)
  }

  /// Turning the lock off forgets the password and the keys of the lock.
  func testTurningOffForgetsEverything() async {
    let lock = await enabledLock()
    lock.disable()
    XCTAssertFalse(lock.isEnabled)
    XCTAssertNil(try store.read())
    XCTAssertFalse(defaults.bool(forKey: PrivacyLock.enabledKey))
    XCTAssertFalse(makeLock(ScenarioProof(.passed)).isLocked)
  }

  /// A changed password opens, the old one does not.
  func testAChangedPasswordReplacesTheOldOne() async {
    let lock = await enabledLock()
    let answer7 = await lock.setPassword("новый1")
    XCTAssertTrue(answer7)
    lock.lock(because: .menu)
    let answer8 = await lock.unlock(password: "1234")
    XCTAssertEqual(answer8, .wrong(attemptsLeft: 4))
    let answer9 = await lock.unlock(password: "новый1")
    XCTAssertEqual(answer9, .unlocked)
  }
}

/// «Скрыть суммы» as a habit of this Mac: off on a new Mac, kept between launches in a suite of
/// the test's own, and every money figure of both languages and every currency style hidden.
@MainActor
final class SettingsScenarioAmountsTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suite = "ohmymoney.tests.f.amounts.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  func testAmountsAreShownOnANewMac() {
    XCTAssertFalse(AmountPrivacy(defaults: defaults).hidesAmounts)
  }

  func testTheSwitchLastsToTheNextLaunch() {
    let first = AmountPrivacy(defaults: defaults)
    first.toggle()
    XCTAssertTrue(AmountPrivacy(defaults: defaults).hidesAmounts)
    first.toggle()
    XCTAssertFalse(AmountPrivacy(defaults: defaults).hidesAmounts)
  }

  /// Without defaults — the test host — nothing is kept, and the switch still works.
  func testWithoutDefaultsNothingIsKept() {
    let privacy = AmountPrivacy(defaults: nil)
    privacy.hidesAmounts = true
    XCTAssertTrue(privacy.hidesAmounts)
    XCTAssertFalse(AmountPrivacy(defaults: nil).hidesAmounts)
  }

  func testEveryStyleAndCurrencyIsHidden() {
    for style in CurrencyStyle.allCases {
      for language in ["ru", "en"] {
        let money = MoneyFormatter(
          locale: Locale(identifier: language), hidesAmounts: true, currencyStyle: style)
        for currency in [CurrencyCode.rub, .usd, .eur, CurrencyCode("KZT"), CurrencyCode("XYZ")] {
          let mask = MoneyFormatter.mask
          XCTAssertEqual(money.exact(AmountE4(raw: 12_345), currency: currency), mask)
          XCTAssertEqual(money.rounded(AmountE4(whole: -1), currency: currency), mask)
        }
        XCTAssertEqual(money.axis(-2_500_000_000), MoneyFormatter.mask)
        XCTAssertEqual(money.signedRubles(0), MoneyFormatter.mask)
      }
    }
  }

  /// Even zero and the largest amount hide behind the same three dots.
  func testZeroAndTheLargestAmountLookAlikeHidden() {
    let money = MoneyFormatter(locale: Locale(identifier: "ru"), hidesAmounts: true)
    XCTAssertEqual(money.exact(AmountE4(raw: 0)), money.exact(AmountE4(raw: Int64.max)))
    XCTAssertEqual(money.rubles(0), money.rubles(Int64.max))
  }
}
