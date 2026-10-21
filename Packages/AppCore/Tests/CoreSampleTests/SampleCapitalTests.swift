import CoreAccounting
import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The capital and the safety cushion the sample adds after the education loan: its own
/// sequence of draws, pinned; every layer under it left as it was, but for the cushion flag and
/// the essential marks; and the car, the brokerage account and the cushion the way the app
/// keeps them.
@Suite("The capital and the safety cushion of the sample")
struct SampleCapitalTests {
  static let seed = SampleFeatureLayersTests.seed

  /// The layers through the capital, without the ones written after it.
  static func layered(language: String = "en") -> SampleDataSet {
    SampleFeatureLayersTests.history(language: language)
      .withAccounts(seed: seed, calendar: .moscow, language: language)
      .withLayersThroughTheCapital(
        seed: seed, calendar: .moscow, language: language, now: nil, demo: false)
  }

  static func earlier(language: String = "en") -> SampleDataSet {
    SampleLoanAndSavingsTests.layered(language: language)
  }

  /// What the layer's draws decide: the assets and every valuation.
  static func digest(_ set: SampleDataSet) -> String {
    func id(_ value: UUID) -> String { value.uuidString.lowercased() }
    var text = ""
    for asset in set.assets {
      text += "asset \(id(asset.id))|\(asset.kind.rawValue)|\(asset.currency.code)|\(asset.sort)\n"
    }
    for valuation in set.assetValuations {
      text += "value \(id(valuation.id))|\(id(valuation.assetId))|\(valuation.day.iso)"
      text += "|\(valuation.valueE4.raw)\n"
    }
    return SHA256.hexDigest(Data(text.utf8))
  }

