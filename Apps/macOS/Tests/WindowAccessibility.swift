import AppKit
import XCTest

/// Elements of a test window found the way VoiceOver finds them: a button or a text of SwiftUI
/// is no `NSView` of the view tree. The tree is there only where an assistive client can read it
/// (`TestEnvironment.requireSwiftUIAccessibility`).
@MainActor
enum WindowAccessibility {
  static func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// Every element of the window under its content view, depth first.
  static func elements(in window: NSWindow) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      found.append(object)
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  static func element(identified identifier: String, in window: NSWindow) -> NSObject? {
    elements(in: window).first {
      attribute($0, "accessibilityIdentifier") as? String == identifier
    }
  }

  /// What the element says: its label, else its value, else its title.
  static func text(of element: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
      if let text = attribute(element, name) as? String, !text.isEmpty { return text }
    }
    return ""
  }

  static func frame(of element: NSObject) -> CGRect {
    (attribute(element, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
  }

  /// A click on the element, as VoiceOver's press.
  static func press(_ element: NSObject) {
    _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
  }

  private final class Tracked: @unchecked Sendable {
    var menu: NSMenu?
  }

  /// Opens the menu the element `identifier` names, the way a click does, and chooses `title`.
  static func choose(_ title: String, inMenu identifier: String, of window: NSWindow) throws {
    let menu = try XCTUnwrap(element(identified: identifier, in: window), identifier)
    let tracked = Tracked()
    let token = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
    ) { note in
      guard let open = note.object as? NSMenu else { return }
      tracked.menu = open
      let index = open.items.firstIndex { $0.title == title }
      RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
          if let index { tracked.menu?.performActionForItem(at: index) }
          tracked.menu?.cancelTracking()
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    press(menu)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
  }
}
