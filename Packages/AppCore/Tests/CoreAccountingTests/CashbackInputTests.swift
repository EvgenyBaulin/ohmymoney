import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// What the field «Кэшбэк» reads: an amount like every typed amount, a percent like a rate.
@Suite("The cashback field's text")
struct CashbackInputTests {
  func percent(_ e4: Int64) -> CashbackInput { .percent(CashbackPercent(e4: e4)!) }

  @Test func anAmount() {
    #expect(CashbackInput.read("45") == .amount(money(45)))
    #expect(CashbackInput.read(" 12,50 ") == .amount(money("12.5")))
    // A lone comma before exactly three digits groups thousands, as every typed amount.
    #expect(CashbackInput.read("1,500") == .amount(money(1500)))
    #expect(CashbackInput.read("0") == .amount(.zero))
  }

  @Test func aPercent() {
    #expect(CashbackInput.read("5%") == percent(50_000))
    #expect(CashbackInput.read("5 %") == percent(50_000))
    #expect(CashbackInput.read("1,5%") == percent(15_000))
    #expect(CashbackInput.read("0.75%") == percent(7_500))
    #expect(CashbackInput.read("100%") == percent(1_000_000))
  }

  @Test func whatDoesNotRead() {
    #expect(CashbackInput.read("150%") == .unreadable(.percentAboveHundred))
    #expect(CashbackInput.read("1.23456%") == .unreadable(.percentTooPrecise))
    #expect(CashbackInput.read("-3") == .unreadable(.negative))
    #expect(CashbackInput.read("-3%") == .unreadable(.negative))
    #expect(CashbackInput.read("abc") == .unreadable(.malformed))
    #expect(CashbackInput.read("%") == .unreadable(.malformed))
    #expect(CashbackInput.read("9" + String(repeating: "9", count: 400)) == .unreadable(.tooLarge))
    #expect(CashbackInput.read("2000000000000") == .unreadable(.tooLarge))
  }

  @Test func anEmptyFieldIsNothing() {
    #expect(CashbackInput.read("") == nil)
    #expect(CashbackInput.read("   ") == nil)
  }
}