  @Test func theLayerDrawsTheSameSequence() {
    let set = Self.layered()
    #expect(set.assets.count == 2)
    #expect(
      Self.digest(set)
        == "3fd86dca3fcebb83064522860da59342cbe05a6cc313069642e284c227180b6a",
      """
      The capital layer drew a different sequence. If this was meant — a new asset, another
      value — put the digest printed by the failure here and say why in the commit. If it was
      not, something asked the layer's random source for one more value.
      """)
  }

  /// The layer moves no money and adds no operation: everything under it is kept, but for the
  /// cushion flag of the savings account and the essential marks of the categories.
  @Test func theLayersUnderItAreKept() {
    let earlier = Self.earlier()
    let set = Self.layered()
    #expect(set.entries == earlier.entries)
    #expect(set.transfers == earlier.transfers)
    #expect(set.reconciliations == earlier.reconciliations)
    #expect(set.reconciledBalances == earlier.reconciledBalances)
    #expect(set.debts == earlier.debts && set.debtEntries == earlier.debtEntries)
    #expect(set.cards == earlier.cards && set.cashbackRules == earlier.cashbackRules)
    #expect(set.planning == earlier.planning)
    #expect(set.accountExpectations == earlier.accountExpectations)
    #expect(set.expectations == earlier.expectations)
    #expect(earlier.assets.isEmpty && earlier.assetValuations.isEmpty)
    var unflagged = set.paymentMethods
    for index in unflagged.indices { unflagged[index].cushion = false }
    #expect(unflagged == earlier.paymentMethods)
    #expect(set.categories.map(\.id) == earlier.categories.map(\.id))
    #expect(earlier.categories.allSatisfy { $0.essential == nil })
    var unmarked = set.categories
    for index in unmarked.indices { unmarked[index].essential = nil }
    #expect(unmarked == earlier.categories)
  }

  /// The car: a vehicle in rubles, valued three times inside the history, each time for less.
  @Test func theCarLosesWorthAtEveryValuation() throws {
    let set = Self.layered(language: "ru")
    let car = try #require(set.assets.first { $0.kind == .vehicle })
    #expect(car.name == "Машина" && car.currency == .rub && car.disposedOn == nil)
    let valuations = set.assetValuations.filter { $0.assetId == car.id }
    #expect(valuations.count == 3)
    #expect(valuations.map(\.day) == valuations.map(\.day).sorted())
    #expect(Set(valuations.map(\.day)).count == 3)
    #expect(valuations.allSatisfy { $0.day >= set.firstDay && $0.day <= set.lastDay })
    for (earlier, later) in zip(valuations, valuations.dropFirst()) {
      #expect(later.valueE4 < earlier.valueE4, "\(earlier.day.iso) → \(later.day.iso)")
    }
    #expect(valuations.allSatisfy { $0.valueE4.raw > 0 })
  }

  /// The brokerage account: an investment valued at the end of every month of the history.
  @Test func theBrokerageAccountIsValuedEveryMonth() throws {
    let set = Self.layered(language: "ru")
    let brokerage = try #require(set.assets.first { $0.kind == .investment })
    #expect(brokerage.name == "Брокерский счёт" && brokerage.currency == .rub)
    let days = set.assetValuations.filter { $0.assetId == brokerage.id }.map(\.day)
    var expected: [DateOnly] = []
    var month = set.firstDay.monthKey
    while month <= set.lastDay.monthKey {
      let end = DateOnly(
        year: month.year, month: month.month, day: CalendarContext.moscow.daysInMonth(month))
      if end >= set.firstDay && end <= set.lastDay { expected.append(end) }
      month = month.next
    }
    #expect(days == expected)
    #expect(days.count >= 5)
    #expect(set.assetValuations.allSatisfy { $0.valueE4.raw > 0 })
  }

  /// The savings account of the loan layer is the cushion, and no other account is.
  @Test func theSavingsAccountIsTheCushion() throws {
    let set = Self.layered(language: "ru")
    let cushion = set.paymentMethods.filter(\.cushion)
    #expect(cushion.count == 1)
    let savings = try #require(cushion.first)
    #expect(savings.name == "Накопительный счёт" && savings.interest != nil && !savings.archived)
  }

  /// Groceries, utilities, the phone, the home internet, transport and health are essential;
  /// sport under health is marked not, and the rest of health inherits.
  @Test func theEssentialSpendingIsMarked() throws {
    let set = Self.layered(language: "ru")
    let tree = CategoryTree(set.categories)
    func category(_ name: String) throws -> CoreKit.Category {
      try #require(set.categories.first { $0.name == name && $0.kind == .expense }, "\(name)")
    }
    for name in [
      "Продукты", "Коммунальные услуги", "Мобильная связь", "Домашний интернет", "Транспорт",
      "Здоровье",
    ] {
      #expect(try category(name).essential == true, "\(name)")
      #expect(tree.isEssential(try category(name).id), "\(name)")
    }
    #expect(try category("Спорт").essential == false)
    #expect(!tree.isEssential(try category("Спорт").id))
    #expect(try category("Аптека").essential == nil)
    #expect(tree.isEssential(try category("Аптека").id))
    #expect(try category("Такси").essential == nil)
    #expect(tree.isEssential(try category("Такси").id))
    #expect(!tree.isEssential(try category("Рестораны").id))
    #expect(!set.categories.contains { $0.systemRole != nil && $0.essential == true })
    #expect(!set.categories.contains { $0.kind != .expense && $0.essential != nil })
  }

  /// The cushion goal: six months, no month to be complete by.
  @Test func theCushionGoalIsSixMonths() {
    let set = Self.layered()
    let settings = CapitalSettings(storedValues: set.settings)
    #expect(settings.targetMonths == 6)
    #expect(settings.targetMonth == nil && !settings.outOfFreeMoney)
  }

  /// The same seed gives the same assets; the layer is applied once.
  @Test func theLayerIsAppliedOnce() {
    let first = Self.layered()
    #expect(Self.layered().assetValuations == first.assetValuations)
    let again = first.withEveryFeature(seed: Self.seed, calendar: .moscow, language: "en")
    #expect(again.assets == first.assets && again.assetValuations == first.assetValuations)
  }

  /// A history of a month gets the cushion and the marks, but no car and no brokerage account.
  @Test func aShortHistoryGetsNoAssets() {
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let history = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: day, calendar: .moscow, language: "en")
    let set = history.withEveryFeature(seed: 3, calendar: .moscow, language: "en")
    #expect(set.assets.isEmpty && set.assetValuations.isEmpty)
    #expect(CapitalSettings(storedValues: set.settings).targetMonths == 6)
  }
}
