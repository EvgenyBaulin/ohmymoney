import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// The two files schema 15 brought, and the columns it added to four older ones.
@Suite("The export of bank conditions, deposits and the columns of schema 15")
struct BankConditionsExportTests {
  private func roundTrip(_ table: ExportTable, row: [String]) throws -> [String: String] {
    #expect(row.count == table.columns.count)
    var writer = CSVWriter(columns: table.columns)
    writer.append(row)
    let dictionaries = try CSVReader.dictionaries(from: writer.data())
    #expect(dictionaries.count == 1)
    return dictionaries[0]
  }

  @Test func conditionsKeepAnAmountNotStatedEmptyAndNeverZero() throws {
    let account = UUID()
    let card = UUID()
    let conditions = BankConditions(
      accountId: account, cardId: card, currency: .usd, freeCashE4: AmountE4(whole: 100_000),
      freeSbpE4: .zero, minBalanceE4: AmountE4(raw: 15_000), note: "без «сюрпризов», \"да\"")
    let read = try roundTrip(ExportTables.bankConditions, row: ExportTables.row(conditions))
    #expect(read["id"] == conditions.id.uuidString)
    #expect(read["payment_method_id"] == account.uuidString)
    #expect(read["card_id"] == card.uuidString)
    #expect(read["currency"] == "USD")
    #expect(read["free_cash"] == "100000")
    #expect(read["free_sbp"] == "0")
    #expect(read["free_interbank"] == "")
    #expect(read["service_free_spend"] == "")
    #expect(read["service_free_balance"] == "")
    #expect(read["min_balance"] == "1.5")
    #expect(read["note"] == "без «сюрпризов», \"да\"")

    let own = BankConditions(accountId: account)
    #expect(try roundTrip(ExportTables.bankConditions, row: ExportTables.row(own))["card_id"] == "")
  }

  @Test func anOfferKeepsItsRateExactly() throws {
    let offer = DepositOffer(
      bankName: "Банк, «Вклад»", ratePercent: Decimal(string: "15.25")!, termMonths: 12,
      minAmountE4: AmountE4(whole: 50_000), newClientOnly: true, topup: true,
      rateOn: DateOnly(year: 2026, month: 10, day: 1), note: "акция", archived: true)
    let read = try roundTrip(ExportTables.depositOffers, row: ExportTables.row(offer))
    #expect(read["bank_name"] == "Банк, «Вклад»")
    #expect(read["rate_percent"] == "15.25")
    #expect(read["term_months"] == "12")
    #expect(read["min_amount"] == "50000")
    #expect(read["max_amount"] == "")
    #expect(read["new_client_only"] == "true")
    #expect(read["needs_subscription"] == "false")
    #expect(read["topup"] == "true")
    #expect(read["rate_on"] == "2026-10-01")
    #expect(read["note"] == "акция")
    #expect(read["archived"] == "true")
  }

  @Test func theColumnsOfSchemaFifteenComeLast() throws {
    #expect(ExportTables.paymentMethods.columns.last == "accent")
    #expect(ExportTables.cards.columns.last == "expires_on")
    #expect(Array(ExportTables.customCurrencies.columns.suffix(2)) == ["rate_source", "coin_id"])
    #expect(Array(ExportTables.expectedIncome.columns.suffix(2)) == ["payout_kind", "asset_id"])
    #expect(
      Array(ExportTables.all.dropLast().suffix(2).map(\.fileName)) == [
        "bank_conditions.csv", "deposit_offers.csv",
      ])

    let method = PaymentMethod(name: "Карта", accent: "07")
    #expect(
      try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(method))["accent"] == "07")
    let card = PaymentCard(
      accountId: UUID(), name: "Visa", expiresOn: MonthKey(year: 2029, month: 3))
    #expect(
      try roundTrip(ExportTables.cards, row: ExportTables.row(card))["expires_on"] == "2029-03")
    let coin = CustomCurrency(
      code: CurrencyCode("BTC"), name: "Bitcoin", rateSource: .coingecko, coinId: "bitcoin")
    let currency = try roundTrip(ExportTables.customCurrencies, row: ExportTables.row(coin))
    #expect(currency["rate_source"] == "coingecko")
    #expect(currency["coin_id"] == "bitcoin")
    let asset = UUID()
    let income = ExpectedIncome(
      name: "Дивиденды", totalE4: AmountE4(whole: 1_000), payoutKind: .dividend, assetId: asset)
    let payout = try roundTrip(ExportTables.expectedIncome, row: ExportTables.row(income))
    #expect(payout["payout_kind"] == "dividend")
    #expect(payout["asset_id"] == asset.uuidString)

    // Nothing stated is empty, as it was before the columns existed.
    let plain = try roundTrip(
      ExportTables.expectedIncome,
      row: ExportTables.row(ExpectedIncome(name: "Аванс", totalE4: AmountE4(whole: 1))))
    #expect(plain["payout_kind"] == "")
    #expect(plain["asset_id"] == "")
  }
}
