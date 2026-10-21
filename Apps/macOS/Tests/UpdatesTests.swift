import AppCore
import XCTest

@testable import OhMyMoney

/// What the Direct build promises about updates, read off the bundle that was actually built
/// and signed — not off the files in the repository.
///
/// The App Store side cannot be checked from here, because the test host is the Direct build:
/// `make check-appstore-clean` looks inside that bundle instead, and `make verify` runs it.
final class UpdatesTests: XCTestCase {
  /// The address of the feed may never change: every copy already installed looks for its
  /// updates there.
  static let feed = "https://EvgenyBaulin.github.io/ohmymoney/appcast.xml"

  private var info: [String: Any] {
    Bundle.main.infoDictionary ?? [:]
  }

  func testTheFeedIsTheOneAddressThatMayNotChange() {
    XCTAssertEqual(info["SUFeedURL"] as? String, Self.feed)
  }

  /// The key is the owner's and is passed in at release time. A build from the repository
  /// carries the placeholder, and that is the point: `make release-local` refuses to release
  /// what carries it.
  func testAKeyBuiltFromTheRepositoryIsThePlaceholder() {
    XCTAssertEqual(info["SUPublicEDKey"] as? String, "SPARKLE_PUBLIC_KEY_NOT_SET")
  }

  /// A sandboxed application launches Sparkle's installer through an XPC service that lives
  /// inside the framework. Sparkle refuses to run if that service is copied into the
  /// application bundle instead, so the key is what turns it on.
  func testTheSandboxedInstallerServiceIsAskedFor() {
    XCTAssertEqual(info["SUEnableInstallerLauncherService"] as? String, "YES")
  }

  /// «Автоматическая проверка и фоновая установка включены по умолчанию; данные о системе не
  /// отправляются».
  func testTheUpdaterChecksByItselfAndTellsNothingAboutThisMac() {
    XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    XCTAssertEqual(info["SUSendProfileInfo"] as? Bool, false)
    XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86_400)
  }

  /// Sparkle in the sandbox needs two Mach services named after the bundle id — its own
  /// guide, and its own test app's entitlements say the same. Read from the signature of the
  /// bundle under test, so this is what was signed and not what was written down. The names
  /// follow the id of the build under test: the Debug build has one of its own.
  ///
  /// Xcode signs a test host with services of its own (`com.apple.testmanagerd` and its
  /// like), so what is checked is every name that is **not** Apple's: the test host is not a
  /// user, and what it adds for itself is not ours.
  func testTheSandboxLetsSparkleReachItsOwnServices() throws {
    let entitlements = try Self.entitlements(of: Bundle.main.bundleURL)
    let names =
      (entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"]
      as? [String] ?? [])
      .filter { !$0.hasPrefix("com.apple.") }

    let id = try XCTUnwrap(Bundle.main.bundleIdentifier)

    XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
    XCTAssertEqual(names.sorted(), ["\(id)-spki", "\(id)-spks"])
  }

  /// And no other hole in the sandbox. Sparkle's own test app also asks to read the host's
  /// preferences; this one does not, and a day when it starts to is a day to think about.
  func testTheSandboxHasNoOtherHolesOfOurs() throws {
    let entitlements = try Self.entitlements(of: Bundle.main.bundleURL)

    for hole in [
      "com.apple.security.temporary-exception.shared-preference.read-write",
      "com.apple.security.temporary-exception.shared-preference.read-only",
      "com.apple.security.temporary-exception.files.home-relative-path.read-write",
      "com.apple.security.temporary-exception.apple-events",
      "com.apple.security.cs.disable-library-validation",
      // `get-task-allow` is not on this list: Xcode puts it in a Debug build so a debugger
      // can attach, and a Debug build is what runs these tests.
    ] {
      XCTAssertNil(entitlements[hole], hole)
    }
  }

  /// A bundle that carries no entitlements fails the two checks above rather than skipping
  /// them: every build that runs these tests is signed (`make`, CI: ad-hoc at the least), so
  /// an empty answer of `codesign` is a signing regression — the Direct build would ship with
  /// Sparkle's services out of reach — and a skip left `make test` green over it.
  func testABundleWithoutEntitlementsFailsInsteadOfSkipping() throws {
    let unsigned = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-unsigned-\(UUID().uuidString).app", isDirectory: true)
    try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unsigned) }

    XCTAssertThrowsError(try Self.entitlements(of: unsigned)) { error in
      XCTAssertFalse(error is XCTSkip, "an unreadable signature skipped the sandbox checks")
    }
  }

  /// The entitlements of a signed bundle, as `codesign` reads them back.
  static func entitlements(of bundle: URL) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-d", "--entitlements", ":-", "--xml", bundle.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard !data.isEmpty,
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      // A failure, never a skip (see the test above): nothing runs these tests unsigned.
      throw EntitlementsUnreadable(
        bundle: bundle.lastPathComponent, status: process.terminationStatus)
    }
    return plist
  }

  /// `codesign` gave nothing to read: the bundle is unsigned or signed without entitlements.
  struct EntitlementsUnreadable: Error, CustomStringConvertible {
    let bundle: String
    let status: Int32

    var description: String {
      "codesign read no entitlements from \(bundle) (exit \(status)): is the bundle signed?"
    }
  }
}

