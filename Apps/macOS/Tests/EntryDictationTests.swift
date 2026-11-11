import XCTest

@testable import OhMyMoney

@MainActor
private final class FakeEntrySpeech: EntrySpeechRecognizing {
  var available = true
  var authorized = true
  var failsToStart = false
  var authorizationCount = 0
  var locales: [String] = []
  var starts = 0
  var stops = 0
  var holdsAuthorization = false
  var pendingAuthorization: CheckedContinuation<Bool, Never>?
  var receivers: [@MainActor @Sendable (EntryDictationEvent) -> Void] = []

  func isAvailable(localeIdentifier: String) -> Bool {
    locales.append(localeIdentifier)
    return available
  }

  func authorize() async -> Bool {
    authorizationCount += 1
    if holdsAuthorization {
      return await withCheckedContinuation { pendingAuthorization = $0 }
    }
    return authorized
  }

  func start(
    localeIdentifier: String,
    receive: @escaping @MainActor @Sendable (EntryDictationEvent) -> Void
  ) throws {
    starts += 1
    locales.append(localeIdentifier)
    if failsToStart { throw EntryDictationError.unavailable }
    receivers.append(receive)
  }

  func stop() { stops += 1 }

  func send(_ words: String, final: Bool = false) {
    receivers.last?(.transcript(words, isFinal: final))
  }
}

@MainActor
private final class FakeEntryPause: EntryDictationPauseScheduling {
  var action: (@MainActor () -> Void)?
  var delay: Duration?
  var schedules = 0

  func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
    schedules += 1
    self.delay = delay
    self.action = action
  }

  func cancel() { action = nil }
  func elapse() { action?() }
}

@MainActor
private final class DictationFixture {
  let speech = FakeEntrySpeech()
  let pause = FakeEntryPause()
  var line = ""
  lazy var dictation = EntryDictation(speech: speech, pause: pause)

  func toggle(code: String = "ru") async {
    await dictation.toggle(
      interfaceCode: code, readLine: { self.line }, writeLine: { self.line = $0 })
  }
}

