import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Мне должны» and «Списать остаток» on random books: purchases with parts paid for other
/// people in every status, money back live and deleted, links to money back the caller did not
/// pass — against a plain model.
@Suite("Owed to me and what is left written off, against a model")
struct OwedToMePropertyTests {
  let categories = StartingCategories()

  struct Book {
    var entries: [TransactionEntry] = []
    var links: [ReimbursementLink] = []
  }

  func book(seed: UInt64) -> Book {
    var dice = MoneyDice(seed: seed)
    var book = Book()
    var owedParts: [TransactionPart] = []
    for number in 1...dice.int(3...25) {
      let at = moment("2026-02-01").addingTimeInterval(
        TimeInterval(dice.below(60) * 86_400 + dice.below(86_400)))
      switch dice.below(4) {
      case 0, 1:
        let parts = (0..<dice.int(1...3)).map { index in
          let forOthers = dice.chance(60)
          let amount = dice.amount(upTo: 5000)
          return TransactionPart(
            id: id(number * 10 + index), transactionId: id(number),
            categoryId: categories.groceries, amountE4: amount,
            amountRubE4: dice.chance(30) ? MoneyDice.rounded(amount.decimal * 90) : amount,
            forWhom: forOthers ? .friends : .me, reimbursable: forOthers,
            debtorPersonId: forOthers ? id(300) : nil,
            reimbursementStatus: forOthers
              ? dice.pick([nil, .expected, .expected, .returned, .writtenOff]) : nil)
        }
        owedParts += parts.filter(\.reimbursable)
        book.entries.append(
          TransactionEntry(
            transaction: Transaction(
              id: id(number), kind: dice.chance(85) ? .expense : .refund, occurredAt: at,
              amountE4: AmountE4.sum(parts.map(\.amountE4)), paymentMethodId: id(1),
              createdAt: at, updatedAt: at, deletedAt: dice.chance(10) ? at : nil),
            parts: parts))
      default:
        let amount = dice.amount(upTo: 3000)
        let known = dice.chance(85)
        if known {
          book.entries.append(
            TransactionEntry(
              transaction: Transaction(
                id: id(number), kind: dice.chance(90) ? .reimbursement : .income, occurredAt: at,
                amountE4: amount, paymentMethodId: id(1), createdAt: at, updatedAt: at,
                deletedAt: dice.chance(20) ? at : nil),
              parts: [TransactionPart(transactionId: id(number), amountE4: amount)]))
        }
        guard !owedParts.isEmpty else { continue }
        let part = dice.pick(owedParts)
        book.links.append(
          ReimbursementLink(
            id: id(90_000 + number), reimbursementTxId: id(number), partId: part.id,
            amountE4: AmountE4(raw: Int64(dice.int(1...Int(part.amountRubE4.raw))))))
      }
    }
    return book
  }

  /// Each part paid for somebody else of a live purchase, still waiting — no status or
  /// `expected` —, with what came back through links of live money back — a link whose money back
  /// the caller did not pass counts as given — and what is left above zero; oldest first.
  @Test(arguments: Array(1...80) as [UInt64])
  func whatIsOwedIsEveryWaitingPartLessWhatCameBack(seed: UInt64) {
    let book = book(seed: seed)
    var gone: Set<UUID> = []
    for entry in book.entries
    where entry.transaction.isDeleted || entry.transaction.kind != .reimbursement {
      gone.insert(entry.id)
    }
    var expected: [(at: Date, part: TransactionPart, back: AmountE4)] = []
    for entry in book.entries
    where !entry.transaction.isDeleted && entry.transaction.kind == .expense {
      for part in entry.parts
      where part.reimbursable && (part.reimbursementStatus ?? .expected) == .expected {
        let back = AmountE4.sum(
          book.links.filter { $0.partId == part.id && !gone.contains($0.reimbursementTxId) }
            .map(\.amountE4))
        guard part.amountRubE4 > back else { continue }
        expected.append((entry.transaction.occurredAt, part, back))
      }
    }
    expected.sort { ($0.at, $0.part.id.uuidString) < ($1.at, $1.part.id.uuidString) }
    let owed = MyExpensesRule.owedToMe(entries: book.entries, links: book.links)
    #expect(owed.map(\.partId) == expected.map(\.part.id), "seed \(seed)")
    #expect(owed.map(\.returnedRubE4) == expected.map(\.back), "seed \(seed)")
    #expect(
      owed.map(\.remainingRubE4) == expected.map { $0.part.amountRubE4 - $0.back }, "seed \(seed)")
    #expect(
      MyExpensesRule.totalOwedToMe(entries: book.entries, links: book.links)
        == AmountE4.sum(expected.map { $0.part.amountRubE4 - $0.back }), "seed \(seed)")
    // «Вручную…» works on what is still owed, in rubles.
    for part in owed {
      #expect(part.inRubles.amountE4 == part.remainingRubE4 && part.inRubles.currency == .rub)
    }
  }

  /// «Списать остаток» of any part still waiting: a purchase in rubles of exactly what is left,
  /// in the part's category, on the purchase's account, for the part's person, with the key
  /// `writeoff:<part>:<operation>`. It is my spending, and a line of the books — it moves no
  /// money, since that money left at the purchase.
  @Test(arguments: Array(1...80) as [UInt64])
  func whatIsLeftWrittenOffIsMySpendingThatMovesNoMoney(seed: UInt64) {
    let book = book(seed: seed)
    for part in MyExpensesRule.owedToMe(entries: book.entries, links: book.links) {
      let operation = id(70_000 + Int(seed))
      let entry = MoneyBack.remainderWriteOff(
        part: part, occurredAt: moment("2026-04-01"), operationId: operation,
        tree: categories.tree, now: moment("2026-04-01"))
      let transaction = entry.transaction
      #expect(transaction.kind == .expense && transaction.currency == .rub, "seed \(seed)")
      #expect(transaction.amountE4 == part.remainingRubE4, "seed \(seed)")
      #expect(entry.parts.map(\.amountRubE4) == [part.remainingRubE4], "seed \(seed)")
      #expect(entry.parts.map(\.categoryId) == [part.categoryId], "seed \(seed)")
      #expect(entry.parts.map(\.forPersonId) == [part.forPersonId ?? part.debtorPersonId])
      #expect(transaction.paymentMethodId == part.accountId, "seed \(seed)")
      #expect(
        transaction.externalId
          == "writeoff:\(part.partId.uuidString.lowercased()):\(operation.uuidString.lowercased())")
      #expect(OperationLink(externalId: transaction.externalId)?.isBookkeeping == true)
      #expect(
        MyExpensesRule.total(entries: [entry]) == part.remainingRubE4, "seed \(seed)")
      #expect(
        AccountBalances.movement(of: entry, mainId: id(1), tree: categories.tree) == nil,
        "seed \(seed)")
    }
  }
}
