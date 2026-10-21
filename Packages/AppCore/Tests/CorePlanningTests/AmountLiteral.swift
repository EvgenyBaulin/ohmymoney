import CoreKit
import Foundation
import Testing

/// An amount as the planning suites write it: a plain decimal, a dot and at most four places —
/// «1250.5», «-0.25». Every `money` and `rub` helper of this target reads through here; each
/// suite keeps its own helper, so its numbers never move with another's, but a typo reads the
/// same everywhere: a failed test that names it. `Decimal(string:)` alone read the longest
/// number it found at the start — «1 000» as 1, «1000 ₽» as 1000 — and «abc» as zero.
func amountLiteral(_ text: String) -> AmountE4 {
  guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]{1,4})?/) != nil,
    let decimal = Decimal(string: text), let amount = try? AmountE4(decimal: decimal)
  else {
    Issue.record("«\(text)» is not an amount: write a plain decimal, such as 1250.5")
    return .zero
  }
  return amount
}

@Suite("Amount literals of the planning fixtures")
struct AmountLiteralTests {
  struct Savings: SavingsFixtures {}

  static let typos = ["1 000", "1,000", "1000 ₽", "1e3", ".5", "0.12345", "abc", ""]

  @Test(arguments: typos)
  func aTypoIsAFailedTest(_ text: String) {
    withKnownIssue { _ = SchedFx.money(text) }
    withKnownIssue { _ = ReconcileSketch.money(text) }
    withKnownIssue { _ = DebtsTests().money(text) }
    withKnownIssue { _ = Savings().rub(text) }
    withKnownIssue { _ = amountLiteral(text) }
  }

  @Test func aPlainDecimalIsTheAmount() {
    #expect(amountLiteral("-1234.5") == AmountE4(raw: -12_345_000))
    #expect(amountLiteral("0.0001") == AmountE4(raw: 1))
    #expect(Savings().rub("50000") == AmountE4(whole: 50_000))
  }
}
