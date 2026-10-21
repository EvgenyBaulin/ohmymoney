import XCTest

@testable import OhMyMoney

/// An authenticator that answers what the test says and counts how often it was asked.
final class FakeAuthenticator: LockAuthenticator, @unchecked Sendable {
  private let queue = NSLock()
  private var answer: LockAuthentication
  private var asked = 0

  init(_ answer: LockAuthentication) { self.answer = answer }

  var timesAsked: Int { queue.withLock { asked } }
  func answer(with next: LockAuthentication) { queue.withLock { answer = next } }

  func authenticate(reason: String) async -> LockAuthentication {
    queue.withLock {
      asked += 1
      return answer
    }
  }
}

final class TestClock: @unchecked Sendable {
  var date = Date(timeIntervalSince1970: 1_800_000_000)
  func advance(minutes: Double) { date = date.addingTimeInterval(minutes * 60) }
}

@MainActor
final class AppLockTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""

  override func setUp() {
    super.setUp()
    suite = "lock-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  private func lock(
    _ answer: LockAuthentication = .passed, clock: TestClock = TestClock()
  ) -> (AppLock, FakeAuthenticator, TestClock) {
    let fake = FakeAuthenticator(answer)
    let lock = AppLock(defaults: defaults, authenticator: fake, now: { clock.date })
    return (lock, fake, clock)
  }

  func testIsOffAndOpenUntilTheOwnerTurnsItOn() {
    let (lock, fake, _) = lock()
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(lock.isLocked)
    XCTAssertEqual(lock.minutes, 5)
    XCTAssertEqual(fake.timesAsked, 0)
  }

  func testTurningItOnAsksForTheProofFirst() async {
    let (lock, fake, _) = lock(.failed)
    let refused = await lock.enable(reason: "x")
    XCTAssertFalse(refused)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertEqual(lock.lastRefusal, .failed)
    fake.answer(with: .passed)
    let accepted = await lock.enable(reason: "x")
    XCTAssertTrue(accepted)
    XCTAssertTrue(lock.isEnabled)
    XCTAssertTrue(defaults.bool(forKey: AppLock.enabledKey))
    // Turned on from an open app: it does not lock itself on the spot.
    XCTAssertFalse(lock.isLocked)
  }

  func testAPhoneThatCanProveNothingCannotTurnItOn() async {
    let (lock, _, _) = lock(.unavailable)
    let accepted = await lock.enable(reason: "x")
    XCTAssertFalse(accepted)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertEqual(lock.lastRefusal, .unavailable)
  }

  func testAnEnabledLockIsLockedFromTheFirstFrame() {
    defaults.set(true, forKey: AppLock.enabledKey)
    let (lock, _, _) = lock()
    XCTAssertTrue(lock.isEnabled)
    XCTAssertTrue(lock.isLocked)
  }

  func testUnlockingNeedsTheProof() async {
    defaults.set(true, forKey: AppLock.enabledKey)
    let (lock, fake, _) = lock(.failed)
    let first = await lock.unlock(reason: "x")
    XCTAssertFalse(first)
    XCTAssertTrue(lock.isLocked)
    XCTAssertEqual(lock.lastRefusal, .failed)
    fake.answer(with: .passed)
    let second = await lock.unlock(reason: "x")
    XCTAssertTrue(second)
    XCTAssertFalse(lock.isLocked)
    XCTAssertNil(lock.lastRefusal)
    XCTAssertEqual(fake.timesAsked, 2)
  }

  func testUnlockingAnOpenAppAsksNothing() async {
    let (lock, fake, _) = lock()
    let open = await lock.unlock(reason: "x")
    XCTAssertTrue(open)
    XCTAssertEqual(fake.timesAsked, 0)
  }

  func testAShortAbsenceDoesNotLockAndALongOneDoes() async {
    defaults.set(true, forKey: AppLock.enabledKey)
    let clock = TestClock()
    let (lock, _, _) = lock(clock: clock)
    XCTAssertTrue(lock.isLocked)
    // Unlocked by hand to test the leaving, not the launch.
    _ = await lock.unlock(reason: "x")
    XCTAssertFalse(lock.isLocked)

    lock.didEnterBackground()
    clock.advance(minutes: 4.9)
    lock.didBecomeActive()
    XCTAssertFalse(lock.isLocked, "back before the five minutes")

    lock.didEnterBackground()
    clock.advance(minutes: 5)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked, "away for the five minutes")
  }

  func testASecondNoticeOfLeavingDoesNotMoveTheMoment() async {
    defaults.set(true, forKey: AppLock.enabledKey)
    let clock = TestClock()
    let (lock, _, _) = lock(clock: clock)
    _ = await lock.unlock(reason: "x")
    lock.didEnterBackground()
    clock.advance(minutes: 3)
    lock.didEnterBackground()
    clock.advance(minutes: 3)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked, "six minutes since the first notice")
  }

  func testTheMinutesAreOneOfTheOffered() {
    let (lock, _, _) = lock()
    lock.minutes = 14
    XCTAssertEqual(lock.minutes, 15)
    lock.minutes = 1
    XCTAssertEqual(defaults.integer(forKey: AppLock.minutesKey), 1)
    XCTAssertEqual(AppLock.sanitized(1000), 60)
    XCTAssertEqual(AppLock.minuteChoices, [1, 5, 15, 60])
  }

  func testALockedAppCannotBeTurnedOffAndAnOpenOneCan() async {
    defaults.set(true, forKey: AppLock.enabledKey)
    let (lock, _, _) = lock()
    lock.disable()
    XCTAssertTrue(lock.isEnabled, "locked: nothing to turn off")
    _ = await lock.unlock(reason: "x")
    lock.disable()
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: AppLock.enabledKey))
  }

  func testEveryLockCountsSoTheRootIsMadeAgain() async {
    let (lock, _, clock) = lock()
    XCTAssertEqual(lock.lockCount, 0)
    _ = await lock.enable(reason: "x")
    XCTAssertEqual(lock.lockCount, 0, "turned on from an open app: not a lock")
    lock.didEnterBackground()
    clock.advance(minutes: 10)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked)
    XCTAssertEqual(lock.lockCount, 1)
    // Opened at the launch with the lock on: the first lock is the launch itself.
    let (launched, _, _) = self.lock()
    XCTAssertEqual(launched.lockCount, 1)
  }
}
