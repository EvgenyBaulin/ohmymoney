import CoreAnalytics
import CoreKit
import Foundation

/// The three things a bank lets the owner do free of a fee up to a sum in a month.
public enum BankLimitKind: String, Hashable, Sendable, CaseIterable {
  case cash
  /// Transfers to people through the fast payment system.
  case sbp
  /// Transfers of the owner to their own account in another bank through the same system: a
  /// limit apart from the one for people.
  case sbpOwn
  case interbank
}

/// One movement that counts against a free limit.
public struct BankLimitMovement: Hashable, Sendable, Identifiable {
  public enum Source: Hashable, Sendable {
    /// A transfer between the owner's accounts.
    case transfer
    /// An expense that carries one of the reserved tags (`BankLimitTags`).
    case operation
  }

  /// The id of the transfer or of the operation.
  public var id: UUID
  public var source: Source
  public var accountId: UUID
  public var kind: BankLimitKind
  public var day: DateOnly
  /// In the currency of the conditions.
  public var amountE4: AmountE4
  /// The owner took the movement out of the limit; it is listed and not summed.
  public var off: Bool

  public init(
    id: UUID, source: Source, accountId: UUID, kind: BankLimitKind, day: DateOnly,
    amountE4: AmountE4, off: Bool = false
  ) {
    self.id = id
    self.source = source
    self.accountId = accountId
    self.kind = kind
    self.day = day
    self.amountE4 = amountE4
    self.off = off
  }
}

/// How far one free limit of one account is used this month.
public struct BankLimitLine: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  public var kind: BankLimitKind
  public var currency: CurrencyCode
  public var limitE4: AmountE4
  public var usedE4: AmountE4
  /// What is still free; zero once used up.
  public var leftE4: AmountE4
  /// What went past the limit, where the bank takes its fee.
  public var overE4: AmountE4
  /// The movements of the month, newest first, those taken out of the limit included.
  public var movements: [BankLimitMovement]

  public var id: String { "\(accountId.uuidString):\(kind.rawValue)" }
  public var exceeded: Bool { overE4.raw > 0 }
  /// Used from `BankLimits.nearShareBp` basis points of the limit and not past it yet.
  public var isNear: Bool {
    !exceeded && limitE4.raw > 0
      && usedE4.raw * 10_000 >= limitE4.raw * Int64(BankLimits.nearShareBp)
  }
  /// Used up exactly: nothing is free any more.
  public var isUsedUp: Bool { leftE4.raw == 0 && limitE4.raw > 0 }

  /// For the limit of transfers to people: what the bank is likely to take for the transfers past
  /// it — 0.5 % of the part of each past the limit, at most 1 500 rubles a transfer. «≈»: the
  /// bank's conditions rule. Zero for any other limit and in a currency other than rubles.
  public var feeEstimateE4: AmountE4 {
    guard kind == .sbp, currency == .rub else { return .zero }
    var running = AmountE4.zero
    var fee = Decimal(0)
    for movement in movements.reversed() where !movement.off {
      let before = running
      running += movement.amountE4
      let over = max(.zero, running - limitE4) - max(.zero, before - limitE4)
      guard over.raw > 0 else { continue }
      fee += min(over.decimal * BankLimits.sbpFeeRate, BankLimits.sbpFeeCapE4.decimal)
    }
    return (try? AmountE4(decimal: fee)) ?? .zero
  }

  public init(
    accountId: UUID, kind: BankLimitKind, currency: CurrencyCode, limitE4: AmountE4,
    usedE4: AmountE4, movements: [BankLimitMovement]
  ) {
    self.accountId = accountId
    self.kind = kind
    self.currency = currency
    self.limitE4 = limitE4
    self.usedE4 = usedE4
    self.leftE4 = usedE4 >= limitE4 ? .zero : limitE4 - usedE4
    self.overE4 = usedE4 > limitE4 ? usedE4 - limitE4 : .zero
    self.movements = movements
  }
}

public enum BankLimits {
  /// The share of a limit (in basis points) from which «Стоит посмотреть» speaks of it.
  public static let nearShareBp = 8_000

  /// What the fast payment system lets the owner send to their own accounts in other banks free
  /// of a fee in a month: 30 million rubles, apart from the limit for people.
  public static let sbpOwnFreeE4 = AmountE4(whole: 30_000_000)

  /// The most a bank takes for one transfer to a person past the free limit, and its share of
  /// the part past it (0.5 %). The bank's own conditions rule; the figure is an estimate.
  public static let sbpFeeCapE4 = AmountE4(whole: 1_500)
  public static let sbpFeeRate = Decimal(5) / 1_000

  /// The bank an account belongs to: its `bankId`, or the account itself when it has none (an
  /// account without a bank reads as a bank of its own name).
  public static func bankKey(_ account: PaymentMethod) -> UUID { account.bankId ?? account.id }

