import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The entry line, its chips and the selection bar float over the bottom of the window. Every
/// scrolling screen has to let its last block scroll up above them: the viewport of the page
/// ends above the top of the bar (the safe area takes the bar's height), so scrolled to the end
/// nothing of the content stands under it — in a wide and in a narrow window, in Russian and in
/// English. A snapshot of a page scrolled to its top shows the bar over the lower cards; that is
/// not the defect this guards.
@MainActor
final class FloatingBarClearanceTests: SectionFigmaHarness {
  private static let sections: [MainWindow.Section] = [
    .overview, .operations, .debts, .capital, .analytics, .calendar, .purchases,
  ]

  /// A pinned chip, so that the strip above the capsule has its height.
  private func seedChips() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(Template(text: "coffee", amountE4: AmountE4(whole: 250), pinned: true))
    try references.save(Template(text: "taxi", amountE4: AmountE4(whole: 300), pinned: true))
    environment.entryChipsShown = true
    NotificationCenter.default.post(name: .templatesChanged, object: nil)
  }

  /// The top of the bar: the highest of the chips and the capsule, in screen coordinates.
  private func barTop(in window: NSWindow) throws -> CGFloat {
    let capsule = try frame(of: "entry.line.capsule", in: window)
    let chips = try frame(of: "entry.templates", in: window)
    XCTAssertGreaterThan(chips.height, 0, "the chips are on the screen")
    return max(capsule.maxY, chips.maxY)
  }

  /// The viewports right of the sidebar, but for the chips strip: what scrolls the page.
  private func pageViewports(in window: NSWindow) throws -> [CGRect] {
    let sidebar = try sidebarEdge(in: window)
    var found: [AnyObject] = []
    Self.elements(in: try XCTUnwrap(window.contentView), into: &found) {
      ($0.accessibilityRole?() == .scrollArea)
        && ($0.accessibilityIdentifier?() ?? "") != "entry.templates"
    }
    return found.compactMap { $0.accessibilityFrame?() }
      .map { window.convertFromScreen($0) }
      .filter { $0.minX >= sidebar - 1 && $0.width > 200 && $0.height > 100 }
  }

  private func checkClearance(
    _ section: MainWindow.Section, width: CGFloat, height: CGFloat, language: AppLanguage.Choice
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = mainWindow(section, width: width, height: height)
    settle(window)
    let top = try barTop(in: window)
    let viewports = try pageViewports(in: window)
    XCTAssertFalse(viewports.isEmpty, "\(section): the page scrolls")
    for viewport in viewports {
      XCTAssertGreaterThanOrEqual(
        viewport.minY, top - 0.5,
        "\(section) \(Int(width))×\(Int(height)) \(language): the page's viewport reaches down to \(viewport.minY), the bar starts at \(top)"
      )
    }
  }

  func testEveryScreenScrollsAboveTheBarWide() throws {
    for section in Self.sections {
      for language in [AppLanguage.Choice.russian, .english] {
        try checkClearance(section, width: 1_440, height: 900, language: language)
      }
    }
  }

  func testEveryScreenScrollsAboveTheBarNarrow() throws {
    for section in Self.sections {
      for language in [AppLanguage.Choice.russian, .english] {
        try checkClearance(section, width: 1_024, height: 700, language: language)
      }
    }
  }

  // MARK: The footer of the list

  /// «Ещё N более ранних…» and «Показать ещё 3 месяца» stand under the table's last row, not over
  /// it and its sum: the table scrolled to its end ends above the footer, and the footer above
  /// the bar.
  private func rowInWindow0(_ t: NSTableView) -> CGRect { t.convert(t.rect(ofRow: t.numberOfRows - 1), to: nil) }

  private func checkFooter(width: CGFloat, height: CGFloat, language: AppLanguage.Choice) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = mainWindow(.operations, width: width, height: height)
    settle(window)
    let top = try barTop(in: window)
    var tables: [NSTableView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &tables)
    let table = try XCTUnwrap(tables.max { $0.numberOfColumns < $1.numberOfColumns })
    let scroll = try XCTUnwrap(table.enclosingScrollView)
    let clip = scroll.contentView
    for _ in 0..<12 {
      clip.scroll(
        to: NSPoint(
          x: 0, y: table.frame.height - clip.bounds.height + clip.contentInsets.bottom))
      scroll.reflectScrolledClipView(clip)
      settle(window, passes: 4)
    }
    settle(window, passes: 10)
    let footer = try frame(of: "operations.earlier", in: window)
    print("FOOT top=\(top) footer=\(footer) row=\(rowInWindow0(table)) inset=\(scroll.contentInsets.bottom) clipinset=\(scroll.contentView.contentInsets.bottom) rows=\(table.numberOfRows) win=\(window.frame)")
    XCTAssertGreaterThan(footer.height, 0)
    XCTAssertGreaterThanOrEqual(footer.minY, top - 0.5, "the footer stands above the bar")
    let lastRow = table.rect(ofRow: table.numberOfRows - 1)
    let rowInWindow = table.convert(lastRow, to: nil)
    XCTAssertGreaterThanOrEqual(
      rowInWindow.minY, footer.maxY - 0.5,
      "\(Int(width))×\(Int(height)) \(language): the last row reaches down to \(rowInWindow.minY), the footer's top is \(footer.maxY)"
    )
  }

  /// The footer is opaque: rows scrolling under it are not seen through it, so it never reads as
  /// text laid over a row and its sum. The footer's picture is the same with the table scrolled
  /// to two offsets that put different rows under it.
  private func checkFooterIsOpaque(language: AppLanguage.Choice) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = mainWindow(.operations, width: 1_440, height: 900)
    settle(window)
    var tables: [NSTableView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &tables)
    let table = try XCTUnwrap(tables.max { $0.numberOfColumns < $1.numberOfColumns })
    let clip = try XCTUnwrap(table.enclosingScrollView).contentView
    let view = try XCTUnwrap(window.contentView)
    let footer = view.convert(try frame(of: "operations.earlier", in: window), from: nil)

    func picture(at offset: CGFloat) throws -> Data {
      clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top + offset))
      table.enclosingScrollView?.reflectScrolledClipView(clip)
      settle(window, passes: 6)
      let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: footer))
      view.cacheDisplay(in: footer, to: rep)
      return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
    let first = try picture(at: 200)
    let second = try picture(at: 217)
    XCTAssertEqual(first, second, "\(language): the rows under the footer show through it")
  }

  func testTheFooterOfTheListIsOpaque() throws {
    for language in [AppLanguage.Choice.russian, .english] {
      try checkFooterIsOpaque(language: language)
    }
  }

  func testTheFooterOfTheListStandsUnderTheLastRowWide() throws {
    for language in [AppLanguage.Choice.russian, .english] {
      try checkFooter(width: 1_440, height: 900, language: language)
    }
  }

  func testTheFooterOfTheListStandsUnderTheLastRowNarrow() throws {
    for language in [AppLanguage.Choice.russian, .english] {
      try checkFooter(width: 1_024, height: 700, language: language)
    }
  }

  // MARK: The editor beside the table

  /// The main window on «Операции» with the editor of the newest operation open beside the table,
  /// the way a double click opens it.
  private func windowWithEditor(width: CGFloat, height: CGFloat) throws -> NSWindow {
    let actions = OperationActions()
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        MainWindow(
          deps: deps, actions: actions, opensDetails: false, selection: .section(.operations))
      }
      .environment(\.windowWidth, width)
      .defaultAppStorage(defaults)
    let window = host(root, width: width, height: height, unified: true)
    settle(window)
    store.show(try XCTUnwrap(compute.snapshot).ledger)
    let newest = try XCTUnwrap(
      try XCTUnwrap(compute.snapshot).dataset.entries
        .filter { $0.transaction.deletedAt == nil && $0.transaction.kind == .expense }
        .max { $0.transaction.occurredAt < $1.transaction.occurredAt })
    actions.edit([newest.transaction.id], store: store)
    settle(window, passes: 40)
    return window
  }

  private func checkEditorBesideTheTable(
    width: CGFloat, height: CGFloat, language: AppLanguage.Choice
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = try windowWithEditor(width: width, height: height)
    var tables: [NSTableView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &tables)
    let table = try XCTUnwrap(tables.max { $0.numberOfColumns < $1.numberOfColumns })
    let widths = table.tableColumns.map { Int($0.width) }
    print("EDITOR \(Int(width)) \(language) columns=\(widths) titles=\(table.tableColumns.map(\.title))")
    let scroller = table.enclosingScrollView?.hasHorizontalScroller == true
    print("EDITOR hscroll=\(scroller) tablewidth=\(table.frame.width) clip=\(table.enclosingScrollView?.contentView.bounds.width ?? 0)")
  }

  func testEditorDump() throws {
    for (w, h) in [(CGFloat(1_440), CGFloat(900)), (1_120, 800), (1_024, 700)] {
      try checkEditorBesideTheTable(width: w, height: h, language: .russian)
    }
  }
}
