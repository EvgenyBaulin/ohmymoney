import XCTest

@testable import OhMyMoney

/// An authenticator that holds its answer until the test lets it go, so a test can look at the
/// lock while a proof is still being asked.
final class GatedAuthenticator: LockAuthenticator, @unchecked Sendable {
  private let queue = NSLock()
  private var waiting: CheckedContinuation<LockAuthentication, Never>?
  private var asked = 0

  var timesAsked: Int { queue.withLock { asked } }

  func authenticate(reason: String) async -> LockAuthentication {
    await withCheckedContinuation { continuation in
      queue.withLock {
        asked += 1
        waiting = continuation
      }
    }
  }

  /// Lets the proof in flight finish with `answer`.
  func finish(with answer: LockAuthentication) {
    let continuation = queue.withLock { () -> CheckedContinuation<LockAuthentication, Never>? in
      defer { waiting = nil }
      return waiting
    }
    continuation?.resume(returning: answer)
  }
}

/// The corners of the lock of the phone the main tests leave: what a refusal leaves behind,
/// the exact minute, a clock that goes back, a second request while the first is open, and
/// what is remembered across a launch.
@MainActor
final class AppLockEdgeTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""

  override func setUp() {
    super.setUp()
    suite = "lock-edge-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  private func make(
    _ answer: LockAuthentication = .passed, clock: TestClock = TestClock()
  ) -> (AppLock, FakeAuthenticator, TestClock) {
    let fake = FakeAuthenticator(answer)
    return (AppLock(defaults: defaults, authenticator: fake, now: { clock.date }), fake, clock)
  }

  private func enabledAndLocked(clock: TestClock = TestClock()) async -> (AppLock, FakeAuthenticator) {
    let (first, _, _) = make(clock: clock)
    _ = await first.enable(reason: "r")
    let (lock, fake, _) = make(clock: clock)
    return (lock, fake)
  }

  func testEveryKindOfRefusalLeavesTheBooksCoveredAndIsRemembered() async {
    for refusal in [LockAuthentication.failed, .cancelled, .unavailable] {
      let (lock, fake) = await enabledAndLocked()
      fake.answer(with: refusal)
      let opened = await lock.unlock(reason: "r")
      XCTAssertFalse(opened, "\(refusal)")
      XCTAssertTrue(lock.isLocked, "\(refusal)")
      XCTAssertEqual(lock.lastRefusal, refusal)
      XCTAssertFalse(lock.isAuthenticating, "a refusal ends the attempt: \(refusal)")
    }
  }

  func testAPassAfterARefusalOpensAndForgetsTheRefusal() async {
    let (lock, fake) = await enabledAndLocked()
    fake.answer(with: .failed)
    _ = await lock.unlock(reason: "r")
    XCTAssertEqual(lock.lastRefusal, .failed)
    fake.answer(with: .passed)
    let opened = await lock.unlock(reason: "r")
    XCTAssertTrue(opened)
    XCTAssertFalse(lock.isLocked)
    XCTAssertNil(lock.lastRefusal)
  }

  func testARefusedEnableChangesNothingNowOrAtTheNextLaunch() async {
    for refusal in [LockAuthentication.failed, .cancelled, .unavailable] {
      let (lock, _, _) = make(refusal)
      let enabled = await lock.enable(reason: "r")
      XCTAssertFalse(enabled, "\(refusal)")
      XCTAssertFalse(lock.isEnabled)
      XCTAssertFalse(lock.isLocked)
      XCTAssertEqual(lock.lastRefusal, refusal)
      let (next, _, _) = make()
      XCTAssertFalse(next.isEnabled, "a refused proof is never stored")
      XCTAssertFalse(next.isLocked)
    }
  }

  func testEnablingTwiceAsksOnlyOnce() async {
    let (lock, fake, _) = make()
    let first = await lock.enable(reason: "r")
    let second = await lock.enable(reason: "r")
    XCTAssertTrue(first)
    XCTAssertTrue(second)
    XCTAssertEqual(fake.timesAsked, 1)
  }

  func testTheLockSurvivesALaunchLockedAndCountsTheLaunchAsALock() async {
    let (lock, _) = await enabledAndLocked()
    XCTAssertTrue(lock.isEnabled)
    XCTAssertTrue(lock.isLocked)
    XCTAssertEqual(lock.lockCount, 1)
    XCTAssertTrue(defaults.bool(forKey: AppLock.enabledKey))
  }

  func testTurningItOffIsKeptForTheNextLaunch() async {
    let (lock, _) = await enabledAndLocked()
    _ = await lock.unlock(reason: "r")
    lock.disable()
    XCTAssertFalse(lock.isEnabled)
    let (next, _, _) = make()
    XCTAssertFalse(next.isEnabled)
    XCTAssertFalse(next.isLocked)
    XCTAssertEqual(next.lockCount, 0)
  }

  func testDisablingAnOffLockOrAClosedOneChangesNothing() async {
    let (off, _, _) = make()
    off.disable()
    XCTAssertFalse(off.isEnabled)
    let (locked, _) = await enabledAndLocked()
    locked.disable()
    XCTAssertTrue(locked.isEnabled, "a covered app cannot be switched off")
    XCTAssertTrue(defaults.bool(forKey: AppLock.enabledKey))
  }

  func testTheExactMinutesLockAndOneSecondLessDoesNot() async {
    let clock = TestClock()
    let (lock, _) = await enabledAndLocked(clock: clock)
    _ = await lock.unlock(reason: "r")
    XCTAssertEqual(lock.minutes, 5)

    lock.didEnterBackground()
    clock.date = clock.date.addingTimeInterval(5 * 60 - 1)
    lock.didBecomeActive()
    XCTAssertFalse(lock.isLocked, "299 seconds are not five minutes")

    lock.didEnterBackground()
    clock.date = clock.date.addingTimeInterval(5 * 60)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked, "exactly five minutes lock")
    XCTAssertEqual(lock.lockCount, 2)
  }

  func testAChangedMinutesChangesTheLimit() async {
    let clock = TestClock()
    let (lock, _) = await enabledAndLocked(clock: clock)
    _ = await lock.unlock(reason: "r")
    lock.minutes = 1
    lock.didEnterBackground()
    clock.advance(minutes: 1)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked)

    _ = await lock.unlock(reason: "r")
    lock.minutes = 60
    lock.didEnterBackground()
    clock.advance(minutes: 59)
    lock.didBecomeActive()
    XCTAssertFalse(lock.isLocked)
    lock.didEnterBackground()
    clock.advance(minutes: 60)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked)
  }

  func testAClockThatWentBackDoesNotLock() async {
    let clock = TestClock()
    let (lock, _) = await enabledAndLocked(clock: clock)
    _ = await lock.unlock(reason: "r")

    lock.didEnterBackground()
    clock.advance(minutes: -120)
    lock.didBecomeActive()
    XCTAssertFalse(lock.isLocked, "a set-back clock is no absence")
  }

  func testComingBackWithoutHavingLeftOrWhileCoveredChangesNothing() async {
    let clock = TestClock()
    let (lock, _) = await enabledAndLocked(clock: clock)
    _ = await lock.unlock(reason: "r")
    clock.advance(minutes: 600)
    lock.didBecomeActive()
    XCTAssertFalse(lock.isLocked, "never left: nothing to count from")

    lock.didEnterBackground()
    clock.advance(minutes: 30)
    lock.didBecomeActive()
    XCTAssertTrue(lock.isLocked)
    XCTAssertEqual(lock.lockCount, 2)
    lock.didEnterBackground()
    clock.advance(minutes: 30)
    lock.didBecomeActive()
    XCTAssertEqual(lock.lockCount, 2, "an already covered app is not covered again")
    XCTAssertNil(lock.leftAt, "the moment is spent by the return")
  }

  func testAnOffLockNeverLocksHoweverLongTheAbsence() {
    let clock = TestClock()
    let (lock, _, _) = make(clock: clock)
    lock.didEnterBackground()
    clock.advance(minutes: 24 * 60)
    lock.didBecomeActive()
    XCTAssertFalse(lock.isLocked)
    XCTAssertEqual(lock.lockCount, 0)
  }

  func testMinutesOutsideTheChoicesSnapToTheNearestAndAreStored() {
    let (lock, _, _) = make()
    for (given, expected) in [(1_000, 60), (-5, 1), (0, 1), (30, 15), (40, 60), (15, 15)] {
      lock.minutes = given
      XCTAssertEqual(lock.minutes, expected, "\(given)")
      XCTAssertEqual(defaults.integer(forKey: AppLock.minutesKey), expected)
    }
    for given in -50...200 {
      XCTAssertTrue(AppLock.minuteChoices.contains(AppLock.sanitized(given)), "\(given)")
    }
  }

  func testAStoredMinutesThatIsDamagedIsReadAsTheNearestChoice() {
    defaults.set(999, forKey: AppLock.minutesKey)
    XCTAssertEqual(make().0.minutes, 60)
    defaults.set("soon", forKey: AppLock.minutesKey)
    XCTAssertEqual(make().0.minutes, AppLock.defaultMinutes, "a text is no number of minutes")
  }

  func testASecondRequestWhileTheFirstIsOpenAsksNothingMore() async {
    let gate = GatedAuthenticator()
    let seed = AppLock(defaults: defaults, authenticator: FakeAuthenticator(.passed))
    _ = await seed.enable(reason: "r")
    let lock = AppLock(defaults: defaults, authenticator: gate)
    XCTAssertTrue(lock.isLocked)

    let first = Task { await lock.unlock(reason: "r") }
    while !lock.isAuthenticating || gate.timesAsked == 0 { await Task.yield() }
    let second = await lock.unlock(reason: "r")
    XCTAssertFalse(second, "the cover is still up while the proof is asked")
    XCTAssertEqual(gate.timesAsked, 1)

    gate.finish(with: .passed)
    let opened = await first.value
    XCTAssertTrue(opened)
    XCTAssertFalse(lock.isLocked)
    XCTAssertFalse(lock.isAuthenticating)
    XCTAssertEqual(gate.timesAsked, 1)
  }

  func testEnableAndUnlockCannotRunOverEachOther() async {
    let gate = GatedAuthenticator()
    let lock = AppLock(defaults: defaults, authenticator: gate)
    let enabling = Task { await lock.enable(reason: "r") }
    while !lock.isAuthenticating || gate.timesAsked == 0 { await Task.yield() }
    let again = await lock.enable(reason: "r")
    XCTAssertFalse(again, "not enabled yet")
    gate.finish(with: .passed)
    let enabled = await enabling.value
    XCTAssertTrue(enabled)
    XCTAssertEqual(gate.timesAsked, 1)
  }
}
