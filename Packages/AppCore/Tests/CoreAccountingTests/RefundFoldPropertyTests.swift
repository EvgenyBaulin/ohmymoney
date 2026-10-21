import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Random purchases — in rubles and in other currencies at random rates, split, some paid for
/// somebody else, some for a goal, on credit or on a debt — refunded through `RefundRules` the
/// way the app refunds them, whole or in parts, with rates edited and refunds deleted in
/// between.
private struct RefundBook {
  let categories = StartingCategories()
  let laptop = Debt(
    id: id(201), direction: .iOwe, type: .installment, name: "Laptop",
    paymentsAreExpenses: false, origin: .purchase)
  let loan = Debt(id: id(200), direction: .iOwe, type: .loan, name: "Loan")
  let start = moment("2026-01-01")
  var entries: [TransactionEntry] = []
  /// Purchase parts whose rate was edited after a refund: the stored rubles of their refunds lag.
  var edited: Set<UUID> = []
  var dice: MoneyDice
  private var next = 1000

  var debts: [UUID: Debt] { [laptop.id: laptop, loan.id: loan] }

  init(seed: UInt64, steps: Int = 90) {
    dice = MoneyDice(seed: seed)
    for _ in 0..<steps {
      switch dice.below(13) {
      case 0, 1, 2, 3: purchase()
      case 4, 5, 6: refund()
      case 7: editRate()
      case 8: deleteSomething()
      case 9: growPart()
      case 10: editRefundAmount()
      case 11: deletePurchaseUnderItsRefunds()
      default: refundOfNoPurchase()
      }
    }
  }

  mutating func number() -> Int {
    next += 1
    return next
  }

  mutating func someDay() -> Date {
    start.addingTimeInterval(TimeInterval(dice.below(120) * 86_400 + dice.below(86_400)))
  }

