import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Changing many operations at once")
struct BulkEditRuleTests {
  let categories = StartingCategories()

  private func plan(
    _ edit: BulkEdit, _ entries: [TransactionEntry],
    history: ManualQualityHistory = .empty
  ) -> BulkEditPlan {
    BulkEditRule.plan(edit, entries: entries, tree: categories.tree, history: history)
  }

  private func groceries(_ n: Int, amount: Int = 100) -> TransactionEntry {
    entry(
      id(n), parts: [part(id(n * 10 + 1), amount: money(amount), category: categories.groceries)])
  }

  // MARK: Category

  /// A change of the parts reaches every part of a split, and the plan counts the split so
  /// the confirmation can say so.
  @Test func aCategoryReachesEveryPartOfASplit() {
    var receipt = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.fuel),
      ])
    receipt.transaction.importBatchId = id(90)
    receipt.transaction.externalId = "bank:1"
    let single = groceries(2)

    let result = plan(.category(categories.education), [receipt, single])

    #expect(result.changedIds == [id(1), id(2)])
    #expect(result.splitCount == 1)
    #expect(result.touchesSplit)
    #expect(result.skipped.isEmpty)
    let changed = result.changed[0]
    #expect(changed.parts.map(\.categoryId) == [categories.education, categories.education])
    #expect(changed.parts.map(\.categorySource) == [.manual, .manual])
    #expect(changed.parts.map(\.quality) == [.good, .good])
    #expect(changed.parts.map(\.qualitySource) == [.category, .category])
    // Only the change itself: when and where it came from stays.
    #expect(changed.transaction.createdAt == receipt.transaction.createdAt)
    #expect(changed.transaction.importBatchId == id(90))
    #expect(changed.transaction.externalId == "bank:1")
    #expect(changed.parts.map(\.amountE4) == receipt.parts.map(\.amountE4))
  }

  @Test func aRatingIGaveByHandSurvivesACategoryChange() {
    let rated = entry(
      id(1),
      parts: [
        part(
          id(11), amount: money(100), category: categories.groceries, quality: .bad,
          qualitySource: .manual)
      ])
    let changed = plan(.category(categories.education), [rated]).changed[0]
    #expect(changed.parts[0].quality == .bad)
    #expect(changed.parts[0].qualitySource == .manual)
  }

  /// Rule 2 before rule 3: a description I rated by hand keeps my rating in its new
  /// category; without that history the category decides.
  @Test func aRatingFromMyHistoryIsKeptAfterACategoryChange() {
    let taxi = entry(
      id(1), note: "Taxi home",
      parts: [
        part(
          id(11), amount: money(100), category: categories.groceries, quality: .bad,
          qualitySource: .history)
      ])
    let history = ManualQualityHistory(latest: ["taxi home": .bad])

    let remembered = plan(.category(categories.education), [taxi], history: history).changed[0]
    #expect(remembered.parts[0].quality == .bad)
    #expect(remembered.parts[0].qualitySource == .history)

    let forgotten = plan(.category(categories.education), [taxi]).changed[0]
    #expect(forgotten.parts[0].quality == .good)
    #expect(forgotten.parts[0].qualitySource == .category)
  }

  /// Income only takes income categories and has no quality; a refund goes back into
  /// spending categories like the expense it takes back.
  @Test func theCategoryHasToBeOfTheOperationsKind() {
    let salary = entry(
      id(1), kind: .income,
      parts: [part(id(11), amount: money(5000), category: categories.salary)])
    let refund = entry(
      id(2), kind: .refund,
      parts: [part(id(21), amount: money(50), category: categories.groceries)])
    let spending = groceries(3)

    let toBonus = plan(.category(categories.bonus), [salary, refund, spending])
    #expect(toBonus.changedIds == [id(1)])
    #expect(toBonus.changed[0].parts[0].quality == nil)
    #expect(toBonus.changed[0].parts[0].qualitySource == nil)
    #expect(Set(toBonus.skipped.map(\.transactionId)) == [id(2), id(3)])
    #expect(toBonus.skipped.allSatisfy { $0.reason == .otherKind && !$0.isPartial })

    let toFuel = plan(.category(categories.fuel), [salary, refund, spending])
    #expect(toFuel.changedIds == [id(2), id(3)])
    #expect(toFuel.skipped == [BulkSkip(transactionId: id(1), reason: .otherKind)])
  }

  @Test func whatTheCategoryChangeLeavesAloneAndWhy() {
    let moneyBack = entry(
      id(1), kind: .reimbursement, parts: [part(id(11), amount: money(300))])
    let loanPayment = entry(
      id(2), debtId: id(200),
      parts: [part(id(21), amount: money(7000), category: categories.loansCar)])
    let contribution = entry(
      id(3), parts: [part(id(31), amount: money(1000), category: categories.goalsTrip)])
    let byGoal = entry(
      id(4),
      parts: [part(id(41), amount: money(1000), category: categories.groceries, goal: id(70))]
    )
    let forgotten = entry(
      id(5), parts: [part(id(51), amount: money(80), category: categories.unknown)])

    let result = plan(
      .category(categories.fuel), [moneyBack, loanPayment, contribution, byGoal, forgotten])

    #expect(result.changed.isEmpty)
    #expect(
      result.skipped == [
        BulkSkip(transactionId: id(1), reason: .moneyReturned),
        BulkSkip(transactionId: id(2), reason: .debtPayment),
        BulkSkip(transactionId: id(3), reason: .goalContribution),
        BulkSkip(transactionId: id(4), reason: .goalContribution),
        BulkSkip(transactionId: id(5), reason: .systemCategory),
      ])
  }

  /// A split where one part is a goal contribution: the rest changes, that part stays, and
  /// the plan says the operation changed only in part.
  @Test func aGoalPartOfASplitStaysWhileTheRestChanges() {
    let mixed = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.goalsTrip),
      ])
    let result = plan(.category(categories.fuel), [mixed])

    #expect(result.changed[0].parts.map(\.categoryId) == [categories.fuel, categories.goalsTrip])
    #expect(
      result.skipped == [BulkSkip(transactionId: id(1), reason: .goalContribution, isPartial: true)]
    )
    #expect(result.partlySkipped.count == 1)
    #expect(result.fullySkipped.isEmpty)
  }

  /// System categories are never a target: the list does not offer them, and the rule
  /// refuses them anyway.
  @Test func nothingIsMovedIntoASystemCategory() {
    let result = plan(.category(categories.loansCar), [groceries(1)])
    #expect(result.changed.isEmpty)
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .systemCategory)])
  }

  /// Only a live category is a target. One archived since the popover opened, one under an
  /// archived parent, or one the dictionary does not know at all is refused — with a
  /// reason of its own, not as «the other kind».
  @Test func aRetiredOrUnknownCategoryIsNeverATarget() {
    let cafe = id(130)
    let lunches = id(131)
    let tree = CategoryTree([
      CoreKit.Category(
        id: categories.groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: cafe, kind: .expense, name: "Cafe", archived: true, quality: .neutral),
      CoreKit.Category(id: lunches, parentId: cafe, kind: .expense, name: "Lunches"),
    ])

    for target in [cafe, lunches, id(999)] {
      let result = BulkEditRule.plan(.category(target), entries: [groceries(1)], tree: tree)
      #expect(result.changed.isEmpty)
      #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .retiredCategory)])
    }
  }

  /// Re-filing — what deleting a used category does — moves only the parts filed under the
  /// categories named. The other parts of a split keep their category and its source, an
  /// operation with none of them is left alone, and a split is counted only when every part
  /// of it moved.
  @Test func aRefilingMovesOnlyThePartsInTheCategoriesNamed() {
    var receipt = entry(
      id(1),
      parts: [
        part(id(11), amount: money(300), category: categories.groceries),
        part(id(12), amount: money(700), category: categories.fuel),
      ])
    receipt.parts[1].categorySource = .model
    let whole = entry(
      id(2),
      parts: [
        part(id(21), amount: money(100), category: categories.groceries),
        part(id(22), amount: money(200), category: categories.groceries),
      ])
    let elsewhere = entry(
      id(3), parts: [part(id(31), amount: money(50), category: categories.fuel)])

    let result = plan(
      .refile(from: [categories.groceries], to: categories.education),
      [receipt, whole, elsewhere])

    #expect(result.changedIds == [id(1), id(2)])
    #expect(result.skipped.isEmpty)
    #expect(result.splitCount == 1)
    let moved = result.changed[0]
    #expect(moved.parts.map(\.categoryId) == [categories.education, categories.fuel])
    #expect(moved.parts.map(\.categorySource) == [.manual, .model])
    #expect(moved.parts[1] == receipt.parts[1])
    #expect(
      result.changed[1].parts.map(\.categoryId) == [categories.education, categories.education])
  }

  @Test func anOperationAlreadyThereIsNeitherChangedNorSkipped() {
    var there = groceries(1)
    there.parts[0].categorySource = .manual
    there.parts[0].quality = .neutral
    there.parts[0].qualitySource = .category
    let result = plan(.category(categories.groceries), [there])
    #expect(result.changed.isEmpty)
    #expect(result.skipped.isEmpty)
  }

  // MARK: Quality

  @Test func aQualityBecomesMineExceptOnGoalsIncomeAndMoneyBack() {
    let mixed = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries, quality: .neutral),
        part(id(12), amount: money(400), category: categories.goalsTrip, quality: .good),
      ])
    let salary = entry(
      id(2), kind: .income, parts: [part(id(21), amount: money(5000), category: categories.salary)])
    let moneyBack = entry(id(3), kind: .reimbursement, parts: [part(id(31), amount: money(300))])
    let refund = entry(
      id(4), kind: .refund, parts: [part(id(41), amount: money(50), category: categories.groceries)]
    )

    let result = plan(.quality(.bad), [mixed, salary, moneyBack, refund])

    #expect(result.changedIds == [id(1), id(4)])
    #expect(result.changed[0].parts.map(\.quality) == [.bad, .good])
    #expect(result.changed[0].parts.map(\.qualitySource) == [.manual, nil])
    #expect(result.changed[1].parts[0].qualitySource == .manual)
    #expect(
      result.skipped == [
        BulkSkip(transactionId: id(1), reason: .goalContribution, isPartial: true),
        BulkSkip(transactionId: id(2), reason: .noQuality),
        BulkSkip(transactionId: id(3), reason: .noQuality),
      ])
  }

  // MARK: For whom

  @Test func aGroupDropsThePersonAndAPersonTurnsMeIntoOther() {
    var withPerson = groceries(1)
    withPerson.parts[0].forWhom = .friends
    withPerson.parts[0].forPersonId = id(60)
    let mine = groceries(2)
    var partner = groceries(3)
    partner.parts[0].forWhom = .partner

    let toFamily = plan(.forWhom(.family), [withPerson, mine])
    #expect(toFamily.changed.map { $0.parts[0].forWhom } == [.family, .family])
    #expect(toFamily.changed.map { $0.parts[0].forPersonId } == [nil, nil])

    let toPerson = plan(.forPerson(id(61)), [mine, partner])
    #expect(toPerson.changed.map { $0.parts[0].forPersonId } == [id(61), id(61)])
    // «Me» cannot be somebody else; a group that was already named stays.
    #expect(toPerson.changed.map { $0.parts[0].forWhom } == [.other, .partner])
  }

  /// A part paid for somebody else already names who owes it; money given back has no
  /// «для кого» at all.
  @Test func forWhomLeavesPartsPaidForOthersAndMoneyBackAlone() {
    let dinner = entry(
      id(1),
      parts: [
        part(id(11), amount: money(200), category: categories.groceries),
        part(
          id(12), amount: money(400), category: categories.groceries, forWhom: .friends,
          reimbursable: true, debtor: id(50)),
      ])
    let theirs = entry(
      id(2),
      parts: [
        part(
          id(21), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50))
      ])
    let moneyBack = entry(id(3), kind: .reimbursement, parts: [part(id(31), amount: money(300))])

    let result = plan(.forWhom(.partner), [dinner, theirs, moneyBack])

    #expect(result.changedIds == [id(1)])
    #expect(result.changed[0].parts.map(\.forWhom) == [.partner, .friends])
    #expect(
      result.skipped == [
        BulkSkip(transactionId: id(1), reason: .paidForSomebodyElse, isPartial: true),
        BulkSkip(transactionId: id(2), reason: .paidForSomebodyElse),
        BulkSkip(transactionId: id(3), reason: .moneyReturned),
      ])
    #expect(plan(.forPerson(id(61)), [moneyBack]).skipped.map(\.reason) == [.moneyReturned])
  }

  // MARK: Event, place, payment method

  /// An event goes on a purchase and a refund, and can be taken away; income and money back
  /// have no event, so they are left as they are and say why.
  @Test func anEventGoesOnSpendingOnlyAndCanBeTakenAway() {
    let salary = entry(
      id(1), kind: .income, parts: [part(id(11), amount: money(5000), category: categories.salary)])
    let moneyBack = entry(id(2), kind: .reimbursement, parts: [part(id(21), amount: money(300))])
    let split = entry(
      id(3),
      parts: [
        part(id(31), amount: money(600), category: categories.groceries),
        part(id(32), amount: money(400), category: categories.goalsTrip),
      ])
    let refund = entry(
      id(4), kind: .refund,
      parts: [part(id(41), amount: money(100), category: categories.groceries)])

    let result = plan(.event(id(80)), [salary, moneyBack, split, refund])
    #expect(result.changedIds == [id(3), id(4)])
    #expect(result.changed[0].parts.map(\.eventId) == [id(80), id(80)])
    #expect(result.skipped.map(\.transactionId) == [id(1), id(2)])
    #expect(result.skipped.allSatisfy { $0.reason == .fieldNotForKind && !$0.isPartial })
    #expect(result.splitCount == 1)

    let cleared = plan(.event(nil), result.changed)
    #expect(cleared.changed.allSatisfy { $0.parts.allSatisfy { $0.eventId == nil } })
  }

  /// Income has no «на кого», and money back has no place: both are left as they are.
  @Test func incomeHasNoForWhomAndMoneyBackHasNoPlace() {
    let salary = entry(
      id(1), kind: .income, parts: [part(id(11), amount: money(5000), category: categories.salary)])
    let moneyBack = entry(id(2), kind: .reimbursement, parts: [part(id(21), amount: money(300))])
    #expect(plan(.forWhom(.family), [salary]).skipped.map(\.reason) == [.fieldNotForKind])
    #expect(plan(.forPerson(id(61)), [salary]).skipped.map(\.reason) == [.fieldNotForKind])
    #expect(plan(.place(id(51)), [moneyBack]).skipped.map(\.reason) == [.fieldNotForKind])
    #expect(plan(.place(id(51)), [salary]).skipped.map(\.reason) == [.incomeHasNoPlace])
    #expect(plan(.forWhom(.family), [moneyBack]).skipped.map(\.reason) == [.moneyReturned])
  }

  /// Place and payment method are fields of the operation: a split changes once, and the
  /// confirmation has no parts to warn about.
  @Test func placeAndPaymentMethodAreFieldsOfTheOperation() {
    let split = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.fuel),
      ])
    let salary = entry(
      id(2), kind: .income, parts: [part(id(21), amount: money(5000), category: categories.salary)])

    let place = plan(.place(id(81)), [split, salary])
    #expect(place.changed.map(\.transaction.placeId) == [id(81)])
    #expect(place.splitCount == 0)
    #expect(place.skipped == [BulkSkip(transactionId: id(2), reason: .incomeHasNoPlace)])

    let card = plan(.paymentMethod(id(82)), [split, salary])
    #expect(card.changed.map(\.transaction.paymentMethodId) == [id(82), id(82)])
    #expect(card.skipped.isEmpty)
  }

  // MARK: Deleting and undoing

  @Test func aPurchaseOnCreditIsNotDeletedFromTheList() {
    let laptop = entry(
      id(1), creditDebtId: id(201),
      parts: [part(id(11), amount: money(90000), category: categories.groceries)])
    let loanPayment = entry(
      id(2), debtId: id(200),
      parts: [part(id(21), amount: money(7000), category: categories.loansCar)])
    let result = BulkEditRule.deletion(of: [laptop, loanPayment, groceries(3)])
    #expect(result.changedIds == [id(2), id(3)])
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .creditPurchase)])
  }

  /// Its debt deleted and never paid, a purchase on credit goes like any other purchase.
  @Test func aCreditPurchaseOfADeletedDebtCanBeDeleted() {
    let laptop = entry(
      id(1), creditDebtId: id(201),
      parts: [part(id(11), amount: money(90000), category: categories.groceries)])
    let result = BulkEditRule.deletion(of: [laptop], deletedDebts: [id(201)])
    #expect(result.changedIds == [id(1)])
    #expect(result.skipped.isEmpty)
    // Another debt deleted says nothing about this one.
    #expect(
      BulkEditRule.deletion(of: [laptop], deletedDebts: [id(202)]).skipped
        == [BulkSkip(transactionId: id(1), reason: .creditPurchase)])
  }

  /// «Телефон» 60,000 ₽ on credit, 3 × 5,000 ₽ paid, the debt deleted: the payments were never
  /// spending, so the purchase stays — spending stays 60,000 ₽ and the 15,000 ₽ that left the
  /// card stay in a figure.
  @Test func aPaidCreditPurchaseOfADeletedDebtStays() {
    let phone = entry(
      id(1), creditDebtId: id(201),
      parts: [part(id(11), amount: money(60000), category: categories.groceries)])
    let payments = (2...4).map { number in
      entry(
        id(number), debtId: id(201),
        parts: [part(id(number * 10), amount: money(5000), category: categories.groceries)])
    }
    let paid = DebtRules.paidDebts(entries: payments, journal: [])
    #expect(paid == [id(201)])
    let result = BulkEditRule.deletion(of: [phone], deletedDebts: [id(201)], paidDebts: paid)
    #expect(result.changedIds.isEmpty)
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .creditPurchasePaid)])
    let debt = Debt(
      id: id(201), direction: .iOwe, type: .installment, name: "Phone",
      paymentsAreExpenses: false, origin: .purchase, deletedAt: moment("2026-09-27"))
    #expect(
      MyExpensesRule.total(entries: [phone] + payments, debts: [id(201): debt]) == money(60000))
  }

  /// A purchase a reimbursement closed a part of stays while that reimbursement is there:
  /// gone, it would leave the reimbursement closing nothing and its shortfall counted as my
  /// spending on nothing. A part still waiting, or written off, stops nothing.
  @Test func aPurchaseAReimbursementClosedAPartOfIsNotDeletedFromUnderIt() {
    func dinner(_ number: Int, _ status: ReimbursementStatus) -> TransactionEntry {
      entry(
        id(number),
        parts: [
          part(id(number * 10), amount: money(600), category: categories.groceries),
          part(
            id(number * 10 + 1), amount: money(400), category: categories.groceries,
            reimbursable: true, status: status, debtor: id(50)),
        ])
    }
    let result = BulkEditRule.deletion(
      of: [dinner(1, .returned), dinner(2, .expected), dinner(3, .writtenOff)])
    #expect(result.changedIds == [id(2), id(3)])
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .closedByReimbursement)])
  }

  /// Undo takes back my change, not what happened since: a part written off after the
  /// change stays written off, and a refined amount in rubles stays refined.
  @Test func revertingPutsBackOnlyWhatTheChangeTouched() {
    var before = entry(
      id(1),
      parts: [
        part(
          id(11), amount: money(600), category: categories.groceries, quality: .neutral,
          qualitySource: .category),
        part(
          id(12), amount: money(400), category: categories.fuel, reimbursable: true,
          debtor: id(50)),
      ])
    before.transaction.placeId = id(81)
    let changed = plan(.category(categories.education), [before]).changed[0]
    var now = changed
    now.parts[1].reimbursementStatus = .writtenOff
    now.parts[0].amountRubE4 = money(612)
    now.transaction.placeId = id(99)

    let reverted = BulkEditRule.revert(now, to: before)

    #expect(reverted.parts.map(\.categoryId) == [categories.groceries, categories.fuel])
    #expect(reverted.parts[0].quality == .neutral)
    #expect(reverted.parts[0].qualitySource == .category)
    #expect(reverted.parts[1].reimbursementStatus == .writtenOff)
    #expect(reverted.parts[0].amountRubE4 == money(612))
    #expect(reverted.transaction.placeId == id(81))
  }

  // MARK: The account and what it is charged

  let rubleCard = PaymentMethod(id: id(82), name: "Card", currency: .rub, isDefault: true)
  let dollarCash = PaymentMethod(id: id(83), name: "Cash", kind: .cash, currency: .usd)
  let tengeCard = PaymentMethod(id: id(84), name: "Tenge", currency: CurrencyCode("KZT"))
  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 90)],
    CurrencyCode("KZT"): [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 2)],
  ])

  /// 50 dollars at 90 on the dollar cash: 4 500 rubles.
  func dollarDinner(_ number: Int, leg: (CurrencyCode, Int)? = nil) -> TransactionEntry {
    var dinner = entry(
      id(number), parts: [part(id(number * 10), amount: money(50), category: categories.groceries)])
    dinner.transaction.currency = .usd
    dinner.transaction.rate = 90
    dinner.transaction.amountRubE4 = money(4500)
    dinner.parts[0].amountRubE4 = money(4500)
    dinner.transaction.paymentMethodId = id(83)
    dinner.transaction.accountCurrency = leg?.0
    dinner.transaction.accountAmountE4 = leg.map { money($0.1) }
    return dinner
  }

  func accountPlan(
    _ edit: BulkEdit, _ entries: [TransactionEntry], rates: DayRates? = nil
  )
    -> BulkEditPlan
  {
    BulkEditRule.plan(
      edit, entries: entries, tree: categories.tree, accounts: [rubleCard, dollarCash, tengeCard],
      rates: rates ?? self.rates, calendar: .utc)
  }

  /// On a ruble card a dollar operation is charged its own rubles, so no ruble figure moves; on
  /// an account that holds dollars nothing is charged apart.
  @Test func anAccountThatDoesNotHoldTheCurrencyIsChargedItsRubles() {
    let moved = accountPlan(.paymentMethod(id(82)), [dollarDinner(1)])
    #expect(moved.changed.first?.transaction.paymentMethodId == id(82))
    #expect(moved.changed.first?.transaction.accountCurrency == .rub)
    #expect(moved.changed.first?.transaction.accountAmountE4 == money(4500))
    #expect(moved.changed.first?.transaction.amountRubE4 == money(4500))

    let back = accountPlan(.paymentMethod(id(83)), moved.changed)
    #expect(back.changed.first?.transaction.accountCurrency == nil)
    #expect(back.changed.first?.transaction.accountAmountE4 == nil)
  }

  @Test func aChargeGoesThroughRublesAtTheRatesOfItsDay() {
    let moved = accountPlan(.paymentMethod(id(84)), [dollarDinner(1)])
    #expect(moved.changed.first?.transaction.accountCurrency == CurrencyCode("KZT"))
    #expect(moved.changed.first?.transaction.accountAmountE4 == money(2250))
  }

  /// A figure already in the currency the new account is charged in stays: it may have been
  /// typed from the statement.
  @Test func aChargeAlreadyInTheRightCurrencyIsKept() {
    let typed = dollarDinner(1, leg: (.rub, 4620))
    let moved = accountPlan(.paymentMethod(id(82)), [typed])
    #expect(moved.changed.first?.transaction.accountAmountE4 == money(4620))
  }

  @Test func withoutTheRateOfTheDayTheOperationIsLeftAsItIs() {
    let moved = accountPlan(.paymentMethod(id(84)), [dollarDinner(1)], rates: .empty)
    #expect(moved.changed.isEmpty)
    #expect(moved.skipped == [BulkSkip(transactionId: id(1), reason: .noRateForCharge)])
  }

  /// A refund of 40 dollars taken back from a purchase keeps the purchase's rate, 90, for its
  /// rubles; moved to a ruble card, it is credited at the rate of its own day, 95: 3 800, not the
  /// 3 600 of its rubles.
  @Test func aRefundMovedToARubleCardIsCreditedAtTheRateOfItsDay() {
    var refund = entry(
      id(5), kind: .refund, on: "2026-03-20",
      parts: [part(id(51), amount: money(40), category: categories.groceries)])
    refund.transaction.currency = .usd
    refund.transaction.rate = 90
    refund.transaction.amountRubE4 = money(3600)
    refund.parts[0].amountRubE4 = money(3600)
    refund.parts[0].refundOfPartId = id(99)
    refund.transaction.paymentMethodId = id(83)
    let dayRates = DayRates(series: [
      .usd: [
        DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 90),
        DayRate(day: DateOnly(year: 2026, month: 3, day: 20), perUnit: 95),
      ]
    ])
    let moved = accountPlan(.paymentMethod(id(82)), [refund], rates: dayRates)
    #expect(moved.changed.first?.transaction.accountCurrency == .rub)
    #expect(moved.changed.first?.transaction.accountAmountE4 == money(3800))
    #expect(moved.changed.first?.transaction.amountRubE4 == money(3600))
    // Without the rate of its day it is left as it is.
    let noRate = accountPlan(.paymentMethod(id(82)), [refund], rates: .empty)
    #expect(noRate.skipped == [BulkSkip(transactionId: id(5), reason: .noRateForCharge)])
  }

  @Test func aContributionToAGoalIsChargedNothing() {
    var contribution = dollarDinner(1)
    contribution.parts[0].categoryId = categories.goalsTrip
    let moved = accountPlan(.paymentMethod(id(82)), [contribution])
    #expect(moved.changed.first?.transaction.paymentMethodId == id(82))
    #expect(moved.changed.first?.transaction.accountCurrency == nil)
  }

  /// Every operation has an account: «no account» moves the operations to the main one.
  @Test func noAccountMeansTheMainAccount() {
    let moved = accountPlan(.paymentMethod(nil), [dollarDinner(1)])
    #expect(moved.changed.first?.transaction.paymentMethodId == id(82))
    #expect(moved.changed.first?.transaction.accountCurrency == .rub)
  }

  /// Undo puts the account back with what it was charged: never the old account with the
  /// charge of the new one.
  @Test func revertingPutsTheChargeBackWithTheAccount() throws {
    let before = dollarDinner(1)
    let moved = try #require(accountPlan(.paymentMethod(id(82)), [before]).changed.first)
    let reverted = BulkEditRule.revert(moved, to: before)
    #expect(reverted.transaction.paymentMethodId == id(83))
    #expect(reverted.transaction.accountCurrency == nil)
    #expect(reverted.transaction.accountAmountE4 == nil)
  }

  // MARK: The card and the cashback typed for an operation

  let otherRubleCard = PaymentMethod(id: id(85), name: "Other card", currency: .rub)

  /// 1 000 rubles of groceries paid with card 700 of the ruble card, with 35 rubles of cashback
  /// typed for it.
  func cardPurchase(_ number: Int) -> TransactionEntry {
    var purchase = entry(
      id(number),
      parts: [part(id(number * 10), amount: money(1000), category: categories.groceries)])
    purchase.transaction.paymentMethodId = id(82)
    purchase.transaction.cardId = id(700)
    purchase.transaction.cashback = Money(amount: money(35), currency: .rub)
    return purchase
  }

  func cardPlan(_ edit: BulkEdit, _ entries: [TransactionEntry]) -> BulkEditPlan {
    BulkEditRule.plan(
      edit, entries: entries, tree: categories.tree,
      accounts: [rubleCard, dollarCash, tengeCard, otherRubleCard], rates: rates, calendar: .utc)
  }

  /// A card always belongs to its own account: moved to another one, the operation names no
  /// card. The cashback typed in rubles stays, since rubles still move on the new account.
  @Test func movingToAnotherAccountDropsTheCard() throws {
    let moved = try #require(cardPlan(.paymentMethod(id(85)), [cardPurchase(1)]).changed.first)
    #expect(moved.transaction.paymentMethodId == id(85))
    #expect(moved.transaction.cardId == nil)
    #expect(moved.transaction.cashback == Money(amount: money(35), currency: .rub))
  }

  /// Moved to the account it is already on, nothing changes, the card included.
  @Test func sameAccountKeepsTheCard() {
    let purchase = cardPurchase(1)
    let outcome = BulkEditRule.apply(
      .paymentMethod(id(82)), to: purchase, tree: categories.tree,
      accounts: [rubleCard, dollarCash, tengeCard, otherRubleCard], rates: rates, calendar: .utc)
    #expect(outcome == .unchanged)
    let plan = cardPlan(.paymentMethod(id(82)), [purchase])
    #expect(plan.changed.isEmpty)
  }

  /// The cashback was typed in the money that moved on the old account; on an account charged
  /// in dollars it says nothing about the operation any more.
  @Test func movingDropsAnOverrideInTheOldCurrency() throws {
    let moved = try #require(cardPlan(.paymentMethod(id(83)), [cardPurchase(1)]).changed.first)
    #expect(moved.transaction.accountCurrency == .usd)
    #expect(moved.transaction.cardId == nil)
    #expect(moved.transaction.cashback == nil)
  }

  /// ⌘Z of a move puts the purchase back on its account with its card and its cashback.
  @Test func revertBringsBackTheCardAndTheCashback() throws {
    let before = cardPurchase(1)
    let moved = try #require(cardPlan(.paymentMethod(id(83)), [before]).changed.first)
    let reverted = BulkEditRule.revert(moved, to: before)
    #expect(reverted.transaction.paymentMethodId == id(82))
    #expect(reverted.transaction.cardId == id(700))
    #expect(reverted.transaction.cashback == Money(amount: money(35), currency: .rub))
    #expect(reverted.transaction.accountCurrency == nil)
    #expect(reverted == before)
  }

  /// A purchase refunds take back from stays while they are there, unless they go with it.
  @Test func aPurchaseWithRefundsIsNotDeletedFromUnderThem() {
    let purchase = groceries(1, amount: 600)
    var refund = entry(
      id(2), kind: .refund,
      parts: [part(id(21), amount: money(100), category: categories.groceries)])
    refund.parts[0].refundOfPartId = purchase.parts[0].id
    let index = RefundIndex(entries: [purchase, refund], debts: [:])
    let alone = BulkEditRule.deletion(of: [purchase], refunds: index)
    #expect(alone.skipped == [BulkSkip(transactionId: id(1), reason: .hasRefunds)])
    let together = BulkEditRule.deletion(of: [purchase, refund], refunds: index)
    #expect(together.changedIds == [id(1), id(2)])
  }

  @Test func theReasonsAreListedOnceInAFixedOrder() {
    let skips = [
      BulkSkip(transactionId: id(1), reason: .systemCategory),
      BulkSkip(transactionId: id(2), reason: .otherKind),
      BulkSkip(transactionId: id(3), reason: .systemCategory),
    ]
    #expect(BulkEditPlan.reasons(of: skips) == [.otherKind, .systemCategory])
  }
}

