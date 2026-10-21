import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The table of fields per kind, on random drafts with every field filled.
@Suite("Fields of each kind, on random drafts")
struct KindFieldsPropertyTests {
  let categories = StartingCategories()

  /// «+5000 $ цель отпуск» on a ruble card: income has no goal, so the goal goes to the note —
  /// and the income is income all the same, money onto the card, whose charge in rubles stays.
  /// Taking the charge away because the goal made it look like money for a goal leaves an
  /// income in dollars on a ruble card with nothing charged, which the save refuses.
  @Test func aGoalNamedOnIncomeDoesNotTakeItsChargeAway() {
    let draft = TransactionDraft(
      kind: .income, occurredAt: moment("2026-03-02"), currency: .usd, amount: money(5000),
      rate: 90, paymentMethodId: id(1), accountCurrency: .rub, accountAmount: money(450_000),
      parts: [PartDraft(categoryId: categories.salary, amount: money(5000), goalId: id(600))])
    let (stripped, toNote) = KindFields.stripped(
      draft, words: [.goal: ["цель", "отпуск"]], tree: categories.tree)
    #expect(stripped.parts.map(\.goalId) == [nil])
    #expect(toNote == ["цель", "отпуск"])
    #expect(stripped.accountCurrency == .rub)
    #expect(stripped.accountAmount == money(450_000))
  }