  mutating func purchase() {
    let number = number()
    let currency = dice.pick([CurrencyCode.rub, .rub, .usd, CurrencyCode("EUR")])
    let rate: Decimal? =
      currency == .rub ? nil : Decimal(dice.int(700_000...1_109_999)) / 10_000
    let count = dice.int(1...3)
    var parts: [TransactionPart] = []
    for index in 0..<count {
      let forGoal = dice.chance(10)
      let forOthers = !forGoal && dice.chance(12)
      parts.append(
        TransactionPart(
          id: id(number * 10 + index), transactionId: id(number),
          categoryId: forGoal ? categories.goalsTrip : categories.groceries,
          amountE4: currency == .rub ? dice.amount(upTo: 20_000) : dice.fineAmount(upTo: 900),
          forWhom: forOthers ? .friends : .me, reimbursable: forOthers,
          debtorPersonId: forOthers ? id(300) : nil,
          reimbursementStatus: forOthers
            ? dice.pick([ReimbursementStatus.expected, .returned, .writtenOff]) : nil))
    }
    let amount = AmountE4.sum(parts.map(\.amountE4))
    let rub = rate.map { MoneyDice.rounded(amount.decimal * $0) } ?? amount
    let shares = rub.allocated(proportionallyTo: parts.map(\.amountE4), outOf: amount)
    for index in parts.indices { parts[index].amountRubE4 = shares[index] }
    let debtRoll = dice.below(20)
    let at = someDay()
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .expense, occurredAt: at, currency: currency, amountE4: amount,
          rate: rate, amountRubE4: rub, paymentMethodId: id(1),
          debtId: debtRoll == 0 ? loan.id : nil, creditDebtId: debtRoll == 1 ? laptop.id : nil,
          createdAt: at, updatedAt: at),
        parts: parts))
  }

  var index: RefundIndex { RefundIndex(entries: entries, debts: debts) }

  /// A refund of a part that can still be refunded, made by `RefundRules` with the rubles it
  /// stores: «Вся сумма» or a part of what is left.
  mutating func refund() {
    let index = self.index
    var open: [(TransactionEntry, TransactionPart)] = []
    for entry in entries {
      for part in entry.parts
      where RefundRules.isRefundable(part: part, in: entry, tree: categories.tree)
        && RefundRules.remaining(part: part, index: index).raw > 0
      {
        open.append((entry, part))
      }
    }
    guard !open.isEmpty else { return purchase() }
    let (purchase, part) = dice.pick(open)
    let left = RefundRules.remaining(part: part, index: index)
    let amount: AmountE4? =
      dice.chance(40) ? nil : AmountE4(raw: Int64(dice.int(1...Int(left.raw))))
    let at = purchase.transaction.occurredAt.addingTimeInterval(
      TimeInterval(dice.int(1...60) * 86_400))
    do {
      let draft = try RefundRules.draft(
        refunding: part, of: purchase, amount: amount, occurredAt: at, accountId: nil,
        index: index, tree: categories.tree)
      let before = RefundRules.refundedBefore(part: part, index: index)
      let refund = try draft.materialize(id: id(number()), now: at) { taken in
        RefundRules.rubles(refundAmount: taken, part: part, refundedBefore: before)
      }
      entries.append(refund)
    } catch {
      Issue.record("a refund of what is left was refused: \(error)")
    }
  }

  /// The rate of a purchase in another currency edited: its rubles change, the stored rubles
  /// of its refunds do not.
  mutating func editRate() {
    let foreign = entries.indices.filter {
      entries[$0].transaction.kind == .expense && entries[$0].transaction.currency != .rub
        && !entries[$0].transaction.isDeleted
    }
    guard !foreign.isEmpty else { return }
    let position = dice.pick(foreign)
    var entry = entries[position]
    let rate = Decimal(dice.int(300_000...1_500_000)) / 10_000
    entry.transaction.rate = rate
    entry.transaction.amountRubE4 = MoneyDice.rounded(entry.transaction.amountE4.decimal * rate)
    let shares = entry.transaction.amountRubE4.allocated(
      proportionallyTo: entry.parts.map(\.amountE4), outOf: entry.transaction.amountE4)
    for index in entry.parts.indices {
      entry.parts[index].amountRubE4 = shares[index]
      edited.insert(entry.parts[index].id)
    }
    entries[position] = entry
  }

  /// A refund deleted — its money is no longer taken off the purchase — or a purchase with no
  /// live refund deleted.
  mutating func deleteSomething() {
    let index = self.index
    let candidates = entries.indices.filter { position in
      let entry = entries[position]
      guard !entry.transaction.isDeleted else { return false }
      if entry.transaction.kind == .refund { return true }
      return entry.parts.allSatisfy { index.refunds(ofPart: $0.id).isEmpty }
    }
    guard !candidates.isEmpty else { return }
    let position = dice.pick(candidates)
    entries[position].transaction.deletedAt = entries[position].transaction.occurredAt
  }

  /// A part of a live purchase made dearer — refunded whole or not before: a refund that took
  /// it all is partial now, and takes back its share of the new amount. The rubles of the whole
  /// purchase are worked out again, so in another currency its other parts' rubles move too.
  mutating func growPart() {
    let purchases = entries.indices.filter {
      entries[$0].transaction.kind == .expense && !entries[$0].transaction.isDeleted
    }
    guard !purchases.isEmpty else { return }
    let position = dice.pick(purchases)
    var entry = entries[position]
    let partIndex = dice.below(entry.parts.count)
    let more =
      entry.transaction.currency == .rub ? dice.amount(upTo: 3000) : dice.fineAmount(upTo: 200)
    entry.parts[partIndex].amountE4 += more
    entry.transaction.amountE4 += more
    let rate = entry.transaction.rate ?? 1
    entry.transaction.amountRubE4 =
      entry.transaction.currency == .rub
      ? entry.transaction.amountE4 : MoneyDice.rounded(entry.transaction.amountE4.decimal * rate)
    let shares = entry.transaction.amountRubE4.allocated(
      proportionallyTo: entry.parts.map(\.amountE4), outOf: entry.transaction.amountE4)
    for index in entry.parts.indices {
      entry.parts[index].amountRubE4 = shares[index]
      if entry.transaction.currency != .rub { edited.insert(entry.parts[index].id) }
    }
    entries[position] = entry
  }

  /// The amount of a live refund taken back from a live purchase edited to anything from a unit
  /// to what is left of the part with the refund's own amount put back — what the editor lets
  /// through; its stored rubles are worked out again the way the editor does.
  mutating func editRefundAmount() {
    let index = self.index
    let parts = purchaseParts
    let refunds = entries.indices.filter { position in
      let entry = entries[position]
      guard !entry.transaction.isDeleted, entry.transaction.kind == .refund,
        let target = entry.parts.first?.refundOfPartId
      else { return false }
      return parts[target] != nil
    }
    guard !refunds.isEmpty else { return }
    let position = dice.pick(refunds)
    var entry = entries[position]
    guard let target = entry.parts[0].refundOfPartId, let purchase = parts[target] else { return }
    let own = entry.parts[0].amountE4
    let ownRub = entry.parts[0].amountRubE4
    let others = index.refunded(part: target) - own
    let limit = purchase.part.amountE4 - others
    guard limit.raw > 0 else { return }
    let amount = AmountE4(raw: Int64(dice.int(1...Int(limit.raw))))
    let rubles = RefundRules.rubles(
      refundAmount: amount, part: purchase.part,
      refundedBefore: (others, index.refundedStoredRub(part: target) - ownRub))
    entry.parts[0].amountE4 = amount
    entry.parts[0].amountRubE4 = rubles
    entry.transaction.amountE4 = amount
    entry.transaction.amountRubE4 = rubles
    entries[position] = entry
  }

  /// A purchase deleted under its live refunds — the app refuses that, but the index must be
  /// right however the rows got there: the refunds count on their own, on their own days.
  mutating func deletePurchaseUnderItsRefunds() {
    let index = self.index
    let candidates = entries.indices.filter { position in
      let entry = entries[position]
      return !entry.transaction.isDeleted && entry.transaction.kind == .expense
        && entry.parts.contains { !index.refunds(ofPart: $0.id).isEmpty }
    }
    guard !candidates.isEmpty else { return }
    let position = dice.pick(candidates)
    entries[position].transaction.deletedAt = entries[position].transaction.occurredAt
  }

  /// «Без покупки»: a refund of its own, counted on its own day.
  mutating func refundOfNoPurchase() {
    let number = number()
    let amount = dice.amount(upTo: 3000)
    let at = someDay()
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .refund, occurredAt: at, amountE4: amount, paymentMethodId: id(1),
          createdAt: at, updatedAt: at),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: categories.groceries,
            amountE4: amount)
        ]))
  }

  // MARK: The model's answers

  var live: [TransactionEntry] { entries.filter { !$0.transaction.isDeleted } }

  /// Purchase parts of live purchases, by id.
  var purchaseParts: [UUID: (entry: TransactionEntry, part: TransactionPart)] {
    var result: [UUID: (TransactionEntry, TransactionPart)] = [:]
    for entry in live where entry.transaction.kind == .expense {
      for part in entry.parts { result[part.id] = (entry, part) }
    }
    return result
  }

  /// What live refunds took back from each live purchase part, in its currency.
  var refunded: [UUID: AmountE4] {
    let parts = purchaseParts
    var result: [UUID: AmountE4] = [:]
    for entry in live where entry.transaction.kind == .refund {
      for part in entry.parts {
        guard let target = part.refundOfPartId, parts[target] != nil else { continue }
        result[target, default: .zero] += part.amountE4
      }
    }
    return result
  }

  /// Whether a part of a live purchase is my spending: not paid for somebody else unless
  /// written off, not a payment on a debt whose payments are no expense, not a purchase on a
  /// debt that records its payments as expenses.
  func isMine(_ part: TransactionPart, in transaction: Transaction) -> Bool {
    if let debt = transaction.debtId.flatMap({ debts[$0] }), !DebtRules.paymentIsExpense(on: debt) {
      return false
    }
    if let debt = transaction.creditDebtId.flatMap({ debts[$0] }),
      DebtRules.paymentIsExpense(on: debt)
    {
      return false
    }
    return !part.reimbursable || part.reimbursementStatus == .writtenOff
  }

  /// My spending of each live part, the fold of the refunds into their purchases included.
  var spending: [UUID: AmountE4] {
    let parts = purchaseParts
    let refunded = self.refunded
    var result: [UUID: AmountE4] = [:]
    for entry in live {
      for part in entry.parts {
        switch entry.transaction.kind {
        case .expense:
          guard isMine(part, in: entry.transaction) else {
            result[part.id] = .zero
            continue
          }
          let taken = refunded[part.id] ?? .zero
          result[part.id] =
            part.amountRubE4 - MoneyDice.share(part.amountRubE4, taken: taken, of: part.amountE4)
        case .refund:
          let linked = part.refundOfPartId.map { parts[$0] != nil } ?? false
          result[part.id] = linked ? .zero : -part.amountRubE4
        case .income, .reimbursement:
          result[part.id] = .zero
        }
      }
    }
    return result
  }
}

