import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Answers every request with the answer a test set, and counts them.
private final class Proof: LockAuthenticator, @unchecked Sendable {
  private let guardLock = NSLock()
  private var _requests = 0
  private var _answer: LockAuthentication = .passed
  var requests: Int { guardLock.withLock { _requests } }
  var answer: LockAuthentication {
    get { guardLock.withLock { _answer } }
    set { guardLock.withLock { _answer = newValue } }
  }

  func authenticate(reason: String) async -> LockAuthentication {
    guardLock.withLock {
      _requests += 1
      return _answer
    }
  }
}

/// 1.8.0: a question the app raised by itself at launch — the offer of a report after a crash,
/// the overdue payments — stood over the cover of the locked app, modal, and the app could not
/// be entered. Every such question waits while the app is locked, and the lock spends none.
@MainActor
final class LockedPromptsTests: XCTestCase {
  private func lockedLock(password: String? = nil) async -> PrivacyLock {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: Proof(),
      passwords: InMemoryLockPasswordStore(), iterations: 200)
    if let password {
      _ = await lock.beginEnabling(reason: "test")
      _ = await lock.enable(password: password)
    } else {
      _ = await lock.enable(reason: "test")
    }
    lock.lock(because: .launch)
    XCTAssertTrue(lock.isLocked)
    return lock
  }

  func testAQuestionIsNotPresentedWhileLockedAndTheLockAnswersNothing() async {
    let lock = await lockedLock()
    var asks = true
    let presented = lock.presenting(Binding(get: { asks }, set: { asks = $0 }))
    XCTAssertFalse(presented.wrappedValue, "presented over the locked app")
    // What SwiftUI writes when the lock takes a question down is not an answer.
    presented.wrappedValue = false
    XCTAssertTrue(asks, "the lock answered the question")

    _ = await lock.unlock(reason: "test")
    XCTAssertTrue(presented.wrappedValue, "the question did not come after the unlock")
    presented.wrappedValue = false
    XCTAssertFalse(asks, "an answer after the unlock is kept")
  }

  func testAnItemIsNotPresentedWhileLocked() async {
    let lock = await lockedLock()
    var item: String? = "cards"
    let presented = lock.presenting(Binding(get: { item }, set: { item = $0 }))
    XCTAssertNil(presented.wrappedValue)
    presented.wrappedValue = nil
    XCTAssertEqual(item, "cards", "the lock put the cards away")
    _ = await lock.unlock(reason: "test")
    XCTAssertEqual(presented.wrappedValue, "cards")
    XCTAssertTrue(lock.lets(true))
    lock.lock(because: .idle)
    XCTAssertFalse(lock.lets(true))
  }

  /// The overdue payments are not even decided while locked — the day's reminders are not
  /// marked shown, «asked this launch» is not set —, and they are once unlocked.
  func testTheRemindersWaitForTheUnlock() {
    let overdue = [
      OverdueDue(
        subject: .scheduled(UUID()), name: "Rent", due: DateOnly(year: 2026, month: 9, day: 5),
        amount: AmountE4(whole: 30_000), currency: .rub, moreOverdue: 0, countAfter: nil,
        key: nil)
    ]
    XCTAssertNil(
      RemindersPresentation.decide(
        daily: [], overdue: overdue, shownToday: false, askedThisLaunch: false, locked: true))
    XCTAssertEqual(
      RemindersPresentation.decide(
        daily: [], overdue: overdue, shownToday: false, askedThisLaunch: false, locked: false)?
        .asksOverdue, true)
  }
}

/// A sheet or an alert open while the app is locked — whatever raised it — carries the way in on
/// its own cover: a modal sheet takes the clicks and keys of the cover of its window.
@MainActor
final class SheetCoverUnlockTests: XCTestCase {
  private var parent: NSWindow?
  private var sheet: NSWindow?

  override func tearDown() async throws {
    if let sheet, let parent { parent.endSheet(sheet) }
    sheet?.close()
    parent?.close()
    sheet = nil
    parent = nil
  }

  private func spin(_ seconds: TimeInterval = 0.4) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private let proof = Proof()

