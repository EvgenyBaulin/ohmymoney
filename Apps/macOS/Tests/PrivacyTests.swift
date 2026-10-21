import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Скрыть суммы»: every figure of money the formatter writes becomes the mask; what is not
/// money — counts, percents, rates, the plain numbers the entry line is given back — stays.
@MainActor
final class AmountMaskTests: XCTestCase {
  private let mask = MoneyFormatter.mask

  func testEveryFigureOfMoneyIsMasked() {
    for locale in [Locale(identifier: "ru"), Locale(identifier: "en")] {
      let money = MoneyFormatter(locale: locale, hidesAmounts: true)
      XCTAssertEqual(money.exact(AmountE4(raw: 12_345_000)), mask)
      XCTAssertEqual(money.exact(AmountE4(whole: -250), currency: .usd), mask)
      XCTAssertEqual(money.rounded(AmountE4(raw: 12_345_000)), mask)
      XCTAssertEqual(money.rubles(12_400), mask)
      XCTAssertEqual(money.signedRubles(-3_400), mask, "no sign is left to read")
      XCTAssertEqual(money.signedRounded(AmountE4(whole: 3_400)), mask)
      XCTAssertEqual(money.axis(1_234_567), mask, "the axis of a chart")
      XCTAssertEqual(money.axis(0), mask)
    }
  }

  func testWhatIsNotMoneyStays() {
    let hidden = MoneyFormatter(locale: Locale(identifier: "ru"), hidesAmounts: true)
    let shown = MoneyFormatter(locale: Locale(identifier: "ru"))
    XCTAssertEqual(hidden.count(1_250), shown.count(1_250))
    XCTAssertEqual(hidden.percent(basisPoints: 3_333), shown.percent(basisPoints: 3_333))
    XCTAssertEqual(hidden.signedPercent(basisPoints: -534), shown.signedPercent(basisPoints: -534))
    XCTAssertEqual(hidden.rate(Decimal(string: "83.125")!), "83.125")
    XCTAssertEqual(hidden.number(Decimal(250)), "250", "the quick line is given back its number")
    XCTAssertEqual(hidden.symbol(for: .usd), "$")
  }

  /// A change keeps its direction and its percent — neither tells how much there is.
  func testAChangeKeepsItsDirectionAndPercent() {
    let hidden = MoneyFormatter(locale: Locale(identifier: "en"), hidesAmounts: true)
    let change = Change(current: AmountE4(whole: 1_100), previous: AmountE4(whole: 1_000))
    let text = hidden.change(change)
    XCTAssertEqual(text.delta, mask)
    XCTAssertEqual(text.direction, .up)
    XCTAssertEqual(text.percent, "+10.0%")
  }

  func testShownAmountsAreUntouched() {
    let money = MoneyFormatter(locale: Locale(identifier: "en"))
    XCTAssertFalse(money.hidesAmounts)
    XCTAssertEqual(money.rubles(12_400), "12,400\u{00A0}₽")
  }

  /// The one formatter of the interface follows the switch, at once.
  func testTheFormatterOfTheEnvironmentFollowsTheSwitch() {
    let environment = AppEnvironment()
    XCTAssertFalse(environment.amounts.hidesAmounts, "the test host starts with amounts shown")
    XCTAssertNotEqual(environment.money.rubles(500), mask)
    environment.amounts.toggle()
    XCTAssertEqual(environment.money.rubles(500), mask)
    XCTAssertEqual(
      PrivacyCommands.amountsTitle(environment), environment.language("privacy.showAmounts"))
    environment.amounts.toggle()
    XCTAssertNotEqual(environment.money.rubles(500), mask)
  }

  /// Kept on this Mac from one launch to the next; the test host keeps nothing.
  func testTheSwitchIsKeptOnThisMacOnly() throws {
    let suite = "ohmymoney.tests.privacy.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = AmountPrivacy(defaults: defaults)
    XCTAssertFalse(first.hidesAmounts)
    first.hidesAmounts = true
    XCTAssertTrue(defaults.bool(forKey: AmountPrivacy.key))
    XCTAssertTrue(AmountPrivacy(defaults: defaults).hidesAmounts, "the next launch")

    let unkept = AmountPrivacy(defaults: nil)
    unkept.hidesAmounts = true
    XCTAssertFalse(AmountPrivacy(defaults: nil).hidesAmounts)
  }

  /// The switches of privacy never reach the archive: another Mac decides for itself.
  func testTheArchiveDoesNotCarryThePrivacyKeys() {
    let environment = AppEnvironment()
    environment.amounts.hidesAmounts = true
    let keys = Set(environment.portableSettings().keys)
    XCTAssertFalse(keys.contains(AmountPrivacy.key))
    XCTAssertFalse(keys.contains(PrivacyLock.enabledKey))
    XCTAssertFalse(keys.contains(PrivacyLock.idleMinutesKey))
    XCTAssertFalse(keys.contains { $0.hasPrefix("privacy.") })
  }
}