/// The fold of refunds into their purchases against a model, on random books.
@Suite("Refunds folded into their purchases, against a model")
struct RefundFoldPropertyTests {
  static let seeds: [UInt64] = Array(1...40)

  /// What each part had taken back, in its currency and in rubles — all of its rubles once the
  /// whole of it came back, whatever rate was edited since, otherwise its share, rounded once.
  @Test(arguments: seeds)
  func everyPartKnowsWhatWasTakenBackFromIt(seed: UInt64) {
    let book = RefundBook(seed: seed)
    let index = book.index
    let refunded = book.refunded
    for (partId, found) in book.purchaseParts {
      let taken = refunded[partId] ?? .zero
      let part = found.part
      #expect(index.refunded(part: partId) == taken, "seed \(seed)")
      #expect(
        index.refundedRub(part: partId)
          == (taken.isZero
            ? .zero : MoneyDice.share(part.amountRubE4, taken: taken, of: part.amountE4)),
        "seed \(seed)")
      #expect(
        RefundRules.remaining(part: part, index: index) == part.amountE4 - taken, "seed \(seed)")
      #expect(taken <= part.amountE4, "seed \(seed): more refunded than bought")
      if taken == part.amountE4 {
        #expect(index.refundedRub(part: partId) == part.amountRubE4, "seed \(seed)")
      }
    }
  }

  /// My spending of the whole book is my spending of every part, each purchase cheaper by what
  /// came back, a linked refund adding nothing, a refund of no purchase taking its own rubles off.
  @Test(arguments: seeds)
  func theTotalIsThePurchasesMadeCheaper(seed: UInt64) {
    let book = RefundBook(seed: seed)
    let expected = AmountE4.sum(book.spending.values)
    let totals = RowTotals(entries: book.entries, debts: book.debts, refunds: book.index)
    #expect(totals.myExpenses == expected, "seed \(seed)")
  }

  /// Any selection of operations adds up to the spending of its own parts — the purchases in it
  /// cheaper by refunds made on other days, the refunds in it adding nothing.
  @Test(arguments: seeds)
  func anySelectionAddsUpToItsOwnParts(seed: UInt64) {
    var book = RefundBook(seed: seed)
    let spending = book.spending
    let index = book.index
    for _ in 0..<8 {
      let chosen = book.entries.filter { _ in book.dice.chance(30) }
      let expected = AmountE4.sum(
        chosen.filter { !$0.transaction.isDeleted }.flatMap(\.parts).map {
          spending[$0.id] ?? .zero
        })
      let totals = RowTotals(entries: chosen, debts: book.debts, refunds: index)
      #expect(totals.myExpenses == expected, "seed \(seed)")
    }
  }

  /// A purchase refunded whole spends nothing, and the rubles its refunds store add up to its
  /// rubles exactly — unless its rate was edited after them, when only the fold stays exact.
  @Test(arguments: seeds)
  func aWholeRefundLeavesNothingAndStoresEveryRuble(seed: UInt64) {
    let book = RefundBook(seed: seed)
    let index = book.index
    let spending = book.spending
    for (partId, found) in book.purchaseParts
    where index.refunded(part: partId) == found.part.amountE4 {
      #expect(index.refundedRub(part: partId) == found.part.amountRubE4, "seed \(seed)")
      if book.isMine(found.part, in: found.entry.transaction) {
        #expect(spending[partId] == .zero, "seed \(seed)")
        let transaction = found.entry.transaction
        let part =
          MyExpensesRule.contribution(
            part: found.part, in: transaction,
            debt: transaction.debtId.flatMap { book.debts[$0] },
            creditDebt: transaction.creditDebtId.flatMap { book.debts[$0] })
          + index.movedContribution(part: partId)
        #expect(part == .zero, "seed \(seed)")
      }
      guard !book.edited.contains(partId) else { continue }
      let stored = AmountE4.sum(
        book.live.filter { $0.transaction.kind == .refund }.flatMap(\.parts)
          .filter { $0.refundOfPartId == partId }.map(\.amountRubE4))
      #expect(stored == found.part.amountRubE4, "seed \(seed)")
    }
  }

  /// Each part lists its live refunds oldest first, and each refund part knows its purchase.
  @Test(arguments: seeds)
  func theRefundsOfAPartAreListedOldestFirst(seed: UInt64) {
    let book = RefundBook(seed: seed)
    let index = book.index
    let parts = book.purchaseParts
    var expected: [UUID: [TransactionEntry]] = [:]
    for entry in book.live where entry.transaction.kind == .refund {
      for part in entry.parts {
        guard let target = part.refundOfPartId, parts[target] != nil else {
          #expect(!index.isLinked(refundPart: part.id), "seed \(seed)")
          continue
        }
        #expect(index.purchasePart(ofRefundPart: part.id) == target, "seed \(seed)")
        expected[target, default: []].append(entry)
      }
    }
    for (partId, refunds) in expected {
      let ordered = refunds.sorted {
        ($0.transaction.occurredAt, $0.id.uuidString) < (
          $1.transaction.occurredAt, $1.id.uuidString
        )
      }
      #expect(index.refunds(ofPart: partId) == ordered.map(\.id), "seed \(seed)")
    }
  }

  /// A refund never goes past what is left of its part: a unit more is refused, exactly what is
  /// left is taken, and «Вся сумма» is what is left.
  @Test(arguments: seeds)
  func aRefundStopsAtWhatIsLeft(seed: UInt64) throws {
    let book = RefundBook(seed: seed)
    let index = book.index
    for entry in book.live where entry.transaction.kind == .expense {
      for part in entry.parts
      where RefundRules.isRefundable(part: part, in: entry, tree: book.categories.tree) {
        let left = RefundRules.remaining(part: part, index: index)
        let over = AmountE4(raw: left.raw + 1)
        #expect(throws: RefundError.exceedsRemaining, "seed \(seed)") {
          try RefundRules.draft(
            refunding: part, of: entry, amount: over, occurredAt: entry.transaction.occurredAt,
            accountId: nil, index: index, tree: book.categories.tree)
        }
        guard left.raw > 0 else {
          #expect(throws: RefundError.exceedsRemaining, "seed \(seed)") {
            try RefundRules.draft(
              refunding: part, of: entry, amount: nil, occurredAt: entry.transaction.occurredAt,
              accountId: nil, index: index, tree: book.categories.tree)
          }
          continue
        }
        let whole = try RefundRules.draft(
          refunding: part, of: entry, amount: nil, occurredAt: entry.transaction.occurredAt,
          accountId: nil, index: index, tree: book.categories.tree)
        #expect(whole.amount == left, "seed \(seed)")
        #expect(whole.currency == entry.transaction.currency, "seed \(seed)")
        #expect(whole.rate == entry.transaction.rate, "seed \(seed)")
        #expect(whole.parts.map(\.refundOfPartId) == [part.id], "seed \(seed)")
        #expect(whole.paymentMethodId == entry.transaction.paymentMethodId, "seed \(seed)")
      }
    }
  }
}