  /// Money back is never split: two parts become one. What the second part named that money
  /// back cannot have — an event here — goes to the note just like that of the first part,
  /// rather than vanishing with the part.
  @Test func aSplitMoneyBackLosesNoWordOfItsSecondPart() {
    let draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment("2026-03-02"), amount: money(500),
      paymentMethodId: id(1),
      parts: [
        PartDraft(amount: money(300), forPersonId: id(300)),
        PartDraft(amount: money(200), forPersonId: id(300), eventId: id(400)),
      ])
    let (stripped, toNote) = KindFields.stripped(
      draft, words: [.event: ["на", "свадьбу"]], tree: categories.tree)
    #expect(stripped.parts.count == 1)
    #expect(stripped.parts.first?.amount == money(500))
    #expect(stripped.parts.first?.eventId == nil)
    #expect(stripped.parts.first?.forPersonId == id(300))
    #expect(toNote == ["на", "свадьбу"])
  }

  /// A draft of `kind` with every field set, whatever the kind allows.
  func crowded(_ kind: TransactionKind, _ dice: inout MoneyDice) -> TransactionDraft {
    let parts = (0..<dice.int(1...3)).map { index in
      PartDraft(
        id: id(10 + index),
        categoryId: dice.pick([
          categories.groceries, categories.salary, categories.goalsTrip, categories.goals,
        ]),
        quality: dice.pick(Quality.allCases), qualitySource: .manual,
        amount: dice.amount(upTo: 900), forWhom: dice.pick([ForWhom.partner, .friends, .other]),
        forPersonId: id(300), reimbursable: true, debtorPersonId: id(301),
        reimbursementStatus: .expected, eventId: id(400), goalId: dice.chance(50) ? id(600) : nil,
        refundOfPartId: id(700 + index))
    }
    return TransactionDraft(
      kind: kind, occurredAt: moment("2026-03-02"), currency: .usd,
      amount: AmountE4.sum(parts.map(\.amount)), rate: 90, placeId: id(500),
      paymentMethodId: id(1), accountCurrency: .rub, accountAmount: dice.amount(upTo: 90_000),
      periodMonth: MonthKey(year: 2026, month: 3), debtId: id(200), creditDebtId: id(201),
      parts: parts)
  }

  /// What each field of the draft holds, by the field.
  func present(_ draft: TransactionDraft) -> Set<OperationField> {
    var fields: Set<OperationField> = [.account, .note]
    if draft.accountCurrency != nil || draft.accountAmount != nil { fields.insert(.accountCharge) }
    if draft.placeId != nil { fields.insert(.place) }
    if draft.creditDebtId != nil { fields.insert(.credit) }
    if draft.debtId != nil { fields.insert(.debt) }
    if draft.periodMonth != nil { fields.insert(.periodMonth) }
    if draft.parts.count > 1 { fields.insert(.split) }
    for part in draft.parts {
      if part.eventId != nil { fields.insert(.event) }
      if part.forWhom != .me { fields.insert(.forWhom) }
      if part.forPersonId != nil {
        fields.insert(draft.kind == .reimbursement ? .fromPerson : .forPerson)
      }
      if part.reimbursable { fields.insert(.reimbursable) }
      if part.debtorPersonId != nil { fields.insert(.debtor) }
      if part.goalId != nil { fields.insert(.goal) }
      if part.categoryId != nil { fields.insert(.category) }
      if part.quality != nil { fields.insert(.quality) }
      if part.refundOfPartId != nil { fields.insert(.refundOf) }
    }
    return fields
  }

  /// After stripping, a draft holds only fields its kind has — never one more; it keeps every
  /// field its kind has; the money stays whole; stripping again changes nothing; and the words
  /// of each field taken away go to the note, in the order of the fields.
  @Test(arguments: Array(1...40) as [UInt64])
  func strippingLeavesExactlyWhatTheKindHas(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    for kind in TransactionKind.allCases {
      let draft = crowded(kind, &dice)
      var words: [OperationField: [String]] = [:]
      for field in OperationField.allCases { words[field] = ["w-\(field.rawValue)"] }
      let (stripped, toNote) = KindFields.stripped(draft, words: words, tree: categories.tree)
      // Only a kind that has goals — a purchase, a refund — can be all goals: every part names a
      // goal or is filed under Goals. A goal named on income or on money back is a field that
      // kind does not have, and goes.
      let goalOnly =
        (kind == .expense || kind == .refund)
        && draft.parts.allSatisfy {
          $0.goalId != nil || $0.categoryId == categories.goals
            || $0.categoryId == categories.goalsTrip
        }
      // Money back keeps its person, as the person it came from, and its «на кого».
      let kept: Set<OperationField> = kind == .reimbursement ? [.fromPerson, .forWhom] : []
      let allowed = KindFields.fields(of: kind, goalOnly: goalOnly).union(kept)
      let left = present(stripped)
      #expect(left.isSubset(of: allowed), "seed \(seed), \(kind): \(left.subtracting(allowed))")
      let removed = present(draft).subtracting(allowed)
      #expect(present(draft).intersection(allowed).isSubset(of: left), "seed \(seed), \(kind)")
      #expect(stripped.amount == draft.amount, "seed \(seed), \(kind)")
      #expect(AmountE4.sum(stripped.parts.map(\.amount)) == draft.amount, "seed \(seed), \(kind)")
      #expect(
        toNote == OperationField.allCases.filter(removed.contains).map { "w-\($0.rawValue)" },
        "seed \(seed), \(kind)")
      let again = KindFields.stripped(stripped, words: words, tree: categories.tree)
      #expect(again.draft == stripped && again.toNote.isEmpty, "seed \(seed), \(kind)")
    }
  }

  /// Reading an operation hides from income what income cannot have and leaves every other
  /// kind exactly as stored; reading twice is reading once.
  @Test(arguments: Array(1...40) as [UInt64])
  func maskingHidesOnlyFromIncome(seed: UInt64) throws {
    var dice = MoneyDice(seed: seed)
    for kind in TransactionKind.allCases {
      let entry = try crowded(kind, &dice).materialize(id: id(1), now: moment("2026-03-02"))
      let masked = KindFields.masked(entry)
      #expect(KindFields.masked(masked) == masked, "seed \(seed), \(kind)")
      guard kind == .income else {
        #expect(masked == entry, "seed \(seed), \(kind)")
        continue
      }
      #expect(masked.transaction.placeId == nil && masked.transaction.creditDebtId == nil)
      #expect(masked.transaction.amountE4 == entry.transaction.amountE4)
      #expect(masked.transaction.paymentMethodId == entry.transaction.paymentMethodId)
      #expect(masked.transaction.debtId == entry.transaction.debtId)
      for (part, was) in zip(masked.parts, entry.parts) {
        #expect(part.eventId == nil && part.forWhom == .me && part.forPersonId == nil)
        #expect(!part.reimbursable && part.reimbursementStatus == nil && part.debtorPersonId == nil)
        #expect(part.amountE4 == was.amountE4 && part.categoryId == was.categoryId)
      }
    }
  }
}

