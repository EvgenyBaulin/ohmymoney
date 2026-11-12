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
    if section == .calendar {
      try checkCalendarScrolledToTheEnd(width: width, height: height, language: language)
      return
    }
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

  /// The narrow calendar stacks a native day list below the month. Its accessibility frame
  /// includes rows outside the enclosing page's clip, so a viewport-frame check cannot tell
  /// whether the last card is reachable. Scroll the page and check the whole card instead.
  private func checkCalendarScrolledToTheEnd(
    width: CGFloat, height: CGFloat, language: AppLanguage.Choice
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = mainWindow(.calendar, width: width, height: height)
    settle(window)
    let root = try XCTUnwrap(window.contentView)
    let sidebar = try sidebarEdge(in: window)
    var scrolls: [NSScrollView] = []
    Self.allSubviews(of: root, into: &scrolls)
    let page = try XCTUnwrap(
      scrolls.filter {
        let rect = $0.convert($0.bounds, to: nil)
        return rect.minX >= sidebar - 1 && rect.width > 400 && rect.height > 300
          && !($0.documentView is NSTableView)
      }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height },
      "the calendar's outer page scroll view")
    let document = try XCTUnwrap(page.documentView)
    let start = document.isFlipped ? document.bounds.minY : document.bounds.maxY
    document.scroll(NSPoint(x: 0, y: start))
    settle(window, passes: 6)
    let before = page.contentView.bounds.origin.y
    let end = document.isFlipped ? document.bounds.maxY : document.bounds.minY
    document.scroll(NSPoint(x: 0, y: end))
    settle(window)
    if !CalendarLayout.isWide(width: page.bounds.width) {
      XCTAssertNotEqual(
        page.contentView.bounds.origin.y, before,
        "\(language): the narrow calendar must actually scroll")
    }
    let card = try frame(of: "calendar.upcoming", in: window)
    let top = try barTop(in: window)
    let viewport = page.contentView.convert(page.contentView.bounds, to: nil)
    XCTAssertGreaterThanOrEqual(
      card.minY, max(top, viewport.minY) - 0.5,
      "\(Int(width))×\(Int(height)) \(language): the last calendar card ends under the bar")
    XCTAssertLessThanOrEqual(
      card.maxY, min(viewport.maxY, window.contentLayoutRect.maxY) + 0.5,
      "\(Int(width))×\(Int(height)) \(language): the whole last calendar card must be visible")
  }

  /// Scrolled to its end, the page's last point stands above the bar: what the owner sees when
  /// the last card is read to the bottom.
  private func checkScrolledToTheEnd(
    _ section: MainWindow.Section, width: CGFloat, height: CGFloat, language: AppLanguage.Choice
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = mainWindow(section, width: width, height: height)
    settle(window)
    let top = try barTop(in: window)
    var scrolls: [NSScrollView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &scrolls)
    // The page's scroll view runs under the sidebar and the bar (the safe area is its content
    // inset), so it is told by its size, not by where it starts.
    let pages = scrolls.filter { scroll in
      let inWindow = scroll.convert(scroll.bounds, to: nil)
      return inWindow.width > 600 && inWindow.height > 300
        && !(scroll.documentView is NSTableView)
    }
    XCTAssertFalse(pages.isEmpty, "\(section): the page scrolls")
    for scroll in pages {
      guard let document = scroll.documentView else { continue }
      let clip = scroll.contentView
      let lowest = max(0, document.frame.height - clip.bounds.height + clip.contentInsets.bottom)
      let isFlipped = document.isFlipped
      clip.scroll(to: NSPoint(x: 0, y: isFlipped ? lowest : -clip.contentInsets.bottom))
      scroll.reflectScrolledClipView(clip)
      settle(window, passes: 6)
      // The document's bottom edge in window coordinates (y grows upwards there).
      let edge = document.convert(
        NSPoint(x: 0, y: isFlipped ? document.bounds.maxY : document.bounds.minY), to: nil
      ).y
      XCTAssertGreaterThanOrEqual(
        edge, top - 0.5,
        "\(section) \(Int(width))×\(Int(height)) \(language): scrolled to the end the page's last point is at \(edge), the bar starts at \(top)"
      )
    }
  }

  func testEveryScreenScrolledToTheEndClearsTheBar() throws {
    // Calendar is checked by scrolling its last card above the bar (above); Operations is a table.
    for section in Self.sections where section != .operations && section != .calendar {
      for (width, height) in [(CGFloat(1_440), CGFloat(900)), (1_024, 700)] {
        for language in [AppLanguage.Choice.russian, .english] {
          try checkScrolledToTheEnd(section, width: width, height: height, language: language)
        }
      }
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

  /// The table beside the editor shows the columns it was given at least their minimum, and does
  /// not run off to the right under a horizontal scroller: the account and the category are
  /// read, not cut to «Повсе…».
  private func checkTableBesideTheEditor(
    width: CGFloat, height: CGFloat, language: AppLanguage.Choice
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = try windowWithEditor(width: width, height: height)
    var tables: [NSTableView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &tables)
    let table = try XCTUnwrap(tables.max { $0.numberOfColumns < $1.numberOfColumns })
    let clip = try XCTUnwrap(table.enclosingScrollView).contentView
    let widths = table.tableColumns.map { Int($0.width) }
    if width >= 1_440 {
      XCTAssertLessThanOrEqual(
        table.frame.width, clip.bounds.width + 0.5,
        "\(Int(width)) \(language): the table is wider than its card (\(widths))")
    }
    for (column, shown) in zip(OperationColumn.allCases.filter(\.shownByDefault), widths)
    where width >= 1_440 {
      XCTAssertGreaterThanOrEqual(
        shown, column.minimumWidth, "\(Int(width)) \(language): \(column) is \(shown) wide")
    }
  }

  func testTheTableBesideTheEditorKeepsItsColumns() throws {
    for (w, h) in [(CGFloat(1_440), CGFloat(900)), (1_500, 900)] {
      for language in [AppLanguage.Choice.russian, .english] {
        try checkTableBesideTheEditor(width: w, height: h, language: language)
      }
    }
  }

  /// The wide window gives the account and the category what a name needs, not the minimum a
  /// squeezed table falls back to.
  func testTheAccountAndCategoryColumnsAreReadableBesideTheEditor() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try seedChips()
    let window = try windowWithEditor(width: 1_440, height: 900)
    var tables: [NSTableView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &tables)
    let table = try XCTUnwrap(tables.max { $0.numberOfColumns < $1.numberOfColumns })
    let widths = table.tableColumns.map { Int($0.width) }
    XCTAssertGreaterThanOrEqual(widths[1], 140, "category \(widths)")
    XCTAssertGreaterThanOrEqual(widths[2], 130, "account \(widths)")
  }

  /// The editor's foot is pinned above the bar and the page of fields scrolls above it: the
  /// viewport ends where the foot begins, and scrolled to its end the last field is whole.
  private func checkEditorFoot(width: CGFloat, height: CGFloat, language: AppLanguage.Choice) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.language.choice = language
    try seedChips()
    let window = try windowWithEditor(width: width, height: height)
    let top = try barTop(in: window)
    let save = try frame(of: "editor.save", in: window)
    let delete = try frame(of: "editor.delete", in: window)
    XCTAssertGreaterThanOrEqual(save.minY, top - 0.5, "the foot stands above the bar")
    let foot = min(save.minY, delete.minY)
    let footTop = max(save.maxY, delete.maxY)
    var scrolls: [NSScrollView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &scrolls)
    let page = try XCTUnwrap(
      scrolls.first { scroll in
        let r = scroll.convert(scroll.bounds, to: nil)
        return r.width < 420 && r.height > 150 && r.minX > width / 2
          && !(scroll.documentView is NSTableView)
      }, "the editor's page of fields")
    let viewport = page.convert(page.bounds, to: nil)
    XCTAssertGreaterThanOrEqual(
      viewport.minY, footTop - 0.5,
      "\(Int(width)) \(language): the page of fields (to \(viewport.minY)) reaches the foot (\(footTop))"
    )
    _ = foot
    let document = try XCTUnwrap(page.documentView)
    let clip = page.contentView
    let lowest = max(0, document.frame.height - clip.bounds.height + clip.contentInsets.bottom)
    clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? lowest : 0))
    page.reflectScrolledClipView(clip)
    settle(window, passes: 6)
    let edge = document.convert(
      NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : document.bounds.minY), to: nil
    ).y
    XCTAssertGreaterThanOrEqual(
      edge, viewport.minY - 0.5, "\(Int(width)) \(language): the last field ends under the foot")
  }

  func testTheFootOfTheEditorIsPinnedAndTheFieldsScroll() throws {
    for (w, h) in [(CGFloat(1_440), CGFloat(900)), (1_120, 720)] {
      for language in [AppLanguage.Choice.russian, .english] {
        try checkEditorFoot(width: w, height: h, language: language)
      }
    }
  }
}
