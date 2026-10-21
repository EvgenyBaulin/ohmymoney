import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A change made to many operations at once, against a model of the table of what each kind
/// takes: every operation either comes out changed to the new value, or is skipped with the
/// reason the table gives, or already had the value — nothing is lost quietly. What an account
/// is charged is worked out by the model too.
@Suite("Bulk changes against a model of the table")
struct BulkEditModelPropertyTests {
  // A small tree of its own, so the model knows which categories are the app's and which are
  // retired without asking the code.
  static let goals = id(100)
  static let goalsTrip = id(101)
  static let loans = id(102)
  static let loansCar = id(103)
  static let groceries = id(110)
  static let fuel = id(116)
  static let car = id(114)
  static let pharmacy = id(113)
  static let salary = id(119)
  static let bonus = id(120)
  static let old = id(130)
  static let oldChild = id(131)
  static let bakery = id(132)

  /// The categories that belong to the app: Goals and Loans with everything under them.
  static let system: Set<UUID> = [goals, goalsTrip, loans, loansCar]
  static let goalCategories: Set<UUID> = [goals, goalsTrip]
  static let incomeCategories: Set<UUID> = [salary, bonus]
  /// Archived, or under an archived parent.
  static let retired: Set<UUID> = [old, oldChild]

  let tree = CategoryTree([
    CoreKit.Category(id: goals, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
    CoreKit.Category(id: goalsTrip, parentId: goals, kind: .expense, name: "Trip"),
    CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
    CoreKit.Category(id: loansCar, parentId: loans, kind: .expense, name: "Car loan"),
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(id: car, kind: .expense, name: "Car", quality: .neutral),
    CoreKit.Category(id: fuel, parentId: car, kind: .expense, name: "Fuel"),
    CoreKit.Category(id: pharmacy, kind: .expense, name: "Pharmacy", quality: .good),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    CoreKit.Category(id: bonus, parentId: salary, kind: .income, name: "Bonus"),
    CoreKit.Category(id: old, kind: .expense, name: "Old", archived: true),
    CoreKit.Category(id: oldChild, parentId: old, kind: .expense, name: "Old child"),
    CoreKit.Category(id: bakery, parentId: groceries, kind: .expense, name: "Bakery"),
  ])

  static let kzt = CurrencyCode("KZT")
  static let gel = CurrencyCode("GEL")
  let card = PaymentMethod(id: id(82), name: "Card", currency: .rub, isDefault: true)
  let cash = PaymentMethod(id: id(83), name: "Cash", kind: .cash, currency: .usd)
  let tenge = PaymentMethod(id: id(84), name: "Tenge", currency: kzt)
  /// An account in a currency the bank has no rate for.
  let lari = PaymentMethod(id: id(85), name: "Lari", currency: gel)
  var accounts: [PaymentMethod] { [card, cash, tenge, lari] }
  /// Rubles for one unit on every day: the dollar at 90, the tenge at 0.18; no euro, no lari.
  static let dayRate: [CurrencyCode: Decimal] = [.usd: 90, kzt: Decimal(18) / 100]
  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 1, day: 1), perUnit: 90)],
    kzt: [DayRate(day: DateOnly(year: 2026, month: 1, day: 1), perUnit: Decimal(18) / 100)],
  ])

  // MARK: Random operations

  func operations(seed: UInt64) -> [TransactionEntry] {
    var dice = MoneyDice(seed: seed)
    var result: [TransactionEntry] = []
    for number in 1...40 {
      let kind = dice.pick(TransactionKind.allCases)
      let currency = dice.pick([CurrencyCode.rub, .rub, .usd, .eur])
      // The operation's own rate is not the bank's rate of the day: a refund's account is
      // charged at the day's rate, everything else at the operation's own.
      let rate: Decimal? =
        switch currency {
        case .rub: nil
        case .usd: Decimal(dice.int(8_500...9_500)) / 100
        default: Decimal(dice.int(9_500...10_500)) / 100
        }
      let at = moment("2026-03-01").addingTimeInterval(TimeInterval(dice.below(30) * 86_400))
      let goalOnly = (kind == .expense || kind == .refund) && dice.chance(12)
      var parts: [TransactionPart] = []
      for index in 0..<(kind == .reimbursement ? 1 : dice.int(1...3)) {
        var category: UUID?
        var goal: UUID?
        switch kind {
        case .income: category = dice.pick([Self.salary, Self.bonus])
        case .reimbursement: category = nil
        case .expense, .refund:
          if goalOnly || dice.chance(10) {
            category = Self.goalsTrip
            goal = id(600)
          } else {
            category = dice.pick([
              Self.groceries, Self.fuel, Self.loansCar, Self.pharmacy, Self.car,
            ])
          }
        }
        let forOthers = kind == .expense && goal == nil && dice.chance(20)
        parts.append(
          TransactionPart(
            id: id(number * 10 + index), transactionId: id(number), categoryId: category,
            categorySource: dice.pick([CategorySource.manual, .model, .history]),
            quality: kind.hasQuality && dice.chance(50) ? dice.pick(Quality.allCases) : nil,
            qualitySource: kind.hasQuality && dice.chance(50)
              ? dice.pick([QualitySource.manual, .category]) : nil,
            amountE4: dice.amount(upTo: 900), forWhom: dice.pick(ForWhom.allCases),
            forPersonId: dice.chance(30) ? id(dice.pick([302, 303])) : nil,
            reimbursable: forOthers, debtorPersonId: forOthers ? id(301) : nil,
            reimbursementStatus: forOthers ? .expected : nil,
            eventId: dice.chance(40) ? id(dice.pick([400, 401])) : nil, goalId: goal,
            refundOfPartId: kind == .refund && goal == nil && dice.chance(50)
              ? id(900 + index) : nil))
      }
      let amount = AmountE4.sum(parts.map(\.amountE4))
      let rub = rate.map { MoneyDice.rounded(amount.decimal * $0) } ?? amount
      let shares = rub.allocated(proportionallyTo: parts.map(\.amountE4), outOf: amount)
      for index in parts.indices { parts[index].amountRubE4 = shares[index] }
      let account = dice.pick(accounts)
      let leg: (CurrencyCode, AmountE4)? =
        account.holds(currency) ? nil : (account.mainCurrency, dice.amount(upTo: 90_000))
      result.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(number), kind: kind, occurredAt: at, currency: currency, amountE4: amount,
            rate: rate, amountRubE4: rub, placeId: dice.chance(40) ? id(500) : nil,
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
        dice.pick([
          Self.groceries, Self.fuel, Self.bonus, Self.goals, Self.old, Self.oldChild,
          Self.bakery, id(999),
        ])),
      .category(dice.pick([Self.salary, Self.pharmacy, Self.loansCar])),
      .refile(from: [Self.groceries, Self.fuel, Self.loansCar], to: Self.pharmacy),
      .quality(dice.pick(Quality.allCases)),
      .forWhom(dice.pick(ForWhom.allCases)),
      .forPerson(id(dice.pick([302, 304]))),
      .event(dice.chance(50) ? id(401) : nil),
      .place(dice.chance(50) ? id(500) : nil),
      .paymentMethod(card.id), .paymentMethod(cash.id), .paymentMethod(tenge.id),
      .paymentMethod(lari.id),
    ]
  }

  // MARK: The model

  enum Expected {
    /// The operation stays as it is, for this reason.
    case skip(BulkSkipReason)
    /// The operation with the change the model makes; `kept` names why some parts stay.
    case apply(TransactionEntry, kept: BulkSkipReason?)
  }

  func isGoalPart(_ part: TransactionPart) -> Bool {
    part.goalId != nil || part.categoryId.map(Self.goalCategories.contains) == true
  }

  /// Why the whole operation cannot take the change, by the table.
  func operationRefusal(_ edit: BulkEdit, _ transaction: Transaction) -> BulkSkipReason? {
    let kind = transaction.kind
    switch edit {
    case .category(let target), .refile(_, let target):
      if kind == .reimbursement { return .moneyReturned }
      if transaction.debtId != nil { return .debtPayment }
      let known =
        [
          Self.goals, Self.goalsTrip, Self.loans, Self.loansCar, Self.groceries, Self.fuel,
          Self.car,
          Self.pharmacy, Self.salary, Self.bonus, Self.old, Self.oldChild, Self.bakery,
        ]
      if !known.contains(target) || Self.retired.contains(target) { return .retiredCategory }
      if Self.system.contains(target) { return .systemCategory }
      let isIncomeCategory = Self.incomeCategories.contains(target)
      if isIncomeCategory != (kind == .income) { return .otherKind }
      return nil
    case .quality:
      return kind == .expense || kind == .refund ? nil : .noQuality
    case .forWhom, .forPerson:
      if kind == .reimbursement { return .moneyReturned }
      if kind == .income { return .fieldNotForKind }
      return nil
    case .place:
      if kind == .income { return .incomeHasNoPlace }
      if kind == .reimbursement { return .fieldNotForKind }
      return nil
    case .event:
      return kind == .expense || kind == .refund ? nil : .fieldNotForKind
    case .paymentMethod:
      return nil
    }
  }

  /// Why one part the change reaches stays as it is.
  func partRefusal(_ edit: BulkEdit, _ part: TransactionPart) -> BulkSkipReason? {
    switch edit {
    case .category, .refile:
      if isGoalPart(part) { return .goalContribution }
      return part.categoryId.map(Self.system.contains) == true ? .systemCategory : nil
    case .quality:
      return isGoalPart(part) ? .goalContribution : nil
    case .forWhom, .forPerson:
      return part.reimbursable ? .paidForSomebodyElse : nil
    case .event, .place, .paymentMethod:
      return nil
    }
  }

  /// What the account is charged for the operation, in its main currency: nothing on an
  /// account that holds the currency, or for money that only goes to goals; a figure already in
  /// that currency stays; a refund taken back from a purchase at the day's rates; a figure in
  /// rubles is the operation's rubles; any other through rubles at the operation's own rate.
  /// `.none` when a rate is missing.
  func charge(
    of entry: TransactionEntry, on account: PaymentMethod
  ) -> (
    currency: CurrencyCode, amount: AmountE4
  )?? {
    let transaction = entry.transaction
    let goalOnly =
      (transaction.kind == .expense || transaction.kind == .refund)
      && entry.parts.allSatisfy(isGoalPart)
    if goalOnly { return .some(nil) }
    let held = [account.mainCurrency] + account.otherCurrencies
    if held.contains(transaction.currency) { return .some(nil) }
    let leg = account.mainCurrency
    if transaction.accountCurrency == leg, let kept = transaction.accountAmountE4 {
      return (leg, kept)
    }
    func perUnit(_ currency: CurrencyCode) -> Decimal? {
      currency == .rub ? 1 : Self.dayRate[currency]
    }
    let isRefund = transaction.kind == .refund && entry.parts.contains { $0.refundOfPartId != nil }
    let own: Decimal? =
      isRefund
      ? perUnit(transaction.currency)
      : transaction.currency == .rub ? 1 : transaction.rate
    if !isRefund, leg == .rub { return (leg, transaction.amountRubE4) }
    guard let own, let target = perUnit(leg) else { return nil }
    return (leg, MoneyDice.rounded(transaction.amountE4.decimal * own / target))
  }

  func expected(_ edit: BulkEdit, for entry: TransactionEntry) -> Expected {
    if let reason = operationRefusal(edit, entry.transaction) { return .skip(reason) }
    var target = entry
    switch edit {
    case .place(let place):
      target.transaction.placeId = place
      return .apply(target, kept: nil)
    case .paymentMethod(let accountId):
      guard let account = accounts.first(where: { $0.id == accountId }) else {
        return .apply(target, kept: nil)
      }
      target.transaction.paymentMethodId = accountId
      guard let charged = charge(of: entry, on: account) else { return .skip(.noRateForCharge) }
      target.transaction.accountCurrency = charged?.currency
      target.transaction.accountAmountE4 = charged?.amount
      return .apply(target, kept: nil)
    case .category, .refile, .quality, .forWhom, .forPerson, .event:
      var kept: BulkSkipReason?
      var reached = 0
      for index in target.parts.indices {
        if case .refile(let from, _) = edit,
          !(target.parts[index].categoryId.map(from.contains) ?? false)
        {
          continue
        }
        if let reason = partRefusal(edit, target.parts[index]) {
          kept = kept ?? reason
          continue
        }
        reached += 1
        switch edit {
        case .category(let category), .refile(_, let category):
          target.parts[index].categoryId = category
          target.parts[index].categorySource = .manual
        case .quality(let quality):
          target.parts[index].quality = quality
          target.parts[index].qualitySource = .manual
        case .forWhom(let forWhom):
          target.parts[index].forWhom = forWhom
          target.parts[index].forPersonId = nil
        case .forPerson(let person):
          target.parts[index].forPersonId = person
          if target.parts[index].forWhom == .me { target.parts[index].forWhom = .other }
        case .event(let event):
          target.parts[index].eventId = event
        case .place, .paymentMethod:
          break
        }
      }
      if reached == 0, let kept { return .skip(kept) }
      return .apply(target, kept: kept)
    }
  }

  /// The values the change sets are the same on both.
  func sameValues(_ edit: BulkEdit, _ left: TransactionEntry, _ right: TransactionEntry) -> Bool {
    switch edit {
    case .category, .refile:
      return left.parts.map(\.categoryId) == right.parts.map(\.categoryId)
        && left.parts.map(\.categorySource) == right.parts.map(\.categorySource)
    case .quality:
      return left.parts.map(\.quality) == right.parts.map(\.quality)
        && left.parts.map(\.qualitySource) == right.parts.map(\.qualitySource)
    case .forWhom, .forPerson:
      return left.parts.map(\.forWhom) == right.parts.map(\.forWhom)
        && left.parts.map(\.forPersonId) == right.parts.map(\.forPersonId)
    case .event:
      return left.parts.map(\.eventId) == right.parts.map(\.eventId)
    case .place:
      return left.transaction.placeId == right.transaction.placeId
    case .paymentMethod:
      return left.transaction.paymentMethodId == right.transaction.paymentMethodId
        && left.transaction.accountCurrency == right.transaction.accountCurrency
        && left.transaction.accountAmountE4 == right.transaction.accountAmountE4
    }
  }

  /// Every operation of a random list, under every change: changed to exactly the model's values
  /// and nothing else of the money, or skipped whole for the model's reason, or left alone because
  /// it already had them. Some parts kept are said once, with the first reason.
  @Test(arguments: Array(1...40) as [UInt64])
  func everyOperationIsChangedSkippedOrAlreadyThere(seed: UInt64) {
    var dice = MoneyDice(seed: seed &+ 7000)
    let entries = operations(seed: seed)
    for edit in edits(&dice) {
      let plan = BulkEditRule.plan(
        edit, entries: entries, tree: tree, accounts: accounts, rates: rates, calendar: .utc)
      let changed = Dictionary(uniqueKeysWithValues: plan.changed.map { ($0.id, $0) })
      let skipped = Dictionary(grouping: plan.skipped, by: \.transactionId)
      for entry in entries {
        let where_ = "seed \(seed), \(edit), operation \(entry.id.uuidString.suffix(3))"
        switch expected(edit, for: entry) {
        case .skip(let reason):
          #expect(changed[entry.id] == nil, "\(where_): changed, expected \(reason)")
          #expect(
            skipped[entry.id] == [BulkSkip(transactionId: entry.id, reason: reason)],
            "\(where_): \(String(describing: skipped[entry.id])), expected \(reason)")
        case .apply(let target, let kept):
          if sameValues(edit, target, entry) {
            // Already there. A new category may still bring a quality worked out anew.
            if let now = changed[entry.id] {
              #expect(
                edit.isCategoryChange && sameValues(edit, now, target),
                "\(where_): changed although the value was there")
            }
            #expect(
              skipped[entry.id]?.allSatisfy(\.isPartial) ?? true, "\(where_): skipped whole")
            continue
          }
          guard let now = changed[entry.id] else {
            Issue.record("\(where_): not changed, expected a change")
            continue
          }
          #expect(sameValues(edit, now, target), "\(where_): not the model's values")
          #expect(now.transaction.amountE4 == entry.transaction.amountE4, "\(where_)")
          #expect(now.transaction.amountRubE4 == entry.transaction.amountRubE4, "\(where_)")
          #expect(now.parts.map(\.amountE4) == entry.parts.map(\.amountE4), "\(where_)")
          #expect(now.parts.map(\.id) == entry.parts.map(\.id), "\(where_)")
          #expect(now.transaction.kind == entry.transaction.kind, "\(where_)")
          let partial = kept.map {
            [BulkSkip(transactionId: entry.id, reason: $0, isPartial: true)]
          }
          #expect(skipped[entry.id] == partial, "\(where_): kept parts \(String(describing: kept))")
        }
      }
    }
  }

  /// The generator reaches every reason of the table and every way a charge is worked out, so a
  /// green run above means something.
  @Test func theRandomListsReachEveryReason() {
    var reasons: Set<BulkSkipReason> = []
    var charges: Set<String> = []
    for seed in 1...40 as ClosedRange<UInt64> {
      var dice = MoneyDice(seed: seed &+ 7000)
      let entries = operations(seed: seed)
      for edit in edits(&dice) {
        for entry in entries {
          switch expected(edit, for: entry) {
          case .skip(let reason): reasons.insert(reason)
          case .apply(_, let kept):
            if let kept { reasons.insert(kept) }
            guard case .paymentMethod(let accountId) = edit,
              let account = accounts.first(where: { $0.id == accountId }),
              case .some(.some(let leg)) = charge(of: entry, on: account)
            else { continue }
            let isRefund = entry.parts.contains { $0.refundOfPartId != nil }
            if entry.transaction.accountCurrency == leg.currency {
              charges.insert("kept")
            } else {
              charges.insert("\(isRefund ? "refund" : "own") in \(leg.currency.code)")
            }
          }
        }
      }
    }
    let wanted: Set<BulkSkipReason> = [
      .otherKind, .retiredCategory, .moneyReturned, .debtPayment, .goalContribution,
      .systemCategory, .noQuality, .paidForSomebodyElse, .incomeHasNoPlace, .fieldNotForKind,
      .noRateForCharge,
    ]
    #expect(wanted.isSubset(of: reasons), "\(wanted.subtracting(reasons))")
    #expect(
      Set(["kept", "own in RUB", "own in USD", "own in KZT", "refund in RUB", "refund in KZT"])
        .isSubset(of: charges), "\(charges)")
  }
}

extension BulkEdit {
  /// A change of category — the one change that also works the quality out anew.
  fileprivate var isCategoryChange: Bool {
    switch self {
    case .category, .refile: true
    default: false
    }
  }
}
