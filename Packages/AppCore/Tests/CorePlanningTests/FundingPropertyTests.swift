import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Funding по валютам» and the figures of the snapshot that must be one on random books: the
/// money each account needs this month for the scheduled payments, in what the account holds,
/// and the goal reserve that three screens share.
@Suite("Funding by account and the shared figures on random books")
struct FundingPropertyTests {
  typealias Book = CashPlanPropertyTests.Book
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...24)

  struct Key: Hashable {
    var account: UUID?
    var currency: CurrencyCode
  }

  /// Every due date of this month from `next_date` on, where the money has to be: an unpaid
  /// one on the payment's account (the main one when it names none), in the payment's
  /// currency when the account holds it, else in the account's main currency at today's
  /// rates — or, without a rate, in its own currency; one paid by «Провести», or by an
  /// ordinary operation that matches it (`matches`), where its operation took the money from.
  /// Remaining = due − paid, never below zero.
  static func model(
    _ book: Book, matches: ScheduledMatches = .empty
  ) -> [Key: (due: AmountE4, paid: AmountE4, noRate: Bool)] {
    let month = Fx.today.monthKey
    let accounts = Dictionary(uniqueKeysWithValues: book.fx.accounts.map { ($0.id, $0) })
    func perUnit(_ currency: CurrencyCode) -> Decimal? {
      currency == .rub ? 1 : book.fx.rubPerUnit[currency]
    }
    var result: [Key: (due: AmountE4, paid: AmountE4, noRate: Bool)] = [:]
    func add(_ key: Key, due: AmountE4, paid: AmountE4, noRate: Bool = false) {
      var line = result[key] ?? (.zero, .zero, false)
      line.due += due
      line.paid += paid
      line.noRate = line.noRate || noRate
      result[key] = line
    }
    // Paid by «Провести»: every linked operation of a due of this month.
    for entry in book.fx.entries {
      guard
        case .scheduled(let paymentId, let due)? = OperationLink(
          externalId: entry.transaction.externalId),
        due.monthKey == month, book.fx.scheduled.contains(where: { $0.id == paymentId })
      else { continue }
      let moved = entry.transaction.movedMoney
      add(
        Key(account: entry.transaction.paymentMethodId ?? Fx.main, currency: moved.currency),
        due: moved.amount, paid: moved.amount)
    }
    for payment in book.fx.scheduled where payment.active {
      for due in PlanningListsPropertyTests.dues(of: payment, through: month.lastDay)
      where due >= month.firstDay && book.linked[payment.id]?.contains(due) != true {
        if let operation = matches.operation(for: payment.id, due),
          let entry = book.fx.entries.first(where: { $0.id == operation })
        {
          let moved = entry.transaction.movedMoney
          add(
            Key(account: entry.transaction.paymentMethodId ?? Fx.main, currency: moved.currency),
            due: moved.amount, paid: moved.amount)
          continue
        }
        let price = PlanningListsPropertyTests.price(book, payment, on: due)
        let accountId = payment.paymentMethodId ?? Fx.main
        guard let account = accounts[accountId], !account.holds(payment.currency) else {
          add(Key(account: accountId, currency: payment.currency), due: price, paid: .zero)
          continue
        }
        if let from = perUnit(payment.currency), let to = perUnit(account.mainCurrency),
          let converted = AccountRules.crossConvert(price, fromPerUnit: from, toPerUnit: to)
        {
          add(Key(account: accountId, currency: account.mainCurrency), due: converted, paid: .zero)
        } else {
          add(
            Key(account: accountId, currency: payment.currency), due: price, paid: .zero,
            noRate: true)
        }
      }
    }
    return result
  }

  @Test(arguments: seeds)
  func eachAccountNeedsWhatItsDueDatesAsk(_ seed: UInt64) {
    let book = Book(seed: seed)
    let funding = book.fx.snapshot().funding
    let model = Self.model(book)
    #expect(funding.count == model.count, "seed \(seed)")
    for line in funding {
      let expected = model[Key(account: line.paymentMethodId, currency: line.currency)]
      #expect(line.due == expected?.due, "seed \(seed): \(line.currency)")
      #expect(line.paid == expected?.paid, "seed \(seed)")
      #expect(line.remaining == max(.zero, line.due - line.paid))
      #expect(line.withoutRate == (expected?.noRate ?? false), "seed \(seed)")
    }
    // The main account first.
    if let first = funding.first, funding.contains(where: { $0.paymentMethodId == Fx.main }) {
      #expect(first.paymentMethodId == Fx.main, "seed \(seed)")
    }
  }

  /// The same with ordinary operations typed near the due dates: a due date one of them pays is
  /// money already taken from where that operation took it, not money still needed on the
  /// payment's account.
  @Test(arguments: seeds)
  func aDuePaidByAnOrdinaryOperationIsFundedWhereItWasPaid(_ seed: UInt64) {
    var book = Book(seed: seed)
    book.typeSomeDues(seed: seed)
    let snapshot = book.fx.snapshot()
    let model = Self.model(book, matches: snapshot.matches)
    #expect(snapshot.funding.count == model.count, "seed \(seed)")
    for line in snapshot.funding {
      let expected = model[Key(account: line.paymentMethodId, currency: line.currency)]
      #expect(line.due == expected?.due, "seed \(seed): \(line.currency)")
      #expect(line.paid == expected?.paid, "seed \(seed)")
      #expect(line.withoutRate == (expected?.noRate ?? false), "seed \(seed)")
    }
  }

  /// The books reach what funding is about: a due date of this month paid by an ordinary
  /// operation, and a payment in a currency the account of a group left out does not hold,
  /// funded in the account's own.
  @Test func theBooksReachEveryCaseOfFunding() {
    var matchedThisMonth = 0
    var foreignOnKazakhstan = 0
    for seed in Self.seeds {
      var book = Book(seed: seed)
      book.typeSomeDues(seed: seed)
      let snapshot = book.fx.snapshot()
      for payment in book.fx.scheduled {
        matchedThisMonth +=
          snapshot.matches.matchedDues(of: payment.id).keys.filter {
            $0.monthKey == Fx.today.monthKey
          }.count
      }
      foreignOnKazakhstan +=
        snapshot.funding.filter {
          $0.paymentMethodId == Fx.freedom && $0.currency == Fx.tenge
        }.count
    }
    #expect(matchedThisMonth >= 5)
    #expect(foreignOnKazakhstan >= 1)
  }

  /// The goal reserve of the snapshot, the goals of the planned month and the goal plans of the
  /// free sum through the end of the month are one figure.
  @Test(arguments: seeds)
  func theGoalReserveIsOneFigure(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.fx.snapshot()
    #expect(snapshot.goalReserve == snapshot.planned.goals, "seed \(seed)")
    #expect(snapshot.goalReserve == snapshot.freeMoney.plan.goalPlans, "seed \(seed)")
  }

  /// The free sum of the month the snapshot keeps is the one asked for the end of the month.
  @Test(arguments: seeds)
  func theMonthsFreeSumIsTheOneAskedForItsLastDay(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.fx.snapshot()
    let asked = snapshot.freeMoney(until: Fx.today.monthKey.lastDay, ledger: book.fx.ledger)
    #expect(asked == snapshot.freeMoney, "seed \(seed)")
    #expect(snapshot.freeMoney.until == Fx.today.monthKey.lastDay)
  }
}
