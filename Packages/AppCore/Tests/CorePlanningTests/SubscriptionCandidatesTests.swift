import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Subscription candidates found in the history")
struct SubscriptionCandidatesTests {
  typealias Fx = SchedFx

  let today = SchedFx.day("2026-09-19")
  let internet = SchedFx.id(40)
  let studio = SchedFx.id(50)

  /// One group per case, each built so that exactly one rule decides it.
  @Test func candidatesAndLookAlikes() {
    var number = 0
    var entries: [TransactionEntry] = []
    func add(
      _ iso: String, _ amount: String, note: String? = nil, place: UUID? = nil,
      category: UUID? = nil, link: OperationLink? = nil, kind: TransactionKind = .expense
    ) {
      number += 1
      entries.append(
        Fx.operation(
          number, iso, amount, kind: kind, note: note, category: category, place: place,
          link: link))
    }

    // Found, monthly: gaps 31, 31, 30, 31 days; 299…309 spread 10 ≤ 29.9; digits differ.
    for (iso, amount, note) in [
      ("2026-05-03", "299", "Music service 05"), ("2026-06-03", "299", "Music service 06"),
      ("2026-07-04", "299", "MUSIC  service 07"), ("2026-08-03", "309", "Music service 08"),
      ("2026-09-03", "309", "Music service 09"),
    ] {
      add(iso, amount, note: note)
    }
    // Found, weekly: every 7 days, two months only — weekly needs no three months.
    for iso in ["2026-08-29", "2026-09-05", "2026-09-12", "2026-09-19"] {
      add(iso, "500", note: "Swimming pool")
    }
    // Found by place: no description, 30–31 days apart.
    for iso in ["2026-06-15", "2026-07-15", "2026-08-14", "2026-09-14"] {
      add(iso, "1500", place: studio)
    }
    // Irregular: gaps 1, 8, 5 — one of three fits a week.
    for iso in ["2026-09-01", "2026-09-02", "2026-09-10", "2026-09-15"] {
      add(iso, "250", note: "Coffee")
    }
    // Monthly, but 300…600 spread by far more than 10 % of 450.
    for (iso, amount) in [("2026-06-20", "300"), ("2026-07-20", "450"), ("2026-08-20", "600")] {
      add(iso, amount, note: "Taxi")
    }
    // Monthly until April: stopped 162 days ago.
    for iso in ["2026-01-10", "2026-02-10", "2026-03-10", "2026-04-10"] {
      add(iso, "100", note: "Old service")
    }
    // Already a payment by name.
    for iso in ["2026-06-07", "2026-07-07", "2026-08-07", "2026-09-07"] {
      add(iso, "799", note: "Video")
    }
    // Already a payment by category and amount: 700 is within 10 % of 690.
    for iso in ["2026-06-11", "2026-07-11", "2026-08-11", "2026-09-11"] {
      add(iso, "700", note: "Provider", category: internet)
    }
    // Paid through «Mark as paid»: planned already.
    for iso in ["2026-06-01", "2026-07-01", "2026-08-01", "2026-09-01"] {
      add(
        iso, "30000", note: "Flat",
        link: .scheduled(paymentId: Fx.id(1), due: Fx.day(iso)))
    }
    // Only two.
    for iso in ["2026-08-16", "2026-09-16"] {
      add(iso, "999", note: "Magazine")
    }
    // Income is never a subscription.
    for iso in ["2026-06-05", "2026-07-05", "2026-08-05", "2026-09-05"] {
      add(iso, "50000", note: "Salary", kind: .income)
    }

    let book = PlanningBook(scheduled: [
      ScheduledPayment(id: Fx.id(1), name: "Rent", amountE4: Fx.money("30000"), day: 1),
      ScheduledPayment(name: "VIDEO", amountE4: Fx.money("799"), day: 7),
      ScheduledPayment(
        name: "Home internet", amountE4: Fx.money("690"), categoryId: internet, day: 11),
    ])
    let found = SubscriptionCandidates.find(
      ledger: Fx.ledger(entries, book: book), book: book, today: today)

    #expect(
      found == [
        SubscriptionCandidate(
          key: "music service", placeId: nil, categoryId: nil, currency: .rub,
          typicalAmount: Fx.money("299"), freq: .monthly, occurrences: 5,
          lastDay: Fx.day("2026-09-03")),
        SubscriptionCandidate(
          key: "place:\(studio.uuidString.lowercased())", placeId: studio, categoryId: nil,
          currency: .rub, typicalAmount: Fx.money("1500"), freq: .monthly, occurrences: 4,
          lastDay: Fx.day("2026-09-14")),
        SubscriptionCandidate(
          key: "swimming pool", placeId: nil, categoryId: nil, currency: .rub,
          typicalAmount: Fx.money("500"), freq: .weekly, occurrences: 4,
          lastDay: Fx.day("2026-09-19")),
      ])
  }

  /// A subscription found in the history is paid from the account — and the card — of its
  /// latest purchase: the payment made of it starts there, so the screen of that account lists it
  /// and the free sum holds it back on the right account.
  @Test func aCandidateNamesTheAccountAndTheCardOfItsLatestPurchase() {
    let apple = Fx.id(60)
    let old = Fx.id(61)
    let appleCard = Fx.id(62)
    var entries = [
      ("2026-06-02", old), ("2026-07-02", apple), ("2026-08-02", apple), ("2026-09-02", apple),
    ].enumerated().map { index, row in
      Fx.operation(index + 1, row.0, "199", note: "Cloud", method: row.1)
    }
    entries[entries.count - 1].transaction.cardId = appleCard
    let found = SubscriptionCandidates.find(
      ledger: Fx.ledger(entries), book: .empty, today: today)
    #expect(found.count == 1)
    #expect(found.first?.paymentMethodId == apple, "the latest purchase decides")
    #expect(found.first?.cardId == appleCard)
  }

  /// With no account on the latest purchase the candidate names none: the payment is the main
  /// account's, as a payment of no account always was.
  @Test func aCandidateWithoutAnAccountNamesNone() {
    let entries = [("2026-06-02", "100"), ("2026-07-02", "100"), ("2026-08-02", "100")]
      .enumerated().map { index, row in
        Fx.operation(index + 1, row.0, row.1, note: "Cloud")
      }
    let found = SubscriptionCandidates.find(
      ledger: Fx.ledger(entries), book: .empty, today: today)
    #expect(found.first?.paymentMethodId == nil)
    #expect(found.first?.cardId == nil)
  }

  /// A median of an even count is the mean of the two middle amounts.
  @Test func theTypicalAmountIsTheMedian() {
    let entries = [
      ("2026-06-02", "100"), ("2026-07-02", "104"), ("2026-08-02", "106"), ("2026-09-02", "108"),
    ].enumerated().map { index, row in
      Fx.operation(index + 1, row.0, row.1, note: "Cloud")
    }
    let found = SubscriptionCandidates.find(
      ledger: Fx.ledger(entries), book: .empty, today: today)
    #expect(found.map(\.typicalAmount) == [Fx.money("105")])
  }

  @Test func descriptionsAreNormalized() {
    #expect(SubscriptionCandidates.normalized("  Music   Service 09/2026 ") == "music service /")
    #expect(SubscriptionCandidates.normalized("2026") == nil)
    #expect(SubscriptionCandidates.normalized(nil) == nil)
  }
}
