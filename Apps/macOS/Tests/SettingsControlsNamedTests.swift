import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Every control a section of Settings offers — a button, a switch, a pop-up, a slider, a field
/// — has a name VoiceOver can say, in both languages: an icon-only button without a label is
/// read as the name of its symbol, and a field without one as «text field». Read from the
/// accessibility tree the window builds, the rows of the lists included.
@MainActor
final class SettingsControlsNamedTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [NSWindow] = []

  /// The roles of what a person presses, picks or types into.
  private static let interactive: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
    "AXTextField", "AXComboBox", "AXIncrementor", "AXDisclosureTriangle", "AXColorWell",
  ]

  override func setUp() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-settings-named-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    for window in windows { window.close() }
    windows = []
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testEveryControlOfEverySectionOfSettingsHasAName() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true))
    try references.save(Person(name: "Аня", relation: .partner))
    try references.save(Template(text: "кофе 250", pinned: true, useCount: 4))
    try references.save(
      CoreKit.Category(kind: .expense, name: "Кофейни", sort: 5_000, quality: .neutral))
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for section in SettingsSection.allCases {
        let window = show(
          SettingsSectionContent(section: section).appDependencies(deps),
          size: CGSize(width: 760, height: 700))
        let controls = Self.controls(in: window)
        XCTAssertFalse(controls.isEmpty, "\(section) offers no control in \(choice.rawValue)")
        for control in controls where Self.name(of: control).isEmpty {
          XCTFail(
            "\(section), \(choice.rawValue): an unnamed \(Self.role(of: control)) "
              + "(identifier «\(Self.attribute(control, "accessibilityIdentifier") ?? "")»)")
        }
        window.close()
      }
    }
  }

  // MARK: Helpers

  private static func attribute(_ object: NSObject, _ name: String) -> String? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name) as? String
  }

  private static func role(of object: NSObject) -> String {
    attribute(object, "accessibilityRole") ?? ""
  }

  /// What VoiceOver says for the control: its label, its title, the element that titles it, a
  /// field's placeholder, or the text SwiftUI nests inside it. The value alone is no name.
  private static func name(of object: NSObject, depth: Int = 0) -> String {
    var words = ["accessibilityLabel", "accessibilityTitle", "accessibilityPlaceholderValue"]
      .compactMap { attribute(object, $0) }
    if object.responds(to: NSSelectorFromString("accessibilityTitleUIElement")),
      let title = object.value(forKey: "accessibilityTitleUIElement") as? NSObject
    {
      words += ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
        .compactMap { attribute(title, $0) }
    }
    if depth < 4, object.responds(to: NSSelectorFromString("accessibilityChildren")),
      let children = object.value(forKey: "accessibilityChildren") as? [Any]
    {
      for child in children.compactMap({ $0 as? NSObject })
      where role(of: child) == "AXStaticText" || role(of: child) == "AXImage" {
        words += ["accessibilityLabel", "accessibilityValue"].compactMap { attribute(child, $0) }
      }
    }
    return words.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
  }

  /// Every interactive element of the window, those in the rows of its lists too.
  private static func controls(in window: NSWindow) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      if interactive.contains(role(of: object)) { found.append(object) }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
          walk(child, depth: depth + 1)
        }
      }
    }
    func tables(in view: NSView) -> [NSTableView] {
      (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
    if let root = window.contentView {
      walk(root, depth: 0)
      for table in tables(in: root) {
        for row in 0..<table.numberOfRows {
          if let view = table.rowView(atRow: row, makeIfNecessary: true) { walk(view, depth: 0) }
        }
      }
    }
    var seen = Set<ObjectIdentifier>()
    return found.filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  private func show<Content: View>(_ view: Content, size: CGSize) -> NSWindow {
    // dependencies: every caller hands them to the view it gives here
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.setContentSize(size)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    return window
  }
}
