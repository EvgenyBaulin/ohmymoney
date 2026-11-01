import AppCore
import SwiftUI

/// The table of the Reports window on paper (⌘P): the name of each line — a child under its
/// parent with an indent — the measures in whole rubles and, when the table has them, the
/// shares. Without amounts («Печатать с суммами?» → «Без сумм») only the names and the shares
/// stay.
@MainActor
enum ReportsPrint {
  static func printable(_ model: ReportsModel, environment: AppEnvironment) -> PrintableTable {
    let title =
      "\(ReportsText.title(of: model.request.kind, environment)) · "
      + ReportsText.subtitle(model.request, environment)
    return PrintableTable(title: title) { withAmounts in
      table(model, environment: environment, withAmounts: withAmounts)
    }
  }

  static func table(
    _ model: ReportsModel, environment: AppEnvironment, withAmounts: Bool
  ) -> PasteTable {
    var columns = [ReportsText.nameColumn(model.request.kind, environment)]
    if withAmounts {
      columns += model.table.measures.map { ReportsText.column($0, environment) }
    }
    if model.table.hasShares {
      columns.append(environment.language("markdown.share", table: MacCommands.table))
    }
    var rows: [[PasteTable.Cell]] = []
    func add(_ line: ReportLine, depth: Int) {
      let indent = String(repeating: "    ", count: depth)
      var row: [PasteTable.Cell] = [
        .text(indent + ReportsText.name(of: line, in: model, environment))
      ]
      if withAmounts {
        row += line.values.map { value in value.map { .amount(AmountE4(whole: $0)) } ?? .empty }
      }
      if model.table.hasShares {
        row.append(line.share.map { .text(ReportsText.share($0, environment)) } ?? .empty)
      }
      rows.append(row)
      for child in line.children { add(child, depth: depth + 1) }
    }
    for line in model.lines where !line.lacksData { add(line, depth: 0) }
    return PasteTable(columns: columns, rows: rows)
  }
}
