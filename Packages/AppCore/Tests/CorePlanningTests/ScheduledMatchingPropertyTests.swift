import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Random books of scheduled payments and ordinary operations around their due dates, checked
/// against the rule of a match written out plainly: whatever the owner types, a due date is
/// paid once, an operation pays once, and every screen agrees on what is paid.
@Suite("Scheduled payments paid by ordinary operations: random books")
struct ScheduledMatchingPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...30)

  struct Book {
    var fx = CashFx()
    var rejections: Set<String> = []

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      let today = CashFx.today
      let categories: [UUID?] = [CashFx.housing, CashFx.rent, CashFx.fun, nil]
      for index in 0..<random.int(in: 1...4) {
        let weekly = random.chance(1, outOf: 3)
        let price = AmountE4(raw: Int64(random.int(in: 5...300)) * 1_000_000)
        let next = CashFx.day("2026-06-01").adding(days: random.int(in: 0...116))
        var payment = ScheduledPayment(
          id: CashFx.id(100 + index), name: "Bill \(index)", amountE4: price,
          categoryId: random.choice(from: categories), freq: weekly ? .weekly : .monthly,
          day: weekly ? next.weekday : next.day, nextDate: next)
        if random.chance(1, outOf: 6) { payment.endDate = next }
        fx.scheduled.append(payment)

        // Operations around the due dates: near and far, cheaper and dearer, in the category,
        // under it, elsewhere, with the name in the note or without.
        let dues = Recurrence.occurrences(
          from: next, through: today.adding(days: 5), rule: RecurrenceRule(payment: payment),
          end: payment.endDate)
        for due in dues {
          for _ in 0..<random.int(in: 0...2) {
            let day = due.adding(days: random.int(in: -7...7))
            let percent = random.int(in: -15...15)
            let amount = SubscriptionMath.rounded(
              price.decimal * Decimal(100 + percent) / 100)
            let category: UUID? =
              random.chance(2, outOf: 3)
              ? (payment.categoryId ?? CashFx.groceries) : random.choice(from: categories)
            let note = random.chance(1, outOf: 2) ? "paid \(payment.name.lowercased())" : nil
            let id = fx.add(
              random.chance(1, outOf: 12) ? .income : .expense, amount.decimal.description,
              at: CalendarContext.utc.startOfDay(day).addingTimeInterval(
                TimeInterval(random.int(in: 0...1_439) * 60)),
              category: category, note: note)
            if random.chance(1, outOf: 15) {
              fx.entries[fx.entries.count - 1].transaction.deletedAt = CashFx.now
            }
            if random.chance(1, outOf: 10) {
              rejections.insert(
                ScheduledMatching.rejectionKey(operation: id, payment: payment.id, due: due))
            }
          }
        }
      }
      fx.count([(CashFx.main, .rub, "1000000")], at: CashFx.at("2026-05-01", 9))
      fx.settings.scheduledMatchRejections = rejections
      fx.settings.reserveGoalPlan = false
    }

    var tree: CategoryTree { CategoryTree(CashFx.categories) }

    /// The rule, plainly: a live expense without a key, in the payment's category or under
    /// it — or, with no category, with the payment's name in its note —, in its currency
    /// within max(1 unit, 10 %) of the price, at most 5 days from the due date, not after
    /// today, and not dismissed for this payment.
    func canPay(_ entry: TransactionEntry, _ payment: ScheduledPayment, _ due: DateOnly) -> Bool {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense, transaction.externalId == nil,
        transaction.currency == payment.currency
      else { return false }
      let day = CalendarContext.utc.day(of: transaction.occurredAt)
      guard abs(day.days(to: due)) <= 5, day <= CashFx.today else { return false }
      let tolerance = max(
        AmountE4(whole: 1), SubscriptionMath.rounded(payment.amountE4.decimal / 10))
      guard (transaction.amountE4 - payment.amountE4).magnitude <= tolerance else { return false }
      if let category = payment.categoryId {
        let parts = entry.parts.compactMap(\.categoryId)
        guard parts.contains(where: { $0 == category || tree.parent(of: $0)?.id == category })
        else { return false }
      } else {
        guard let note = transaction.note,
          note.range(of: payment.name, options: .caseInsensitive) != nil
        else { return false }
      }
      // «Это другое» about any due date of the payment dismisses the operation for all of them.
      return !rejections.contains { key in
        key.lowercased().hasPrefix(
          "\(entry.id.uuidString.lowercased()):\(payment.id.uuidString.lowercased()):")
      }
    }

    /// The due dates the matching looks at: from `next_date` through today + 5.
    func dues(of payment: ScheduledPayment) -> [DateOnly] {
      guard let next = payment.nextDate else { return [] }
      return Recurrence.occurrences(
        from: next, through: CashFx.today.adding(days: 5), rule: RecurrenceRule(payment: payment),
        end: payment.endDate)
    }
  }

  func matches(_ book: Book) -> ScheduledMatches {
    ScheduledMatching.matches(
      book: book.fx.book, ledger: book.fx.ledger, today: Fx.today, rejections: book.rejections)
  }

  /// An operation pays one due date at most, and only one it can pay by the rule.
  @Test(arguments: seeds)
  func everyMatchKeepsTheRuleAndAnOperationPaysOnce(_ seed: UInt64) {
    let book = Book(seed: seed)
    let found = matches(book)
    var payers: [UUID] = []
    for payment in book.fx.scheduled {
      for (due, operation) in found.matchedDues(of: payment.id) {
        payers.append(operation)
        guard let entry = book.fx.entries.first(where: { $0.id == operation }) else {
          Issue.record("seed \(seed): the operation of a match is not in the book")
          continue
        }
        #expect(book.canPay(entry, payment, due), "seed \(seed), \(payment.name) \(due)")
        #expect(book.dues(of: payment).contains(due))
      }
    }
    #expect(Set(payers).count == payers.count, "seed \(seed): an operation paid twice")
    #expect(found.operationIds.isSuperset(of: payers))
  }

  /// Nothing that could pay is left idle: a due date left unpaid has no operation that could
  /// pay it and pays nothing else.
  @Test(arguments: seeds)
  func anUnpaidDueHasNoFreeOperationThatCouldPayIt(_ seed: UInt64) {
    let book = Book(seed: seed)
    let found = matches(book)
    let used = Set(book.fx.scheduled.flatMap { found.matchedDues(of: $0.id).values })
    for payment in book.fx.scheduled {
      for due in book.dues(of: payment) where !found.isPaid(payment.id, due) {
        let idle = book.fx.entries.filter {
          !used.contains($0.id) && book.canPay($0, payment, due)
        }
        #expect(idle.isEmpty, "seed \(seed), \(payment.name) \(due)")
      }
    }
  }

  /// The result is the owner's book, not the order it came in: operations and payments in
  /// any order give the same matches.
  @Test(arguments: seeds)
  func theOrderOfTheBookDoesNotMatter(_ seed: UInt64) {
    let book = Book(seed: seed)
    var shuffled = book
    var random = SeededRandom(seed: seed &* 7)
    shuffled.fx.entries.shuffle(using: &random)
    shuffled.fx.scheduled.shuffle(using: &random)
    let one = matches(book)
    let other = matches(shuffled)
    #expect(one == other, "seed \(seed)")
  }

  /// Every screen takes a due date as paid once: the free sum, the planned month, the list,
  /// the reminders and the 7-day card never ask again for a due date an operation paid.
  @Test(arguments: seeds)
  func everyScreenAgreesOnWhatIsPaid(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.fx.snapshot()
    let found = snapshot.matches
    for payment in book.fx.scheduled where payment.active {
      let paid = found.matchedDues(of: payment.id).keys
      for due in paid {
        #expect(
          !snapshot.planned.items.contains { $0.id == payment.id && $0.due == due },
          "seed \(seed)")
        #expect(
          !snapshot.upcoming.contains { $0.id == payment.id && $0.due == due }, "seed \(seed)")
        #expect(
          !snapshot.reminders.contains {
            $0.id == "pay:\(payment.id.uuidString.lowercased()):\(due.iso)"
          },
          "seed \(seed)")
      }
      if let status = snapshot.scheduled.first(where: { $0.id == payment.id }) {
        #expect(
          !found.isPaid(payment.id, status.nextUnpaid)
            || status.nextUnpaid == book.dues(of: payment).last)
      }
    }
    // The free sum through the end of the month holds back every due date after the count of
    // 1 May — all of them, the book's dates start in June — that nothing paid, at its price,
    // once: the due dates the calendar names, not stepped to.
    var model = AmountE4.zero
    for payment in book.fx.scheduled where payment.active {
      guard let next = payment.nextDate else { continue }
      for day in PlainCalendar.days(from: next, through: Fx.day("2026-09-30"))
      where PlainCalendar.isDue(day, of: payment) && !found.isPaid(payment.id, day) {
        model += payment.amountE4
      }
    }
    #expect(snapshot.freeMoney.until == Fx.day("2026-09-30"))
    #expect(snapshot.freeMoney.plan.scheduled == model, "seed \(seed)")
  }

  /// «Привязать» on any match changes no figure: the due date was paid and stays paid, every
  /// other match stays as it was, and the free sum, the planned month and the reminders are
  /// what they were.
  @Test(arguments: seeds)
  func bindingAnyMatchChangesNoFigure(_ seed: UInt64) {
    let book = Book(seed: seed)
    let before = book.fx.snapshot()
    for payment in book.fx.scheduled where payment.active {
      for (due, operation) in before.matches.matchedDues(of: payment.id).sorted(by: {
        $0.key < $1.key
      }) {
        var bound = book
        guard let index = bound.fx.entries.firstIndex(where: { $0.id == operation }) else {
          continue
        }
        let result = ScheduledMatching.bind(
          bound.fx.entries[index], to: payment, due: due, matches: before.matches)
        bound.fx.entries[index] = result.operation
        if let place = bound.fx.scheduled.firstIndex(where: { $0.id == payment.id }) {
          bound.fx.scheduled[place] = result.payment
        }
        let after = bound.fx.snapshot()
        #expect(after.matches.isLinked(payment.id, due), "seed \(seed)")
        #expect(after.freeMoney.plan.scheduled == before.freeMoney.plan.scheduled, "seed \(seed)")
        #expect(after.planned.scheduled == before.planned.scheduled, "seed \(seed)")
        #expect(
          after.reminders.filter { $0.kind == .payment }
            == before.reminders.filter { $0.kind == .payment }, "seed \(seed)")
        for other in book.fx.scheduled where other.id != payment.id {
          #expect(
            after.matches.matchedDues(of: other.id) == before.matches.matchedDues(of: other.id),
            "seed \(seed)")
        }
      }
    }
  }

  /// «Это другое» on any match: that operation never pays that due date again, and the due
  /// date is paid only if another operation can pay it.
  @Test(arguments: seeds)
  func dismissingAnyMatchUnpaysItForGood(_ seed: UInt64) {
    let book = Book(seed: seed)
    let before = matches(book)
    for payment in book.fx.scheduled {
      for (due, operation) in before.matchedDues(of: payment.id) {
        var dismissed = book
        dismissed.rejections.insert(
          ScheduledMatching.rejectionKey(operation: operation, payment: payment.id, due: due))
        let after = matches(dismissed)
        #expect(after.operation(for: payment.id, due) != operation, "seed \(seed)")
        if let other = after.operation(for: payment.id, due),
          let entry = book.fx.entries.first(where: { $0.id == other })
        {
          #expect(dismissed.canPay(entry, payment, due))
        }
      }
    }
  }
}

extension ScheduledMatchingPropertyTests {
  /// The random books reach what the rule is about: operations that pay, dismissed pairs,
  /// deleted operations, payments without a category paid by the name in the note.
  @Test func theRandomBooksReachEveryCase() {
    var matched = 0
    var byName = 0
    var dismissed = 0
    var deleted = 0
    for seed in Self.seeds {
      let book = Book(seed: seed)
      let found = matches(book)
      for payment in book.fx.scheduled {
        let dues = found.matchedDues(of: payment.id)
        matched += dues.count
        if payment.categoryId == nil { byName += dues.count }
      }
      dismissed += book.rejections.count
      deleted += book.fx.entries.filter(\.transaction.isDeleted).count
    }
    #expect(matched >= 20)
    #expect(byName >= 1)
    #expect(dismissed >= 3)
    #expect(deleted >= 1)
  }
}
