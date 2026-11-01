import CoreKit
import Foundation

/// A table handed to another application — dragged into Numbers or Mail, or copied: a header
/// row and then the rows, as tab-separated text (what Numbers and Excel read as cells) and as
/// an HTML table (what Mail keeps as a table).
///
/// The cells are written for a spreadsheet, not for the eye: an amount is a plain number with
/// a dot — no thousands separator, no «−», no currency sign — so Numbers takes it as a number
/// and can sum the column, and a day is `YYYY-MM-DD`, which every spreadsheet reads as a
/// date. That is the opposite of how the screen writes them («1,234.56 ₽», «1 нояб.»), on
/// purpose.
public struct PasteTable: Hashable, Sendable {
  public enum Cell: Hashable, Sendable {
    case text(String)
    case amount(AmountE4)
    case day(DateOnly)
    case empty
  }

  public var columns: [String]
  public var rows: [[Cell]]

  public init(columns: [String], rows: [[Cell]]) {
    self.columns = columns
    self.rows = rows
  }

  /// The text of a cell as it goes into the file: an amount as `CSVValue` writes it.
  public static func text(of cell: Cell) -> String {
    switch cell {
    case .text(let text): text
    case .amount(let amount): CSVValue.string(amount: amount)
    case .day(let day): day.iso
    case .empty: ""
    }
  }

  /// Tab-separated, one line per row, the header first, a newline after the last row. A tab
  /// or a line break inside a description would start a new cell or a new row, so it becomes
  /// a space: there is no quoting that Numbers, Excel and Mail all read the same way.
  public var tabSeparated: String {
    var lines = [columns.map(Self.flatten).joined(separator: "\t")]
    for row in rows {
      lines.append(row.map { Self.flatten(Self.text(of: $0)) }.joined(separator: "\t"))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// A plain HTML table: a header row of `th`, a row of `td` for each row; amounts aligned to
  /// the right. Only `&`, `<`, `>` and `"` are escaped — it is text in cells, nothing more.
  public var html: String {
    var out = "<table>\n<tr>"
    for column in columns { out += "<th>\(Self.escape(column))</th>" }
    out += "</tr>\n"
    for row in rows {
      out += "<tr>"
      for cell in row {
        let text = Self.escape(Self.text(of: cell))
        if case .amount = cell {
          out += "<td align=\"right\">\(text)</td>"
        } else {
          out += "<td>\(text)</td>"
        }
      }
      out += "</tr>\n"
    }
    return out + "</table>\n"
  }

  static func flatten(_ text: String) -> String {
    var flat = ""
    flat.reserveCapacity(text.count)
    for character in text {
      flat.append(character == "\t" || character.isNewline ? " " : character)
    }
    return flat
  }

  static func escape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      default: out.append(character)
      }
    }
    return out
  }
}

/// The operations selected in a list as a `PasteTable`: day, kind, description, category,
/// account, amount, currency and the amount in rubles. The amount is always positive and the
/// kind says which way the money went — the sign is the kind, as everywhere in the app.
///
/// With amounts hidden («Скрыть суммы») the two amount columns are left out altogether: a
/// table dragged out of a window that hides its sums does not carry them away.
public enum OperationsPasteTable {
  /// The words of the header and of the kinds, in the interface language.
  public struct Labels: Sendable {
    public var day: String
    public var kind: String
    public var description: String
    public var category: String
    public var account: String
    public var amount: String
    public var currency: String
    public var rubles: String
    public var kinds: @Sendable (TransactionKind) -> String

    public init(
      day: String, kind: String, description: String, category: String, account: String,
      amount: String, currency: String, rubles: String,
      kinds: @escaping @Sendable (TransactionKind) -> String
    ) {
      self.day = day
      self.kind = kind
      self.description = description
      self.category = category
      self.account = account
      self.amount = amount
      self.currency = currency
      self.rubles = rubles
      self.kinds = kinds
    }
  }

  /// - Parameters:
  ///   - day: the calendar day of an operation, in its own time zone as the list shows it.
  ///   - categoryName: the name of a category; the categories of a split are listed once each,
  ///     in the order of its parts.
  ///   - accountName: the name of an account.
  public static func make(
    _ entries: [TransactionEntry], labels: Labels, hidesAmounts: Bool,
    day: (Transaction) -> DateOnly, categoryName: (UUID) -> String?,
    accountName: (UUID) -> String?
  ) -> PasteTable {
    var columns = [labels.day, labels.kind, labels.description, labels.category, labels.account]
    if !hidesAmounts { columns += [labels.amount, labels.currency, labels.rubles] }
    let rows = entries.map { entry -> [PasteTable.Cell] in
      let transaction = entry.transaction
      var names: [String] = []
      for part in entry.parts {
        guard let id = part.categoryId, let name = categoryName(id), !names.contains(name) else {
          continue
        }
        names.append(name)
      }
      var row: [PasteTable.Cell] = [
        .day(day(transaction)),
        .text(labels.kinds(transaction.kind)),
        transaction.note.map(PasteTable.Cell.text) ?? .empty,
        names.isEmpty ? .empty : .text(names.joined(separator: ", ")),
        transaction.paymentMethodId.flatMap(accountName).map(PasteTable.Cell.text) ?? .empty,
      ]
      if !hidesAmounts {
        row += [
          .amount(transaction.amountE4), .text(transaction.currency.code),
          .amount(transaction.amountRubE4),
        ]
      }
      return row
    }
    return PasteTable(columns: columns, rows: rows)
  }
}
