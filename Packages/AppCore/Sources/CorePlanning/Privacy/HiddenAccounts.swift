import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The accounts the owner hid. Hidden does not mean gone: the totals still hold their money
/// and say so (`partHidden`), a transfer to one is shown without its name, and only a copy
/// made «без скрытых» loses them.
///
/// Everything takes the set of ids as a parameter, so the rules do not depend on how the app
/// stores the flag.
public struct HiddenAccounts: Hashable, Sendable {
  public let ids: Set<UUID>

  public init(ids: some Sequence<UUID>) {
    self.ids = Set(ids)
  }

  public var isEmpty: Bool { ids.isEmpty }

  public func isHidden(_ accountId: UUID?) -> Bool {
    accountId.map(ids.contains) ?? false
  }

  // MARK: Totals

  /// A sum over accounts with the note that some of it lies in hidden ones.
  public struct Total: Hashable, Sendable {
    /// All the money, hidden accounts included: the total is never lowered by hiding.
    public var amountE4: AmountE4
    /// The part that lies in the visible accounts.
    public var visibleE4: AmountE4
    /// The part that lies in the hidden accounts.
    public var hiddenE4: AmountE4
    /// `true` when at least one hidden account is in the sum: the screen then says «часть
    /// скрыта» next to the figure and does not say how much.
    public var partHidden: Bool
  }

  /// Sums rows of (account, amount). A row of a hidden account counts into `amountE4` and
  /// `hiddenE4` and turns `partHidden` on, even when its amount is zero.
  public func total(_ rows: some Sequence<(accountId: UUID, amountE4: AmountE4)>) -> Total {
    var visible = AmountE4.zero
    var hidden = AmountE4.zero
    var any = false
    for row in rows {
      if ids.contains(row.accountId) {
        hidden += row.amountE4
        any = true
      } else {
        visible += row.amountE4
      }
    }
    return Total(amountE4: visible + hidden, visibleE4: visible, hiddenE4: hidden, partHidden: any)
  }

  // MARK: Transfers

  /// How a transfer reads on the screen of the visible account.
  public enum TransferCaption: String, Hashable, Sendable {
    /// The money went to a hidden account: «Перевод на скрытый счёт».
    case toHidden = "privacy.transfer.toHidden"
    /// The money came from a hidden account: «Перевод со скрытого счёта».
    case fromHidden = "privacy.transfer.fromHidden"
    /// Between two hidden accounts; shown only where hidden accounts are shown.
    case betweenHidden = "privacy.transfer.betweenHidden"

    /// The string-catalog key.
    public var key: String { rawValue }

    /// The Russian text, for tests and as the catalog's source; it never holds a name.
    public var russian: String {
      switch self {
      case .toHidden: "Перевод на скрытый счёт"
      case .fromHidden: "Перевод со скрытого счёта"
      case .betweenHidden: "Перевод между скрытыми счетами"
      }
    }

    public var english: String {
      switch self {
      case .toHidden: "Transfer to a hidden account"
      case .fromHidden: "Transfer from a hidden account"
      case .betweenHidden: "Transfer between hidden accounts"
      }
    }
  }

  /// The neutral caption for a transfer that touches a hidden account; `nil` when it touches
  /// none and shows as it always did.
  public func caption(for transfer: Transfer) -> TransferCaption? {
    switch (isHidden(transfer.fromAccountId), isHidden(transfer.toAccountId)) {
    case (false, false): nil
    case (false, true): .toHidden
    case (true, false): .fromHidden
    case (true, true): .betweenHidden
    }
  }

  // MARK: A copy without them

  public struct Exclusion: Sendable {
    public var dataset: Dataset
    /// Transfers that became one-sided operations of the visible account, by transfer id.
    public var oneSided: [UUID]
    /// One-sided operations of a foreign currency written without a rate (`rubPerUnit` had
    /// none): their ruble column holds the amount itself and the operation is marked
    /// provisional. Transfer ids.
    public var withoutRate: [UUID]
  }

