import AppCore
import Foundation

// MARK: Card or account

extension EntryDraftModel {
  /// The card of the operation laid again by the defaults: a card the line named or the owner
  /// picked stays; otherwise a purchase is made with the card that paid at the place last
  /// (`placeCard`), else the main card of its account, else its one live card
  /// (`CardRules.operationCard`) — unless it says «со счёта» (`paysFromAccount`). Any other kind
  /// takes only the card of the place, as before. A saved operation in the editor keeps its card
  /// unless the owner changes the account (`force`).
  func layTheCard(placeCard: UUID?, force: Bool = false) {
    guard !editsSavedOperation || force else { return }
    if let card = draft.cardId, card != cardFromDefaults { return }
    let laid: UUID?
    if !has(.card) || paysFromAccount {
      laid = nil
    } else if draft.kind != .expense {
      laid = placeCard
    } else if let account = selectedAccount, !account.archived {
      laid = CardRules.operationCard(
        named: nil, withoutCard: false, placeCard: placeCard, account: account, cards: cards)
    } else {
      laid = placeCard
    }
    draft.cardId = laid
    cardFromDefaults = laid
  }

  /// Whether the panel offers «Карта · Счёт»: a purchase on an account that has a live card.
  public var offersCardOrAccount: Bool {
    guard has(.card), draft.kind == .expense, !isReconcileDifference,
      let account = selectedAccount
    else { return false }
    return liveCards.contains { $0.accountId == account.id }
  }

  /// «Карта» of «Карта · Счёт»: the operation names a card.
  public var paysWithCard: Bool { draft.cardId != nil }

  /// «Карта · Счёт» switched: «Счёт» drops the card and keeps it off; «Карта» brings the card
  /// back — the one of the place or the main one, and for an account of several cards with no
  /// main one the first of them.
  public func setPaysFromAccount(_ fromAccount: Bool) {
    paysFromAccountByTheLine = false
    paysFromAccount = fromAccount
    if fromAccount {
      draft.cardId = nil
      cardFromDefaults = nil
      return
    }
    guard draft.cardId == nil else { return }
    layTheCard(placeCard: nil, force: true)
    if draft.cardId == nil, let account = selectedAccount {
      let first = CardRules.ordered(cards, of: account.id).first?.id
      draft.cardId = first
      cardFromDefaults = first
    }
  }
}

// MARK: Self-employment

extension EntryDraftModel {
  /// «смз 15000»: the income is filed under the category taxed as professional income at the
  /// lowest rate — «от физлиц (4 %)» of the ready categories —, unless the owner chose another
  /// category by hand. Without such a category the line is an income like any other, and Enter
  /// asks for the category.
  func takeTheSelfEmployment(of reading: InputLineReading) {
    lineSaysSelfEmployed = reading.selfEmployed
    guard reading.selfEmployed, draft.kind == .income, has(.category), !draft.parts.isEmpty,
      let id = selfEmployedCategoryId
    else { return }
    let first = draft.parts[0]
    guard first.categoryId == nil || first.categorySource != .manual || first.categoryId == id
    else { return }
    setCategory(id, forPartAt: 0, source: .manual)
  }

  /// The live income category with a tax on professional income of its own at the lowest rate;
  /// on equal rates the first in the owner's order.
  public var selfEmployedCategoryId: UUID? {
    categories
      .filter { $0.kind == .income && !$0.archived && $0.tax?.npd == true }
      .sorted { left, right in
        let (a, b) = (left.tax?.rate ?? 0, right.tax?.rate ?? 0)
        if a != b { return a < b }
        if left.sort != right.sort { return left.sort < right.sort }
        return left.name < right.name
      }
      .first?.id
  }

  /// «налог ≈ 240 ₽ (4 %)» under the amount of an income in a taxed category: the tax of this
  /// income alone, as `NPDTax` works it out — at the bank's rate of its day, with the deduction
  /// left. `nil` for any other operation, with self-employment off, or when its rubles cannot be
  /// worked out yet. Shown in grey, never money.
  public func taxEstimate(
    settings: SelfEmploymentSettings, dayRates: DayRates, deductionLeft: AmountE4?
  ) -> (taxE4: AmountE4, rate: Decimal)? {
    guard settings.enabled, draft.kind == .income, draft.amount.raw > 0,
      let conversion = conversion(of: draftForSaving),
      let entry = try? conversion.draft.materialize(rublesConverter: conversion.rubles)
    else { return nil }
    guard
      let tax = NPDTax.tax(
        of: entry, tree: categoryTree, settings: settings, dayRates: dayRates,
        deductionLeft: deductionLeft)
    else { return nil }
    return tax
  }
}

