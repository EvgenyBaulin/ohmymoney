import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// A book for «Предложить лимиты…»: today is 19 September 2026, so June, July and August are
/// the full months looked at.
private struct SuggestionBook {
  static let food = id(1)
  static let cafe = id(2)
  static let taxi = id(3)
  static let gifts = id(4)
  static let goals = id(5)
  static let vacation = id(6)
  static let unknown = id(7)
  static let clothes = id(8)
  static let reconcile = id(9)
  static let hobby = id(10)
  static let salary = id(11)
  static let books = id(12)

  static let today = DateOnly(year: 2026, month: 9, day: 19)

  var entries: [TransactionEntry] = []
  var hobbyArchived = true
  private var next = 1_000

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: Self.food, kind: .expense, name: "Food"),
      CoreKit.Category(id: Self.cafe, parentId: Self.food, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: Self.taxi, kind: .expense, name: "Taxi"),
      CoreKit.Category(id: Self.gifts, kind: .expense, name: "Gifts"),
      CoreKit.Category(id: Self.goals, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: Self.vacation, parentId: Self.goals, kind: .expense, name: "Vacation"),
      CoreKit.Category(id: Self.unknown, kind: .expense, name: "Unknown", systemRole: .unknown),
      CoreKit.Category(id: Self.clothes, kind: .expense, name: "Clothes"),
      CoreKit.Category(id: Self.reconcile, kind: .expense, name: "Сверка"),
      CoreKit.Category(id: Self.hobby, kind: .expense, name: "Hobby", archived: hobbyArchived),
      CoreKit.Category(id: Self.salary, kind: .income, name: "Salary"),
      CoreKit.Category(id: Self.books, kind: .expense, name: "Books"),
    ]
  }

  var ledger: Ledger {
    Ledger(dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
  }

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  /// One operation of one part at noon UTC of the day.
  mutating func add(
    _ iso: String, _ rubles: String, _ category: UUID, kind: TransactionKind = .expense,
    reimbursable: Bool = false, goal: UUID? = nil
  ) {
    next += 1
    let transactionId = Self.id(next)
    let day = DateOnly(iso: iso) ?? Self.today
    let when = CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
    let amount = amountLiteral(rubles)
    let part = TransactionPart(
      id: Self.id(next + 500_000), transactionId: transactionId, categoryId: category,
      quality: kind.hasQuality ? .neutral : nil, qualitySource: kind.hasQuality ? .manual : nil,
      amountE4: amount, forWhom: .me, reimbursable: reimbursable,
      reimbursementStatus: reimbursable ? .expected : nil, goalId: goal)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, amountE4: amount, createdAt: when,
          updatedAt: when),
        parts: [part]))
  }

  /// Food in every month (a part under «Cafe» too), Taxi in two, Gifts in one, and spending
  /// the suggestions must never see.
  static var usual: SuggestionBook {
    var book = SuggestionBook()
    book.add("2026-06-03", "10000", food)
    book.add("2026-06-20", "2000", cafe)
    book.add("2026-07-11", "9300", food)
    book.add("2026-08-02", "15100", food)
    book.add("2026-08-05", "4000", food, reimbursable: true)
    book.add("2026-07-08", "2100", taxi)
    book.add("2026-08-30", "3000", taxi)
    book.add("2026-07-15", "5000", gifts)
    for month in ["06", "07", "08"] {
      book.add("2026-\(month)-10", "7000", vacation, goal: id(77))
      book.add("2026-\(month)-11", "800", unknown)
      book.add("2026-\(month)-12", "3000", clothes)
      book.add("2026-\(month)-13", "500", reconcile)
      book.add("2026-\(month)-14", "1200", hobby)
      book.add("2026-\(month)-15", "90000", salary, kind: .income)
    }
    // Outside the window: May before it, September is the month of today.
    book.add("2026-05-20", "50000", books)
    book.add("2026-09-01", "50000", books)
    book.add("2026-09-02", "50000", taxi)
    return book
  }
}

@Suite("Suggested limits: three full months, the median, rounded up")
struct LimitSuggestionsTests {
  private typealias Book = SuggestionBook

  private func suggestions(
    _ book: SuggestionBook, budgets: [Budget] = [], limitless: Set<UUID> = [Book.reconcile]
  ) -> [LimitSuggestion] {
    LimitSuggestions.suggestions(
      ledger: book.ledger, budgets: budgets, today: Book.today, limitless: limitless)
  }