/// The rubles a refund stores, when the purchase's rate was edited after earlier refunds.
@Suite("The rubles a refund stores")
struct RefundStoredRublesTests {
  let categories = StartingCategories()

  /// 100 dollars bought at 90 — 9 000 ₽ —, 90 dollars back, storing 8 100 ₽; then the owner
  /// corrects the purchase's rate to 50, and the part is 5 000 ₽. The last 10 dollars cannot
  /// store 5 000 − 8 100 = −3 100 ₽: a refund brings money back, and its rubles are never below
  /// zero. It stores its own share at the part's rate, 500 ₽; the purchase still comes to
  /// nothing, since the fold is worked out from the part.
  @Test func aRefundNeverStoresRublesBelowZero() {
    let part = TransactionPart(
      transactionId: id(1), categoryId: categories.groceries, amountE4: money(100),
      amountRubE4: money(5000))
    let rubles = RefundRules.rubles(
      refundAmount: money(10), part: part, refundedBefore: (money(90), money(8100)))
    #expect(rubles == money(500))
  }

  /// 100 dollars bought at 90 — 9 000 ₽ —, 50 dollars back, storing 4 500 ₽; then the rate of the
  /// purchase is corrected to 45, and the part is 4 500 ₽: nothing of its rubles is left for the
  /// other 50 dollars. Money came back, so the refund does not store 0 ₽: it stores its own share
  /// at the part's rate, 2 250 ₽.
  @Test func aRefundCompletingAPartWithNoRublesLeftStoresItsShare() {
    let part = TransactionPart(
      transactionId: id(1), categoryId: categories.groceries, amountE4: money(100),
      amountRubE4: money(4500))
    let rubles = RefundRules.rubles(
      refundAmount: money(50), part: part, refundedBefore: (money(50), money(4500)))
    #expect(rubles == money(2250))
  }

  /// Whatever was edited between them — rates, amounts of purchases and of refunds —, a refund
  /// of a part whose rubles are above zero stores rubles above zero.
  @Test(arguments: Array(1...40) as [UInt64])
  func everyRefundOfMoneyStoresRublesAboveZero(seed: UInt64) {
    let book = RefundBook(seed: seed)
    for entry in book.live where entry.transaction.kind == .refund {
      #expect(entry.transaction.amountRubE4.raw > 0, "seed \(seed)")
      for part in entry.parts { #expect(part.amountRubE4.raw > 0, "seed \(seed)") }
    }
  }

  /// Rates edited any way between refunds: no refund stores rubles below zero.
  @Test(arguments: Array(1...40) as [UInt64])
  func noRefundStoresRublesBelowZero(seed: UInt64) {
    let book = RefundBook(seed: seed)
    for entry in book.live where entry.transaction.kind == .refund {
      #expect(entry.transaction.amountRubE4.raw >= 0, "seed \(seed)")
      for part in entry.parts { #expect(part.amountRubE4.raw >= 0, "seed \(seed)") }
    }
  }
}