// MARK: Instalments

extension EntryDraftModel {
  /// The parts an instalment plan may have.
  public static let instalmentPartsRange = 2...120

  static func withinParts(_ parts: Int) -> Int {
    min(max(parts, instalmentPartsRange.lowerBound), instalmentPartsRange.upperBound)
  }

  /// What one payment of the plan is: for instalments its first part of the price and of the
  /// markup (`InstalmentPlan.parts`), for credit the amount split into the payments.
  func instalment(of plan: CreditPlan) -> AmountE4 {
    guard plan.instalments else {
      return Self.instalment(of: draft.amount, over: plan.payments)
    }
    guard draft.amount.raw > 0 else { return .zero }
    let price = InstalmentPlan.parts(total: draft.amount, count: plan.payments).first ?? .zero
    let markup =
      InstalmentPlan.markupShares(markup: plan.markup, count: plan.payments).first ?? .zero
    return price + markup
  }

  /// «Рассрочка частями» on: four parts every two weeks, the first today; off: a credit of
  /// twelve monthly payments, as the box starts.
  public func setInstalments(_ on: Bool) {
    guard var plan = creditPlan, plan.debtId == nil else { return }
    plan.instalments = on
    plan.payments = on ? InstalmentPlan.defaultCount : 12
    plan.everyDays = InstalmentPlan.defaultEveryDays
    plan.markup = .zero
    plan.monthlyAmount = instalment(of: plan)
    creditPlan = plan
  }

  /// How often a part is paid: every `days` days, or — `nil` — on the day of the purchase of
  /// every month.
  public func setInstalmentStep(_ days: Int?) {
    guard var plan = creditPlan, plan.instalments else { return }
    plan.everyDays = days.map {
      min(max($0, DebtSteps.range.lowerBound), DebtSteps.range.upperBound)
    }
    creditPlan = plan
  }

  /// The markup typed: what the plan costs above the price.
  public func setInstalmentMarkup(_ markup: AmountE4) {
    guard var plan = creditPlan, plan.instalments, plan.markup != markup else { return }
    plan.markup = markup.isNegative ? .zero : markup
    plan.monthlyAmount = instalment(of: plan)
    creditPlan = plan
  }

  /// The debt and its first line a new instalment plan is written with for the purchase
  /// `entry` (`InstalmentPlan.make`): its id is the one the draft points at (`creditDebtId`).
  func instalmentPlan(
    for entry: TransactionEntry, name: String, calendar: CalendarContext
  ) -> (debt: Debt, line: DebtEntry)? {
    guard let plan = creditPlan, plan.instalments, plan.debtId == nil,
      let id = entry.transaction.creditDebtId
    else { return nil }
    let day = calendar.day(of: entry.transaction.occurredAt)
    var made = InstalmentPlan.make(
      purchase: entry, price: entry.transaction.amountE4, count: plan.payments,
      everyDays: plan.everyDays, paymentDay: plan.everyDays == nil ? day.day : nil,
      markup: plan.markup, name: name, id: id, calendar: calendar)
    made.1.description = entry.transaction.note
    return (made.0, made.1)
  }

  // MARK: A thing bought in instalments, returned

  /// The open instalment plan the purchase picked for this refund was bought on; `nil` for any
  /// other refund. The refund then asks whether the bank lowers the debt or pays to the card
  /// (`InstalmentReturnSheet`).
  public var instalmentPlanOfTheRefund: Debt? {
    guard draft.kind == .refund, let target = refundTarget,
      let id = target.purchase.transaction.creditDebtId
    else { return nil }
    return debts.first { $0.id == id && $0.isInstalmentPlan && !$0.closed && !$0.isDeleted }
  }

  /// The plan a purchase was bought on, open or not, for whether it may be refunded at all.
  func instalmentPlan(of purchase: TransactionEntry) -> Debt? {
    guard let id = purchase.transaction.creditDebtId else { return nil }
    return allDebtsById[id].flatMap { $0.isInstalmentPlan ? $0 : nil }
  }
}