/// «Проверить обновления…» and «Перезапустить»: which of the two this build offers, and that
/// the words match what pressing it will actually do.
@MainActor
final class UpdateServiceTests: XCTestCase {
  /// The tests run in a Direct build — the test host is the app itself — so the store
  /// answer must not be the one on offer here.
  func testADirectBuildNeverOffersTheStorePage() {
    XCTAssertNotEqual(UpdateService.kind, .restartAndStorePage)
  }

  /// The word on the item promises exactly what the build can do: «Проверить обновления…» only
  /// where an update can actually arrive, and nothing about a restart there — a check that
  /// finds nothing leaves the windows as they are.
  func testTheTitlePromisesOnlyWhatTheBuildCanDo() {
    let environment = AppEnvironment()
    environment.language.choice = .english
    XCTAssertEqual(UpdateService.title(of: .checkForUpdates, environment), "Check for Updates…")
    XCTAssertEqual(UpdateService.title(of: .restartOnly, environment), "Restart")
    XCTAssertEqual(UpdateService.title(of: .restartAndStorePage, environment), "Restart")

    environment.language.choice = .russian
    XCTAssertEqual(
      UpdateService.title(of: .checkForUpdates, environment), "Проверить обновления…")
    XCTAssertEqual(UpdateService.title(of: .restartOnly, environment), "Перезапустить")

    XCTAssertEqual(
      UpdateService.title(environment), UpdateService.title(of: UpdateService.kind, environment))
  }

  /// The address of the store page parses; nothing opens it outside the store build.
  func testTheStorePageAddressIsAnAddress() {
    XCTAssertEqual(UpdateService.storePageURL?.scheme, "macappstore")
  }

  /// A build from the repository carries the placeholder, so it cannot tell a real update
  /// from anything else — and therefore never asks for one.
  ///
  /// Asserted without calling `startIfPossible(isTestHost: false)`: `XCTAssert` does not
  /// stop the method, so a day when this build did carry a real key that one line would
  /// start Sparkle inside the test run and send it to the network. The two conditions are
  /// checked instead of the door being opened to see whether it is locked.
  func testABuildThatCannotVerifyNeverChecks() {
    XCTAssertFalse(UpdateService.canVerifyUpdates)
    XCTAssertEqual(UpdateService.kind, .restartOnly)
  }

  /// And the test host never starts an updater whatever the key says: a test run does not go
  /// to the network, and the host is not a user.
  func testTheTestHostNeverStartsTheUpdater() {
    XCTAssertFalse(UpdateService.startIfPossible(isTestHost: true))
  }

  /// Sparkle ignores a check asked for while a session of its own runs in the background. A
  /// press then must not vanish: it waits for the running session to end and makes the owner's
  /// check then — once.
  func testAPressDuringABackgroundSessionWaitsForItsEndAndThenChecks() {
    var ask = UpdateAsk()

    XCTAssertEqual(ask.pressed(canCheck: false, sessionInProgress: true), .wait)
    XCTAssertTrue(ask.cycleEnded(userInitiated: false), "his check starts when that one ends")
    XCTAssertFalse(ask.cycleEnded(userInitiated: true), "his own check is not waited for")
    XCTAssertFalse(ask.cycleEnded(userInitiated: false), "the press outlived its check")
  }

  /// A session of Sparkle's own schedule, with nobody waiting for it, starts no check when it
  /// ends — nor after the owner's own check is over.
  func testASessionOfTheScheduleStartsNoCheckOfItsOwn() {
    var ask = UpdateAsk()
    XCTAssertFalse(ask.cycleEnded(userInitiated: false))

    XCTAssertEqual(ask.pressed(canCheck: true, sessionInProgress: false), .check)
    XCTAssertFalse(ask.cycleEnded(userInitiated: true), "his check failed: no network")
    XCTAssertFalse(ask.cycleEnded(userInitiated: false))
  }

