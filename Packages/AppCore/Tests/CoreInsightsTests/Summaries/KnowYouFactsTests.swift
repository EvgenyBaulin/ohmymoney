import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("«Знаешь ли ты»: the checks")
struct KnowYouFactsTests {
  let end = SummaryBook.end

  func fact(_ id: FactID, _ book: SummaryBook) -> KnowFact? {
    KnowYouFacts.check(id, ledger: book.ledger, through: end)
  }

  @Test func theSetHasBetweenTwentyAndThirtyChecks() {
    #expect((20...30).contains(FactID.allCases.count))
  }

  @Test func aFlatBookHasNothingToSay() {
    let book = SummaryBook.flat()
    #expect(KnowYouFacts.facts(ledger: book.ledger, through: end).isEmpty)
  }

  @Test func tooLittleHistoryOrTooFewPurchasesSayNothing() {
    let book = SummaryBook.flat()
    #expect(
      KnowYouFacts.facts(ledger: book.ledger, through: SummaryBook.start.adding(days: 30)).isEmpty)
    var few = SummaryBook()
    for day in DayRange(SummaryBook.start, end).days where day.day == 3 { few.spend(1000, on: day) }
    few.spend(1000, on: SummaryBook.start)
    #expect(KnowYouFacts.facts(ledger: few.ledger, through: end).isEmpty)
  }

  // MARK: Weekdays

  @Test func lowestWeekdayIsFoundAndTheThresholdHolds() {
    let low = SummaryBook.flat { _, day, book in
      guard day.weekday == 3 else { return false }
      book.spend(500, on: day)
      return true
    }
    let found = fact(.weekdayLowest, low)
    #expect(found?.args.first == .weekday(3))
    #expect((found?.differenceBP ?? 0) >= 2_000)
    // 800 instead of 1,000 is 17.6 % under the usual day: not enough.
    let near = SummaryBook.flat { _, day, book in
      guard day.weekday == 3 else { return false }
      book.spend(800, on: day)
      return true
    }
    #expect(fact(.weekdayLowest, near) == nil)
    #expect(fact(.weekdayHighest, low) == nil)
  }

  @Test func highestWeekdayIsFoundAndTheThresholdHolds() {
    let high = SummaryBook.flat { _, day, book in
      guard day.weekday == 5 else { return false }
      book.spend(2000, on: day)
      return true
    }
    #expect(fact(.weekdayHighest, high)?.args.first == .weekday(5))
    let near = SummaryBook.flat { _, day, book in
      guard day.weekday == 5 else { return false }
      book.spend(1150, on: day)
      return true
    }
    #expect(fact(.weekdayHighest, near) == nil)
  }

  @Test func weekendAgainstWeekdays() {
    let heavy = SummaryBook.flat { _, day, book in
      guard day.weekday >= 6 else { return false }
      book.spend(2000, on: day)
      return true
    }
    #expect(fact(.weekendHeavier, heavy) != nil)
    #expect(fact(.weekendLighter, heavy) == nil)
    let light = SummaryBook.flat { _, day, book in
      guard day.weekday >= 6 else { return false }
      book.spend(500, on: day)
      return true
    }
    #expect(fact(.weekendLighter, light) != nil)
    #expect(fact(.weekendHeavier, light) == nil)
  }

  @Test func halvesOfTheMonth() {
    let first = SummaryBook.flat { _, day, book in
      book.spend(day.day <= 15 ? 2000 : 1000, on: day)
      return true
    }
    #expect(fact(.firstHalfHeavier, first) != nil)
    #expect(fact(.secondHalfHeavier, first) == nil)
    let second = SummaryBook.flat { _, day, book in
      book.spend(day.day <= 15 ? 1000 : 2000, on: day)
      return true
    }
    #expect(fact(.secondHalfHeavier, second) != nil)
    #expect(fact(.firstHalfHeavier, second) == nil)
  }

  @Test func daysAfterAnIncome() {
    let book = SummaryBook.flat { _, day, book in
      if day.day == 10 { book.earn(50_000, on: day) }
      book.spend((10...12).contains(day.day) ? 2000 : 1000, on: day)
      return true
    }
    #expect(fact(.afterIncomeHeavier, book) != nil)
    let plain = SummaryBook.flat { _, day, book in
      if day.day == 10 { book.earn(50_000, on: day) }
      book.spend(1000, on: day)
      return true
    }
    #expect(fact(.afterIncomeHeavier, plain) == nil)
  }

  // MARK: Time of day

  @Test func biggestAndSmallestChecksByTimeOfDay() {
    let morning = SummaryBook.flat { index, day, book in
      book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
      if index < 10 { book.add(SummaryBook.Spec(amount: 3000, hour: 8), on: day) }
      return true
    }
    #expect(fact(.timeBiggestChecks, morning)?.args.first == .timeOfDay(.morning))
    let night = SummaryBook.flat { index, day, book in
      book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
      if index < 10 { book.add(SummaryBook.Spec(amount: 100, hour: 2), on: day) }
      return true
    }
    #expect(fact(.timeSmallestChecks, night)?.args.first == .timeOfDay(.night))
    #expect(fact(.timeBiggestChecks, night) == nil)
  }

  @Test func aTimeNobodyTypedIsNotATime() {
    // Twelve o'clock sharp is the time an operation gets when nobody said when.
    let book = SummaryBook.flat { index, day, book in
      book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
      if index < 10 {
        var spec = SummaryBook.Spec(amount: 3000, hour: 12)
        spec.note = "x\(index)"
        let moment = SummaryBook.calendar.noon(of: day)
        book.add(spec, on: day)
        book.entries[book.entries.count - 1].transaction.occurredAt = moment
      }
      return true
    }
    #expect(fact(.timeBiggestChecks, book) == nil)
  }

  // MARK: Places

  @Test func dearestAndCheapestPlace() {
    let dear = SummaryBook.flat { index, day, book in
      book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
      if index < 4 { book.add(SummaryBook.Spec(amount: 4000, place: book.shopB.id), on: day) }
      return true
    }
    #expect(fact(.placeDearest, dear)?.args.first == .place(dear.shopB.id))
    let cheap = SummaryBook.flat { index, day, book in
      book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
      if index < 4 { book.add(SummaryBook.Spec(amount: 100, place: book.shopB.id), on: day) }
      return true
    }
    #expect(fact(.placeCheapest, cheap)?.args.first == .place(cheap.shopB.id))
    // A place seen twice does not count.
    let twice = SummaryBook.flat { index, day, book in
      book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
      if index < 2 { book.add(SummaryBook.Spec(amount: 4000, place: book.shopB.id), on: day) }
      return true
    }
    #expect(fact(.placeDearest, twice) == nil)
  }

  @Test func mostVisitedPlace() {
    let often = SummaryBook.flat { index, day, book in
      let place = index % 86 < 60 ? book.shopA.id : book.shopB.id
      book.add(SummaryBook.Spec(place: place, note: "n\(index)"), on: day)
      return true
    }
    let found = fact(.placeMostVisited, often)
    #expect(found?.args == [.place(often.shopA.id), .count(60)])
    let even = SummaryBook.flat { index, day, book in
      let place = index < 45 ? book.shopA.id : book.shopB.id
      book.add(SummaryBook.Spec(place: place, note: "n\(index)"), on: day)
      return true
    }
    #expect(fact(.placeMostVisited, even) == nil)
  }

  // MARK: Categories, checks, counts

  @Test func aCategoryThatGrewAndOneThatShrank() {
    func book(prior: Int64, recent: Int64) -> SummaryBook {
      SummaryBook.flat { index, day, book in
        book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
        if SummaryBook.isPrior(day) {
          book.spend(prior, on: day, category: book.cafe.id)
        } else if SummaryBook.isRecent(day) {
          book.spend(recent, on: day, category: book.cafe.id)
        }
        return true
      }
    }
    let grew = book(prior: 400, recent: 800)
    #expect(fact(.categoryGrew, grew)?.args.first == .category(grew.cafe.id))
    #expect(fact(.categoryShrank, grew) == nil)
    let shrank = book(prior: 800, recent: 400)
    #expect(fact(.categoryShrank, shrank)?.args.first == .category(shrank.cafe.id))
    #expect(fact(.categoryGrew, book(prior: 400, recent: 460)) == nil)
  }

  @Test func theAverageCheckMoves() {
    func book(recent: Int64) -> SummaryBook {
      SummaryBook.flat { index, day, book in
        book.add(
          SummaryBook.Spec(
            amount: SummaryBook.isRecent(day) ? recent : 1000, place: book.shopA.id,
            note: "n\(index)"), on: day)
        return true
      }
    }
    #expect(fact(.checkGrew, book(recent: 1500)) != nil)
    #expect(fact(.checkShrank, book(recent: 1500)) == nil)
    #expect(fact(.checkShrank, book(recent: 600)) != nil)
    #expect(fact(.checkGrew, book(recent: 1100)) == nil)
  }

  @Test func theNumberOfPurchasesMoves() {
    func book(prior: Int, recent: Int) -> SummaryBook {
      SummaryBook.flat { index, day, book in
        let count = SummaryBook.isPrior(day) ? prior : SummaryBook.isRecent(day) ? recent : 1
        for step in 0..<count {
          book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)-\(step)"), on: day)
        }
        return true
      }
    }
    #expect(fact(.purchasesMore, book(prior: 1, recent: 2)) != nil)
    #expect(fact(.purchasesFewer, book(prior: 1, recent: 2)) == nil)
    #expect(fact(.purchasesFewer, book(prior: 2, recent: 1)) != nil)
  }

  @Test func aRepeatedNote() {
    let book = SummaryBook.flat { index, day, book in
      book.add(
        SummaryBook.Spec(place: book.shopA.id, note: index < 10 ? "Кофе " : "n\(index)"), on: day)
      return true
    }
    #expect(fact(.repeatedNote, book)?.args == [.name("кофе"), .count(10)])
  }

  // MARK: Quality, savings, quiet days

  @Test func theShareOfGoodAndBadMoney() {
    func book(_ quality: Quality, prior: Int64, recent: Int64) -> SummaryBook {
      SummaryBook.flat { index, day, book in
        let part: Int64 =
          SummaryBook.isRecent(day) ? recent : SummaryBook.isPrior(day) ? prior : 200
        book.add(
          SummaryBook.Spec(amount: part, place: book.shopA.id, note: "n\(index)", quality: quality),
          on: day)
        book.add(
          SummaryBook.Spec(
            amount: 1000 - part, place: book.shopA.id, note: "m\(index)", quality: .neutral),
          on: day)
        return true
      }
    }
    #expect(fact(.goodShareGrew, book(.good, prior: 200, recent: 400)) != nil)
    #expect(fact(.goodShareGrew, book(.good, prior: 200, recent: 220)) == nil)
    #expect(fact(.badShareGrew, book(.bad, prior: 200, recent: 400)) != nil)
    #expect(fact(.badShareGrew, book(.good, prior: 200, recent: 400)) == nil)
  }

  @Test func theSavingsRateMoves() {
    func book(recentIncome: Int64) -> SummaryBook {
      var book = SummaryBook.flat()
      book.earn(40_000, on: end.adding(days: -40))
      book.earn(recentIncome, on: end.adding(days: -10))
      return book
    }
    #expect(fact(.savingsGrew, book(recentIncome: 60_000)) != nil)
    #expect(fact(.savingsShrank, book(recentIncome: 60_000)) == nil)
    #expect(fact(.savingsShrank, book(recentIncome: 30_000)) != nil)
    #expect(fact(.savingsGrew, book(recentIncome: 41_000)) == nil)
  }

  @Test func daysWithoutSpending() {
    func book(priorQuiet: Int, recentQuiet: Int) -> SummaryBook {
      SummaryBook.flat { index, day, book in
        let quiet =
          (SummaryBook.isPrior(day) && day.days(to: end) - 28 < priorQuiet)
          || (SummaryBook.isRecent(day) && day.days(to: end) < recentQuiet)
        if quiet { return true }
        book.add(SummaryBook.Spec(place: book.shopA.id, note: "n\(index)"), on: day)
        return true
      }
    }
    #expect(fact(.noSpendDaysMore, book(priorQuiet: 2, recentQuiet: 8)) != nil)
    #expect(fact(.noSpendDaysFewer, book(priorQuiet: 2, recentQuiet: 8)) == nil)
    #expect(fact(.noSpendDaysFewer, book(priorQuiet: 8, recentQuiet: 2)) != nil)
    #expect(fact(.noSpendDaysMore, book(priorQuiet: 2, recentQuiet: 3)) == nil)
  }

  // MARK: The finding of the week

  @Test func theFindingOfAWeekIsFixedAndFollowsTheWeekNumber() {
    let book = SummaryBook.flat { _, day, book in
      book.spend(day.weekday >= 6 ? 2000 : (day.day <= 15 ? 1500 : 900), on: day)
      return true
    }
    let week = WeekKey(containing: end)
    let first = KnowYouFacts.find(ledger: book.ledger, week: week)
    #expect(first != nil)
    #expect(first == KnowYouFacts.find(ledger: book.ledger, week: week))
    let all = KnowYouFacts.facts(ledger: book.ledger, through: week.end)
    #expect(all.count >= 2)
    #expect(all.contains(first!))
    // The next week, judged on the same data, takes the next check in the list.
    let ordinal = (week.start.dayNumber / 7) % all.count
    #expect(first == all[ordinal])
  }

  @Test func everyFindingIsAtLeastTwentyPercent() {
    let book = SummaryBook.flat { _, day, book in
      book.spend(day.weekday >= 6 ? 2000 : (day.day <= 15 ? 1500 : 900), on: day)
      return true
    }
    for found in KnowYouFacts.facts(ledger: book.ledger, through: end) {
      #expect(found.differenceBP >= KnowYouFacts.thresholdBP)
      #expect(!found.line.showsMoney)
    }
  }
}