/// A clock a test moves by hand.
@MainActor
private final class TestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

/// Answers every request with the answer a test set, and counts them.
private final class FakeAuthenticator: LockAuthenticator, @unchecked Sendable {
  private let lock = NSLock()
  private var _answer: LockAuthentication
  private var _requests = 0

  init(_ answer: LockAuthentication) { _answer = answer }

  var answer: LockAuthentication {
    get { lock.withLock { _answer } }
    set { lock.withLock { _answer = newValue } }
  }
  var requests: Int { lock.withLock { _requests } }

  func authenticate(reason: String) async -> LockAuthentication {
    lock.withLock {
      _requests += 1
      return _answer
    }
  }
}

/// «Блокировать Итого»: off by default; turned on only after the proof; locked at the launch,
/// after the idle time and at the sleep of the Mac; opened only by the proof.
@MainActor
final class PrivacyLockTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private let clock = TestClock()

  override func setUp() async throws {
    suite = "ohmymoney.tests.lock.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeLock(
    _ authenticator: FakeAuthenticator, applies: Bool = true
  ) -> PrivacyLock {
    let clock = self.clock
    return PrivacyLock(
      applies: applies, defaults: defaults, authenticator: authenticator, now: { clock.now })
  }

  /// Turned on and proven, as Settings does it.
  private func enabledLock(_ authenticator: FakeAuthenticator) async -> PrivacyLock {
    let lock = makeLock(authenticator)
    let enabled = await lock.enable(reason: "test")
    XCTAssertTrue(enabled)
    return lock
  }

  func testOffByDefault() {
    let lock = makeLock(FakeAuthenticator(.passed))
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(lock.isLocked)
    XCTAssertEqual(lock.idleMinutes, 5)
    clock.advance(minutes: 600)
    XCTAssertFalse(lock.checkIdle(), "a lock that is off never locks")
    lock.lock(because: .sleep)
    XCTAssertFalse(lock.isLocked)
  }

  func testTurningOnAsksForTheProofFirst() async {
    let authenticator = FakeAuthenticator(.failed)
    let lock = makeLock(authenticator)
    let refused = await lock.enable(reason: "test")
    XCTAssertFalse(refused)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertEqual(lock.lastRefusal, .failed)
    XCTAssertFalse(defaults.bool(forKey: PrivacyLock.enabledKey))

    authenticator.answer = .passed
    let turned = await lock.enable(reason: "test")
    XCTAssertTrue(turned)
    XCTAssertTrue(lock.isEnabled)
    XCTAssertFalse(lock.isLocked, "turning it on does not cover the window the owner is in")
    XCTAssertNil(lock.lastRefusal)
    XCTAssertEqual(authenticator.requests, 2)
    XCTAssertTrue(defaults.bool(forKey: PrivacyLock.enabledKey))
  }

  func testTheNextLaunchStartsLocked() async {
    _ = await enabledLock(FakeAuthenticator(.passed))
    let next = makeLock(FakeAuthenticator(.passed))
    XCTAssertTrue(next.isEnabled)
    XCTAssertTrue(next.isLocked, "locked from the first frame")
  }

  /// A data set and the test host are never locked, whatever this Mac keeps.
  func testWhereTheLockDoesNotApplyNothingLocks() async {
    defaults.set(true, forKey: PrivacyLock.enabledKey)
    let lock = makeLock(FakeAuthenticator(.passed), applies: false)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(lock.isLocked)
    let enabled = await lock.enable(reason: "test")
    XCTAssertFalse(enabled)
    XCTAssertFalse(AppEnvironment().lock.applies, "the test host")
    XCTAssertFalse(AppEnvironment().lock.isLocked)
  }

  func testIdleTimeLocksAndActivityPostponesIt() async {
    let lock = await enabledLock(FakeAuthenticator(.passed))
    lock.idleMinutes = 5
    clock.advance(minutes: 4)
    XCTAssertFalse(lock.checkIdle())
    lock.noteActivity()
    clock.advance(minutes: 4)
    XCTAssertFalse(lock.checkIdle(), "a click a minute ago starts the count again")
    clock.advance(minutes: 1)
    XCTAssertTrue(lock.checkIdle())
    XCTAssertTrue(lock.isLocked)
    XCTAssertFalse(lock.checkIdle(), "locked once")
  }

  func testEveryIdleChoiceIsKept() async {
    for minutes in PrivacyLock.idleChoices {
      let lock = await enabledLock(FakeAuthenticator(.passed))
      lock.idleMinutes = minutes
      XCTAssertEqual(makeLock(FakeAuthenticator(.passed)).idleMinutes, minutes)
      lock.noteActivity()
      clock.advance(minutes: Double(minutes) - 0.5)
      XCTAssertFalse(lock.checkIdle())
      clock.advance(minutes: 0.5)
      XCTAssertTrue(lock.checkIdle(), "\(minutes) minutes")
      lock.disable()
    }
  }

  func testAStoredTimeThatIsNoChoiceBecomesTheNearest() {
    defaults.set(7, forKey: PrivacyLock.idleMinutesKey)
    XCTAssertEqual(makeLock(FakeAuthenticator(.passed)).idleMinutes, 5)
    defaults.set(40, forKey: PrivacyLock.idleMinutesKey)
    XCTAssertEqual(makeLock(FakeAuthenticator(.passed)).idleMinutes, 60)
    defaults.set(0, forKey: PrivacyLock.idleMinutesKey)
    XCTAssertEqual(makeLock(FakeAuthenticator(.passed)).idleMinutes, 1)
    let lock = makeLock(FakeAuthenticator(.passed))
    lock.idleMinutes = 14
    XCTAssertEqual(lock.idleMinutes, 15)
  }

  func testTheSleepOfTheMacLocksAtOnce() async {
    let lock = await enabledLock(FakeAuthenticator(.passed))
    lock.lock(because: .sleep)
    XCTAssertTrue(lock.isLocked)
  }

  func testOnlyTheProofUnlocks() async {
    let authenticator = FakeAuthenticator(.passed)
    let lock = await enabledLock(authenticator)
    lock.lock(because: .menu)

    authenticator.answer = .cancelled
    var opened = await lock.unlock(reason: "test")
    XCTAssertFalse(opened)
    XCTAssertTrue(lock.isLocked)
    XCTAssertNil(LockCover.refusalKey(lock.lastRefusal!), "a cancel says nothing")

    authenticator.answer = .failed
    opened = await lock.unlock(reason: "test")
    XCTAssertFalse(opened)
    XCTAssertTrue(lock.isLocked)
    XCTAssertEqual(LockCover.refusalKey(lock.lastRefusal!), "privacy.unlock.failed")

    authenticator.answer = .passed
    opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)
    XCTAssertFalse(lock.isLocked)
    XCTAssertNil(lock.lastRefusal)
    XCTAssertFalse(lock.checkIdle(), "the idle time starts again at the unlock")
  }

  func testTurningOffUncoversAndForgets() async {
    let lock = await enabledLock(FakeAuthenticator(.passed))
    lock.disable()
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: PrivacyLock.enabledKey))
    XCTAssertFalse(makeLock(FakeAuthenticator(.passed)).isLocked)
  }
}

