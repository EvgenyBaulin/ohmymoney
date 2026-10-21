import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Answers every request with the answer a test set.
private final class AnsweringAuthenticator: LockAuthenticator, @unchecked Sendable {
  private let lock = NSLock()
  private var _answer: LockAuthentication

  init(_ answer: LockAuthentication) { _answer = answer }

  var answer: LockAuthentication {
    get { lock.withLock { _answer } }
    set { lock.withLock { _answer = newValue } }
  }

  func authenticate(reason: String) async -> LockAuthentication {
    lock.withLock { _answer }
  }
}

/// «Блокировать Итого» wired to the app: the sleep of the Mac and the lock of its screen, as the
/// system posts them, cover the windows; «Вид → Заблокировать Итого» is offered only while the
/// lock is on; Settings says in words why the lock stayed off.
@MainActor
final class PrivacyLockWiringTests: XCTestCase {
  private var window: NSWindow?

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
  }

  private func enabledLock() async -> PrivacyLock {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: AnsweringAuthenticator(.passed))
    let enabled = await lock.enable(reason: "test")
    XCTAssertTrue(enabled)
    return lock
  }

  private func post(_ name: Notification.Name, to center: NotificationCenter) {
    center.post(name: name, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  }

  /// A word of a catalog in one language, as the bundle has it.
  private static func word(_ language: String, _ key: String, table: String = "Common") -> String {
    Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))?
      .localizedString(forKey: key, value: nil, table: table) ?? key
  }

  // MARK: The system's notifications

  /// The sleep of the Mac, its displays going dark, and the lock of its screen each lock at once;
  /// a watch stopped hears nothing.
  func testTheSleepAndTheLockOfTheScreenLock() async throws {
    let lock = await enabledLock()
    let workspace = NotificationCenter()
    let distributed = NotificationCenter()
    let watch = PrivacyLockWatch(
      lock: lock, workspace: workspace, distributed: distributed, watchesActivity: false)
    defer { watch.stop() }

    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
      XCTAssertFalse(lock.isLocked)
      post(name, to: workspace)
      XCTAssertTrue(lock.isLocked, "\(name.rawValue) did not lock")
      let opened = await lock.unlock(reason: "test")
      XCTAssertTrue(opened)
    }

    post(PrivacyLockWatch.screenLocked, to: distributed)
    XCTAssertTrue(lock.isLocked, "the lock of the screen did not lock")
    let opened = await lock.unlock(reason: "test")
    XCTAssertTrue(opened)

    watch.stop()
    post(NSWorkspace.willSleepNotification, to: workspace)
    post(PrivacyLockWatch.screenLocked, to: distributed)
    XCTAssertFalse(lock.isLocked, "a stopped watch locked")
  }

  /// What the app listens to by default: the workspace's sleep and the system's own name of a
  /// locked screen, on the distributed center where the system posts it.
  func testTheWatchListensWhereTheSystemPosts() {
    XCTAssertEqual(PrivacyLockWatch.screenLocked.rawValue, "com.apple.screenIsLocked")
    XCTAssertEqual(
      Set(PrivacyLockWatch.sleeps),
      [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification])
  }

  /// A lock that is off hears the sleep and stays open.
  func testALockThatIsOffIgnoresTheSleep() {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: AnsweringAuthenticator(.passed))
    let workspace = NotificationCenter()
    let watch = PrivacyLockWatch(
      lock: lock, workspace: workspace, distributed: NotificationCenter(),
      watchesActivity: false)
    defer { watch.stop() }
    post(NSWorkspace.willSleepNotification, to: workspace)
    XCTAssertFalse(lock.isLocked)
  }

  // MARK: «Вид → Заблокировать Итого»

  func testTheMenuOffersToLockOnlyWhileTheLockIsOn() async {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: AnsweringAuthenticator(.passed))
    XCTAssertFalse(PrivacyCommands.offersLockNow(lock), "off: no item")
    _ = await lock.enable(reason: "test")
    XCTAssertTrue(PrivacyCommands.offersLockNow(lock), "on: the item is there")
    lock.disable()
    XCTAssertFalse(PrivacyCommands.offersLockNow(lock), "off again: the item goes")
  }

  /// The test host's lock is off, and its menu bar has no «Заблокировать Итого»; «Скрыть суммы»
  /// with ⌃⌘H is there.
  func testTheMenuBarOfTheHostHasNoLockItemWhileOff() {
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let all = items(NSApp.mainMenu)
    let environment = AppEnvironment()
    XCTAssertFalse(environment.lock.isEnabled)
    let lockTitles = [
      Self.word("ru", "privacy.lockNow"), Self.word("en", "privacy.lockNow"),
    ]
    XCTAssertFalse(all.contains { lockTitles.contains($0.title) }, "\(lockTitles)")
    XCTAssertTrue(
      all.contains {
        $0.keyEquivalent == "h"
          && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            == [.command, .control]
      }, "⌃⌘H is not in the menu bar")
  }

  // MARK: Settings

  private func showSettings(with lock: PrivacyLock) -> NSWindow {
    let environment = AppEnvironment()
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: ComputeStore(calendar: .utc))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Form { PrivacySettingsSection(lockShown: lock) }
        .formStyle(.grouped)
        .appDependencies(deps))
    window.orderFront(nil)
    self.window = window
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    return window
  }

  /// Lets SwiftUI draw what changed.
  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func texts(in window: NSWindow) -> [String] {
    WindowAccessibility.elements(in: window).map(WindowAccessibility.text(of:))
  }

  /// The switch turned on, the proof refused: it stays off and the caption says why; a cancel
  /// says nothing.
  func testARefusedProofIsSaidUnderTheSwitch() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let authenticator = AnsweringAuthenticator(.failed)
    let lock = PrivacyLock(applies: true, defaults: nil, authenticator: authenticator)
    let window = showSettings(with: lock)
    let refused = AppEnvironment().language("settings.privacy.lockRefused", table: "Settings")
    XCTAssertFalse(texts(in: window).contains { $0.contains(refused) }, "no caption before")

    let toggle = try XCTUnwrap(
      WindowAccessibility.element(identified: "settings.privacy.lock", in: window))
    WindowAccessibility.press(toggle)
    for _ in 0..<20 where lock.lastRefusal == nil {
      try await Task.sleep(for: .milliseconds(50))
      spin(0.02)
    }
    spin(0.3)
    XCTAssertFalse(lock.isEnabled, "a refused proof leaves the lock off")
    XCTAssertTrue(
      texts(in: window).contains { $0.contains(refused) }, "no caption: \(texts(in: window))")

    authenticator.answer = .cancelled
    WindowAccessibility.press(toggle)
    for _ in 0..<20 where lock.lastRefusal != .cancelled {
      try await Task.sleep(for: .milliseconds(50))
      spin(0.02)
    }
    spin(0.3)
    XCTAssertFalse(lock.isEnabled)
    XCTAssertFalse(texts(in: window).contains { $0.contains(refused) }, "a cancel says nothing")
  }

  /// The words of the caption, in both languages.
  func testTheCaptionsOfARefusalAreTranslated() {
    XCTAssertEqual(PrivacySettingsSection.refusalKey(.failed), "settings.privacy.lockRefused")
    XCTAssertEqual(
      PrivacySettingsSection.refusalKey(.unavailable), "settings.privacy.lockUnavailable")
    XCTAssertNil(PrivacySettingsSection.refusalKey(.cancelled))
    for key in ["settings.privacy.lockRefused", "settings.privacy.lockUnavailable"] {
      let ru = Self.word("ru", key, table: "Settings")
      let en = Self.word("en", key, table: "Settings")
      XCTAssertNotEqual(ru, key)
      XCTAssertNotEqual(en, key)
      XCTAssertNotEqual(ru, en, key)
    }
  }
}
