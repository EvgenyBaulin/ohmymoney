import AppCore
import AppDatabase
import Foundation

/// What a database holds that a copy is described and compared by: its live operations, the
/// money on each account and the names of the categories — a plain value built from the
/// loaded data (`Dataset`), so the description and the comparison are both worked out in one
/// place, and neither writes anything.
struct BackupSnapshot: Equatable, Sendable {
  struct Operation: Equatable, Sendable {
    var id: UUID
    var occurredAt: Date
    var kind: String
    var amountE4: Int64
    var currency: String
    var note: String?
    var accountId: UUID?
    /// The categories of its parts, in the order of the parts.
    var categoryIds: [UUID?]
    var categoryNames: [String]
  }

  struct Balance: Equatable, Sendable {
    var accountId: UUID
    var account: String
    var currency: String
    var amountE4: Int64
  }

  var operations: [UUID: Operation]
  var balances: [Balance]
  var categories: [UUID: String]

  /// The newest operation by the moment it happened.
  var lastOperation: Operation? {
    operations.values.max {
      ($0.occurredAt, $0.id.uuidString) < ($1.occurredAt, $1.id.uuidString)
    }
  }

  init(operations: [UUID: Operation], balances: [Balance], categories: [UUID: String]) {
    self.operations = operations
    self.balances = balances
    self.categories = categories
  }

  init(dataset: Dataset, now: Date = Date(), calendar: CalendarContext = .system) {
    let names = Dictionary(
      dataset.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    var operations: [UUID: Operation] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      let transaction = entry.transaction
      let ids = entry.parts.map(\.categoryId)
      operations[transaction.id] = Operation(
        id: transaction.id, occurredAt: transaction.occurredAt, kind: transaction.kind.rawValue,
        amountE4: transaction.amountE4.raw, currency: transaction.currency.code,
        note: transaction.note, accountId: transaction.paymentMethodId, categoryIds: ids,
        categoryNames: ids.map { $0.flatMap { names[$0] } ?? "" })
    }
    let accounts = Dictionary(
      dataset.paymentMethods.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let book = AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: now, calendar: calendar)
    var balances: [Balance] = []
    for key in book.keys {
      guard let amount = book[key]?.amountE4 else { continue }
      balances.append(
        Balance(
          accountId: key.accountId, account: accounts[key.accountId] ?? "",
          currency: key.currency.code, amountE4: amount.raw))
    }
    balances.sort { ($0.account, $0.currency) < ($1.account, $1.currency) }
    self.init(operations: operations, balances: balances, categories: names)
  }

  /// The snapshot of a database file nobody has open, read without writing into it. A file of an
  /// older schema — a copy made before an update, an archive of an earlier version — is not read
  /// as it is: it is brought up to the schema of this build in a scratch file and read there
  /// (`DatabaseStack.dataset(ofOlderFileAt:)`); the file itself is left as it is.
  static func of(
    fileAt url: URL, now: Date = Date(), schema: any SchemaSource = BundleSchemaSource()
  ) throws -> BackupSnapshot {
    let pending = (try? DatabaseStack.pendingMigrations(fileAt: url, schema: schema)) ?? []
    let dataset =
      pending.isEmpty
      ? try DatabaseStack.dataset(fileAt: url)
      : try DatabaseStack.dataset(ofOlderFileAt: url, schema: schema)
    return BackupSnapshot(dataset: dataset, now: now)
  }
}