  private func lockedLock(password: String?) async -> PrivacyLock {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: proof,
      passwords: InMemoryLockPasswordStore(), iterations: 200)
    if let password {
      _ = await lock.beginEnabling(reason: "test")
      _ = await lock.enable(password: password)
    } else {
      _ = await lock.enable(reason: "test")
    }
    lock.lock(because: .launch)
    return lock
  }

  /// A small sheet over a window, as an alert of SwiftUI is.
  private func showSheet() -> NSWindow {
    let parent = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled],
      backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    parent.orderFront(nil)
    let sheet = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 260, height: 150), styleMask: [.titled],
      backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    // dependencies: none — a sheet that reads nothing.
    sheet.contentView = NSHostingView(
      rootView: Button("Прошлый сеанс оборвался") {}.frame(width: 260, height: 150))
    parent.beginSheet(sheet)
    self.parent = parent
    self.sheet = sheet
    spin()
    return sheet
  }

  private func cover(of sheet: NSWindow) -> NSView? {
    sheet.contentView?.subviews.first { $0.identifier == PrivacySheetCovers.identifier }
  }

  func testTheCoverOfASheetUnlocksByTouchID() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let lock = await lockedLock(password: nil)
    let language = AppLanguage()
    let sheet = showSheet()
    PrivacySheetCovers.update(lock: lock, language: language)
    spin()
    XCTAssertNotNil(cover(of: sheet), "the sheet is not covered")
    let touchID = try XCTUnwrap(
      WindowAccessibility.element(identified: "privacy.sheetCover.touchID", in: sheet),
      "the cover of the sheet offers no way in")
    XCTAssertNil(WindowAccessibility.element(identified: "privacy.sheetCover.password", in: sheet))
    WindowAccessibility.press(touchID)
    let deadline = Date().addingTimeInterval(3)
    while lock.isLocked, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(lock.isLocked, "Touch ID on the cover of the sheet did not unlock")
    PrivacySheetCovers.update(lock: lock, language: language)
    XCTAssertNil(cover(of: sheet), "the cover stays after the unlock")
  }

  /// A click on the cover lands on the cover, not on the sheet under it.
  func testAClickOnTheCoverOfASheetLandsOnTheCover() async throws {
    let lock = await lockedLock(password: "1234")
    let sheet = showSheet()
    PrivacySheetCovers.update(lock: lock, language: AppLanguage())
    spin()
    let view = try XCTUnwrap(cover(of: sheet), "the sheet is not covered")
    let content = try XCTUnwrap(sheet.contentView)
    for point in [
      CGPoint(x: content.bounds.midX, y: content.bounds.midY),
      CGPoint(x: content.bounds.midX, y: content.bounds.minY + 30),
    ] {
      let inSuperview = content.superview.map { content.convert(point, to: $0) } ?? point
      let hit = try XCTUnwrap(content.hitTest(inSuperview), "nothing at \(point)")
      XCTAssertTrue(hit.isDescendant(of: view), "a click at \(point) lands on \(hit)")
    }
  }

  /// The app's password typed into the field of the cover of the key sheet, and Return.
  func testThePasswordTypedOnTheCoverOfASheetUnlocks() async throws {
    let lock = await lockedLock(password: "1234")
    // Only the password can open it: Touch ID refuses.
    proof.answer = .failed
    let language = AppLanguage()
    let sheet = showSheet()
    PrivacySheetCovers.update(lock: lock, language: language)
    spin()
    let view = try XCTUnwrap(cover(of: sheet), "the sheet is not covered")
    let field = try XCTUnwrap(
      Self.firstSubview(of: view) as NSSecureTextField?, "the cover has no password field")
    XCTAssertTrue(sheet.makeFirstResponder(field))
    let editor = try XCTUnwrap(sheet.fieldEditor(true, for: field) as? NSTextView)
    editor.insertText("1234", replacementRange: NSRange(location: NSNotFound, length: 0))
    spin(0.1)
    // Return as the keyboard sends it: through the keys of the covered window.
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: sheet.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    XCTAssertTrue(PrivacySheetCovers.handles(event), "Return passed to what is under the cover")
    let deadline = Date().addingTimeInterval(5)
    while lock.isLocked, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(lock.isLocked, "the password on the cover of the sheet did not unlock")
  }

  /// Esc and Return never reach the alert under the cover: «Позже» pressed blind would spend
  /// the offer.
  func testTheKeysOfTheAlertUnderTheCoverAreSwallowed() async throws {
    let lock = await lockedLock(password: "1234")
    let sheet = showSheet()
    PrivacySheetCovers.update(lock: lock, language: AppLanguage())
    spin()
    sheet.makeFirstResponder(nil)
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    XCTAssertTrue(PrivacySheetCovers.handles(escape))
    let letter = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: sheet.windowNumber, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    XCTAssertFalse(PrivacySheetCovers.handles(letter), "typing goes to the field")
    _ = await lock.unlock(reason: "test")
    PrivacySheetCovers.update(lock: lock, language: AppLanguage())
    XCTAssertFalse(PrivacySheetCovers.handles(escape), "keys are swallowed after the unlock")
  }

  /// The cover fits the smallest sheet — an alert, about 260 × 150 — in both languages, with
  /// the password, a problem under it and Touch ID.
  func testTheCoverFitsASmallAlertInBothLanguages() async throws {
    let lock = await lockedLock(password: "1234")
    _ = await lock.unlock(password: "0000")
    for choice in [AppLanguage.Choice.russian, .english] {
      let language = AppLanguage()
      language.choice = choice
      // dependencies: none — the cover reads only the lock and the language it is handed.
      let host = NSHostingController(
        rootView: PrivacySheetCovers.Controls(lock: lock, language: language))
      let size = host.sizeThatFits(in: CGSize(width: 260, height: CGFloat.infinity))
      XCTAssertLessThanOrEqual(size.width, 260, "\(choice)")
      XCTAssertLessThanOrEqual(size.height, 150, "\(choice): \(size)")
    }
  }

  private static func firstSubview<T: NSView>(of view: NSView) -> T? {
    for child in view.subviews {
      if let match = child as? T { return match }
      if let match: T = firstSubview(of: child) { return match }
    }
    return nil
  }
}
