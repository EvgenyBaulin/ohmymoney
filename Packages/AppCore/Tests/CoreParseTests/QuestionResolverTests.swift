import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// «Понял так»: what a phrase of the question is taken for, and what else it could be.
@Suite("Вопросы: что значит слово")
struct QuestionResolverTests {
  static let food = UUID()
  static let groceries = UUID()
  static let transport = UUID()
  static let taxi = UUID()
  static let cafe = UUID()
  static let coffee = UUID()
  static let coffeeAndTea = UUID()
  static let coffeeShop = UUID()
  static let salary = UUID()
  static let giftsOut = UUID()
  static let giftsIn = UUID()
  static let fiveShop = UUID()
  static let starbucks = UUID()
  static let masha = UUID()
  static let sber = UUID()

  static let catalog = QuestionCatalog(
    categories: [
      QuestionName(id: food, name: "Еда", kind: .expense),
      QuestionName(id: groceries, name: "Продукты", parentId: food, kind: .expense),
      QuestionName(id: transport, name: "Транспорт", kind: .expense),
      QuestionName(id: taxi, name: "Такси", parentId: transport, kind: .expense),
      QuestionName(id: cafe, name: "Кафе", kind: .expense),
      QuestionName(id: coffee, name: "Кофе", kind: .expense),
      QuestionName(id: coffeeAndTea, name: "Кофе и чай", kind: .expense),
      QuestionName(id: coffeeShop, name: "Кофейня", kind: .expense),
      QuestionName(id: salary, name: "Зарплата", kind: .income),
      QuestionName(id: giftsOut, name: "Подарки", kind: .expense),
      QuestionName(id: giftsIn, name: "Подарки", kind: .income),
    ],
    places: [
      QuestionName(id: fiveShop, name: "Пятёрочка"),
      QuestionName(id: starbucks, name: "Starbucks"),
    ],
    people: [QuestionName(id: masha, name: "Маша")],
    paymentMethods: [QuestionName(id: sber, name: "Сбер")])

  private func resolve(
    _ text: String, hint: QuestionTermHint = .about, measure: QuestionMeasure = .spending,
    in catalog: QuestionCatalog = QuestionResolverTests.catalog
  ) -> ResolvedTerm {
    QuestionResolver.resolve(QuestionTerm(text: text, hint: hint), measure: measure, in: catalog)
  }

  @Test("Подкатегория знает родителя, а слово в описаниях остаётся запасным чтением")
  func aSubcategoryKnowsItsParent() {
    let term = resolve("такси")
    #expect(term.chosen == .subcategory(id: Self.taxi, name: "Такси", parentId: Self.transport))
    #expect(term.alternatives.last == .text("такси"))
  }

  @Test("Верхняя категория — категория")
  func aTopCategory() {
    #expect(resolve("кафе").chosen == .category(id: Self.cafe, name: "Кафе"))
  }

