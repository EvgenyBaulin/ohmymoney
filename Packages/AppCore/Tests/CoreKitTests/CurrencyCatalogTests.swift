import Foundation
import Testing

@testable import CoreKit

/// Custom currencies — USDT, bitcoin, points — sit next to the currencies of the bank: three
/// capital Latin letters that are no ISO 4217 code, the owner's name and symbol, 0…4 digits.
@Suite("The catalog of custom currencies")
struct CurrencyCatalogTests {
  let tether = CustomCurrency(
    code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 4, sort: 0)
  let points = CustomCurrency(
    code: CurrencyCode("PTS"), name: "баллы", symbol: nil, fractionDigits: 0, archived: true,
    sort: 1)

  var catalog: CurrencyCatalog { CurrencyCatalog(custom: [tether, points]) }

  @Test func aCustomCurrencyIsKnownByItsCodeArchivedOrNot() {
    #expect(catalog.isCustom(tether.code))
    #expect(catalog.isCustom(points.code))
    #expect(!catalog.isCustom(.usd))
    #expect(!CurrencyCatalog.empty.isCustom(tether.code))
    #expect(catalog.active == [tether])
  }

  @Test func itsDigitsSymbolAndNameAreTheOwners() {
    #expect(catalog.fractionDigits(tether.code) == 4)
    #expect(catalog.fractionDigits(points.code) == 0)
    #expect(catalog.fractionDigits(.usd) == 2)
    #expect(catalog.symbol(tether.code) == "₮")
    #expect(catalog.symbol(points.code) == nil)
    #expect(catalog.symbol(.usd) == nil)
    #expect(catalog.name(tether.code, language: "en") == "Tether")
    #expect(catalog.name(points.code, language: "ru") == "баллы")
    #expect(catalog.name(.eur, language: "ru") == nil)
  }

  @Test func aSymbolLeadsBackToItsCurrencyWhileItIsNotArchived() {
    #expect(catalog.code(forSymbol: "₮") == tether.code)
    #expect(catalog.code(forSymbol: " ₮ ") == tether.code)
    #expect(catalog.code(forSymbol: "$") == nil)
    let archived = CurrencyCatalog(custom: [
      CustomCurrency(code: CurrencyCode("BTX"), name: "Bit", symbol: "Ƀ", archived: true)
    ])
    #expect(archived.code(forSymbol: "Ƀ") == nil)
  }

  @Test func choicesAreTheEnabledOnesThenTheActiveCustomOnesWithNoLimit() {
    let enabled =
      CurrencyCode.defaultEnabled
      + ["GBP", "CHF", "JPY", "INR", "PLN"].map {
        CurrencyCode($0)
      }
    #expect(enabled.count == 15)
    let choices = catalog.choices(enabled: enabled)
    #expect(choices == enabled + [tether.code])
    #expect(catalog.choices(enabled: [tether.code, .rub]) == [tether.code, .rub])
  }

  @Test func aCodeMustBeThreeCapitalLettersThatAreNoISOCode() {
    #expect(CurrencyCatalog.refusal(newCode: "UST", existing: []) == nil)
    #expect(CurrencyCatalog.refusal(newCode: "BTC", existing: []) == nil)
    #expect(CurrencyCatalog.refusal(newCode: "usd", existing: []) == .notThreeCapitalLetters)
    #expect(CurrencyCatalog.refusal(newCode: "USDT", existing: []) == .notThreeCapitalLetters)
    #expect(CurrencyCatalog.refusal(newCode: "U1T", existing: []) == .notThreeCapitalLetters)
    #expect(CurrencyCatalog.refusal(newCode: "ÄBC", existing: []) == .notThreeCapitalLetters)
    #expect(CurrencyCatalog.refusal(newCode: "USD", existing: []) == .isoCode)
    #expect(CurrencyCatalog.refusal(newCode: "XAU", existing: []) == .isoCode)
    #expect(CurrencyCatalog.refusal(newCode: "RUB", existing: []) == .isoCode)
    #expect(CurrencyCatalog.refusal(newCode: "UST", existing: [tether]) == .alreadyThere)
  }

  @Test func theWholeCurrencyIsCheckedAndAnEditIsNoClashWithItself() {
    #expect(CurrencyCatalog.refusal(for: tether, existing: [tether, points]) == nil)
    var nameless = tether
    nameless.name = "  "
    #expect(CurrencyCatalog.refusal(for: nameless, existing: []) == .emptyName)
    var tooPrecise = tether
    tooPrecise.fractionDigits = 8
    #expect(CurrencyCatalog.refusal(for: tooPrecise, existing: []) == .fractionDigits)
  }

  @Test func aSymbolOfTheBanksCurrenciesIsRefused() {
    for sign in ["$", "€", "₽", "£", "¥", "₸", "руб.", "usd", "EUR"] {
      #expect(
        CurrencyCatalog.symbolRefusal(sign, code: tether.code, existing: [])
          == .symbolOfBankCurrency, "\(sign)")
    }
    #expect(CurrencyCatalog.symbolRefusal("₮", code: tether.code, existing: []) == nil)
    #expect(CurrencyCatalog.symbolRefusal(nil, code: tether.code, existing: []) == nil)
    #expect(CurrencyCatalog.symbolRefusal("  ", code: tether.code, existing: []) == nil)
    #expect(CurrencyCatalog.symbolRefusal("b1", code: tether.code, existing: []) == .symbolNotASign)
    #expect(
      CurrencyCatalog.symbolRefusal("a b", code: tether.code, existing: []) == .symbolNotASign)
    var dollarish = tether
    dollarish.symbol = "$"
    #expect(CurrencyCatalog.refusal(for: dollarish, existing: []) == .symbolOfBankCurrency)
  }

  @Test func aSymbolAnotherCustomCurrencyGoesByIsTaken() {
    let bitcoin = CustomCurrency(code: CurrencyCode("BTC"), name: "Bitcoin", symbol: "₮")
    #expect(CurrencyCatalog.refusal(for: bitcoin, existing: [tether]) == .symbolTaken)
    let byCode = CustomCurrency(code: CurrencyCode("BTC"), name: "Bitcoin", symbol: "ust")
    #expect(CurrencyCatalog.refusal(for: byCode, existing: [tether]) == .symbolTaken)
  }

  @Test func theISOListHoldsEveryCurrencyTheBankPublishesAndTheDefaults() {
    let published = [
      "AUD", "AZN", "DZD", "GBP", "AMD", "BHD", "BYN", "BGN", "BOB", "BRL", "HUF", "VND", "HKD",
      "GEL", "DKK", "AED", "USD", "EUR", "EGP", "INR", "IDR", "IRR", "KZT", "CAD", "QAR", "KGS",
      "CNY", "CUP", "MDL", "MNT", "NGN", "NZD", "NOK", "OMR", "PLN", "SAR", "RON", "XDR", "SGD",
      "TJS", "THB", "BDT", "TRY", "TMT", "UZS", "UAH", "CZK", "SEK", "CHF", "ETB", "RSD", "ZAR",
      "KRW", "JPY", "MMK",
    ]
    for code in published + CurrencyCode.defaultEnabled.map(\.code) {
      #expect(ISOCurrencies.contains(CurrencyCode(code)), "\(code)")
    }
    #expect(ISOCurrencies.codes.allSatisfy { $0.count == 3 && $0 == $0.uppercased() })
    #expect(!ISOCurrencies.contains(CurrencyCode("BTC")))
  }
}
