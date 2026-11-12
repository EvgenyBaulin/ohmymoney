import CoreKit
import Foundation

public struct FinancialNamesakeRecord: Hashable, Sendable {
  public var record: NamesakeRecord
  public var aliases: [String]
  public var accountId: UUID?
  public var restoresAccount = false
}

extension Namesakes {
  public static func financialRecords(
    accounts: [PaymentMethod], cards: [PaymentCard], banks: [Bank],
    entries: [TransactionEntry], transfers: [Transfer] = [], planning: PlanningBook = .empty,
    calendar: CalendarContext
  ) -> [FinancialNamesakeRecord] {
    var accountNames = Self.accounts(accounts, entries: entries, calendar: calendar)
    var extra: [UUID: [MonthKey]] = [:]
    for transfer in transfers {
      extra[transfer.fromAccountId, default: []].append(
        calendar.day(of: transfer.occurredAt).monthKey)
      extra[transfer.toAccountId, default: []].append(
        calendar.day(of: transfer.arrivedAt ?? transfer.occurredAt).monthKey)
    }
    let reconciliations = Dictionary(
      planning.reconciliations.map { ($0.id, $0.date.monthKey) },
      uniquingKeysWith: { first, _ in first })
    for balance in planning.reconciledBalances {
      if let month = reconciliations[balance.reconciliationId] {
        extra[balance.accountId, default: []].append(month)
      }
    }
    for entry in planning.debtEntries {
      if let account = entry.paymentMethodId, let at = entry.occurredAt {
        extra[account, default: []].append(calendar.day(of: at).monthKey)
      }
    }
    for index in accountNames.indices {
      let previous = accountNames[index].period.map { [$0.first, $0.last] } ?? []
      accountNames[index].period = NameHistoryPeriod(
        months: previous + (extra[accountNames[index].id] ?? []))
    }
    let cardNames = Self.cards(cards, entries: entries, calendar: calendar)
    let bankNames = banks.map { bank in
      let ids = Set(accounts.filter { $0.bankId == bank.id }.map(\.id))
      let history = accountNames.filter { ids.contains($0.id) }.flatMap {
        $0.period.map { [$0.first, $0.last] } ?? []
      }
      return NamesakeRecord(
        kind: .bank, id: bank.id, name: bank.name, archived: bank.archived,
        history: history)
    }
    let archived = Set(accounts.filter(\.archived).map(\.id))
    let accountRecords = zip(accountNames, accounts).map {
      FinancialNamesakeRecord(record: $0.0, aliases: $0.1.aliases, accountId: nil)
    }
    let cardRecords = zip(cardNames, cards).map {
      var record = $0.0
      record.archived = record.archived || archived.contains($0.1.accountId)
      return FinancialNamesakeRecord(
        record: record, aliases: $0.1.aliases,
        accountId: $0.1.accountId, restoresAccount: archived.contains($0.1.accountId))
    }
    let bankRecords = bankNames.map {
      FinancialNamesakeRecord(record: $0, aliases: [], accountId: nil)
    }
    return accountRecords + cardRecords + bankRecords
  }

  /// Only archived financial names produce nonblocking advice. Live clashes are validation
  /// errors. Accounts and cards share a namespace, with the card's own account excepted.
  public static func financialProposals(
    for own: NamesakeRecord, aliases: [String] = [], accountId: UUID? = nil,
    among records: [FinancialNamesakeRecord], hidden: String = ""
  ) -> [NamesakeProposal] {
    let hidden = Set(hidden.split(whereSeparator: \.isNewline).map(String.init))
    let names = ([own.name] + aliases).filter { !NameKey.fold($0).isEmpty }
    return records.compactMap { candidate in
      let other = candidate.record
      guard other.archived, !(own.kind == other.kind && own.id == other.id) else { return nil }
      if own.kind == .bank || other.kind == .bank {
        guard own.kind == .bank && other.kind == .bank else { return nil }
      } else {
        guard [.account, .card].contains(own.kind), [.account, .card].contains(other.kind)
        else { return nil }
        if own.kind == .account, candidate.accountId == own.id { return nil }
        if other.kind == .account, other.id == accountId { return nil }
      }
      let key = pairKey(own, other)
      guard !hidden.contains(key) else { return nil }
      for spelling in names {
        let folded = NameKey.fold(spelling)
        if let matched = ([other.name] + candidate.aliases).first(where: {
          NameKey.fold($0) == folded
        }) {
          return NamesakeProposal(
            existing: other, id: key,
            existingSpelling: matched == other.name ? nil : matched,
            newSpelling: spelling == own.name ? nil : spelling,
            restoresAccount: candidate.restoresAccount)
        }
      }
      return nil
    }
  }
}
