import AppCore
import AppKit
import SwiftUI

/// Whether printing asks first: with «Скрыть суммы» on, «Печатать с суммами?» — a page on paper
/// is outside the app as much as a file is. Without it, the page is printed with its amounts.
enum PrintAmounts {
  static func asks(hidesAmounts: Bool) -> Bool { hidesAmounts }
}

/// Something the window in front can print: a title and its table, with amounts and without.
/// The Operations list and the Reports window hand one to «Файл → Печать…» (⌘P).
struct PrintableTable {
  let title: String
  /// The table; `withAmounts` false leaves the amounts out.
  let table: @MainActor (_ withAmounts: Bool) -> PasteTable?
}

struct PrintableTableKey: FocusedValueKey {
  typealias Value = PrintableTable
}

extension FocusedValues {
  var printableTable: PrintableTable? {
    get { self[PrintableTableKey.self] }
    set { self[PrintableTableKey.self] = newValue }
  }
}

/// Any table on paper: the title, the header row and the rows, amounts to the right. Light, in
/// black on white, of a fixed size: a document, not a screen.
struct TablePrintPage: View {
  let title: String
  let table: PasteTable

  static let width: CGFloat = 720

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: title)
        .font(.system(size: 18, weight: .bold))  // font-fixed: a printed page has a fixed size
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
        GridRow {
          ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
            Text(verbatim: column)
              .font(.system(size: 10, weight: .semibold))  // font-fixed: a printed page has a fixed size
              .gridColumnAlignment(alignment(of: index))
          }
        }
        Divider()
        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              Text(verbatim: PasteTable.text(of: cell))
                .font(.system(size: 10))  // font-fixed: a printed page has a fixed size
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .padding(24)
    .frame(width: Self.width, alignment: .leading)
    .background(Color.white)
    .foregroundStyle(Color.black)
    .environment(\.colorScheme, .light)
  }

  /// A column of amounts — the first row tells — stands to the right.
  private func alignment(of index: Int) -> HorizontalAlignment {
    guard let first = table.rows.first, index < first.count, case .amount = first[index] else {
      return .leading
    }
    return .trailing
  }
}

/// The print panel of the Mac over a SwiftUI page: the page laid out at its own width, split into
/// sheets of paper top to bottom, fitted to the width of the paper.
@MainActor
enum MacPrint {
  static func run<Page: View>(_ page: Page, width: CGFloat, jobTitle: String) {
    // dependencies: none — a printed page is plain text and figures handed in, it reads
    // nothing of the app's.
    let host = NSHostingView(rootView: page)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
    let size = host.fittingSize
    host.frame = NSRect(x: 0, y: 0, width: width, height: max(size.height, 10))
    let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isHorizontallyCentered = true
    info.isVerticallyCentered = false
    let operation = NSPrintOperation(view: host, printInfo: info)
    operation.jobTitle = jobTitle
    operation.showsPrintPanel = true
    operation.showsProgressPanel = true
    if let window = NSApp.keyWindow {
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
      operation.run()
    }
    AppLog.info("print.started", .ui, "the print panel was opened")
  }
}

/// «Файл → Печать…» (⌘P): the table of the window in front, after «Печатать с суммами?» when the
/// amounts are hidden.
struct PrintCommands: Commands {
  let environment: AppEnvironment
  @FocusedValue(\.printableTable) private var printable

  var body: some Commands {
    CommandGroup(replacing: .printItem) {
      Button(environment.language("mac.print.menu", table: MacCommands.table)) {
        guard let printable else { return }
        PrintFlow.print(printable, environment: environment)
      }
      .keyboardShortcut("p")
      .disabled(printable == nil)
    }
  }
}

/// The question about the amounts, asked as an alert of the app before the print panel.
@MainActor
enum PrintFlow {
  static func print(_ printable: PrintableTable, environment: AppEnvironment) {
    var withAmounts = true
    if PrintAmounts.asks(hidesAmounts: environment.amounts.isHidingNow) {
      switch askAboutAmounts(environment) {
      case .with: withAmounts = true
      case .without: withAmounts = false
      case .cancel: return
      }
    }
    guard let table = printable.table(withAmounts) else { return }
    MacPrint.run(
      TablePrintPage(title: printable.title, table: table), width: TablePrintPage.width,
      jobTitle: printable.title)
  }

  enum Answer { case with, without, cancel }

  /// «Печатать с суммами?»: «С суммами», «Без сумм», «Отмена».
  static func askAboutAmounts(_ environment: AppEnvironment) -> Answer {
    func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }
    let alert = NSAlert()
    alert.messageText = t("mac.print.ask")
    alert.informativeText = t("mac.print.askMessage")
    alert.addButton(withTitle: t("mac.print.with"))
    alert.addButton(withTitle: t("mac.print.without"))
    alert.addButton(withTitle: environment.language("action.cancel"))
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .with
    case .alertSecondButtonReturn: return .without
    default: return .cancel
    }
  }
}
