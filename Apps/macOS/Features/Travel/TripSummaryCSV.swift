import AppCore
import Foundation

/// «Итог поездки» as CSV, in the family of the Reports files (`ReportCSV`): UTF-8 without a BOM,
/// a dot for decimals, English snake_case headers that `pandas.read_csv` reads with no parameters,
/// the whole rubles (`amount_rub`) beside the exact amount with four decimals
/// (`amount_rub_exact`) and the share as a fraction with four decimals, the shares of a file
/// summing to exactly 1 (`Shares`). One file for each section of the screen: by day, by category,
/// by currency and the settlement with the people who travelled. The figures are the summary's;
/// this only writes them.
enum TripSummaryCSV {
  struct File: Equatable {
    /// The name of the file, ready for a folder.
    let name: String
    let data: Data
  }

  /// The four files of a trip. `category` names a top-level category (`nil` — without one),
  /// `person` names the one who owes.
  static func files(
    for summary: TripSummary, tripName: String, category: (UUID?) -> String,
    person: (UUID) -> String
  ) -> [File] {
    let stem = "trip-" + slug(tripName)
    return [
      File(
        name: "\(stem)-by-day.csv",
        data: table(
          summary.byDay.map { ($0.day.iso, $0.amount) }, total: summary.total)),
      File(
        name: "\(stem)-by-category.csv",
        data: table(
          summary.byCategory.map { (category($0.categoryId), $0.amount) }, total: summary.total)),
      File(name: "\(stem)-by-currency.csv", data: currencies(summary)),
      File(name: "\(stem)-settlement.csv", data: settlement(summary, person: person)),
    ]
  }

  /// The columns every file of the family starts with.
  static let columns = ["row_type", "name", "amount_rub", "amount_rub_exact", "share"]

  /// Items and a total, with shares.
  static func table(_ rows: [(name: String, amount: AmountE4)], total: AmountE4) -> Data {
    var writer = CSVWriter(columns: columns)
    let shares = Shares.basisPoints(rows.map(\.amount))
    for (row, share) in zip(rows, shares) {
      writer.append(["item", row.name] + amounts(row.amount) + [ReportCSV.share(share)])
    }
    let anyShare = shares.contains { $0 != nil }
    writer.append(
      ["total", "Total"] + amounts(total) + [anyShare ? ReportCSV.share(Shares.whole) : ""])
    return writer.data()
  }

  /// By currency: the rubles of the operations and, beside them, the same operations in their
  /// own currency.
  static func currencies(_ summary: TripSummary) -> Data {
    var writer = CSVWriter(columns: columns + ["amount", "amount_exact"])
    let shares = Shares.basisPoints(summary.byCurrency.map(\.rubles))
    for (row, share) in zip(summary.byCurrency, shares) {
      writer.append(
        ["item", row.currency.code] + amounts(row.rubles) + [ReportCSV.share(share)]
          + amounts(row.amount))
    }
    let anyShare = shares.contains { $0 != nil }
    writer.append(
      ["total", "Total"] + amounts(summary.total) + [anyShare ? ReportCSV.share(Shares.whole) : ""]
        + ["", ""])
    return writer.data()
  }

  /// What each person still owes the owner, and from how many parts that is made.
  static func settlement(_ summary: TripSummary, person: (UUID) -> String) -> Data {
    var writer = CSVWriter(columns: ["row_type", "name", "amount_rub", "amount_rub_exact", "parts"])
    for share in summary.settlement {
      writer.append(["item", person(share.personId)] + amounts(share.owed) + ["\(share.parts)"])
    }
    writer.append(
      ["total", "Total"] + amounts(AmountE4.sum(summary.settlement.map(\.owed)))
        + ["\(summary.settlement.map(\.parts).reduce(0, +))"])
    return writer.data()
  }

  private static func amounts(_ amount: AmountE4) -> [String] {
    [String(amount.wholeRubles), ReportCSV.exact(amount)]
  }

  /// A name made fit for a file name: letters and digits stay, anything else becomes one dash.
  static func slug(_ name: String) -> String {
    var result = ""
    var dash = false
    for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
      if character.isLetter || character.isNumber {
        result.append(character)
        dash = false
      } else if !dash, !result.isEmpty {
        result.append("-")
        dash = true
      }
    }
    while result.hasSuffix("-") { result.removeLast() }
    return result.isEmpty ? "trip" : result
  }
}
