import CoreKit
import Foundation

/// What a column of another application's table holds.
public enum MigrationRole: String, Sendable, Codable, Hashable, CaseIterable {
  case date
  /// One signed amount (or an unsigned one with a type column beside it).
  case amount
  /// Separate columns for money in and money out, both positive.
  case income
  case expense
  /// «Расход», «Доход», «Перевод»: what the line is.
  case kind
  case category
  case subcategory
  /// The account money left or arrived on.
  case account
  /// The account of the income column, where a file has one per side (Дзен-мани).
  case incomeAccount
  /// «Из» and «В» (CoinKeeper): an expense goes from an account to a category, an income from
  /// a category to an account, a transfer from an account to an account.
  case from
  case to
  case currency
  case incomeCurrency
  case description
  /// The shop or the person on the other side.
  case payee
  case comment
}

/// The application a table most likely came from. Only the name in the preview depends on it:
/// the columns are read the same way whatever it is.
public enum MigrationSourceKind: String, Sendable, Codable, Hashable, CaseIterable {
  case coinKeeper
  case zenmoney
  case moneyManager
  case spreadsheet
}

/// How the columns of a table are read: a role per column, and the order of day and month.
/// Remembered per layout of columns (`MigrationTable.signature`), so the next export of the same
/// application opens already mapped.
public struct MigrationMapping: Sendable, Codable, Hashable {
  /// Column index → role. A column without a role is not read.
  public var roles: [Int: MigrationRole]
  public var dateOrder: MigrationDates.Order
  public var source: MigrationSourceKind

  public init(
    roles: [Int: MigrationRole] = [:], dateOrder: MigrationDates.Order = .dayFirst,
    source: MigrationSourceKind = .spreadsheet
  ) {
    self.roles = roles
    self.dateOrder = dateOrder
    self.source = source
  }

  public func column(_ role: MigrationRole) -> Int? {
    roles.filter { $0.value == role }.map(\.key).min()
  }

  /// Gives `column` the role, taking it from any other column first: one column per role.
  public mutating func assign(_ role: MigrationRole?, to column: Int) {
    if let role {
      for (other, existing) in roles where existing == role { roles[other] = nil }
    }
    roles[column] = role
  }

  /// The mapping can be read: a date, and money in one of the two shapes.
  public var isComplete: Bool {
    column(.date) != nil
      && (column(.amount) != nil || column(.income) != nil || column(.expense) != nil)
  }
}

/// Guesses the mapping of a table from the names of its columns (Russian and English, as the
/// three applications and spreadsheets write them) and then from the contents of the columns no
/// name explained.
public enum MigrationColumnGuesser {
  public static func guess(_ table: MigrationTable) -> MigrationMapping {
    let names = table.header.map { NameKey.fold(StatementText.collapse($0)) }
    var mapping = MigrationMapping(source: source(of: names))
    // Exact names first, then names that contain a known word, so «Сумма в RUB» does not take
    // the place of «Сумма».
    for exact in [true, false] {
      for (index, name) in names.enumerated() where mapping.roles[index] == nil && !name.isEmpty {
        guard let role = role(for: name, exact: exact), mapping.column(role) == nil else {
          continue
        }
        mapping.roles[index] = role
      }
    }
    let sample = Array(table.rows.prefix(200))
    if mapping.column(.date) == nil,
      let column = sniff(
        table, sample, mapping, { MigrationDates.parse($0, order: .dayFirst) != nil })
    {
      mapping.roles[column] = .date
    }
    if mapping.column(.amount) == nil, mapping.column(.income) == nil,
      mapping.column(.expense) == nil,
      let column = sniff(table, sample, mapping, { MigrationAmounts.parse($0) != nil })
    {
      mapping.roles[column] = .amount
    }
    if let date = mapping.column(.date) {
      mapping.dateOrder = MigrationDates.order(for: sample.map { table.cell($0, date) })
    }
    return mapping
  }

  static func source(of names: [String]) -> MigrationSourceKind {
    let set = Set(names)
    if set.contains("outcomeaccountname") && set.contains("incomeaccountname") { return .zenmoney }
    if (set.contains("из") && set.contains("в") && set.contains("тип"))
      || (set.contains("from") && set.contains("to") && set.contains("type"))
    {
      return .coinKeeper
    }
    if (set.contains("period") || set.contains("период"))
      && (set.contains("income/expense") || set.contains("доход/расход")
        || set.contains("inc./exp.") || set.contains("доход/расх."))
    {
      return .moneyManager
    }
    return .spreadsheet
  }

  /// Folded names of each role. Order matters inside a list only for reading; a name belongs to
  /// one role.
  static let names: [(MigrationRole, [String])] = [
    (
      .date,
      [
        "дата", "date", "данные", "period", "период", "день", "дата операции", "дата и время",
        "date and time", "datetime", "время", "time", "transaction date", "дата транзакции",
      ]
    ),
    (
      .amount,
      [
        "сумма", "amount", "sum", "сумма операции", "value", "значение", "итого", "total",
        "сумма в валюте счета", "сумма в валюте операции",
      ]
    ),
    (.income, ["income", "доход", "приход", "поступление", "зачисление", "incoming", "inflow"]),
    (.expense, ["outcome", "expense", "расход", "списание", "outgoing", "outflow", "траты"]),
    (
      .kind,
      [
        "тип", "type", "income/expense", "доход/расход", "inc./exp.", "доход/расх.", "вид",
        "тип операции", "kind",
      ]
    ),
    (.category, ["категория", "category", "categoryname", "статья", "category name"]),
    (.subcategory, ["подкатегория", "subcategory", "sub category", "sub-category"]),
    (
      .account,
      [
        "счет", "account", "accounts", "счета", "кошелек", "wallet", "outcomeaccountname",
        "карта", "account name", "название счета",
      ]
    ),
    (.incomeAccount, ["incomeaccountname"]),
    (.from, ["из", "from", "откуда"]),
    (.to, ["в", "to", "куда"]),
    (
      .currency, ["валюта", "currency", "outcomecurrencyshorttitle", "currency code", "код валюты"]
    ),
    (.incomeCurrency, ["incomecurrencyshorttitle"]),
    (
      .description,
      [
        "описание", "note", "заметка", "название", "назначение", "memo", "details", "детали",
        "name",
      ]
    ),
    (.payee, ["получатель", "payee", "контрагент", "место", "merchant", "плательщик", "магазин"]),
    (.comment, ["комментарий", "comment", "примечание", "notes", "description", "comments"]),
  ]

  static func role(for name: String, exact: Bool) -> MigrationRole? {
    for (role, words) in names {
      if exact {
        if words.contains(name) { return role }
      } else {
        // A known word of three letters or more inside a longer name.
        if words.contains(where: { $0.count >= 4 && name.contains($0) }) { return role }
      }
    }
    return nil
  }

  /// The first column without a role whose filled sample cells all but rarely read as `test`.
  private static func sniff(
    _ table: MigrationTable, _ sample: [[String]], _ mapping: MigrationMapping,
    _ test: (String) -> Bool
  ) -> Int? {
    for column in table.header.indices where mapping.roles[column] == nil {
      let cells = sample.map { table.cell($0, column) }.filter { !$0.isEmpty }
      guard cells.count >= 1 else { continue }
      let passing = cells.filter(test).count
      if passing * 10 >= cells.count * 9 { return column }
    }
    return nil
  }
}