extension BulkEditRuleTests {
  /// The difference a count recorded: a bulk change keeps it on its account and out of «Цели»
  /// and the categories of the app, and still gives it a category, a rating, a place or an
  /// event of the owner's.
  @Test func aDifferenceKeepsItsAccountAndStaysOutOfTheAppsCategories() {
    var lost = groceries(1, amount: 8_000)
    lost.transaction.externalId =
      OperationLink.reconciledBalance(
        reconciliation: id(6), balance: id(7)
      ).externalId
    let plain = groceries(2)
    let other = PaymentMethod(id: id(301), name: "Cash", kind: .cash, currency: .rub)

    let moved = BulkEditRule.plan(
      .paymentMethod(other.id), entries: [lost, plain], tree: categories.tree,
      accounts: [other])
    #expect(moved.changedIds == [id(2)])
    #expect(moved.skipped == [BulkSkip(transactionId: id(1), reason: .reconciliationDifference)])

    for target in [categories.goalsTrip, categories.loans] {
      let filed = plan(.category(target), [lost])
      #expect(filed.skipped == [BulkSkip(transactionId: id(1), reason: .reconciliationDifference)])
    }
    let refiled = plan(.refile(from: [categories.groceries], to: categories.goals), [lost])
    #expect(refiled.skipped == [BulkSkip(transactionId: id(1), reason: .reconciliationDifference)])

    #expect(plan(.category(categories.education), [lost]).changedIds == [id(1)])
    #expect(plan(.quality(.bad), [lost]).changedIds == [id(1)])
    #expect(plan(.place(id(600)), [lost]).changedIds == [id(1)])
  }
}
