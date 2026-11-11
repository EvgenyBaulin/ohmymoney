import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Dated thing valuations with their own currencies")
struct ThingValuationTests {
  private let day = DateOnly(year: 2026, month: 11, day: 11)

  @Test func storedEntryRoundTripsAndHasAnIndependentSyncKey() throws {
    let entry = ThingValuation(
      owner: .ownedItem, ownerId: UUID(), day: day,
      amountE4: AmountE4(raw: 123_456), currency: CurrencyCode("EUR"), note: "Synthetic")
    #expect(try ThingValuation.decode(try entry.storedValue) == entry)
    #expect(entry.storageKey == ThingValuation.storagePrefix + entry.id.uuidString)
  }

  @Test func latestExcludesFutureAndOtherOwnersAndKeepsPurchaseDay() {
    let item = OwnedItem(
      name: "Desk", boughtOn: DateOnly(year: 2026, month: 1, day: 1),
      priceE4: AmountE4(whole: 100))
    let current = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 80), currency: CurrencyCode("USD"), note: "Value")
    var future = current
    future.id = UUID()
    future.day = DateOnly(year: 2027, month: 1, day: 1)
    future.amountE4 = AmountE4(whole: 1)
    let subject = OwnershipSubject(
      item: item, valuations: [future, current], today: day,
      rubPerUnit: [CurrencyCode("USD"): 90])
    #expect(subject.priceRubE4 == AmountE4(whole: 7200))
    #expect(subject.boughtOn == item.boughtOn)
    #expect(item.priceE4 == AmountE4(whole: 100))
  }

  @Test func revaluationDoesNotCountTheTaggedPurchaseAgain() {
    let bought = CapitalFx.day("2026-01-01")
    let tag = Tag(name: "Desk")
    let purchase = CapitalFx.operation(1, bought.iso, "100")
    let item = OwnedItem(
      name: "Desk", boughtOn: bought,
      priceE4: AmountE4(whole: 100), tagId: tag.id)
    let value = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 80), currency: .rub)
    let subject = OwnershipSubject(item: item, valuations: [value], today: day, rubPerUnit: [:])
    let cost = OwnershipCost.compute(
      subject, entries: [purchase],
      tagBook: TagBook(
        tags: [tag], links: purchase.parts.map { PartTag(partId: $0.id, tagId: tag.id) }),
      today: day, calendar: .utc)
    #expect(cost.runningRubE4 == .zero)
    #expect(cost.totalRubE4 == AmountE4(whole: 80))
  }

  @Test func privacyAndPeriodCopiesIncludeNewObservations() {
    let value = ThingValuation(
      owner: .ownedItem, ownerId: UUID(), day: day,
      amountE4: AmountE4(whole: 1), currency: .rub, note: "Private")
    var dataset = Dataset()
    dataset.thingValuations = [value]
    let anonymous = Anonymizer.apply(to: dataset)
    #expect(anonymous.thingValuations.first?.note == nil)
    #expect(dataset.thingValuations.first?.note == "Private")
    let before = DayRange(CapitalFx.day("2026-01-01"), CapitalFx.day("2026-10-01"))
    #expect(PeriodScope.apply(before, to: dataset).thingValuations.isEmpty)
  }

  @Test func unknownExchangeRateDoesNotTreatForeignMoneyAsRubles() {
    let item = OwnedItem(name: "Desk", priceE4: AmountE4(whole: 100))
    let value = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 80), currency: CurrencyCode("USD"))
    let subject = OwnershipSubject(item: item, valuations: [value], today: day, rubPerUnit: [:])
    #expect(subject.priceRubE4 == nil)
  }
}

@Suite("Latest thing valuations in net worth")
struct ThingValuationCapitalTests {
  @Test func anOwnedThingEntersCapitalOnceAndUsesItsObservationCurrency() {
    let day = CapitalFx.day("2026-11-11")
    let item = OwnedItem(
      name: "Desk", boughtOn: CapitalFx.day("2026-01-01"),
      priceE4: AmountE4(whole: 100))
    var dataset = Dataset(ownedItems: [item])
    dataset.thingValuations = [
      ThingValuation(
        owner: .ownedItem, ownerId: item.id, day: CapitalFx.day("2026-10-01"),
        amountE4: AmountE4(whole: 80), currency: CurrencyCode("USD")),
      ThingValuation(
        owner: .ownedItem, ownerId: item.id, day: day,
        amountE4: AmountE4(whole: 70), currency: CurrencyCode("EUR")),
      ThingValuation(
        owner: .ownedItem, ownerId: item.id, day: CapitalFx.day("2027-01-01"),
        amountE4: AmountE4(whole: 1), currency: .rub),
    ]
    let capital = CapitalFx.capital(dataset, today: day, rates: [CurrencyCode("EUR"): 100])
    #expect(capital.now.assetsRub == AmountE4(whole: 7000))
    #expect(capital.breakdown.have.count == 1)
  }

  @Test func updatesOverrideLegacyValuationsWithoutDoubleCountingAndMissingRateIsReported() {
    let day = CapitalFx.day("2026-11-11")
    let asset = Asset(name: "Car")
    var dataset = Dataset(
      assets: [asset],
      assetValuations: [
        AssetValuation(
          assetId: asset.id, day: CapitalFx.day("2026-01-01"),
          valueE4: AmountE4(whole: 100))
      ])
    dataset.thingValuations = [
      ThingValuation(
        owner: .asset, ownerId: asset.id, day: day,
        amountE4: AmountE4(whole: 80), currency: CurrencyCode("USD"))
    ]
    let missing = CapitalFx.capital(dataset, today: day)
    #expect(missing.now.assetsRub == .zero)
    #expect(missing.now.withoutRate == [CurrencyCode("USD")])
    let capital = CapitalFx.capital(dataset, today: day, rates: [CurrencyCode("USD"): 90])
    #expect(capital.now.assetsRub == AmountE4(whole: 7200))
    #expect(capital.breakdown.have.count == 1)
  }

  @Test func differentOwnerTablesMayUseTheSameIdentifier() {
    let day = CapitalFx.day("2026-11-11")
    let id = UUID()
    let asset = Asset(id: id, name: "Car")
    let item = OwnedItem(id: id, name: "Desk")
    var dataset = Dataset(
      assets: [asset],
      assetValuations: [
        AssetValuation(assetId: id, day: day, valueE4: AmountE4(whole: 100))
      ], ownedItems: [item])
    dataset.thingValuations = [
      ThingValuation(
        owner: .ownedItem, ownerId: id, day: day,
        amountE4: AmountE4(whole: 80), currency: .rub)
    ]
    let capital = CapitalFx.capital(dataset, today: day)
    #expect(capital.now.assetsRub == AmountE4(whole: 180))
    #expect(capital.breakdown.have.count == 2)
  }
}
