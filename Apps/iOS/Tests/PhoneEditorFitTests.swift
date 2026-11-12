import AppCore
import AppDatabase
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// The editor a saved operation opens in on the phone: one column as wide as the sheet, the
/// kinds, every field and «Отмена» / «Сохранить» inside the screen — not the Mac's wide grid cut
/// off at both edges — and no list of keyboard shortcuts among the buttons of the toolbar.
@MainActor
final class PhoneEditorFitTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [UIWindow] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-phone-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    environment.language.choice = .russian
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    for window in windows {
      window.rootViewController = nil
      window.isHidden = true
    }
    windows = []
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var deps: AppDependencies {
    AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
  }

  private func host<Content: View>(_ content: Content, size: CGSize) -> UIWindow {
    let controller = UIHostingController(rootView: content.appDependencies(deps))
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    window.frame = CGRect(origin: .zero, size: size)
    window.windowLevel = .alert + 1
    controller.safeAreaRegions = []
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    windows.append(window)
    settle(window)
    return window
  }

  private func settle(_ window: UIWindow, passes: Int = 40) {
    for _ in 0..<passes {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private func savedOperation() throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 300), note: "Dinner")
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    try XCTUnwrap(environment.transactions).save(entry)
    return entry
  }

  /// Every accessibility element under `root`, with its frame on the screen.
  private func elements(in root: UIView) -> [(id: String, label: String, frame: CGRect)] {
    var found: [(String, String, CGRect)] = []
    func visit(_ object: NSObject) {
      let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
      let label = object.accessibilityLabel ?? ""
      if !(id.isEmpty && label.isEmpty) {
        found.append((id, label, object.accessibilityFrame))
      }
      if let children = object.accessibilityElements as? [NSObject] {
        children.forEach(visit)
      } else if let view = object as? UIView {
        if view.accessibilityElementCount() > 0, view.accessibilityElementCount() != NSNotFound {
          for index in 0..<view.accessibilityElementCount() {
            if let child = view.accessibilityElement(at: index) as? NSObject { visit(child) }
          }
        }
        view.subviews.forEach(visit)
      }
    }
    visit(root)
    return found
  }

  private func assertEditorFits(
    width: CGFloat, file: StaticString = #filePath, line: UInt = #line
  )
    throws
  {
    let entry = try savedOperation()
    let size = CGSize(width: width, height: 900)
    let window = host(EditTransactionSheet(entry: entry), size: size)
    settle(window, passes: 60)
    let all = elements(in: window)
    for id in [environment.language("action.cancel"), environment.language("action.save")] {
      let button = all.first { $0.label == id }
      XCTAssertNotNil(button, "\(id) is not on the screen", file: file, line: line)
      if let frame = button?.frame {
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(id) at \(width)", file: file, line: line)
        XCTAssertLessThanOrEqual(
          frame.maxX, width + 0.5, "\(id) at \(width)", file: file, line: line)
      }
    }
    // Nothing the editor draws stands left of the screen or right of it.
    for element in all where element.frame.width > 0 && element.frame.height > 0 {
      XCTAssertGreaterThanOrEqual(
        element.frame.minX, -0.5, "\(element.id) \(element.label) at \(width)", file: file,
        line: line)
      XCTAssertLessThanOrEqual(
        element.frame.maxX, width + 0.5, "\(element.id) \(element.label) at \(width)",
        file: file, line: line)
    }
    let asked = try XCTUnwrap(window.rootViewController as? any HostingSizing)
      .fitting(CGSize(width: width, height: .greatestFiniteMagnitude))
    XCTAssertLessThanOrEqual(
      asked.width, width + 0.5, "asked width at \(width)", file: file, line: line)
  }

  func testTheEditorFitsAnIPhoneProMaxScreen() throws { try assertEditorFits(width: 440) }

  func testTheEditorFitsAnIPhoneProScreen() throws { try assertEditorFits(width: 402) }


  /// The toolbar of the phone has no «Палитра команд»: it is the list of keyboard shortcuts.
  func testThePhoneToolbarHasNoCommandPalette() throws {
    let size = CGSize(width: 402, height: 800)
    let window = host(
      NavigationStack {
        Color.clear.modifier(PhoneToolbar(deps: deps, router: PhoneRouter()))
      }, size: size)
    settle(window, passes: 60)
    let labels = elements(in: window).map(\.label)
    let recompute = environment.language("action.recompute")
    XCTAssertTrue(labels.contains(recompute), "the toolbar is on screen: \(labels)")
    XCTAssertFalse(labels.contains(QuestionsText.t("questions.menu.palette", environment)))
    XCTAssertFalse(elements(in: window).contains { $0.id == "toolbar.palette" })
  }
}

@MainActor
private protocol HostingSizing {
  func fitting(_ size: CGSize) -> CGSize
}

extension UIHostingController: HostingSizing {
  fileprivate func fitting(_ size: CGSize) -> CGSize { sizeThatFits(in: size) }
}