  /// The movements of the month `month` that count against the limits of `data`'s accounts.
  ///
  /// * A transfer from an account to a cash account is cash taken out.
  /// * A transfer to an account of another bank is a transfer through the fast payment system
  ///   when it is in rubles and the account states that limit, else a transfer to another bank.
  /// * An expense that carries a reserved tag counts as that kind, by what moved on its account.
  ///
  /// A movement in another currency than the conditions state is left out. The movements in the
  /// owner's list of those taken out are marked `off`.
  public static func movements(
    ledger: Ledger, data: BankData, month: MonthKey
  ) -> [BankLimitMovement] {
    let dataset = ledger.dataset
    let accounts = Dictionary(
      dataset.paymentMethods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let own = Dictionary(
      data.conditions.filter { $0.cardId == nil }.map { ($0.accountId, $0) },
      uniquingKeysWith: { first, _ in first })
    var result: [BankLimitMovement] = []
    for transfer in dataset.transfers {
      guard let conditions = own[transfer.fromAccountId],
        transfer.fromCurrency == conditions.currency,
        ledger.calendar.day(of: transfer.occurredAt).monthKey == month,
        let from = accounts[transfer.fromAccountId], let to = accounts[transfer.toAccountId],
        transfer.fromAccountId != transfer.toAccountId
      else { continue }
      let kind: BankLimitKind
      if to.kind == .cash {
        guard conditions.freeCashE4 != nil else { continue }
        kind = .cash
      } else if bankKey(from) != bankKey(to) {
        if conditions.currency == .rub, conditions.freeSbpE4 != nil {
          kind = .sbpOwn
        } else if conditions.freeInterbankE4 != nil {
          kind = .interbank
        } else {
          continue
        }
      } else {
        continue
      }
      result.append(
        BankLimitMovement(
          id: transfer.id, source: .transfer, accountId: transfer.fromAccountId, kind: kind,
          day: ledger.calendar.day(of: transfer.occurredAt), amountE4: transfer.fromAmountE4,
          off: data.settings.limitOff.contains(transfer.id)))
    }
    let kindOfTag = Dictionary(
      dataset.tagBook.tags.compactMap { tag in
        BankLimitTags.kind(ofTag: tag.name).map { (tag.id, $0) }
      }, uniquingKeysWith: { first, _ in first })
    if !kindOfTag.isEmpty {
      for entry in dataset.entries {
        let transaction = entry.transaction
        guard !transaction.isDeleted, transaction.kind == .expense,
          let accountId = transaction.paymentMethodId, let conditions = own[accountId]
        else { continue }
        let day = ledger.calendar.day(
          of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
        guard day.monthKey == month else { continue }
        let moved = transaction.movedMoney
        guard moved.currency == conditions.currency else { continue }
        let kinds = entry.parts.flatMap { dataset.tagBook.tagIds(of: $0.id) }.compactMap {
          kindOfTag[$0]
        }
        guard var kind = kinds.first else { continue }
        // A person is paid through the fast payment system when the account states that limit.
        if kind == .sbp, conditions.freeSbpE4 == nil || conditions.currency != .rub {
          kind = .interbank
        }
        result.append(
          BankLimitMovement(
            id: transaction.id, source: .operation, accountId: accountId, kind: kind, day: day,
            amountE4: moved.amount, off: data.settings.limitOff.contains(transaction.id)))
      }
    }
    return result.sorted {
      ($0.day, $0.id.uuidString) > ($1.day, $1.id.uuidString)
    }
  }

  /// The limits an account states, each with what the month used. Accounts in the order of
  /// `data.conditions`; `kind`s in cash, SBP, interbank order.
  public static func progress(
    ledger: Ledger, data: BankData, month: MonthKey
  ) -> [BankLimitLine] {
    let movements = movements(ledger: ledger, data: data, month: month)
    var lines: [BankLimitLine] = []
    let live = Set(ledger.dataset.paymentMethods.filter { !$0.archived }.map(\.id))
    for conditions in data.conditions
    where conditions.cardId == nil && live.contains(conditions.accountId) {
      let limits: [(BankLimitKind, AmountE4?)] = [
        (.cash, conditions.freeCashE4),
        (.sbp, conditions.currency == .rub ? conditions.freeSbpE4 : nil),
        (.sbpOwn, conditions.currency == .rub && conditions.freeSbpE4 != nil ? sbpOwnFreeE4 : nil),
        (.interbank, conditions.freeInterbankE4),
      ]
      for (kind, limit) in limits {
        guard let limit else { continue }
        let mine = movements.filter { $0.accountId == conditions.accountId && $0.kind == kind }
        let used = AmountE4.sum(mine.filter { !$0.off }.map(\.amountE4))
        lines.append(
          BankLimitLine(
            accountId: conditions.accountId, kind: kind, currency: conditions.currency,
            limitE4: limit, usedE4: used, movements: mine))
      }
    }
    return lines
  }
}
