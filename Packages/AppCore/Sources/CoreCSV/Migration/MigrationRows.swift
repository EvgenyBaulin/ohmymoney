import CoreKit
import Foundation

/// A category of the other application: its kind (an expense category and an income category of
/// one name are two), its name and, when it has one, the subcategory.
public struct MigrationCategoryKey: Sendable, Codable, Hashable, Comparable {
  public var kind: CategoryKind
  public var parent: String
  public var child: String?

  public init(kind: CategoryKind, parent: String, child: String? = nil) {
    self.kind = kind
    self.parent = parent
    self.child = child
  }

  /// Folded, so «Кафе» and «кафе » are one category; the key remembered in the settings.
  public var id: String {
    [kind.rawValue, NameKey.fold(parent), NameKey.fold(child ?? "")].joined(separator: "|")
  }

  /// As the preview writes it: «Еда / Кафе».
  public var title: String { child.map { parent + " / " + $0 } ?? parent }

  public static func < (lhs: MigrationCategoryKey, rhs: MigrationCategoryKey) -> Bool {
    (lhs.kind.rawValue, lhs.title.lowercased()) < (rhs.kind.rawValue, rhs.title.lowercased())
  }
}

/// One line of the other application, read: the operation in the shape the loading of
/// statements uses (`accountRef` is the other application's account name) and the category it
/// was filed under there.
public struct MigrationOperation: Sendable, Hashable {
  public var operation: ImportedOperation
  public var category: MigrationCategoryKey?

  public init(operation: ImportedOperation, category: MigrationCategoryKey?) {
    self.operation = operation
    self.category = category
  }
}

/// Everything a table gives under a mapping, before anything is written.
public struct MigrationParse: Sendable, Hashable {
  public var operations: [MigrationOperation] = []
  /// Transfers between the other application's own accounts. They move no money in or out and
  /// the books keep transfers between accounts of their own, so they are counted, not written.
  public var transfers = 0
  /// Lines with a zero amount (a placeholder, a balance line): nothing to write.
  public var zeroLines = 0
  public var unparsed: [StatementUnparsedLine] = []

  public init() {}

  /// The first and last day of the operations.
  public var period: (from: DateOnly, to: DateOnly)? {
    let days = operations.map(\.operation.moment.day)
    guard let first = days.min(), let last = days.max() else { return nil }
    return (first, last)
  }

  /// The other application's accounts, in the order they first appear.
  public var accountNames: [String] {
    var seen = Set<String>()
    return operations.map(\.operation.accountRef).filter { seen.insert(NameKey.fold($0)).inserted }
  }

  /// The other application's categories, sorted, each once.
  public var categories: [MigrationCategoryKey] {
    var seen = Set<String>()
    return operations.compactMap(\.category).filter { seen.insert($0.id).inserted }.sorted()
  }
}

/// Reads the rows of a table under a mapping.
public enum MigrationRowReader {
  enum LineKind {
    case expense
    case income
    case refund
    case transfer
  }