  /// A press while Sparkle shows an update it found by itself only brings that update into
  /// view. The owner dismisses it; the session ends; the press is over with it.
  func testAPressThatBroughtAShownUpdateIntoViewEndsWithItsSession() {
    var ask = UpdateAsk()
    XCTAssertEqual(ask.pressed(canCheck: true, sessionInProgress: true), .check)
    XCTAssertFalse(ask.cycleEnded(userInitiated: false), "the shown update was dismissed")
  }

  /// An updater that can neither check nor is busy has not started: the owner is told so, and
  /// the application is not restarted in place of a check.
  func testAnUpdaterThatCannotCheckAtAllSaysSo() {
    var ask = UpdateAsk()
    XCTAssertEqual(ask.pressed(canCheck: false, sessionInProgress: false), .unavailable)
    XCTAssertFalse(ask.cycleEnded(userInitiated: false))
  }

  func testEveryWordIsTranslated() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in [
        "action.reload", "action.checkForUpdates", "action.openStorePage",
        "update.unavailable.title", "update.unavailable.message",
      ] {
        XCTAssertNotEqual(environment.language(key), key, "\(key), \(choice)")
      }
    }
  }

  /// The button that checked, installed and restarted is gone, and so is its name: a hint that
  /// sends the owner to «Обновить и перезапустить» sends them to a command there is none of.
  /// Every table the app ships, in both languages.
  func testNoWordNamesTheCommandThatIsGone() throws {
    let gone = ["Обновить и перезапустить", "Reload & Update", "Reload and Update"]
    var read = 0
    for code in ["en", "ru"] {
      let folder = try XCTUnwrap(Bundle.main.url(forResource: code, withExtension: "lproj"))
      for table in try FileManager.default.contentsOfDirectory(atPath: folder.path)
      where table.hasSuffix(".strings") {
        let values = try XCTUnwrap(
          NSDictionary(contentsOf: folder.appendingPathComponent(table)) as? [String: String],
          table)
        read += values.count
        for (key, value) in values {
          for name in gone {
            XCTAssertFalse(value.contains(name), "\(code)/\(table): \(key) says «\(name)»")
          }
        }
      }
    }
    XCTAssertGreaterThan(read, 100, "the tables of the app were not found")
  }
}

/// «Обновления: автоматические вкл/выкл (по умолчанию вкл)».
///
/// Written against a suite of its own: the test host's standard defaults are the owner's, and
/// the switch must never start an updater from a test.
@MainActor
final class AutomaticUpdatesTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suite = "ohmymoney.tests.updates.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    defaults?.removePersistentDomain(forName: suite)
  }

  /// Nothing chosen yet: what `Info.plist` says, and it says «on».
  func testAutomaticUpdatesAreOnUntilTheOwnerSaysOtherwise() {
    XCTAssertTrue(AutomaticUpdates(defaults: defaults).isOn)
    XCTAssertTrue(AutomaticUpdates(defaults: defaults, info: [:]).isOn)
    XCTAssertFalse(
      AutomaticUpdates(defaults: defaults, info: [AutomaticUpdates.checksKey: false]).isOn)
  }

  /// The choice is kept where Sparkle reads it before `Info.plist`: both the schedule of the
  /// checks and the installing in the background, the two halves of automatic updates.
  func testTurningThemOffIsKeptWhereTheUpdaterReadsIt() {
    let updates = AutomaticUpdates(defaults: defaults)
    updates.isOn = false

    XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
    XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, false)
    XCTAssertFalse(AutomaticUpdates(defaults: defaults).isOn)

    updates.isOn = true
    XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, true)
    XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, true)
    XCTAssertTrue(AutomaticUpdates(defaults: defaults).isOn)
  }

  /// The switch changes something only where an update can arrive; elsewhere it stays in
  /// view, greyed, with the reason under it.
  func testTheSwitchIsLiveOnlyWhereAnUpdateCanArrive() {
    XCTAssertEqual(AutomaticUpdates.isChangeable, UpdateService.kind == .checkForUpdates)
  }

  func testTheWordsOfTheSwitchAreTranslated() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in [
        "settings.updates", "settings.updates.automatic", "settings.updates.automaticHint",
        "settings.updates.unavailableHint",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
    }
  }
}

