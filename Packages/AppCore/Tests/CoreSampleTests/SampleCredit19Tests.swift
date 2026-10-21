import CoreAccounting
import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The credit the sample adds after the capital: its own sequence of draws, pinned; every layer
/// under it left as it was, but for the marks of reviewed debts and the main card; and the credit
/// card, the instalment plan, the early repayment and the pledge the way the app keeps them.
@Suite("The credit of the sample")
struct SampleCredit19Tests {
  static let seed = SampleFeatureLayersTests.seed

  static func accounts(language: String) -> SampleDataSet {
    SampleFeatureLayersTests.history(language: language)
      .withAccounts(seed: seed, calendar: .moscow, language: language)
  }

  /// The layers through the capital: what the credit is written on.
  static func earlier(language: String = "en") -> SampleDataSet {
    accounts(language: language).withLayersThroughTheCapital(
      seed: seed, calendar: .moscow, language: language, now: nil, demo: false)
  }

  /// The layers through the credit, without the allocation after it.
  static func layered(language: String = "en", now: Date? = nil) -> SampleDataSet {
    accounts(language: language)
      .withLayersThroughTheCapital(
        seed: seed, calendar: .moscow, language: language, now: now, demo: false
      )
      .withCreditLayer(seed: seed, calendar: .moscow, language: language, now: now)
  }

  /// What a layer's draws decide: every row it adds — accounts and their terms, banks, cards,
  /// operations, transfers, counts, debts with their journals and costs, rules, currencies and
  /// rates —, the main cards, and the money of every account at the end.
  static func digest(_ set: SampleDataSet, over earlier: SampleDataSet) -> String {
    func id(_ value: UUID?) -> String { value?.uuidString.lowercased() ?? "-" }
    func seconds(_ moment: Date) -> String { String(Int(moment.timeIntervalSince1970)) }
    var text = ""
    let accounts = Set(earlier.paymentMethods.map(\.id))
    for account in set.paymentMethods {
      if !accounts.contains(account.id) {
        text += "account \(id(account.id))|\(account.name)|\(id(account.bankId))"
        text += "|\(account.credit.map { "\($0.limitE4.raw)|\($0.grace)" } ?? "-")\n"
      }
      let before = earlier.paymentMethods.first { $0.id == account.id }?.mainCardId
      if let card = account.mainCardId, card != before {
        text += "main \(id(account.id))|\(id(card))\n"
      }
    }
    for bank in set.banks where !earlier.banks.contains(bank) {
      text += "bank \(id(bank.id))|\(bank.name)\n"
    }
    for card in set.cards where !earlier.cards.contains(card) {
      text += "card \(id(card.id))|\(id(card.accountId))\n"
    }
    let entries = Set(earlier.entries.map(\.id))
    for entry in set.entries where !entries.contains(entry.id) {
      let transaction = entry.transaction
      text +=
        "op \(id(transaction.id))|\(transaction.kind.rawValue)|\(seconds(transaction.occurredAt))"
      text += "|\(seconds(transaction.createdAt))|\(transaction.amountE4.raw)"
      text += "|\(id(transaction.paymentMethodId))|\(id(transaction.debtId))"
      text += "|\(id(transaction.creditDebtId))|\(transaction.externalId ?? "-")\n"
      for part in entry.parts {
        text += "  \(id(part.id))|\(id(part.categoryId))|\(part.amountE4.raw)|\(id(part.goalId))\n"
      }
    }
    let transfers = Set(earlier.transfers.map(\.id))
    for transfer in set.transfers where !transfers.contains(transfer.id) {
      text += "transfer \(id(transfer.id))|\(seconds(transfer.occurredAt))"
      text +=
        "|\(id(transfer.fromAccountId))|\(id(transfer.toAccountId))|\(transfer.fromAmountE4.raw)"
      text += "|\(transfer.externalId ?? "-")\n"
    }
    for count in set.reconciliations where !earlier.reconciliations.contains(count) {
      text += "count \(id(count.id))|\(count.date.iso)\n"
    }
    for balance in set.reconciledBalances where !earlier.reconciledBalances.contains(balance) {
      text += "balance \(id(balance.id))|\(id(balance.accountId))|\(balance.actualE4.raw)\n"
    }
    let debts = Set(earlier.debts.map(\.id))
    for debt in set.debts where !debts.contains(debt.id) {
      text += "debt \(id(debt.id))|\(debt.direction.rawValue)|\(debt.parts ?? 0)"
      text += "|\(debt.steps.map { "\($0.everyDays)|\($0.firstDue.iso)" } ?? "-")"
      text += "|\(debt.pledge)|\(debt.returnBy?.iso ?? "-")\n"
    }
    let lines = Set(earlier.debtEntries.map(\.id))
    for line in set.debtEntries where !lines.contains(line.id) {
      text += "line \(id(line.id))|\(id(line.debtId))|\(line.kind.rawValue)|\(line.amountE4.raw)"
      text +=
        "|\(line.date?.iso ?? "-")|\(id(line.transactionId))|\(line.prepay?.rawValue ?? "-")\n"
    }
    for cost in set.debtCosts where !earlier.debtCosts.contains(cost) {
      text += "cost \(id(cost.id))|\(id(cost.debtId))|\(cost.amountE4.raw)|\(cost.day.iso)\n"
    }
    for category in set.categories
    where !earlier.categories.contains(where: { $0.id == category.id }) {
      text += "category \(id(category.id))|\(id(category.parentId))|\(category.name)\n"
    }
    for goal in set.goals where !earlier.goals.contains(goal) {
      text += "goal \(id(goal.id))|\(goal.targetE4.raw)\n"
    }
    for rule in set.allocationRules where !earlier.allocationRules.contains(rule) {
      text += "rule \(id(rule.id))|\(rule.target.storedKind)|\(rule.sort)\n"
    }
    for currency in set.customCurrencies where !earlier.customCurrencies.contains(currency) {
      text += "currency \(currency.code.code)\n"
    }
    for rate in set.rates where !earlier.rates.contains(rate) {
      text += "rate \(rate.date.iso)|\(rate.rubPerUnit)\n"
    }
    for (key, value) in set.settings.sorted(by: { $0.key < $1.key })
    where earlier.settings[key] != value {
      text += "setting \(key)\n"
    }
    for (key, amount) in set.accountExpectations.sorted(by: { $0.key < $1.key })
    where earlier.accountExpectations[key] != amount {
      text += "end \(id(key.accountId))|\(key.currency.code)|\(amount.raw)\n"
    }
    return SHA256.hexDigest(Data(text.utf8))
  }

