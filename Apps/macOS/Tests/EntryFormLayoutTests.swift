import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The form at the side of the window lays the fields of the ↓ panel in one column of about
/// 380 pt: no control runs past either edge of the column and no menu cuts its title — in both
/// languages, for a plain expense, income, a split, another currency, a purchase on credit, a
/// transfer and an exchange.
/// Laid as the panel's grid, the fields wanted some 450 pt and were centred in the column, cut
/// off on both sides.
@MainActor
final class EntryFormLayoutTests: XCTestCase {
  private var host: EntryHost?
  private var windows: [NSWindow] = []

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    host?.close()
    host = nil
  }

  private func controls(in view: NSView) -> [NSControl] {
    view.subviews.flatMap { subview -> [NSControl] in
      ((subview as? NSControl).map { [$0] } ?? []) + controls(in: subview)
    }
  }

  /// What VoiceOver finds in the window that a click can reach: menus, buttons, boxes and
  /// fields, with their frames on the screen. SwiftUI draws its menus without views of AppKit.
  private func reachable(in window: NSWindow) -> [(role: String, frame: CGRect)] {
    let roles: Set<String> = [
      "AXPopUpButton", "AXMenuButton", "AXButton", "AXCheckBox", "AXTextField",
    ]
    var found: [(String, CGRect)] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      if object.responds(to: NSSelectorFromString("accessibilityRole")),
        let role = object.value(forKey: "accessibilityRole") as? String, roles.contains(role),
        let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
        frame.width > 0
      {
        found.append((role, frame))
      }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(child) }
      }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  private func model(_ variant: String, in environment: AppEnvironment) -> EntryDraftModel {
    let model = EntryDraftModel(environment: environment)
    model.assisted = false
    model.prepareForPanel(today: environment.today)
    model.setTotal(AmountE4(whole: 1500))
    model.draft.note = "coffee"
    if let first = model.categoryOptions(forPartAt: 0).first {
      model.setCategory(first.id, forPartAt: 0)
    }
    switch variant {
    case "income":
      model.draft.kind = .income
    case "split":
      model.draft.parts[0].amount = AmountE4(whole: 1000)
      model.addPart()
      model.draft.parts[1].reimbursable = true
    case "currency":
      model.setCurrency(.usd)
    case "credit":
      model.startCreditPlan()
    case "transfer", "exchange":
      model.chooseTransfer(calendar: environment.calendar)
      let name = variant == "exchange" ? "Abroad" : "Savings"
      let other = model.paymentMethods.first { $0.name == name }
      if let other { model.transfer?.form.chooseTo(other) }
      model.transfer?.form.fee = AmountE4(whole: 15)
    default:
      break
    }
    model.applyDefaults(today: environment.today)
    return model
  }

  func testEveryControlOfTheFormStaysInsideTheColumn() async throws {
    let host = try await EntryHost(opensDetails: false, width: 380, style: .line) { environment in
      try EntryHost.history("coffee", in: environment)
      try environment.references!.save(PaymentMethod(name: "Savings", currency: .rub))
      try environment.references!.save(PaymentMethod(name: "Abroad", currency: .usd))
    }
    self.host = host
    // On a CI runner SwiftUI builds no accessibility tree: there only the views of AppKit — the
    // fields and the date — are checked.
    let walksAccessibility = !TestEnvironment.isCI
    if walksAccessibility { TestEnvironment.enableAccessibilityTree() }
    let deps = AppDependencies(
      environment: host.environment, store: host.store, compute: ComputeStore(calendar: .system))
    for language in [AppLanguage.Choice.russian, .english] {
      host.environment.language.choice = language
      for width in [CGFloat(340), MainWindow.entryFormWidth, 420] {
        for variant in [
          "expense", "income", "split", "currency", "credit", "transfer", "exchange",
        ] {
          // Tall enough for the tallest form (a split at 340 pt is ~1 500 pt of fields): a
          // taller form would scroll, and its scroller at the edge is not a control past it.
          let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 2400), styleMask: [.titled],
            backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          windows.append(window)
          let column = EntryFormColumn(
            model: model(variant, in: host.environment), focusedInside: .constant(false),
            save: {}, clear: {},
            quickLine: { focus in
              // The quick line stands over the fields as wide as the column.
              AnyView(
                TextField(text: .constant("кофе 300")) { Text(verbatim: "") }
                  .textFieldStyle(.roundedBorder)
                  .focused(focus, equals: .quick))
            }
          ) {
            EmptyView()
          }
          .frame(width: width, height: 2400)
          .appDependencies(deps)
          window.contentView = NSHostingView(rootView: column)
          window.makeKeyAndOrderFront(nil)
          host.settle(0.4)
          let content = try XCTUnwrap(window.contentView)
          content.layoutSubtreeIfNeeded()
          let found = controls(in: content).filter { !$0.isHidden && $0.frame.width > 0 }
          let place = "\(language) \(width) \(variant)"
          XCTAssertGreaterThanOrEqual(found.count, 3, "the fields are there: \(place)")
          for control in found {
            let frame = control.convert(control.bounds, to: nil)
            let name = "\(type(of: control)) «\(control.stringValue)» \(place)"
            XCTAssertGreaterThanOrEqual(frame.minX, 8, "past the left edge: \(name)")
            XCTAssertLessThanOrEqual(frame.maxX, width - 8, "past the right edge: \(name)")
            // A menu as narrow as its title or narrower cuts it.
            if let menu = control as? NSPopUpButton, !menu.titleOfSelectedItem.isNilOrEmpty {
              XCTAssertGreaterThanOrEqual(
                menu.frame.width + 0.5, menu.intrinsicContentSize.width,
                "the title is cut: \(name)")
            }
          }
          if walksAccessibility {
            let elements = reachable(in: window)
            XCTAssertGreaterThan(elements.count, 8, "the menus are there: \(place)")
            for element in elements {
              let name = "\(element.role) at \(element.frame) \(place)"
              XCTAssertGreaterThanOrEqual(
                element.frame.minX, window.frame.minX + 8, "past the left edge: \(name)")
              XCTAssertLessThanOrEqual(
                element.frame.maxX, window.frame.minX + width - 8, "past the right edge: \(name)")
            }
          }
          window.contentView = nil
          window.close()
        }
      }
    }
  }
}

extension Optional where Wrapped == String {
  fileprivate var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