  @Test("Падеж и число не мешают: «пятёрочке», «продуктах»")
  func caseDoesNotMatter() {
    #expect(resolve("пятерочке", hint: .at).chosen == .place(id: Self.fiveShop, name: "Пятёрочка"))
    #expect(
      resolve("продуктах").chosen
        == .subcategory(id: Self.groceries, name: "Продукты", parentId: Self.food))
    #expect(resolve("еде").chosen == .category(id: Self.food, name: "Еда"))
  }

  @Test("Целое имя лучше части длинного")
  func aWholeNameBeatsAPartOfALongerOne() {
    #expect(resolve("кофе").chosen == .category(id: Self.coffee, name: "Кофе"))
    // «кофе чай» is exactly the long one.
    #expect(resolve("кофе чай").chosen == .category(id: Self.coffeeAndTea, name: "Кофе и чай"))
    // Without the exact name the longer one is a reading, below the shorter.
    let without = QuestionCatalog(categories: [
      QuestionName(id: Self.coffeeAndTea, name: "Кофе и чай")
    ])
    #expect(
      resolve("кофе", in: without).chosen == .category(id: Self.coffeeAndTea, name: "Кофе и чай"))
  }

  @Test("«кофе» — не «кофейня»")
  func aWordIsNotItsRelative() {
    let only = QuestionCatalog(categories: [QuestionName(id: Self.coffeeShop, name: "Кофейня")])
    #expect(resolve("кофе", in: only).chosen == .text("кофе"))
  }

  @Test("Незнакомое остаётся словом в описаниях")
  func anUnknownWordIsText() {
    let term = resolve("самокат")
    #expect(term.chosen == .text("самокат"))
    #expect(term.alternatives.isEmpty)
  }

  @Test("«для …» — человек, и только он")
  func forWhomIsAPerson() {
    #expect(resolve("маши", hint: .forWhom).chosen == .person(id: Self.masha, name: "Маша"))
    #expect(resolve("кафе", hint: .forWhom).chosen == .text("кафе"))
  }

  @Test("«в …» предпочитает место и счёт, но категория остаётся запасной")
  func atPrefersPlaces() {
    let both = QuestionCatalog(
      categories: [QuestionName(id: Self.cafe, name: "Старбакс", kind: .expense)],
      places: [QuestionName(id: Self.starbucks, name: "Старбакс")])
    #expect(
      resolve("старбакс", hint: .at, in: both).chosen
        == .place(id: Self.starbucks, name: "Старбакс"))
    #expect(
      resolve("старбакс", hint: .about, in: both).chosen
        == .category(id: Self.cafe, name: "Старбакс"))
    #expect(resolve("сбер", hint: .at).chosen == .paymentMethod(id: Self.sber, name: "Сбер"))
  }

  @Test("Вопрос о доходе берёт категорию дохода, о расходе — расхода")
  func theMeasurePicksTheKindOfCategory() {
    #expect(
      resolve("подарки", measure: .income).chosen == .category(id: Self.giftsIn, name: "Подарки"))
    #expect(
      resolve("подарки", measure: .spending).chosen == .category(id: Self.giftsOut, name: "Подарки")
    )
  }

  @Test("Выбор не зависит от порядка каталога")
  func theChoiceDoesNotDependOnTheOrder() {
    let twin = QuestionName(id: UUID(), name: "Подарки", kind: .expense)
    var forward = Self.catalog
    forward.categories.append(twin)
    var backward = forward
    backward.categories.reverse()
    #expect(resolve("подарки", in: forward).chosen == resolve("подарки", in: backward).chosen)
  }

  @Test("Поправить: выбранное чтение уходит в запасные")
  func correctingSwapsTheReading() throws {
    let parsed = ParsedQuestion(intent: .howMuch, terms: [QuestionTerm(text: "такси")])
    let question = QuestionResolver.resolve(parsed, in: Self.catalog)
    let was = question.terms[0].chosen
    let fixed = question.choosing(.text("такси"), forTermAt: 0)
    #expect(fixed.terms[0].chosen == .text("такси"))
    #expect(fixed.terms[0].alternatives.contains(was))
    #expect(!fixed.terms[0].alternatives.contains(.text("такси")))
    // An index outside the terms changes nothing.
    #expect(question.choosing(.text("x"), forTermAt: 5) == question)
  }

  @Test("Слова без букв и пустой запрос не падают")
  func emptyPhrases() {
    #expect(resolve("").chosen == .text(""))
    #expect(resolve("   ").chosen == .text("   "))
  }

  @Test("Сходство слов: окончания, а не родственники")
  func wordMatching() {
    #expect(QuestionResolver.wordsMatch("аптеку", "аптека"))
    #expect(QuestionResolver.wordsMatch("еде", "еда"))
    #expect(QuestionResolver.wordsMatch("такси", "такси"))
    #expect(!QuestionResolver.wordsMatch("кот", "кос"))
    #expect(!QuestionResolver.wordsMatch("кофе", "кофейня"))
    #expect(!QuestionResolver.wordsMatch("дом", "домашний"))
    #expect(!QuestionResolver.wordsMatch("кафе", "кино"))
  }
}