  /// The data without the hidden accounts.
  ///
  /// * The accounts, their cards, cashback rules, bank conditions and operations are gone; so
  ///   are the banks left with no account because of that.
  /// * A transfer between two hidden accounts is gone. A transfer between a hidden and a
  ///   visible one becomes one operation of the visible account, with no name and no
  ///   comment: money out is an expense, money in an income, filed under `reconciliation`
  ///   (the twin categories of «Сверка», which the spending figures leave out, so the
  ///   balance of the visible account is right and no spending appears). Without a category
  ///   id the part is left uncategorised.
  /// * A scheduled payment from a hidden account is gone; the other records that name a
  ///   hidden account (an expected income, a goal, a journal line of a debt) keep working
  ///   with no account.
  /// * A reconciliation that counted a hidden account is gone with its counts — its totals
  ///   held hidden money; old totals-only ones stay.
  /// * Links to operations that are gone are cleared.
  public func exclude(
    from dataset: Dataset,
    reconciliation: (expense: UUID?, income: UUID?) = (nil, nil),
    rubPerUnit: [CurrencyCode: Decimal] = [:]
  ) -> Exclusion {
    guard !ids.isEmpty else { return Exclusion(dataset: dataset, oneSided: [], withoutRate: []) }
    var d = dataset

    // Operations of the hidden accounts (by account or by card) are gone.
    let hiddenCards = Set(dataset.cards.filter { ids.contains($0.accountId) }.map(\.id))
    func onHidden(_ transaction: Transaction) -> Bool {
      isHidden(transaction.paymentMethodId)
        || (transaction.cardId.map(hiddenCards.contains) ?? false)
    }
    let goneEntries = Set(dataset.entries.filter { onHidden($0.transaction) }.map(\.id))
    d.entries = dataset.entries.filter { !goneEntries.contains($0.id) }
    let keptParts = Set(d.entries.flatMap { $0.parts.map(\.id) })
    d.links = dataset.links.filter {
      !goneEntries.contains($0.reimbursementTxId) && keptParts.contains($0.partId)
    }
    d.tagBook.links = dataset.tagBook.links.filter { keptParts.contains($0.partId) }
    d.feedback = dataset.feedback.filter { $0.partId.map(keptParts.contains) ?? true }
    for index in d.entries.indices {
      for part in d.entries[index].parts.indices {
        if let origin = d.entries[index].parts[part].refundOfPartId, !keptParts.contains(origin) {
          d.entries[index].parts[part].refundOfPartId = nil
        }
      }
    }

    // Accounts, cards, rules, conditions, banks.
    d.paymentMethods = dataset.paymentMethods.filter { !ids.contains($0.id) }
    d.cards = dataset.cards.filter { !ids.contains($0.accountId) }
    d.cashbackRules = dataset.cashbackRules.filter { !ids.contains($0.accountId) }
    var bank = dataset.bankData
    bank.conditions = bank.conditions.filter { !ids.contains($0.accountId) }
    d.bankData = bank
    let hiddenBanks = Set(
      dataset.paymentMethods.filter { ids.contains($0.id) }.compactMap(\.bankId))
    let banksStillUsed = Set(d.paymentMethods.compactMap(\.bankId))
    d.banks = dataset.banks.filter {
      !hiddenBanks.contains($0.id) || banksStillUsed.contains($0.id)
    }

    // Transfers.
    var oneSided: [UUID] = []
    var withoutRate: [UUID] = []
    var transfers: [Transfer] = []
    for transfer in dataset.transfers {
      let fromHidden = isHidden(transfer.fromAccountId)
      let toHidden = isHidden(transfer.toAccountId)
      if !fromHidden && !toHidden {
        transfers.append(transfer)
      } else if fromHidden && toHidden {
        continue
      } else {
        let outgoing = toHidden
        let (currency, amount) =
          outgoing
          ? (transfer.fromCurrency, transfer.fromAmountE4)
          : (transfer.toCurrency, transfer.toAmountE4)
        let account = outgoing ? transfer.fromAccountId : transfer.toAccountId
        let (rubE4, rate, provisional) = ruble(amount, currency, rubPerUnit)
        if provisional && currency != .rub { withoutRate.append(transfer.id) }
        let id = transfer.id
        let transaction = Transaction(
          id: id, kind: outgoing ? .expense : .income, occurredAt: transfer.occurredAt,
          currency: currency, amountE4: amount, rate: rate, rateProvisional: provisional,
          amountRubE4: rubE4, paymentMethodId: account, createdAt: transfer.createdAt,
          updatedAt: transfer.updatedAt)
        let part = TransactionPart(
          id: Self.oneSidedPartId(for: id), transactionId: id,
          categoryId: outgoing ? reconciliation.expense : reconciliation.income,
          amountE4: amount, amountRubE4: rubE4)
        d.entries.append(TransactionEntry(transaction: transaction, parts: [part]))
        oneSided.append(transfer.id)
      }
    }
    d.transfers = transfers

    // Plans and the things that name an account.
    var planning = dataset.planning
    planning.scheduled = planning.scheduled.filter { !isHidden($0.paymentMethodId) }
    for index in planning.expected.indices where isHidden(planning.expected[index].paymentMethodId) {
      planning.expected[index].paymentMethodId = nil
    }
    for index in planning.debtEntries.indices
    where isHidden(planning.debtEntries[index].paymentMethodId) {
      planning.debtEntries[index].paymentMethodId = nil
    }
    planning.expectedLinks = planning.expectedLinks.filter { !goneEntries.contains($0.transactionId) }
    let touched = Set(
      dataset.planning.reconciledBalances.filter { ids.contains($0.accountId) }
        .map(\.reconciliationId))
    planning.reconciliations = planning.reconciliations.filter { !touched.contains($0.id) }
    planning.reconciledBalances = planning.reconciledBalances.filter {
      !touched.contains($0.reconciliationId)
    }
    d.planning = planning
    for index in d.goals.indices where isHidden(d.goals[index].accountId) {
      d.goals[index].accountId = nil
    }

    d.version &+= 1
    return Exclusion(dataset: d, oneSided: oneSided, withoutRate: withoutRate)
  }

  /// Deterministic id of the single part of a one-sided operation, so the same data gives the
  /// same copy: the transfer's id with its last byte changed.
  static func oneSidedPartId(for transferId: UUID) -> UUID {
    var bytes = transferId.uuid
    bytes.15 = bytes.15 ^ 0xA5
    return UUID(uuid: bytes)
  }

  private func ruble(
    _ amount: AmountE4, _ currency: CurrencyCode, _ rates: [CurrencyCode: Decimal]
  ) -> (AmountE4, Decimal?, Bool) {
    if currency == .rub { return (amount, nil, false) }
    if let rate = rates[currency], let converted = try? AmountE4(decimal: amount.decimal * rate),
      converted > .zero
    {
      return (converted, rate, false)
    }
    return (amount, nil, true)
  }
}