/// The same tests compile into both hosts; no Speech or microphone permission is requested.
@MainActor
final class EntryDictationTests: XCTestCase {
  func testStartsIdleAndDoesNotRequestPermissionAtInitialization() {
    let f = DictationFixture()
    XCTAssertEqual(f.dictation.state, .idle)
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.speech.authorizationCount, 0)
    XCTAssertEqual(f.speech.starts, 0)
    XCTAssertNil(f.dictation.state.hintKey)
  }

  func testAuthorizedTapStartsLocalRecognitionInInterfaceLanguage() async {
    let f = DictationFixture()
    await f.toggle()
    XCTAssertEqual(f.dictation.state, .listening)
    XCTAssertTrue(f.dictation.isActive)
    XCTAssertEqual(f.speech.locales, ["ru-RU", "ru-RU"])
    XCTAssertEqual(f.speech.authorizationCount, 1)
    XCTAssertEqual(f.pause.delay, .seconds(6))
    f.dictation.stop()
  }

  func testEnglishAndSystemResolvedCodesUseSupportedLocales() {
    XCTAssertEqual(EntryDictation.localeIdentifier(interfaceCode: "ru"), "ru-RU")
    XCTAssertEqual(EntryDictation.localeIdentifier(interfaceCode: "ru-RU"), "ru-RU")
    XCTAssertEqual(EntryDictation.localeIdentifier(interfaceCode: "en"), "en-US")
  }

  func testMissingLocalModelNeverRequestsPermissionOrStartsRecognition() async {
    let f = DictationFixture()
    f.line = "typed"
    f.speech.available = false
    await f.toggle()
    XCTAssertEqual(f.dictation.state, .unavailable)
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.line, "typed")
    XCTAssertEqual(f.speech.authorizationCount, 0)
    XCTAssertEqual(f.speech.starts, 0)
  }

  func testDeniedPermissionPreservesTypingAndOffersExplanation() async {
    let f = DictationFixture()
    f.line = "typed"
    f.speech.authorized = false
    await f.toggle()
    XCTAssertEqual(f.dictation.state, .denied)
    XCTAssertEqual(f.dictation.state.hintKey, "entry.dictation.denied")
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.speech.starts, 0)
    f.line += " more"
    f.dictation.lineChanged(to: f.line)
    XCTAssertEqual(f.line, "typed more")
  }

  func testPermissionCanBeRetriedAfterSettingsChange() async {
    let f = DictationFixture()
    f.speech.authorized = false
    await f.toggle()
    f.speech.authorized = true
    await f.toggle(code: "en")
    XCTAssertEqual(f.dictation.state, .listening)
    XCTAssertEqual(f.speech.locales.last, "en-US")
    f.dictation.stop()
  }

  func testPartialResultsReplaceHypothesesInsteadOfAppendingThem() async {
    let f = DictationFixture()
    f.line = "typed"
    await f.toggle()
    f.speech.send("coffee")
    XCTAssertEqual(f.line, "typed coffee")
    f.speech.send("coffee 250")
    XCTAssertEqual(f.line, "typed coffee 250")
    f.dictation.lineChanged(to: f.line)
    XCTAssertTrue(f.dictation.isActive)
    XCTAssertEqual(f.pause.delay, .seconds(2))
    f.dictation.stop()
  }

  func testEmptyPrefixAndExistingWhitespaceNeedNoExtraSpace() async {
    for prefix in ["", "typed ", "typed\n"] {
      let f = DictationFixture()
      f.line = prefix
      await f.toggle()
      f.speech.send("coffee")
      XCTAssertEqual(f.line, prefix + "coffee")
      f.dictation.stop()
    }
  }

  func testEmptyResultDoesNotChangeTheLineOrKeepTheMicrophoneAlive() async {
    let f = DictationFixture()
    f.line = "typed"
    await f.toggle()
    let deadline = f.pause.action
    f.speech.send("")
    XCTAssertEqual(f.line, "typed")
    XCTAssertEqual(f.pause.delay, .seconds(6))
    deadline?()
    XCTAssertEqual(f.dictation.state, .idle)
  }

  func testSecondTapStopsAndKeepsLatestText() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee 250")
    await f.toggle()
    XCTAssertEqual(f.dictation.state, .idle)
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.line, "coffee 250")
    XCTAssertNil(f.pause.action)
    XCTAssertEqual(f.speech.stops, 1)
    f.speech.send("late words")
    XCTAssertEqual(f.line, "coffee 250")
  }

  func testPauseStopsAndPreservesText() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee")
    f.pause.elapse()
    XCTAssertEqual(f.dictation.state, .idle)
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.line, "coffee")
    XCTAssertEqual(f.speech.stops, 1)
  }

  func testRepeatedHypothesisDoesNotExtendSilenceDeadline() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee")
    let deadline = f.pause.action
    f.speech.send("coffee")
    XCTAssertEqual(f.pause.schedules, 2)
    deadline?()
    XCTAssertFalse(f.dictation.isActive)
    f.dictation.stop()
  }

  func testFinalResultStopsAndWritesItsLastCorrection() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee 200")
    f.speech.send("coffee 250", final: true)
    XCTAssertEqual(f.line, "coffee 250")
    XCTAssertEqual(f.dictation.state, .idle)
    XCTAssertNil(f.pause.action)
    f.speech.send("late")
    XCTAssertEqual(f.line, "coffee 250")
  }

  func testEmptyFinalStopsWithoutChangingTypedText() async {
    let f = DictationFixture()
    f.line = "typed"
    await f.toggle()
    f.speech.send("", final: true)
    XCTAssertEqual(f.line, "typed")
    XCTAssertEqual(f.dictation.state, .idle)
  }

  func testKeyboardEditStopsAndCannotBeOverwrittenByLateResult() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee")
    f.line = "tea 200"
    f.dictation.lineChanged(to: f.line)
    f.speech.send("coffee 250")
    XCTAssertEqual(f.line, "tea 200")
    XCTAssertFalse(f.dictation.isActive)
  }

  func testKeyboardEditIsProtectedEvenBeforeSwiftUIReportsTheChange() async {
    let f = DictationFixture()
    await f.toggle()
    f.line = "keyboard"
    f.speech.send("late hypothesis")
    XCTAssertEqual(f.line, "keyboard")
    XCTAssertEqual(f.dictation.state, .idle)
  }

  func testOldSessionResultAndDeadlineCannotAffectNewSession() async {
    let f = DictationFixture()
    await f.toggle()
    let oldReceiver = f.speech.receivers[0]
    let oldDeadline = f.pause.action
    f.speech.send("coffee")
    f.dictation.stop()
    await f.toggle()
    oldReceiver(.transcript("old", isFinal: true))
    oldReceiver(.unavailable)
    oldDeadline?()
    XCTAssertEqual(f.dictation.state, .listening)
    XCTAssertEqual(f.line, "coffee")
    f.speech.send("250")
    XCTAssertEqual(f.line, "coffee 250")
    f.dictation.stop()
  }

  func testRuntimeFailureKeepsThePartialTextAndReleasesMicrophone() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee")
    f.speech.receivers.last?(.unavailable)
    XCTAssertEqual(f.dictation.state, .unavailable)
    XCTAssertEqual(f.dictation.state.hintKey, "entry.dictation.unavailable")
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.line, "coffee")
    XCTAssertNil(f.pause.action)
    XCTAssertEqual(f.speech.stops, 1)
  }

  func testAudioStartupFailureCleansUpWithoutTouchingInput() async {
    let f = DictationFixture()
    f.line = "typed"
    f.speech.failsToStart = true
    await f.toggle()
    XCTAssertEqual(f.dictation.state, .unavailable)
    XCTAssertFalse(f.dictation.isActive)
    XCTAssertEqual(f.line, "typed")
    XCTAssertEqual(f.speech.stops, 1)
    XCTAssertNil(f.pause.action)
  }

  func testStopWhilePermissionIsPendingCannotStartMicrophoneLater() async {
    let f = DictationFixture()
    f.speech.holdsAuthorization = true
    let toggle = Task { await f.toggle() }
    // Yield until the fake reaches its continuation; no wall-clock delay or system prompt.
    while f.speech.pendingAuthorization == nil { await Task.yield() }
    XCTAssertTrue(f.dictation.isActive)
    await f.toggle()
    f.speech.pendingAuthorization?.resume(returning: true)
    await toggle.value
    XCTAssertEqual(f.dictation.state, .idle)
    XCTAssertEqual(f.speech.starts, 0)
  }

  func testEditingWhilePermissionIsPendingCancelsTheRequest() async {
    let f = DictationFixture()
    f.speech.holdsAuthorization = true
    let toggle = Task { await f.toggle() }
    while f.speech.pendingAuthorization == nil { await Task.yield() }
    f.line = "keyboard"
    f.dictation.lineChanged(to: f.line)
    f.speech.pendingAuthorization?.resume(returning: true)
    await toggle.value
    XCTAssertEqual(f.speech.starts, 0)
    XCTAssertEqual(f.line, "keyboard")
  }

  func testOldAuthorizationCannotDenyANewerSession() async {
    let f = DictationFixture()
    f.speech.holdsAuthorization = true
    let first = Task { await f.toggle() }
    while f.speech.pendingAuthorization == nil { await Task.yield() }
    let oldAuthorization = f.speech.pendingAuthorization
    f.dictation.stop()
    f.speech.holdsAuthorization = false
    await f.toggle()
    oldAuthorization?.resume(returning: false)
    await first.value
    XCTAssertEqual(f.dictation.state, .listening)
    XCTAssertTrue(f.dictation.isActive)
    XCTAssertEqual(f.speech.starts, 1)
    f.dictation.stop()
  }

  func testLifecycleStopReleasesAudioAndInvalidatesPendingResults() async {
    let f = DictationFixture()
    await f.toggle()
    f.speech.send("coffee")
    // The view uses stop on save, dismissal, language change and scene deactivation.
    f.dictation.stop()
    f.line = ""
    f.speech.send("late words", final: true)
    XCTAssertEqual(f.line, "")
    XCTAssertEqual(f.speech.stops, 1)
    XCTAssertNil(f.pause.action)
  }
}