#if canImport(Sparkle)
  import Sparkle

  /// «Проверить обновления…»: whatever Sparkle answers, the application is not restarted by
  /// the answer — Sparkle restarts it itself only to install an update.
  ///
  /// Sparkle's answers are delivered here the way Sparkle itself delivers them: through the
  /// delegate protocol, each one only when the delegate has it (`respondsToSelector`), in the
  /// order `SPUUpdater` and `SPUBasicUpdateDriver` use, «nothing found» marked user-initiated
  /// only for the check a user asked for (`SPUNoUpdateFoundUserInitiatedKey`). A restart would
  /// be counted by `AppRestart`, which in the test host counts instead of quitting. The rules
  /// themselves are `UpdateAsk`'s (`UpdateServiceTests`); these hold the delegate.
  @MainActor
  final class UpdateAnswersTests: XCTestCase {
    private var answers: UpdateService.Answers!
    /// Never started: the delegate methods are only handed it. Starting one would schedule
    /// checks and reach the network from a test.
    private var updater: SPUUpdater!
    private var restartsBefore = 0

    /// Relaunches asked for since the test began.
    private var restarts: Int { AppRestart.askedInTestHost - restartsBefore }

    override func setUp() async throws {
      UpdateService.Answers.ask = UpdateAsk()
      restartsBefore = AppRestart.askedInTestHost
      answers = UpdateService.Answers()
      updater = SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
    }

    override func tearDown() async throws {
      UpdateService.Answers.ask = UpdateAsk()
    }

    /// «Nothing new», as Sparkle reports it for `check`: marked user-initiated only for the
    /// check a user asked for.
    private func nothingNew(_ check: SPUUpdateCheck) -> NSError {
      NSError(
        domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
        userInfo: [SPUNoUpdateFoundUserInitiatedKey: check == .updates])
    }

    private let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

    /// What the menu item does before Sparkle starts its check, with no session of Sparkle's
    /// own running.
    private func ownerPressesCheckForUpdates() {
      XCTAssertEqual(
        UpdateService.Answers.ask.pressed(canCheck: true, sessionInProgress: false), .check)
    }

    /// One cycle of Sparkle ending: «nothing found» first when that is the outcome, then the
    /// abort for any error, then the end of the cycle — as `SPUUpdater` sends them.
    private func sparkleEnds(_ check: SPUUpdateCheck, with error: NSError?) {
      let delegate: SPUUpdaterDelegate = answers
      if let error, error.domain == SUSparkleErrorDomain,
        error.code == Int(SUError.noUpdateError.rawValue)
      {
        if delegate.updaterDidNotFindUpdate?(updater, error: error) == nil {
          delegate.updaterDidNotFindUpdate?(updater)
        }
      }
      if let error {
        delegate.updater?(updater, didAbortWithError: error)
      }
      delegate.updater?(updater, didFinishUpdateCycleFor: check, error: error)
    }

    /// The case that was found: the owner asked, Sparkle offered 0.2.0, the owner skipped it (the
    /// cycle ends with no error). The next day's scheduled check sees only the skipped
    /// version and reports «nothing new» — and must not restart the app under the owner's
    /// hands.
    func testAScheduledCheckAfterADeclinedOneNeverRestarts() {
      ownerPressesCheckForUpdates()
      sparkleEnds(.updates, with: nil)
      sparkleEnds(.updatesInBackground, with: nothingNew(.updatesInBackground))
      XCTAssertEqual(restarts, 0, "a scheduled check restarted the application")
    }

    /// The same after a check the owner asked for that could not be made.
    func testAScheduledCheckAfterAFailedOneNeverRestarts() {
      ownerPressesCheckForUpdates()
      sparkleEnds(.updates, with: offline)
      sparkleEnds(.updatesInBackground, with: nothingNew(.updatesInBackground))
      XCTAssertEqual(restarts, 0)
    }

    /// Nothing to install: Sparkle says «Установлена последняя версия» itself, and the windows
    /// the owner was working in stay where they are.
    func testTheCheckTheOwnerAskedForNeverRestartsWhenThereIsNothingNew() {
      ownerPressesCheckForUpdates()
      sparkleEnds(.updates, with: nothingNew(.updates))
      XCTAssertEqual(restarts, 0, "a check that found nothing restarted the application")
    }

    /// A check Sparkle made on its own schedule never restarts anything; nor does a check by
    /// hand that the menu item did not begin.
    func testAScheduledCheckAloneNeverRestarts() {
      sparkleEnds(.updatesInBackground, with: nothingNew(.updatesInBackground))
      sparkleEnds(.updatesInBackground, with: nil)
      sparkleEnds(.updates, with: nothingNew(.updates))
      XCTAssertEqual(restarts, 0)
    }
  }
#endif