/// What makes a transfer wrong, on random transfers between random accounts.
@Suite("Transfers checked against the rule")
struct TransferRulesPropertyTests {
  static let kzt = CurrencyCode("KZT")
  let accounts = [
    PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true),
    PaymentMethod(id: id(2), name: "Freedom", currency: kzt, otherCurrencies: [.rub, .usd]),
    PaymentMethod(id: id(3), name: "Old", currency: .rub, archived: true),
  ]

  /// The first thing wrong, in this order: nothing sent or received; the same key; an account
  /// archived or unknown; a currency the account does not hold, from before to; in one currency,
  /// the amounts differ. Anything else is a transfer.
  @Test(arguments: Array(1...200) as [UInt64])
  func theFirstThingWrongIsSaid(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let ids = [id(1), id(2), id(3), id(4)]
    let currencies = [CurrencyCode.rub, .usd, Self.kzt]
    let sent = dice.chance(10) ? AmountE4.zero : dice.amount(upTo: 1000)
    let transfer = Transfer(
      id: id(70), occurredAt: moment("2026-03-02"), fromAccountId: dice.pick(ids),
      fromCurrency: dice.pick(currencies), fromAmountE4: sent, toAccountId: dice.pick(ids),
      toCurrency: dice.pick(currencies),
      toAmountE4: dice.chance(50) ? sent : dice.chance(10) ? .zero : dice.amount(upTo: 1000))
    let byId = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    let expected: TransferIssue?
    if transfer.fromAmountE4.raw <= 0 || transfer.toAmountE4.raw <= 0 {
      expected = .notPositive
    } else if transfer.from == transfer.to {
      expected = .sameKey
    } else if let from = byId[transfer.fromAccountId], let to = byId[transfer.toAccountId],
      !from.archived, !to.archived
    {
      if !from.holds(transfer.fromCurrency) {
        expected = .currencyNotHeld(.from)
      } else if !to.holds(transfer.toCurrency) {
        expected = .currencyNotHeld(.to)
      } else if transfer.fromCurrency == transfer.toCurrency,
        transfer.fromAmountE4 != transfer.toAmountE4
      {
        expected = .amountsDiffer
      } else {
        expected = nil
      }
    } else {
      expected = .archivedAccount
    }
    #expect(TransferRules.validate(transfer, accounts: accounts) == expected, "seed \(seed)")
  }

  /// The fee of any transfer is a purchase of the fee, from the account and in the currency the
  /// money left, at the moment of the transfer, in the fee category; its key points back at the
  /// transfer and nothing else.
  @Test(arguments: Array(1...40) as [UInt64])
  func theFeeLeavesWithTheMoney(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let categories = StartingCategories()
    let transfer = Transfer(
      id: id(dice.int(70...90)),
      occurredAt: moment("2026-03-02").addingTimeInterval(
        TimeInterval(dice.below(86_400))), fromAccountId: id(2), fromCurrency: .usd,
      fromAmountE4: dice.amount(upTo: 900), toAccountId: id(1), toCurrency: .rub,
      toAmountE4: dice.amount(upTo: 90_000))
    let fee = dice.amount(upTo: 30)
    let draft = TransferRules.feeDraft(
      transfer: transfer, fee: fee, categoryId: categories.fees, tree: categories.tree)
    #expect(draft.kind == .expense && draft.amount == fee && draft.currency == .usd)
    #expect(draft.paymentMethodId == id(2) && draft.occurredAt == transfer.occurredAt)
    #expect(draft.parts.map(\.categoryId) == [categories.fees])
    #expect(draft.parts.map(\.quality) == [.bad])
    #expect(
      OperationLink(externalId: TransferRules.feeKey(of: transfer.id)) == .transferFee(transfer.id))
    #expect(
      OperationLink(externalId: TransferRules.feeKey(of: transfer.id))?.isBookkeeping == false)
  }
}

