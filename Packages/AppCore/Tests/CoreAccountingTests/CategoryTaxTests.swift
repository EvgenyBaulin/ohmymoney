import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The tax an income owes follows its category: a subcategory without one of its own takes its
/// parent's, and only an income category owes one.
@Suite("The tax of an income category")
struct CategoryTaxTests {
  @Test func aSubcategoryTakesItsParentsTax() {
    let earnings = CoreKit.Category(kind: .income, name: "Заработок")
    let selfEmployed = CoreKit.Category(
      parentId: earnings.id, kind: .income, name: "Самозанятость",
      tax: IncomeTax(rate: 4, npd: true))
    let individuals = CoreKit.Category(
      parentId: selfEmployed.id, kind: .income, name: "От физлиц")
    let organisations = CoreKit.Category(
      parentId: selfEmployed.id, kind: .income, name: "От организаций",
      tax: IncomeTax(rate: 6, npd: true))
    let salary = CoreKit.Category(parentId: earnings.id, kind: .income, name: "Зарплата")
    let food = CoreKit.Category(kind: .expense, name: "Еда", tax: IncomeTax(rate: 13))
    let tree = CategoryTree([earnings, selfEmployed, individuals, organisations, salary, food])
    #expect(tree.tax(of: selfEmployed.id) == IncomeTax(rate: 4, npd: true))
    #expect(tree.tax(of: individuals.id) == IncomeTax(rate: 4, npd: true))
    #expect(tree.tax(of: organisations.id) == IncomeTax(rate: 6, npd: true))
    #expect(tree.tax(of: salary.id) == nil)
    #expect(tree.tax(of: earnings.id) == nil)
    #expect(tree.tax(of: food.id) == nil, "spending owes no tax")
    #expect(tree.tax(of: nil) == nil)
  }

  /// «Нет» on a subcategory of a taxed category is a rate of zero: it owes nothing, and so does a
  /// category at the top with a rate of zero.
  @Test func aRateOfZeroIsNoTax() {
    let freelance = CoreKit.Category(
      kind: .income, name: "Фриланс", tax: IncomeTax(rate: 4, npd: true))
    let gifts = CoreKit.Category(
      parentId: freelance.id, kind: .income, name: "Подарки", tax: IncomeTax(rate: 0))
    let zero = CoreKit.Category(kind: .income, name: "Прочее", tax: IncomeTax(rate: 0))
    let tree = CategoryTree([freelance, gifts, zero])
    #expect(tree.tax(of: freelance.id) == IncomeTax(rate: 4, npd: true))
    #expect(tree.tax(of: gifts.id) == nil)
    #expect(tree.tax(of: zero.id) == nil)
  }
}