  @Test func theLayerDrawsTheSameSequence() {
    let set = Self.layered()
    #expect(
      Self.digest(set, over: Self.earlier())
        == "5da3b432a8931485ee25cf88792403ea9b78229eb4c15295826d51fdda6faed7",
      """
      The credit layer drew a different sequence. If this was meant — a new row, another
      amount — put the digest printed by the failure here and say why in the commit. If it was
      not, something asked the layer's random source for one more value.
      """)
  }

  /// Everything under the layer is kept, but for the marks of reviewed debts and the main card
  /// of the main account; the money the layers under it expect at the end moves only by what
  /// this one adds.
  @Test func theLayersUnderItAreKept() {
    let earlier = Self.earlier()
    let set = Self.layered()
    let entries = Set(set.entries.map(\.id))
    #expect(earlier.entries.allSatisfy { entries.contains($0.id) })
    let old = Set(earlier.entries.map(\.id))
    #expect(set.entries.filter { old.contains($0.id) } == earlier.entries)
    #expect(Array(set.transfers.filter { earlier.transfers.contains($0) }) == earlier.transfers)
    #expect(
      Array(set.reconciliations.prefix(earlier.reconciliations.count)) == earlier.reconciliations)
    #expect(
      Array(set.reconciledBalances.prefix(earlier.reconciledBalances.count))
        == earlier.reconciledBalances)
    // The limits of the planning are sized by the spending of the months, which the layer
    // adds to; everything else of the planning is as it was.
    #expect(set.planning.scheduled == earlier.planning.scheduled)
    #expect(set.planning.prices == earlier.planning.prices)
    #expect(set.planning.expected == earlier.planning.expected)
    #expect(set.planning.expectedLinks == earlier.planning.expectedLinks)
    #expect(set.planning.budgets.map(\.id) == earlier.planning.budgets.map(\.id))
    #expect(set.assets == earlier.assets && set.assetValuations == earlier.assetValuations)
    #expect(Array(set.categories.prefix(earlier.categories.count)) == earlier.categories)
    var unmarked = Array(set.debts.prefix(earlier.debts.count))
    for index in unmarked.indices {
      unmarked[index].termsReviewed = earlier.debts[index].termsReviewed
    }
    #expect(unmarked == earlier.debts)
    #expect(Array(set.debtEntries.prefix(earlier.debtEntries.count)) == earlier.debtEntries)
    var withoutMainCard = Array(set.paymentMethods.prefix(earlier.paymentMethods.count))
    for index in withoutMainCard.indices { withoutMainCard[index].mainCardId = nil }
    #expect(withoutMainCard == earlier.paymentMethods)
    #expect(Array(set.cards.prefix(earlier.cards.count)) == earlier.cards)
  }

  /// The sample is written by this version: no debt in it is an old one to ask about.
  @Test func everyDebtIsReviewed() {
    #expect(SampleFeatureLayersTests.layered().debts.allSatisfy { $0.termsReviewed })
    #expect(Self.earlier().debts.contains { !$0.termsReviewed }, "the marks are this layer's")
  }

  /// The main account has two cards; its own card is its main card.
  @Test func theMainAccountHasItsMainCard() throws {
    let set = Self.layered()
    let main = try #require(set.mainAccount)
    #expect(set.cards.filter { $0.accountId == main.id && !$0.archived }.count >= 2)
    #expect(main.mainCardId == CardsMigration.cardId(forAccount: main.id))
    #expect(set.paymentMethods.filter { $0.mainCardId != nil }.count == 1)
  }

  /// «Кредитка Т-Банка»: an account of the bank «Т-Банк» with the bank's terms, its first count at
  /// zero before its latest statement, the purchases of that statement paid in full from the
  /// main account before it is due, a purchase after it, and cash taken with the bank's fee.
  @Test func theCreditCardIsKeptAsTheBankKeepsIt() throws {
    let set = Self.layered(language: "ru")
    let card = try #require(set.paymentMethods.first { $0.isCreditCard })
    #expect(card.name == "Кредитка Т-Банка" && card.kind == .card && card.currency == .rub)
    let bank = try #require(set.banks.first { $0.id == card.bankId })
    #expect(bank.name == "Т-Банк")
    #expect(card.credit == SampleDataSet.tBankTerms)
    let terms = try #require(card.credit)
    #expect(terms.limitE4 == AmountE4(whole: 150_000))
    #expect(terms.grace == .statement(day: 5, payDays: 25))
    #expect(
      terms.purchaseRate == Decimal(string: "29.9") && terms.cashRate == Decimal(string: "49.9"))
    #expect(terms.minPercent == 8 && terms.minFloorE4 == AmountE4(whole: 600))
    #expect(
      terms.cashFeePercent == Decimal(string: "2.9") && terms.cashFeeFixedE4 == AmountE4(whole: 290)
    )
    #expect(terms.cashWithoutGrace)
    #expect(set.cards.contains { $0.accountId == card.id && $0.name == card.name })

    let statement = SampleDataSet.latestStatement(before: set.lastDay)
    #expect(statement.day == 5 && statement < set.lastDay)
    let opening = try #require(
      set.reconciledBalances.first { $0.accountId == card.id && $0.isStartingPoint })
    #expect(opening.actualE4.isZero)
    let count = try #require(set.reconciliations.first { $0.id == opening.reconciliationId })
    #expect(count.date < statement && count.kind == .opening)

    let purchases = set.entries.filter {
      $0.transaction.paymentMethodId == card.id && $0.transaction.kind == .expense
        && $0.transaction.externalId == nil
    }
    let inStatement = purchases.filter { day(of: $0) <= statement }
    #expect(inStatement.count == 3)
    #expect(purchases.count == 4)
    #expect(inStatement.allSatisfy { day(of: $0) > count.date })
    let owed = AmountE4.sum(inStatement.map(\.transaction.amountE4))
    let paid = try #require(set.transfers.first { $0.toAccountId == card.id })
    let paidOn = CalendarContext.moscow.day(of: paid.occurredAt)
    #expect(paid.fromAccountId == set.mainAccount?.id && paid.fromAmountE4 == owed)
    #expect(paidOn > statement && paidOn <= CalendarContext.moscow.adding(days: 25, to: statement))
    #expect(paidOn > CalendarContext.moscow.adding(days: -14, to: set.lastDay), "after the count")

    let cash = try #require(set.transfers.first { $0.fromAccountId == card.id })
    #expect(set.paymentMethods.first { $0.id == cash.toAccountId }?.kind == .cash)
    #expect(cash.fromAmountE4 == SampleDataSet.cashTaken)
    #expect(CalendarContext.moscow.day(of: cash.occurredAt) > statement)
    let fee = try #require(
      set.entries.first { $0.transaction.externalId == TransferRules.feeKey(of: cash.id) })
    // 2.9 % of 5,000 is 145, and 290 on top.
    #expect(fee.transaction.amountE4 == AmountE4(whole: 435))
    #expect(fee.transaction.paymentMethodId == card.id)
    #expect(fee.transaction.occurredAt == cash.occurredAt)
    // Paid off whole that evening from the main account: the card ends at zero.
    let payOff = try #require(
      set.transfers.last { $0.toAccountId == card.id && $0.id != paid.id })
    #expect(payOff.fromAccountId == set.mainAccount?.id && payOff.occurredAt >= cash.occurredAt)
    #expect(
      payOff.fromAmountE4
        == AmountE4.sum(purchases.map(\.transaction.amountE4)) - owed + SampleDataSet.cashTaken
        + fee.transaction.amountE4)
    #expect(set.accountExpectations[BalanceKey(accountId: card.id, currency: .rub)] == .zero)
  }

  /// «Пылесос»: 12,000 in four parts every two weeks from the day of the purchase, the first paid
  /// that day; the next due is after the last day, so nothing is overdue.
  @Test func theInstalmentPlanHasItsFirstPartPaid() throws {
    let set = Self.layered(language: "ru")
    let plan = try #require(set.debts.first { $0.isInstalmentPlan })
    #expect(plan.name == "Пылесос" && plan.parts == 4 && plan.direction == .iOwe)
    #expect(plan.steps?.everyDays == 14 && !plan.paymentsAreExpenses && plan.termsReviewed)
    #expect(plan.markupE4 == nil)
    let steps = try #require(plan.steps)
    let purchase = try #require(set.entries.first { $0.transaction.creditDebtId == plan.id })
    #expect(day(of: purchase) == steps.firstDue)
    #expect(purchase.transaction.amountE4 == AmountE4(whole: 12_000))
    let lines = set.debtEntries.filter { $0.debtId == plan.id }
    #expect(lines.map(\.kind) == [.borrowed, .payment])
    #expect(lines[0].amountE4 == AmountE4(whole: 12_000) && lines[0].transactionId == purchase.id)
    #expect(lines[1].amountE4 == AmountE4(whole: -3_000) && lines[1].date == steps.firstDue)
    let payment = try #require(set.entries.first { $0.id == lines[1].transactionId })
    #expect(
      payment.transaction.debtId == plan.id
        && payment.transaction.amountE4 == AmountE4(whole: 3_000))
    #expect(CalendarContext.moscow.adding(days: 14, to: steps.firstDue) > set.lastDay)
  }

  /// The bank loan: an early repayment of 50,000 «a shorter term» after the main account's count,
  /// my spending in its subcategory; its insurance paid once the day it began, before the
  /// history, with no operation.
  @Test func theBankLoanHasAnEarlyRepaymentAndItsInsurance() throws {
    let set = Self.layered(language: "ru")
    let loan = try #require(set.debts.first { $0.name == "Кредит в банке" })
    let prepay = try #require(set.debtEntries.first { $0.debtId == loan.id && $0.prepay != nil })
    #expect(prepay.prepay == .term && prepay.kind == .payment)
    #expect(prepay.amountE4 == AmountE4(whole: -50_000))
    let payment = try #require(set.entries.first { $0.id == prepay.transactionId })
    #expect(payment.transaction.debtId == loan.id)
    #expect(payment.parts.first?.categoryId == loan.loansSubcategoryId)
    #expect(day(of: payment) > CalendarContext.moscow.adding(days: -14, to: set.lastDay))
    #expect(DebtRules.balance(of: loan.id, entries: set.debtEntries).raw > 0)

    let cost = try #require(set.debtCosts.first)
    #expect(set.debtCosts.count == 1)
    #expect(cost.debtId == loan.id && cost.kind == .insurance && cost.every == .once)
    #expect(cost.transactionId == nil && !cost.inLoan)
    #expect(cost.day < set.firstDay, "paid long before the history")
  }

  /// «Залог за квартиру»: 30,000 owed back to me in four months, given without money moving
  /// inside the history.
  @Test func thePledgeIsOwedBackInFourMonths() throws {
    let set = Self.layered(language: "ru")
    let pledge = try #require(set.debts.first { $0.pledge })
    #expect(pledge.name == "Залог за квартиру" && pledge.direction == .owedToMe)
    #expect(!pledge.paymentsAreExpenses && pledge.termsReviewed && !pledge.closed)
    let lines = set.debtEntries.filter { $0.debtId == pledge.id }
    #expect(lines.count == 1 && lines[0].kind == .adjustment)
    #expect(lines[0].amountE4 == AmountE4(whole: 30_000))
    let given = try #require(lines[0].date)
    let returnBy = try #require(pledge.returnBy)
    #expect(returnBy.monthKey == given.monthKey.next.next.next.next)
    #expect(returnBy > set.lastDay)
  }

  /// Every row that moves money on an account counted before is dated after that account's last
  /// count; nothing comes after the moment the set is made.
  @Test func nothingMovesMoneyBeforeACountOfItsAccount() {
    let earlier = Self.earlier()
    let set = Self.layered()
    func lastCount(of account: UUID) -> Date? {
      let counts = earlier.reconciledBalances.filter { $0.accountId == account }
        .compactMap { row in earlier.reconciliations.first { $0.id == row.reconciliationId } }
      return counts.compactMap(\.reconciledAt).max()
    }
    let old = Set(earlier.entries.map(\.id))
    for entry in set.entries where !old.contains(entry.id) {
      let movesMoney =
        entry.transaction.creditDebtId == nil
        && !entry.parts.allSatisfy { $0.goalId != nil }
      guard movesMoney, let account = entry.transaction.paymentMethodId,
        let counted = lastCount(of: account)
      else { continue }
      #expect(entry.transaction.occurredAt > counted, "\(entry.transaction.note ?? "")")
    }
    let transfers = Set(earlier.transfers.map(\.id))
    for transfer in set.transfers where !transfers.contains(transfer.id) {
      for account in [transfer.fromAccountId, transfer.toAccountId] {
        if let counted = lastCount(of: account) { #expect(transfer.occurredAt > counted) }
      }
    }
  }

  @Test func theNamesFollowTheLanguage() {
    let set = Self.layered(language: "en")
    #expect(set.paymentMethods.contains { $0.name == "T-Bank credit card" })
    #expect(set.banks.contains { $0.name == "T-Bank" })
    #expect(set.debts.contains { $0.name == "Vacuum cleaner" })
    #expect(set.debts.contains { $0.name == "Rental deposit" })
  }

  /// The same seed gives the same layer; applied once.
  @Test func theLayerIsAppliedOnce() {
    let first = SampleFeatureLayersTests.layered()
    let again = first.withEveryFeature(seed: Self.seed, calendar: .moscow, language: "en")
    #expect(again.debts == first.debts && again.entries == first.entries)
    #expect(SampleFeatureLayersTests.layered().debtEntries == first.debtEntries)
  }

  /// A history of a month gets the marks of reviewed debts, and nothing else of the layer.
  @Test func aShortHistoryGetsOnlyTheMarks() {
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let history = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: day, calendar: .moscow, language: "en")
    let set = history.withEveryFeature(seed: 3, calendar: .moscow, language: "en")
    #expect(!set.paymentMethods.contains { $0.isCreditCard })
    #expect(!set.debts.contains { $0.pledge || $0.isInstalmentPlan && $0.steps != nil })
    #expect(set.debtCosts.isEmpty && set.paymentMethods.allSatisfy { $0.mainCardId == nil })
    #expect(set.debts.allSatisfy { $0.termsReviewed })
  }

  fileprivate func day(of entry: TransactionEntry) -> DateOnly {
    CalendarContext.moscow.day(of: entry.transaction.occurredAt)
  }
}
