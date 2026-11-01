import AppCore
import Foundation
import SwiftUI

/// What a file of the archive's container holds when it carries tables and no database: a table
/// export locked with a password («Итог поездки», «Отчёты», «Банкам за год») or a copy made as «Только
/// CSV». Such a file is looked at, never imported: the owner's books are not touched by it. The
/// tables are the bytes that were sealed, read as RFC 4180 by `CoreCSV`; «Сохранить CSV…» writes
/// those very bytes out, in the open.
struct ArchiveTables: Equatable, Sendable {
  struct Table: Equatable, Sendable, Identifiable {
    /// The file name, «trip-turkey-by-day.csv».
    var name: String
    var data: Data
    var id: String { name }
  }

  /// The first lines of a table for the screen.
  struct Grid: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
      let id: Int
      /// As many cells as the header has columns: a short line is padded with empty cells.
      let cells: [String]
    }

    let header: [String]
    let lines: [Line]
    /// Every line of the table under its header, shown or not.
    let totalLines: Int

    var isCut: Bool { lines.count < totalLines }

    /// The two numbers of «Показаны первые 1,000; всего строк: 1,005», grouped as every number of
    /// the interface is.
    var cutNumbers: (shown: String, total: String) {
      (NumberText.integer(Int64(lines.count)), NumberText.integer(Int64(totalLines)))
    }
  }

  /// How many lines of a table the screen shows; the saved file has them all.
  static let shownLines = 1_000

  let tables: [Table]

  init(tables: [Table]) { self.tables = tables }

  init(_ opened: ArchiveOpener.OpenedArchive) {
    tables = opened.csvTables.compactMap { table in
      opened.csv(table: table).map { Table(name: table + ".csv", data: $0) }
    }
  }

  /// The file carries tables and no database: it is shown, not imported. A file with neither is
  /// no such file — the import says what is wrong with it.
  static func holdsOnlyTables(_ opened: ArchiveOpener.OpenedArchive) -> Bool {
    opened.database == nil && !opened.csvTables.isEmpty
  }

  /// The header and the first `limit` lines of a table. A line longer than the header widens the
  /// grid with nameless columns, a shorter one is padded: a file edited by hand never traps. Bytes
  /// that are not UTF-8 throw.
  static func grid(of table: Table, limit: Int = shownLines) throws -> Grid {
    let rows = try CSVReader.rows(from: table.data)
    guard let first = rows.first else { return Grid(header: [], lines: [], totalLines: 0) }
    let body = rows.dropFirst()
    let shown = body.prefix(limit)
    let width = max(first.count, shown.map(\.count).max() ?? 0)
    func padded(_ row: [String]) -> [String] {
      row.count < width ? row + Array(repeating: "", count: width - row.count) : row
    }
    return Grid(
      header: padded(first),
      lines: shown.enumerated().map { Grid.Line(id: $0.offset, cells: padded($0.element)) },
      totalLines: body.count)
  }

  /// The tables as files, byte for byte as they were inside.
  var files: [PersonalDataExport.File] {
    tables.map { PersonalDataExport.File(name: $0.name, data: $0.data) }
  }

  /// How many of the files are in the folder already.
  func replacing(in directory: URL) -> Int {
    tables.count {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path)
    }
  }

  /// Every table into the folder, each whole or not at all; the first failure stops. The journal
  /// has the counts, never a name.
  func write(to directory: URL) throws -> Int {
    do {
      for table in tables {
        try table.data.write(to: directory.appendingPathComponent(table.name), options: .atomic)
      }
    } catch {
      AppLog.error(
        "archive.tables.failed", .archive, "the tables of a locked file were not saved",
        [LogPair("error", .error(error))])
      throw error
    }
    AppLog.info(
      "archive.tables.saved", .archive, "the tables of a locked file were saved as CSV",
      [LogPair("files", .count(tables.count))])
    return tables.count
  }
}