/// The order of the accounts in every menu and in the sidebar, on random sets of accounts.
@Suite("The order of the accounts, on random sets")
struct AccountOrderPropertyTests {
  static let names = [
    "Сбер", "сбер плюс", "Т-Банк", "Альфа", "ВТБ", "Kaspi", "halyk", "Freedom",
    "Ёлка", "Наличные", "альфа", "Озон",
  ]

  func accounts(_ dice: inout MoneyDice) -> ([PaymentMethod], [AccountGroup]) {
    let groups = [
      AccountGroup(id: id(90), name: "Россия", sort: dice.int(0...2)),
      AccountGroup(id: id(91), name: "Казахстан", inSummary: false, sort: dice.int(0...2)),
      AccountGroup(id: id(92), name: "Архив", archived: true),
    ]
    let count = dice.int(1...9)
    let mainIndex = dice.below(count)
    let accounts = (0..<count).map { index in
      PaymentMethod(
        id: id(index + 1), name: dice.pick(Self.names), isDefault: index == mainIndex,
        archived: index != mainIndex && dice.chance(15),
        groupId: dice.chance(60) ? dice.pick([id(90), id(91), id(92), id(93)]) : nil,
        sort: dice.chance(30) ? dice.int(0...4) : 0)
    }
    // The main account never sits in a group left out of the summary.
    let fixed = accounts.map { account in
      var account = account
      if account.isDefault, account.groupId == id(91) { account.groupId = nil }
      return account
    }
    return (fixed, groups)
  }

  /// Every live account once, the main one first, then by the place dragged to and the name;
  /// the order never depends on the order they came in.
  @Test(arguments: Array(1...100) as [UInt64])
  func theMainAccountLeadsAndTheRestFollowTheirPlaceAndName(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let (accounts, _) = accounts(&dice)
    let locale = Locale(identifier: "ru_RU")
    let ordered = AccountRules.ordered(accounts, locale: locale)
    #expect(Set(ordered.map(\.id)) == Set(accounts.filter { !$0.archived }.map(\.id)))
    #expect(ordered.count == accounts.filter { !$0.archived }.count)
    #expect(ordered.first?.isDefault == true, "seed \(seed)")
    #expect(
      AccountRules.ordered(dice.shuffled(accounts), locale: locale) == ordered, "seed \(seed)")
    for (left, right) in zip(ordered.dropFirst(), ordered.dropFirst(2)) {
      #expect(left.sort <= right.sort, "seed \(seed)")
      if left.sort == right.sort {
        #expect(
          left.name.compare(right.name, options: [.caseInsensitive], range: nil, locale: locale)
            != .orderedDescending, "seed \(seed)")
      }
    }
    #expect(
      AccountRules.ordered(AccountRules.alphabetized(accounts), locale: locale).dropFirst()
        .map(\.sort).allSatisfy { $0 == 0 })
  }

  /// The sidebar lists every live account exactly once: the main account first of all, the
  /// groups left out of the summary last, an archived or unknown group as no group.
  @Test(arguments: Array(1...100) as [UInt64])
  func theSidebarListsEveryLiveAccountOnce(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let (accounts, groups) = accounts(&dice)
    let sections = AccountRules.sidebarSections(
      accounts: accounts, groups: groups, locale: Locale(identifier: "ru_RU"))
    let listed = sections.flatMap(\.accounts)
    #expect(listed.count == Set(listed.map(\.id)).count, "seed \(seed)")
    #expect(
      Set(listed.map(\.id)) == Set(accounts.filter { !$0.archived }.map(\.id)), "seed \(seed)")
    #expect(listed.first?.isDefault == true, "seed \(seed)")
    let inSummary = sections.map { $0.group?.inSummary ?? true }
    #expect(inSummary == inSummary.sorted { $0 && !$1 }, "seed \(seed): left out last")
    for section in sections {
      #expect(section.group?.archived != true, "seed \(seed)")
      #expect(!section.accounts.isEmpty || section.group != nil, "seed \(seed)")
      for account in section.accounts {
        let live = groups.first { $0.id == account.groupId && !$0.archived }
        #expect(section.group?.id == live?.id, "seed \(seed)")
      }
    }
  }
}
