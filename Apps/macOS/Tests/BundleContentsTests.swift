import XCTest

@testable import OhMyMoney

/// What the app carries. The test host is `OhMyMoney.app` itself, so `Bundle.main` here is the
/// bundle the owner runs.
@MainActor
final class BundleContentsTests: XCTestCase {
  /// Documentation written for whoever reads the repository has no business inside the app:
  /// `Apps/macOS/Platform/Updates/README.md` was being copied into `Contents/Resources`
  /// only because it sat next to the code.
  func testNoMarkdownIsCarriedInsideTheApp() {
    let markdown = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
    XCTAssertEqual(
      markdown.map(\.lastPathComponent), [],
      "the app carries documentation it does not need")
  }

  /// The migrations, on the other hand, are the app's own: the schema lives in the bundle.
  func testTheSchemaIsThere() {
    let sql = Bundle.main.urls(forResourcesWithExtension: "sql", subdirectory: "Schema") ?? []
    XCTAssertFalse(sql.isEmpty, "the migrations did not reach the bundle")
  }

  /// On a Russian Mac the app is «Итого» in Finder, the Dock and Spotlight too, not only in its
  /// own windows. Launch Services looks the name up in the bundle's `InfoPlist.strings` only
  /// when the bundle says its name is localised; without the key the file-system name «OhMyMoney»
  /// stays everywhere outside the app.
  func testTheDisplayNameIsDeclaredLocalised() throws {
    XCTAssertEqual(
      Bundle.main.object(forInfoDictionaryKey: "LSHasLocalizedDisplayName") as? Bool, true,
      "Launch Services does not look for a localised name of the app")
    let url = try XCTUnwrap(
      Bundle.main.url(
        forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "ru"),
      "the Russian names of the app did not reach the bundle")
    let names = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    XCTAssertEqual(names["CFBundleDisplayName"], "OhMyMoney")
    XCTAssertEqual(names["CFBundleName"], "OhMyMoney")
  }

  /// Logging out, restarting or shutting the Mac down asks the app to quit, rather than
  /// killing it: only the ordered shutdown ends the session (`SessionMarker.end`). Killed past
  /// it — sudden termination on, or automatic termination of an app without a window — the
  /// mark of a running session stayed, and every restart of the Mac read as a crash at the
  /// next launch: `session.interrupted` in the journal and an offer of a problem report.
  func testTheAppIsNotKilledPastTheOrderedShutdown() {
    for key in ["NSSupportsSuddenTermination", "NSSupportsAutomaticTermination"] {
      XCTAssertNotEqual(
        Bundle.main.object(forInfoDictionaryKey: key) as? Bool, true,
        "\(key): macOS may kill the app without asking it to quit")
    }
  }

  /// The About panel prints `NSHumanReadableCopyright` under the version, as the copyright of
  /// the app. It held a tagline — «Personal finance tracker. All data stays on this Mac.» —
  /// which the panel showed in the place of a copyright.
  func testTheAboutPanelSaysWhoseTheAppIs() throws {
    // The Info.plist itself, not its translation into the language of the test host.
    let copyright = try XCTUnwrap(
      Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String)
    XCTAssertTrue(copyright.hasPrefix("© "), "not a copyright line: \(copyright)")
    XCTAssertTrue(copyright.contains("Evgeny Baulin"), copyright)
  }

  /// In the Russian interface the About panel and Finder's «Тип» said «OhMyMoney Archive» and the
  /// copyright in English: `InfoPlist.strings` had only the two names of the app. The kind of
  /// an archive is looked up there under its English name, for the document type and for the
  /// exported type alike; the copyright under its own key.
  func testTheKindOfAnArchiveAndTheCopyrightAreRussianOnARussianMac() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
    let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
    let kind = try XCTUnwrap(types.first?["CFBundleTypeName"] as? String)
    XCTAssertEqual(exported.first?["UTTypeDescription"] as? String, kind)

    let url = try XCTUnwrap(
      Bundle.main.url(
        forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "ru"))
    let russian = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    XCTAssertEqual(russian[kind], "Архив OhMyMoney", "Finder calls an archive «\(kind)»")
    let copyright = try XCTUnwrap(russian["NSHumanReadableCopyright"], "the copyright is English")
    XCTAssertTrue(copyright.hasPrefix("© "), copyright)
    XCTAssertTrue(copyright.contains("Евгений Баулин"), copyright)
  }

  /// A double click on an archive opens the owner's copy, never a build from the repository:
  /// both declare the type, and Launch Services prefers the one that says it owns it. The
  /// Debug build, with an id of its own since 1.0.0, only offers itself as an alternative.
  func testOnlyTheOwnersCopyClaimsArchives() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
    let rank = try XCTUnwrap(types.first?["LSHandlerRank"] as? String)
    #if DEBUG
      XCTAssertEqual(rank, "Alternate")
    #else
      XCTAssertEqual(rank, "Owner")
    #endif
  }

  /// Two copies of the app can sit in the Dock at once, and they are told apart at a glance:
  /// the Debug build wears the icon with a red «DEBUG» band.
  func testTheDebugBuildWearsAnIconOfItsOwn() throws {
    let icon = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String)
    #if DEBUG
      XCTAssertEqual(icon, "AppIconDebug")
    #else
      XCTAssertEqual(icon, "AppIcon")
    #endif
    XCTAssertNotNil(Bundle.main.image(forResource: icon), "the icon \(icon) is not in the bundle")
  }

  /// The icon comes from the owner's Icon Composer file, and each build carries only its own:
  /// the compiled `.icns` of this build is there, the other one is not.
  func testEachBuildCarriesOnlyItsOwnIcon() throws {
    #if DEBUG
      let own = "AppIconDebug", other = "AppIcon"
    #else
      let own = "AppIcon", other = "AppIconDebug"
    #endif
    XCTAssertNotNil(Bundle.main.url(forResource: own, withExtension: "icns"))
    XCTAssertNil(Bundle.main.url(forResource: other, withExtension: "icns"))
    let catalog = try XCTUnwrap(Bundle.main.url(forResource: "Assets", withExtension: "car"))
    let bytes = try Data(contentsOf: catalog)
    XCTAssertNotNil(bytes.range(of: Data("\(own)_Assets/".utf8)), "\(own) layers are missing")
    XCTAssertNil(bytes.range(of: Data("\(other)_Assets/".utf8)), "\(other) layers are inside")
  }
}
