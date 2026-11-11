import CoreKit
import Foundation
import Testing

@testable import CoreParse

struct ScreenshotMatchTests {
  private let account = UUID()
  private let day = DateOnly(year: 2026, month: 9, day: 15)

  private func candidate(
    _ amount: Int64, hours: Int = 12, account: UUID? = nil,
    currency: CurrencyCode = .rub
  ) -> ScreenshotCandidate {
    ScreenshotCandidate(
      id: UUID(), accountID: account ?? self.account, kind: .expense,
      currency: currency, amount: AmountE4(whole: amount),
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(
        TimeInterval(hours * 3_600)))
  }

  private func match(_ candidates: [ScreenshotCandidate]) -> ScreenshotProposal {
    ScreenshotMatch.propose(
      amount: AmountE4(whole: 1_000), kind: .expense,
      currency: .rub, accountID: account, day: day, time: TimeOfDay(hour: 12, minute: 0),
      among: candidates, calendar: .utc)
  }

  @Test func exactWinsEvenWhenASimilarCandidateIsCloserInTime() {
    let exact = candidate(1_000, hours: 9)
    let similar = candidate(1_001)
    let proposal = match([similar, exact])
    #expect(proposal.matches == [exact])
    #expect(!proposal.isSimilar)
  }

  @Test func fallbackIncludesFivePercentAndTwentyFourHoursButNotBeyond() {
    let limit = candidate(1_050, hours: 36)
    let tooFar = candidate(1_000, hours: 37)
    let wrongSum = candidate(1_051)
    let wrongAccount = candidate(1_000, account: UUID())
    let wrongCurrency = candidate(1_000, currency: .usd)
    let proposal = match([limit, tooFar, wrongSum, wrongAccount, wrongCurrency])
    #expect(proposal.matches == [limit])
    #expect(proposal.isSimilar)
    #expect(match([wrongAccount, wrongCurrency]).matches.isEmpty)
  }

  @Test func sameAmountOnTheNextDayIsOnlyASuggestion() {
    let otherDay = candidate(1_000, hours: 25)
    #expect(match([otherDay]).isSimilar)
    #expect(match([otherDay]).matches == [otherDay])
  }

  @Test func aDateWithoutAClockCanMatchExactlyButCannotEstablishTwentyFourHours() {
    let similar = candidate(1_050)
    let exact = candidate(1_000)
    func propose(_ candidates: [ScreenshotCandidate]) -> ScreenshotProposal {
      ScreenshotMatch.propose(
        amount: AmountE4(whole: 1_000), kind: .expense, currency: .rub,
        accountID: account, day: day, time: nil, among: candidates, calendar: .utc)
    }
    #expect(propose([similar]).matches.isEmpty)
    #expect(propose([similar, exact]).matches == [exact])
  }

  @Test func deletedEntriesStayOutAndBothSidesOfATransferCanBeFound() throws {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day), amount: AmountE4(whole: 1_000))
    draft.paymentMethodId = account
    draft.normalizeSinglePart()
    var entry = try draft.materialize(timeZone: CalendarContext.utc.timeZone)
    entry.transaction.deletedAt = Date()
    let destination = UUID()
    let transfer = Transfer(
      occurredAt: CalendarContext.utc.moment(day, hour: 12, minute: 0),
      fromAccountId: account, fromCurrency: .rub, fromAmountE4: AmountE4(whole: 1_000),
      toAccountId: destination, toCurrency: .rub, toAmountE4: AmountE4(whole: 1_000))
    let candidates = ScreenshotMatch.candidates(entries: [entry], transfers: [transfer])
    #expect(candidates.count == 2)
    #expect(match(candidates).matches.first?.id == transfer.id)
    #expect(match(candidates).matches.first?.isTransfer == true)
    let incoming = ScreenshotMatch.propose(
      amount: AmountE4(whole: 1_000), kind: .income,
      currency: .rub, accountID: destination, day: day, time: nil, among: candidates, calendar: .utc
    )
    #expect(incoming.matches.first?.id == transfer.id)
  }
}
