import CoreKit
import Foundation
import Testing

@testable import CoreParse

// Synthetic data only.

@Suite("A bank's text gives the stored merchant code and commission")
struct BankMessageStoredFieldsTests {
  @Test func aBankTextGivesTheCodeAndAFeeOfTheOperationsCurrencyOnly() {
    var message = BankMessage(
      operation: .purchase, money: Money(amount: AmountE4(whole: 100), currency: .rub))
    #expect(message.merchantCode == nil && message.storedFields == nil)
    message.mcc = 742
    message.fee = Money(amount: AmountE4(raw: 12_500), currency: .rub)
    #expect(message.merchantCode == "0742")
    let fields = message.storedFields
    #expect(fields?.mcc == "0742")
    #expect(fields?.commission(in: .rub) == AmountE4(raw: 12_500))
    #expect(fields?.commission(in: CurrencyCode("USD")) == nil)
    message.mcc = 12_345
    message.fee = Money(amount: .zero, currency: .rub)
    #expect(message.merchantCode == nil)
    #expect(message.storedFields?.commission(in: .rub) == nil)
    message.fee = nil
    #expect(message.storedFields == nil)
  }

  @Test func theFieldsRoundTripAsJSONForTheDraftThatKeepsThem() throws {
    let fields = BankStoredFields(
      mcc: "5", fee: Money(amount: AmountE4(raw: 1), currency: CurrencyCode("EUR")))
    #expect(fields.mcc == "0005")
    let back = try JSONDecoder().decode(
      BankStoredFields.self, from: JSONEncoder().encode(fields))
    #expect(back == fields)
  }
}
