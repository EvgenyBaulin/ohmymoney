import AppCore
import Foundation

/// Two databases side by side: what a copy holds against what the database holds now. Worked
/// out from two snapshots and written nowhere. Seen from the copy: an operation the database
/// has and the copy lacks is *added*, one the copy has and the database lacks has *vanished*,
/// and one both have, by id, whose money, kind, day, account, note or categories differ is
/// *changed* — a mass edit of a hundred operations is one line, «изменено 100», that opens
/// to «было → стало».
struct BackupComparison: Equatable, Sendable {
  struct Change: Equatable, Sendable {
    var was: BackupSnapshot.Operation
    var now: BackupSnapshot.Operation
  }

  struct BalanceRow: Equatable, Sendable {
    var account: String
    var currency: String
    var copyE4: Int64?
    var currentE4: Int64?
    var isDifferent: Bool { copyE4 != currentE4 }
  }

  var operationsInCopy: Int
  var operationsNow: Int
  var balances: [BalanceRow]
  var categoriesInCopy: Int
  var categoriesNow: Int
  var categoriesAdded: [String]
  var categoriesVanished: [String]
  var added: [BackupSnapshot.Operation]
  var vanished: [BackupSnapshot.Operation]
  var changed: [Change]

  var isIdentical: Bool {
    added.isEmpty && vanished.isEmpty && changed.isEmpty && balances.allSatisfy { !$0.isDifferent }
      && categoriesAdded.isEmpty && categoriesVanished.isEmpty
  }

  init(copy: BackupSnapshot, current: BackupSnapshot) {
    operationsInCopy = copy.operations.count
    operationsNow = current.operations.count
    func newest(_ list: [BackupSnapshot.Operation]) -> [BackupSnapshot.Operation] {
      list.sorted { ($0.occurredAt, $0.id.uuidString) > ($1.occurredAt, $1.id.uuidString) }
    }
    added = newest(current.operations.values.filter { copy.operations[$0.id] == nil })
    vanished = newest(copy.operations.values.filter { current.operations[$0.id] == nil })
    let both = newest(
      current.operations.values.filter { operation in
        copy.operations[operation.id].map { $0 != operation } ?? false
      })
    changed = both.compactMap { now in
      copy.operations[now.id].map { Change(was: $0, now: now) }
    }

    struct Key: Hashable {
      var account: UUID
      var currency: String
    }
    var rows: [Key: BalanceRow] = [:]
    for balance in copy.balances {
      rows[Key(account: balance.accountId, currency: balance.currency)] = BalanceRow(
        account: balance.account, currency: balance.currency, copyE4: balance.amountE4,
        currentE4: nil)
    }
    for balance in current.balances {
      let key = Key(account: balance.accountId, currency: balance.currency)
      var row =
        rows[key]
        ?? BalanceRow(
          account: balance.account, currency: balance.currency, copyE4: nil, currentE4: nil)
      row.account = balance.account
      row.currentE4 = balance.amountE4
      rows[key] = row
    }
    balances = rows.values.sorted { ($0.account, $0.currency) < ($1.account, $1.currency) }

    categoriesInCopy = copy.categories.count
    categoriesNow = current.categories.count
    categoriesAdded = current.categories.filter { copy.categories[$0.key] == nil }.map(\.value)
      .sorted()
    categoriesVanished = copy.categories.filter { current.categories[$0.key] == nil }.map(\.value)
      .sorted()
  }

  /// The comparison of a copy file with the database now; nothing is written to either.
  static func of(
    copyAt url: URL, with current: Dataset, now: Date = Date()
  ) throws
    -> BackupComparison
  {
    BackupComparison(
      copy: try BackupSnapshot.of(fileAt: url, now: now),
      current: BackupSnapshot(dataset: current, now: now))
  }
}