/// A locked window shows no figure and no word of the books — to the eye or to VoiceOver — only
/// the cover with «Разблокировать».
@MainActor
final class PrivacyCurtainWindowTests: XCTestCase {
  private var window: NSWindow?

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
  }

  /// Lets SwiftUI draw what changed.
  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
  }

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// Every text VoiceOver can reach in the window, and every identifier.
  private func texts(in window: NSWindow) -> (texts: [String], identifiers: Set<String>) {
    var texts: [String] = []
    var identifiers = Set<String>()
    func walk(_ element: Any, depth: Int) {
      guard depth < 40, let object = element as? NSObject else { return }
      for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
        if let text = attribute(object, name) as? String, !text.isEmpty { texts.append(text) }
      }
      if let identifier = attribute(object, "accessibilityIdentifier") as? String {
        identifiers.insert(identifier)
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    if let root = window.contentView { walk(root, depth: 0) }
    return (texts, identifiers)
  }

  func testALockedWindowShowsNoMoney() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = AppEnvironment()
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: FakeAuthenticator(.passed))
    let enabled = await lock.enable(reason: "test")
    XCTAssertTrue(enabled)
    let amount = environment.money.exact(AmountE4(whole: 123_456))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the content reads the formatter and the lock it is handed.
    window.contentView = NSHostingView(
      rootView: VStack {
        Text(verbatim: amount)
        Button(amount) {}
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .privacyCurtain(lock, language: environment.language))
    window.orderFront(nil)
    self.window = window
    settle()
    XCTAssertTrue(texts(in: window).texts.contains { $0.contains("123,456") }, "shown unlocked")

    lock.lock(because: .menu)
    settle()
    let locked = texts(in: window)
    XCTAssertFalse(locked.texts.contains { $0.contains("123,456") }, "\(locked.texts)")
    XCTAssertTrue(locked.identifiers.contains("privacy.unlock"), "the cover offers to unlock")

    _ = await lock.unlock(reason: "test")
    settle()
    XCTAssertTrue(texts(in: window).texts.contains { $0.contains("123,456") }, "shown again")
  }
}
