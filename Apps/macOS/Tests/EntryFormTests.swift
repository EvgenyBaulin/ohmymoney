import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The form at the side of the window (`EntryStyle.form`): no line, the fields open once a kind is
/// chosen, its own «Save» and «Clear», Return from its fields, and nothing taken from history.
@MainActor
final class EntryFormTests: XCTestCase {
  private var host: EntryHost?
  private let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  /// The form with «Расход» chosen: its fields are open.
  private func openForm() async throws -> EntryHost {
    let cafe = cafe
    let host = try await EntryHost(opensDetails: false, style: .form) { environment in
      try environment.references!.save(cafe)
    }
    self.host = host
    try press("entry.kind.expense", in: host)
    return host
  }

  // MARK: Finding things the way VoiceOver does

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  private func element(identified identifier: String, in window: NSWindow) -> NSObject? {
    var found: NSObject?
    func walk(_ element: Any) {
      guard found == nil, let object = element as? NSObject else { return }
      if attribute(object, "accessibilityIdentifier") as? String == identifier {
        found = object
        return
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  private func press(_ identifier: String, in host: EntryHost) throws {
    let element = try XCTUnwrap(element(identified: identifier, in: host.window), identifier)
    _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
    host.settle(0.4)
  }

  private final class Tracked: @unchecked Sendable {
    var menu: NSMenu?
  }

  /// Opens the menu `identifier` names the way a click does and chooses `title` in it.
  private func choose(_ title: String, inMenu identifier: String, host: EntryHost) throws {
    let menu = try XCTUnwrap(element(identified: identifier, in: host.window), identifier)
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
    _ = menu.perform(NSSelectorFromString("accessibilityPerformPress"))
    host.settle(0.4)
  }

  // MARK: The tests

  /// The form is there at once — its fields once a kind is chosen —, and the line, the chips and
  /// the chevron of the capsule are not.
  func testTheFormHasNoLineAndShowsItsFieldsAtOnce() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    XCTAssertNotNil(host.textFields().first { $0.placeholderString == "0" }, "the amount")
    let prompt = host.environment.language("entry.placeholder", table: "Entry")
    XCTAssertNil(host.textFields().first { $0.placeholderString == prompt }, "there is no line")
    XCTAssertNil(element(identified: "entry.details.toggle", in: host.window), "no chevron")
    XCTAssertNotNil(element(identified: "entry.form.save", in: host.window), "its own «Save»")
    XCTAssertNotNil(element(identified: "entry.form.clear", in: host.window), "and «Clear»")
  }

  /// Without a category nothing is saved — «Не помню» is there for what the owner does not
  /// remember —; once one is chosen «Save» writes the operation, and the form stands open and
  /// empty for the next one.
  func testTheFormWaitsForACategoryAndSavesOnceItIsChosen() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try host.type("250", into: try host.field(prompt: "0"))
    try press("entry.form.save", in: host)
    XCTAssertEqual(try host.transactions.count(), 0, "no category, nothing saved")

    try choose("Cafe", inMenu: "entry.category", host: host)
    try press("entry.form.save", in: host)
    let saved = try XCTUnwrap(try host.transactions.recentEntries(limit: 5).first)
    XCTAssertEqual(saved.transaction.amountE4, AmountE4(whole: 250))
    XCTAssertEqual(saved.parts.first?.categoryId, cafe.id)
    XCTAssertNil(
      host.textFields().first { $0.placeholderString == "0" }, "the form is back at the kinds")
    try press("entry.kind.expense", in: host)
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "", "the form is empty again")
    XCTAssertNotNil(element(identified: "entry.form.save", in: host.window), "and still there")
  }

  /// Return in a field of the form saves, as in the panel of the line.
  func testReturnInAFieldOfTheFormSaves() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try choose("Cafe", inMenu: "entry.category", host: host)
    let amount = try host.type("300", into: try host.field(prompt: "0"))
    amount.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 1)
    XCTAssertEqual(
      try host.transactions.recentEntries(limit: 1).first?.transaction.amountE4,
      AmountE4(whole: 300))
  }

  /// «Очистить» drops what was typed.
  func testClearDropsWhatWasTyped() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try host.type("250", into: try host.field(prompt: "0"))
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "250")
    try press("entry.form.clear", in: host)
    try press("entry.kind.expense", in: host)
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "")
    XCTAssertEqual(try host.transactions.count(), 0)
  }

  /// Nothing the form shows came from history: the same words filed in a category before do not
  /// file the new operation there.
  func testTheFormDoesNotFileByHistory() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await EntryHost(opensDetails: false, style: .form) { environment in
      try EntryHost.history("coffee", in: environment)
    }
    self.host = host
    try press("entry.kind.expense", in: host)
    let noteTitle = host.environment.language("entry.note", table: "Entry")
    try host.type("coffee", into: try host.field(prompt: noteTitle))
    try host.type("250", into: try host.field(prompt: "0"))
    try press("entry.form.save", in: host)
    XCTAssertEqual(try host.transactions.count(), 1, "only the operation of the history")
  }
}