#if os(macOS)
  import AppKit

  /// The window that shows a file of tables: their names at the left, the chosen one as a table,
  /// «Сохранить CSV…» and «Закрыть». It is a window of its own, so it wears the cover of the lock
  /// at its root as every scene does.
  @MainActor
  enum ArchiveTablesWindow {
    private static var open: [NSWindow: Closer] = [:]

    static func show(_ tables: ArchiveTables, environment: AppEnvironment) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.title = environment.language("archive.tables.title", table: "Reports")
      let closer = Closer()
      closer.window = window
      window.delegate = closer
      // dependencies: the content reads none — it is handed the environment it needs — and gets
      // the language, the theme and the size of the text here, as the roots of the scenes do.
      window.contentViewController = NSHostingController(
        rootView: ArchiveTablesView(
          tables: tables, environment: environment, close: { [weak window] in window?.performClose(nil) }
        )
        .environment(\.locale, environment.language.locale)
        .modifier(AppThemeModifier(theme: environment.theme))
        .modifier(AppFontSizing(size: environment.theme.fontSize))
        .privacyCurtain(environment))
      window.setContentSize(NSSize(width: 860, height: 560))
      window.minSize = NSSize(width: 560, height: 360)
      window.center()
      open[window] = closer
      window.makeKeyAndOrderFront(nil)
    }

    /// Lets the window go once it is closed.
    @MainActor private final class Closer: NSObject, NSWindowDelegate {
      weak var window: NSWindow?

      func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        ArchiveTablesWindow.open.removeValue(forKey: window)
      }
    }

    /// «Сохранить CSV…»: the warning about names and amounts, a folder, the question before files
    /// with these names are replaced, then the files — in the open — and the result in words.
    static func save(_ tables: ArchiveTables, environment: AppEnvironment) {
      guard FileCommands.confirmPersonalData(environment) else { return }
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      guard panel.runModal() == .OK, let directory = panel.url else { return }
      let replaced = tables.replacing(in: directory)
      if replaced > 0 {
        let ask = NSAlert()
        ask.alertStyle = .warning
        ask.messageText = environment.format("export.replace.title", table: "Settings", replaced)
        ask.informativeText = environment.language("export.replace.body", table: "Settings")
        ask.addButton(
          withTitle: environment.language("export.replace.action", table: "Settings"))
        ask.addButton(withTitle: environment.language("action.cancel"))
        guard ask.runModal() == .alertFirstButtonReturn else { return }
      }
      let alert = NSAlert()
      do {
        let written = try tables.write(to: directory)
        alert.messageText = environment.format("export.done", table: "Settings", written)
      } catch {
        alert.alertStyle = .warning
        alert.messageText = environment.language("export.failed", table: "Settings")
        alert.informativeText = environment.language("export.failed.body", table: "Settings")
      }
      alert.runModal()
    }
  }

  /// The content of the window: the list of the tables and the chosen one.
  private struct ArchiveTablesView: View {
    let tables: ArchiveTables
    let environment: AppEnvironment
    let close: () -> Void
    @State private var selection: String?

    private func t(_ key: String) -> String { environment.language(key, table: "Reports") }

    var body: some View {
      VStack(spacing: 0) {
        HSplitView {
          List(tables.tables, selection: $selection) { table in
            Text(verbatim: table.name)
              .lineLimit(1)
              .truncationMode(.middle)
              .tag(table.name)
          }
          .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
          .accessibilityIdentifier("archive.tables.list")
          Group {
            if let table = tables.tables.first(where: { $0.name == selection }) {
              ArchiveTableGrid(table: table, environment: environment)
                .id(table.name)
            } else {
              Text(verbatim: t("archive.tables.choose"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        Divider()
        HStack {
          Text(verbatim: t("archive.tables.note"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
          Spacer()
          Button(t("archive.tables.save")) {
            ArchiveTablesWindow.save(tables, environment: environment)
          }
          .accessibilityIdentifier("archive.tables.save")
          Button(environment.language("action.close"), action: close)
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
      }
      .onAppear { if selection == nil { selection = tables.tables.first?.name } }
      .accessibilityIdentifier("archive.tables")
    }
  }

  /// One table: a SwiftUI `Table` with a column for each field of the header. It is made empty and
  /// filled once it is on screen — a table made with its lines lays them out inside its own making
  /// and AppKit touches it from its delegate; each table of the file is a new grid (`id`).
  private struct ArchiveTableGrid: View {
    let table: ArchiveTables.Table
    let environment: AppEnvironment
    @State private var grid: ArchiveTables.Grid?
    @State private var lines: [ArchiveTables.Grid.Line] = []
    @State private var unreadable = false

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        if unreadable {
          Text(verbatim: environment.language("archive.tables.unreadable", table: "Reports"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let grid, grid.header.isEmpty {
          Text(verbatim: environment.language("archive.tables.empty", table: "Reports"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          let header = grid?.header ?? []
          Table(lines) {
            TableColumnForEach(header.indices, id: \.self) { index in
              TableColumn(Text(verbatim: header[index])) { (line: ArchiveTables.Grid.Line) in
                Text(verbatim: index < line.cells.count ? line.cells[index] : "")
                  .monospacedDigit()
              }
            }
          }
          .accessibilityIdentifier("archive.tables.grid")
          if let grid, grid.isCut {
            Text(
              verbatim: environment.format(
                "archive.tables.cut", table: "Reports", grid.cutNumbers.shown,
                grid.cutNumbers.total)
            )
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
          }
        }
      }
      .padding(.bottom, 6)
      .onAppear {
        do {
          let read = try ArchiveTables.grid(of: table)
          grid = read
          lines = read.lines
        } catch {
          unreadable = true
        }
      }
    }
  }
#endif