  /// `profileID` names the source in the import row (`migration.<source>`).
  public static func read(_ table: MigrationTable, mapping: MigrationMapping) -> MigrationParse {
    var result = MigrationParse()
    let profileID = "migration." + mapping.source.rawValue
    let column = { (role: MigrationRole) in mapping.column(role) }
    for (index, row) in table.rows.enumerated() {
      let cell = { (role: MigrationRole) in table.cell(row, column(role)) }
      guard row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
        continue
      }
      guard let moment = MigrationDates.parse(cell(.date), order: mapping.dateOrder) else {
        result.unparsed.append(
          StatementUnparsedLine(
            sourceIndex: index, reason: .badDate,
            amount: MigrationAmounts.parse(cell(.amount))?.amount))
        continue
      }
      let wording = kind(cell(.kind))
      // The money: one signed column, or a column each way.
      var amount: AmountE4?
      var cellCurrency: CurrencyCode?
      var lineKind: LineKind?
      var account = cell(.account)
      if column(.income) != nil || column(.expense) != nil {
        let income = MigrationAmounts.parse(cell(.income))
        let expense = MigrationAmounts.parse(cell(.expense))
        let incoming = income.map { !$0.amount.isZero } ?? false
        let outgoing = expense.map { !$0.amount.isZero } ?? false
        switch (incoming, outgoing) {
        case (true, true):
          // Both sides filled: money moved between two accounts of the other application.
          lineKind = .transfer
        case (true, false):
          amount = income?.amount.magnitude
          cellCurrency = income?.currency
          lineKind = .income
          let incomeAccount = cell(.incomeAccount)
          if !incomeAccount.isEmpty { account = incomeAccount }
          if let code = currencyCode(cell(.incomeCurrency)) { cellCurrency = code }
        case (false, true):
          amount = expense.map { AmountE4(raw: -$0.amount.magnitude.raw) }
          cellCurrency = expense?.currency
          lineKind = .expense
        case (false, false):
          if income != nil || expense != nil {
            result.zeroLines += 1
          } else {
            result.unparsed.append(
              StatementUnparsedLine(sourceIndex: index, reason: .amountColumnsConflict))
          }
          continue
        }
      } else {
        guard let reading = MigrationAmounts.parse(cell(.amount)) else {
          result.unparsed.append(StatementUnparsedLine(sourceIndex: index, reason: .badAmount))
          continue
        }
        cellCurrency = reading.currency
        let magnitude = reading.amount.magnitude
        switch wording {
        case .expense?:
          amount = AmountE4(raw: -magnitude.raw)
          lineKind = .expense
        case .income?:
          amount = magnitude
          lineKind = .income
        case .refund?:
          amount = magnitude
          lineKind = .refund
        case .transfer?:
          lineKind = .transfer
        case nil:
          amount = reading.amount
          lineKind = reading.amount.isNegative ? .expense : .income
        }
      }
      if wording == .transfer { lineKind = .transfer }
      if lineKind == .transfer {
        result.transfers += 1
        continue
      }
      guard var money = amount, let kindOfLine = lineKind else { continue }
      if money.isZero {
        result.zeroLines += 1
        continue
      }
      if kindOfLine == .refund, money.isNegative { money = money.magnitude }
      // «Из» and «В»: which of the two is the account depends on the direction.
      var categoryName = cell(.category)
      if column(.from) != nil || column(.to) != nil {
        if kindOfLine == .income {
          account = cell(.to)
          if categoryName.isEmpty { categoryName = cell(.from) }
        } else {
          account = cell(.from)
          if categoryName.isEmpty { categoryName = cell(.to) }
        }
      }
      let currency = currencyCode(cell(.currency)) ?? cellCurrency ?? .rub
      let category = categoryKey(
        categoryName, child: cell(.subcategory),
        kind: kindOfLine == .income ? .income : .expense)
      let payee = cell(.payee)
      let description = StatementText.collapse(cell(.description))
      let comment = StatementText.collapse(cell(.comment))
      // What the operation is called: the description, else the shop, else the comment, else
      // the category, so the line is never nameless.
      let name = [description, payee, comment, category?.title ?? ""].first { !$0.isEmpty } ?? ""
      let operation = ImportedOperation(
        profileID: profileID, sourceIndex: index, accountRef: StatementText.collapse(account),
        moment: moment, amount: money, currency: currency,
        kind: kindOfLine == .refund ? .purchaseRefund : .unknown, description: name,
        counterparty: StatementCounterparty(name: payee.isEmpty ? nil : payee),
        merchant: payee.isEmpty ? nil : payee, bankCategory: category?.title,
        comment: comment.isEmpty || comment == name ? nil : comment)
      result.operations.append(MigrationOperation(operation: operation, category: category))
    }
    return result
  }

  /// The words of a type column.
  static func kind(_ raw: String) -> LineKind? {
    let word = NameKey.fold(raw).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    guard !word.isEmpty else { return nil }
    if word.hasPrefix("transfer") || word.hasPrefix("перевод") || word.hasPrefix("перемещ") {
      return .transfer
    }
    if word.hasPrefix("возврат") || word.hasPrefix("refund") { return .refund }
    if word.hasPrefix("расход") || word.hasPrefix("exp") || word.hasPrefix("outcome")
      || word.hasPrefix("трат") || word.hasPrefix("списан") || word == "-"
    {
      return .expense
    }
    if word.hasPrefix("доход") || word.hasPrefix("inc") || word.hasPrefix("поступ")
      || word.hasPrefix("зачисл") || word.hasPrefix("приход") || word == "+"
    {
      return .income
    }
    return nil
  }

  static func currencyCode(_ raw: String) -> CurrencyCode? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    if let reading = MigrationAmounts.parse("0 " + text), let currency = reading.currency {
      return currency
    }
    return MigrationAmounts.word(text)
  }

  /// «Еда / Кафе» in one cell is a category and its subcategory, as Дзен-мани writes them.
  static func categoryKey(
    _ raw: String, child rawChild: String, kind: CategoryKind
  )
    -> MigrationCategoryKey?
  {
    var parent = StatementText.collapse(raw)
    var child = StatementText.collapse(rawChild)
    if child.isEmpty, let range = parent.range(of: " / ") {
      child = StatementText.collapse(String(parent[range.upperBound...]))
      parent = StatementText.collapse(String(parent[..<range.lowerBound]))
    }
    guard !parent.isEmpty else { return nil }
    return MigrationCategoryKey(kind: kind, parent: parent, child: child.isEmpty ? nil : child)
  }
}