  @Test func theMonthsAreTheThreeFullOnesBeforeToday() {
    #expect(
      LimitSuggestions.months(before: Book.today)
        == [
          MonthKey(year: 2026, month: 6), MonthKey(year: 2026, month: 7),
          MonthKey(year: 2026, month: 8),
        ])
    #expect(
      LimitSuggestions.months(before: DateOnly(year: 2027, month: 1, day: 31))
        == [
          MonthKey(year: 2026, month: 10), MonthKey(year: 2026, month: 11),
          MonthKey(year: 2026, month: 12),
        ])
  }

  @Test func onlyCategoriesSpentOnInTwoMonthsWithoutALimitAreOffered() {
    let budgets = [Budget(scope: .category, categoryId: Book.clothes, amountE4: Book.rub(4_000))]
    let offered = suggestions(.usual, budgets: budgets).map(\.categoryId)
    #expect(offered == [Book.food, Book.taxi])
  }

  @Test func aCategoryIsCountedWithItsSubcategoriesAndMyExpensesOnly() throws {
    let food = try #require(suggestions(.usual).first { $0.categoryId == Book.food })
    // June: 10,000 + 2,000 under «Cafe»; August: the part paid for somebody else is not mine.
    #expect(food.months == [Book.rub(12_000), Book.rub(9_300), Book.rub(15_100)])
    #expect(food.median == Book.rub(12_000))
    #expect(food.usual == Book.rub(12_000))
    #expect(food.tenPercentLess == Book.rub(11_000), "10,800 rounded up to a thousand")
    #expect(food.amount(.usual) == food.usual)
    #expect(food.amount(.tenPercentLess) == food.tenPercentLess)
  }

  @Test func aMonthWithoutSpendingCountsAsZeroInTheMedian() throws {
    let taxi = try #require(suggestions(.usual).first { $0.categoryId == Book.taxi })
    #expect(taxi.months == [.zero, Book.rub(2_100), Book.rub(3_000)])
    #expect(taxi.median == Book.rub(2_100))
    #expect(taxi.usual == Book.rub(2_500))
    #expect(taxi.tenPercentLess == Book.rub(2_000), "1,890 rounded up to 500")
  }

  @Test func theSystemCategoriesTheReconciliationAndTheArchiveAreNeverOffered() {
    let offered = Set(suggestions(.usual).map(\.categoryId))
    for never in [Book.goals, Book.vacation, Book.unknown, Book.reconcile, Book.hobby, Book.salary]
    {
      #expect(!offered.contains(never))
    }
    var unarchived = SuggestionBook.usual
    unarchived.hobbyArchived = false
    #expect(suggestions(unarchived).contains { $0.categoryId == Book.hobby })
    #expect(
      suggestions(.usual, limitless: []).contains { $0.categoryId == Book.reconcile },
      "«Сверка» is kept out only as the reconciliation's category")
  }

  @Test func aCategoryWithALimitOnASubcategoryIsStillOffered() {
    let budgets = [Budget(scope: .category, categoryId: Book.cafe, amountE4: Book.rub(2_000))]
    #expect(suggestions(.usual, budgets: budgets).contains { $0.categoryId == Book.food })
    let other = [Budget(scope: .forWhom, forWhom: .partner, amountE4: Book.rub(2_000))]
    #expect(suggestions(.usual, budgets: other) == suggestions(.usual))
  }

  @Test func refundsTakeAMonthDownToZeroNotBelow() throws {
    var book = SuggestionBook()
    book.add("2026-06-03", "1000", Book.books)
    book.add("2026-07-03", "1000", Book.books)
    book.add("2026-08-03", "600", Book.books, kind: .refund)
    let books = try #require(suggestions(book).first)
    #expect(books.months == [Book.rub(1_000), Book.rub(1_000), .zero])
    #expect(books.usual == Book.rub(1_000))
  }

  @Test func nothingToSuggestOnAnEmptyBook() {
    #expect(suggestions(SuggestionBook()).isEmpty)
  }

  @Test func theBiggestComeFirstThenByName() {
    var book = SuggestionBook()
    for month in ["06", "07", "08"] {
      book.add("2026-\(month)-03", "1000", Book.taxi)
      book.add("2026-\(month)-03", "1000", Book.books)
      book.add("2026-\(month)-03", "4000", Book.gifts)
    }
    #expect(suggestions(book).map(\.categoryId) == [Book.gifts, Book.books, Book.taxi])
  }

  @Test(arguments: [
    ("0", "0"), ("-50", "0"), ("0.01", "500"), ("500", "500"), ("500.01", "1000"),
    ("9999.99", "10000"), ("10000", "10000"), ("10000.01", "11000"), ("12345", "13000"),
  ])
  func roundingIsUpToFiveHundredUnderTenThousandAndToAThousandFromIt(
    _ amount: String, _ rounded: String
  ) {
    #expect(LimitSuggestions.roundedUp(amountLiteral(amount)) == amountLiteral(rounded))
  }

  @Test func aTenthLessIsNinetyPercent() {
    #expect(LimitSuggestions.lessATenth(Book.rub(12_000)) == Book.rub(10_800))
    #expect(LimitSuggestions.lessATenth(amountLiteral("0.0005")) == amountLiteral("0.0005"))
    #expect(LimitSuggestions.lessATenth(.zero) == .zero)
  }

  @Test func theMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
    #expect(LimitSuggestions.median(of: []) == .zero)
    #expect(
      LimitSuggestions.median(of: [Book.rub(3), Book.rub(1), Book.rub(2)]) == Book.rub(2))
    #expect(LimitSuggestions.median(of: [Book.rub(1), Book.rub(2)]) == amountLiteral("1.5"))
  }

  @Test func theLimitsWrittenStartThisMonthAndSkipWhatCannotBeSaved() {
    let book = SuggestionBook.usual
    let existing = [Budget(scope: .category, categoryId: Book.clothes, amountE4: Book.rub(4_000))]
    let month = Book.today.monthKey
    let written = LimitSuggestions.budgets(
      for: [
        (Book.food, Book.rub(12_000)), (Book.taxi, Book.rub(2_500)),
        (Book.food, Book.rub(1_000)), (Book.clothes, Book.rub(1_000)),
        (Book.unknown, Book.rub(1_000)), (Book.gifts, .zero), (Book.reconcile, Book.rub(1)),
      ],
      existing: existing, tree: book.ledger.tree, in: month, limitless: [Book.reconcile])
    #expect(written.map(\.categoryId) == [Book.food, Book.taxi])
    #expect(written.map(\.amountE4) == [Book.rub(12_000), Book.rub(2_500)])
    #expect(written.allSatisfy { $0.scope == .category && !$0.rollover && $0.startMonth == month })
    #expect(Set(written.map(\.id)).count == 2)
  }
}
