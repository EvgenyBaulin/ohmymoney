import Foundation
import Testing

@testable import CoreKit

@Suite("A bank holds accounts")
struct BankModelTests {
  @Test func aNewBankIsLiveAndUnordered() {
    let bank = Bank(name: "Сбер")
    #expect(bank.name == "Сбер")
    #expect(bank.sort == 0)
    #expect(!bank.archived)
  }

  @Test func anAccountHasNoBankUntilItIsFiledUnderOne() {
    #expect(PaymentMethod(name: "Cash").bankId == nil)
    let bank = Bank(name: "Т-Банк")
    let account = PaymentMethod(name: "Black", bankId: bank.id)
    #expect(account.bankId == bank.id)
  }

  /// An account written before banks existed has no `bankId` in its encoding; it still reads.
  @Test func anAccountEncodedWithoutABankStillDecodes() throws {
    let account = PaymentMethod(name: "Card", kind: .account, currency: .usd)
    let data = try JSONEncoder().encode(account)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("bankId"))
    #expect(try JSONDecoder().decode(PaymentMethod.self, from: data) == account)
  }

  @Test func theBankOfAnAccountSurvivesAnEncoding() throws {
    let account = PaymentMethod(name: "Black", bankId: UUID())
    let data = try JSONEncoder().encode(account)
    #expect(try JSONDecoder().decode(PaymentMethod.self, from: data).bankId == account.bankId)
  }

  @Test func aBankSurvivesAnEncoding() throws {
    let bank = Bank(name: "ВТБ", sort: 3, archived: true)
    let data = try JSONEncoder().encode(bank)
    #expect(try JSONDecoder().decode(Bank.self, from: data) == bank)
  }
}
