import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The cards of the accounts and the cashback they earn, over a set with accounts:
  ///
  /// * every live account of the kind «card» has a card named like it, with the id the update
  ///   gives such a card (`CardsMigration`), and the main account a second one, «Virtual»;
  /// * the main account has the bank's rules, which both its cards follow: «Food out» 5 % and
  ///   everything else 1 % always, «Groceries» 3 % in the month of the last day and «Transport»
  ///   5 % in the month before — rules of both kinds, so the account screen and Analytics show
  ///   cashback expected next to cashback received;
  /// * about a third of the main account's own purchases name one of its cards, the own one four
  ///   times in five; the latest one in rubles on the own card has the cashback the bank showed
  ///   typed over the one its rules give;
  /// * the monthly cashback of the history names the card of the account it came to.
  ///
  /// Nothing here moves money or changes what was drawn: a card says what paid, the money stays
  /// on the account, and cashback expected is never income.
  func withCards(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: 0x0012_CA2D_0000_0012, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    var set = self
    set.cards =
      CardsMigration.plan(
        accounts: paymentMethods.map { account in
          MigratingCardAccount(
            id: account.id, name: account.name, kind: account.kind, archived: account.archived)
        }
      ).cards
    guard let main = mainAccount,
      let own = set.cards.first(where: { $0.accountId == main.id })
    else { return set }
    var virtualStream = layer.stream("virtual card")
    let virtual = PaymentCard(
      id: virtualStream.nextUUID(), accountId: main.id, name: layer.word("Virtual", "Виртуальная"))
    set.cards.append(virtual)
    set.cashbackRules = rules(on: main, layer: layer)

    let cardOfAccount = Dictionary(
      set.cards.filter { $0.id != virtual.id }.map { ($0.accountId, $0.id) },
      uniquingKeysWith: { first, _ in first })
    for index in set.entries.indices {
      let entry = set.entries[index]
      let transaction = entry.transaction
      if transaction.kind == .income, !entry.parts.isEmpty,
        entry.parts.allSatisfy({ $0.categoryId == cashbackCategoryId }),
        let account = transaction.paymentMethodId, let card = cardOfAccount[account]
      {
        set.entries[index].transaction.cardId = card
        continue
      }
      guard Self.namesACard(entry, account: main.id) else { continue }
      var rng = SeededRandom(
        seed: layer.seed ^ SampleAccountsWriter.fnv1a("card of \(entry.id.uuidString)"))
      guard rng.chance(1, outOf: 3) else { continue }
      set.entries[index].transaction.cardId = rng.chance(1, outOf: 5) ? virtual.id : own.id
    }
    set.typeCashbackOver(on: own)
    return set
  }

  /// A purchase of my own on `account` that a card could have paid: not a line the app wrote
  /// for a payment, a fee or a count, not on credit, not money put into a goal.
  static func namesACard(_ entry: TransactionEntry, account: UUID) -> Bool {
    let transaction = entry.transaction
    return transaction.kind == .expense && transaction.paymentMethodId == account
      && transaction.externalId == nil && transaction.creditDebtId == nil
      && !entry.parts.isEmpty && !entry.parts.contains { $0.goalId != nil }
  }

  /// The bank's rules on the main account: two that always hold, one of this month and one of
  /// the month before.
  private func rules(on account: PaymentMethod, layer: SampleLayer) -> [CashbackRule] {
    let month = lastDay.monthKey
    let specs: [(key: String, english: String?, month: MonthKey?, percent: Int64)] = [
      ("always food out", "Food out", nil, 5),
      ("always everything else", nil, nil, 1),
      ("month groceries", "Groceries", month, 3),
      ("month transport", "Transport", month.previous, 5),
    ]
    return specs.compactMap { spec in
      var categoryId: UUID?
      if let english = spec.english {
        guard let found = starter(english) else { return nil }
        categoryId = found.category.id
      }
      var rng = layer.stream("cashback rule \(spec.key)", on: spec.month?.firstDay)
      guard let percent = CashbackPercent(e4: spec.percent * CashbackPercent.unitsPerPercent)
      else { return nil }
      return CashbackRule(
        id: rng.nextUUID(), accountId: account.id, categoryId: categoryId, month: spec.month,
        percent: percent)
    }
  }

  /// The cashback the bank showed for the latest purchase in rubles on `card`, typed over what
  /// the rules give: 5 % of it in whole rubles. When no purchase names the card, the latest one
  /// in rubles of its account is taken and named.
  private mutating func typeCashbackOver(on card: PaymentCard) {
    func candidate(_ entry: TransactionEntry) -> Bool {
      Self.namesACard(entry, account: card.accountId) && !entry.transaction.isDeleted
        && entry.transaction.currency == .rub && entry.transaction.accountCurrency == nil
        && entry.transaction.amountE4.raw >= AmountE4(whole: 20).raw
    }
    let index =
      entries.lastIndex { candidate($0) && $0.transaction.cardId == card.id }
      ?? entries.lastIndex(where: candidate)
    guard let index else { return }
    let amount = entries[index].transaction.amountE4
    let whole = max(1, amount.raw / AmountE4.unitsPerWhole / 20)
    entries[index].transaction.cardId = card.id
    entries[index].transaction.cashback = Money(amount: AmountE4(whole: whole), currency: .rub)
  }
}
