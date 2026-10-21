import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Changes made to many operations at once, on random operations of every kind: what a change
/// may touch, that a second time changes nothing more, and that undo gives back exactly what
/// was there.
@Suite("Bulk changes on random operations")
struct BulkEditPropertyTests {
  let categories = StartingCategories()
  let card = PaymentMethod(id: id(82), name: "Card", currency: .rub, isDefault: true)
  let cash = PaymentMethod(id: id(83), name: "Cash", kind: .cash, currency: .usd)
  let tenge = PaymentMethod(id: id(84), name: "Tenge", currency: CurrencyCode("KZT"))
  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 1, day: 1), perUnit: 90)],
    CurrencyCode("KZT"): [
      DayRate(day: DateOnly(year: 2026, month: 1, day: 1), perUnit: Decimal(18) / 100)
    ],
  ])
  var accounts: [PaymentMethod] { [card, cash, tenge] }

  func operations(seed: UInt64) -> [TransactionEntry] {
    var dice = MoneyDice(seed: seed)
    var result: [TransactionEntry] = []
    for number in 1...30 {
      let kind = dice.pick(TransactionKind.allCases)
      let currency = dice.pick([CurrencyCode.rub, .usd])
      let at = moment("2026-03-01").addingTimeInterval(TimeInterval(dice.below(30) * 86_400))
      var parts: [TransactionPart] = []
      for index in 0..<(kind == .reimbursement ? 1 : dice.int(1...3)) {
        let category: UUID? =
          switch kind {
          case .income: dice.pick([categories.salary, categories.bonus])
          case .reimbursement: nil
          case .expense, .refund:
            dice.pick([
              categories.groceries, categories.fuel, categories.goalsTrip, categories.fines,
              categories.loansCar, categories.education,
            ])
          }
        let forOthers = kind == .expense && dice.chance(15)
        parts.append(
          TransactionPart(
            id: id(number * 10 + index), transactionId: id(number), categoryId: category,
            categorySource: dice.pick([CategorySource.manual, .model, .system]),
            quality: kind.hasQuality && dice.chance(40) ? dice.pick(Quality.allCases) : nil,
            qualitySource: kind.hasQuality && dice.chance(40)
              ? dice.pick([QualitySource.manual, .category]) : nil,
            amountE4: dice.amount(upTo: 900), forWhom: dice.pick(ForWhom.allCases),
            forPersonId: dice.chance(30) ? id(300) : nil, reimbursable: forOthers,
            debtorPersonId: forOthers ? id(301) : nil,
            reimbursementStatus: forOthers ? .expected : nil,
            eventId: dice.chance(30) ? id(400) : nil))
      }
      let amount = AmountE4.sum(parts.map(\.amountE4))
      let account = dice.pick(accounts)
      let leg: (CurrencyCode, AmountE4)? =
        account.holds(currency) ? nil : (account.mainCurrency, dice.amount(upTo: 90_000))
      result.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(number), kind: kind, occurredAt: at, currency: currency, amountE4: amount,
            rate: currency == .rub ? nil : 90, placeId: dice.chance(40) ? id(500) : nil,
            paymentMethodId: account.id, accountCurrency: leg?.0, accountAmountE4: leg?.1,
            debtId: kind == .expense && dice.chance(10) ? id(200) : nil, createdAt: at,
            updatedAt: at),
          parts: parts))
    }
    return result
  }

  func edits(_ dice: inout MoneyDice) -> [BulkEdit] {
    [
      .category(
        dice.pick([categories.groceries, categories.fuel, categories.bonus, categories.goals])),
      .refile(from: [categories.groceries, categories.fuel], to: categories.pharmacy),
      .quality(dice.pick(Quality.allCases)),
      .forWhom(dice.pick(ForWhom.allCases)),
      .forPerson(id(302)),
      .event(dice.chance(50) ? id(401) : nil),
      .place(dice.chance(50) ? id(501) : nil),
      .paymentMethod(dice.pick([card.id, cash.id, tenge.id])),
    ]
  }

  func apply(_ edit: BulkEdit, _ entries: [TransactionEntry]) -> BulkEditPlan {
    BulkEditRule.plan(
      edit, entries: entries, tree: categories.tree, accounts: accounts, rates: rates,
      calendar: .utc)
  }

  /// Undo of any change gives every operation back exactly as it was.
  @Test(arguments: Array(1...30) as [UInt64])
  func undoGivesBackExactlyWhatWasThere(seed: UInt64) {
    var dice = MoneyDice(seed: seed &+ 1000)
    let entries = operations(seed: seed)
    let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    for edit in edits(&dice) {
      for changed in apply(edit, entries).changed {
        guard let original = byId[changed.id] else { continue }
        #expect(BulkEditRule.revert(changed, to: original) == original, "seed \(seed), \(edit)")
      }
    }
  }

  /// A change made a second time finds nothing more to do.
  @Test(arguments: Array(1...30) as [UInt64])
  func aSecondTimeChangesNothing(seed: UInt64) {
    var dice = MoneyDice(seed: seed &+ 2000)
    let entries = operations(seed: seed)
    for edit in edits(&dice) {
      let once = apply(edit, entries)
      let twice = apply(edit, once.changed)
      #expect(twice.changed.isEmpty, "seed \(seed), \(edit)")
    }
  }

  /// A change never gives an operation what its kind does not have — income no place, event or
  /// person; money back no category, quality, place or event —, never touches the money, and
  /// never takes an operation off its account.
  @Test(arguments: Array(1...30) as [UInt64])
  func aChangeKeepsToWhatTheKindHas(seed: UInt64) {
    var dice = MoneyDice(seed: seed &+ 3000)
    let entries = operations(seed: seed)
    let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    for edit in edits(&dice) {
      for changed in apply(edit, entries).changed {
        guard let original = byId[changed.id] else { continue }
        let transaction = changed.transaction
        #expect(transaction.amountE4 == original.transaction.amountE4)
        #expect(transaction.amountRubE4 == original.transaction.amountRubE4)
        #expect(changed.parts.map(\.amountE4) == original.parts.map(\.amountE4))
        #expect(changed.parts.map(\.reimbursable) == original.parts.map(\.reimbursable))
        #expect(transaction.paymentMethodId != nil)
        switch transaction.kind {
        case .income:
          #expect(transaction.placeId == original.transaction.placeId, "seed \(seed), \(edit)")
          for (now, was) in zip(changed.parts, original.parts) {
            #expect(now.eventId == was.eventId && now.forWhom == was.forWhom, "seed \(seed)")
            #expect(now.forPersonId == was.forPersonId, "seed \(seed)")
            #expect(now.quality == nil, "seed \(seed): income is not rated")
          }
        case .reimbursement:
          #expect(transaction.placeId == original.transaction.placeId, "seed \(seed), \(edit)")
          #expect(changed.parts.map(\.categoryId) == original.parts.map(\.categoryId))
          #expect(changed.parts.map(\.eventId) == original.parts.map(\.eventId))
          #expect(changed.parts.map(\.quality) == original.parts.map(\.quality))
        case .expense, .refund:
          break
        }
        // What an account is charged: nothing on one that holds the currency, its main
        // currency on any other.
        if case .paymentMethod(let accountId) = edit,
          let account = accounts.first(where: { $0.id == accountId })
        {
          if account.holds(transaction.currency)
            || KindFields.isGoalOnly(changed, tree: categories.tree)
          {
            #expect(transaction.accountCurrency == nil && transaction.accountAmountE4 == nil)
          } else {
            #expect(transaction.accountCurrency == account.mainCurrency, "seed \(seed)")
            #expect((transaction.accountAmountE4?.raw ?? 0) > 0, "seed \(seed)")
          }
        }
      }
    }
  }
}
