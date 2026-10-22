import Foundation
import Testing

@testable import CoreKit

/// A number with the check digit that makes it valid, built from the digits before it.
private func withCheckDigit(_ body: String) -> String {
  for check in 0...9 where CardDetails.isValid(number: body + String(check)) {
    return body + String(check)
  }
  return body
}

@Suite("Card data")
struct CardDetailsTests {
  @Test func theLastDigitsAreTakenFromTheNumber() {
    let number = withCheckDigit("220070123456789")
    let details = CardDetails(number: number)
    #expect(details.last4 == String(number.suffix(4)))
    #expect(details.problems.isEmpty)
    #expect(details.masked == "•••• " + number.suffix(4))
  }

  @Test func theNumberIsReadFromWhatTheOwnerTypes() {
    #expect(CardDetails.digits("2200 7012 3456 7890") == "2200701234567890")
    #expect(CardDetails.digits("2200-7012-3456-7890 ") == "2200701234567890")
    #expect(CardDetails(number: "4111 1111 1111 1111").number == "4111111111111111")
  }

  @Test func theCheckDigitCatchesASlip() {
    #expect(CardDetails.isValid(number: "4111111111111111"))
    #expect(!CardDetails.isValid(number: "4111111111111112"))
    #expect(!CardDetails.isValid(number: "41111111111"))
    #expect(!CardDetails.isValid(number: "41111111111111111111"))
    #expect(!CardDetails.isValid(number: "4111a11111111111"))
    #expect(CardDetails(number: "4111111111111112").problems == [.badNumber])
  }

  @Test func onlyTheLastDigitsMakeACardToo() {
    let details = CardDetails(last4: "3230")
    #expect(details.problems.isEmpty)
    #expect(details.number == nil)
    #expect(CardDetails(last4: "32a0").problems == [.badLast4])
    #expect(CardDetails(last4: "323").problems == [.badLast4])
  }

  @Test func theLastDigitsMustAgreeWithTheNumber() {
    let details = CardDetails(last4: "0000", number: "4111111111111111")
    #expect(details.problems == [.last4DoesNotMatchNumber])
  }

  @Test func theSystemIsFoundByTheFirstDigits() {
    #expect(CardDetails.network(of: "2200701234567890") == .mir)
    #expect(CardDetails.network(of: "4111111111111111") == .visa)
    #expect(CardDetails.network(of: "5555555555554444") == .mastercard)
    #expect(CardDetails.network(of: "2221000000000009") == .mastercard)
    #expect(CardDetails.network(of: "6759649826438453") == .maestro)
    #expect(CardDetails.network(of: "6200000000000005") == .unionpay)
    #expect(CardDetails.network(of: "378282246310005") == .amex)
    #expect(CardDetails.network(of: "9999999999999999") == nil)
    #expect(CardDetails.network(of: "4111") == nil)
    #expect(CardDetails(number: "4111111111111111").network == .visa)
  }

  @Test func theExpiryIsReadInTheWaysItIsWritten() {
    let may2028 = MonthKey(year: 2028, month: 5)
    #expect(CardDetails.expiry(from: "05/28") == may2028)
    #expect(CardDetails.expiry(from: "5/2028") == may2028)
    #expect(CardDetails.expiry(from: "05.28") == may2028)
    #expect(CardDetails.expiry(from: "2028-05") == may2028)
    #expect(CardDetails.expiry(from: "13/28") == nil)
    #expect(CardDetails.expiry(from: "0528") == nil)
    #expect(CardDetails.expiry(from: "05/1899") == nil)
    #expect(CardDetails.expiry(from: "") == nil)
  }

  @Test func aCardRunsOutAtTheEndOfItsMonth() {
    let details = CardDetails(expiry: MonthKey(year: 2026, month: 10))
    #expect(!details.isExpired(on: DateOnly(year: 2026, month: 10, day: 31)))
    #expect(details.isExpired(on: DateOnly(year: 2026, month: 11, day: 1)))
    #expect(!CardDetails().isExpired(on: DateOnly(year: 2099, month: 1, day: 1)))
    #expect(CardDetails(expiry: MonthKey(year: 2026, month: 13)).problems == [.badExpiry])
  }

  @Test func thereIsNoPlaceForASecurityCode() throws {
    let data = try JSONEncoder().encode(
      CardDetails(
        last4: "3230", number: "4111111111111111", holder: "A",
        expiry: MonthKey(year: 2028, month: 5)))
    let keys = Set(
      try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
    #expect(keys.isSubset(of: ["last4", "number", "holder", "expiry", "network"]))
    #expect(
      !keys.contains(where: { $0.lowercased().contains("cvv") || $0.lowercased().contains("cvc") }))
  }

  @Test func theCardSurvivesTheArchive() throws {
    let card = CardDetails(
      number: withCheckDigit("220070123456789"), holder: "IVAN IVANOV",
      expiry: MonthKey(year: 2028, month: 5))
    let back = try JSONDecoder().decode(CardDetails.self, from: JSONEncoder().encode(card))
    #expect(back == card)
  }
}

@Suite("Notes of days and lines for later")
struct QuickEntryRecordsTests {
  let day = DateOnly(year: 2026, month: 10, day: 12)
  let now = Date(timeIntervalSince1970: 1_760_000_000)

  @Test func aNoteIsTrimmedAndKept() throws {
    let note = try #require(
      DayNote.cleaned(day: day, text: "  день рождения мамы \n", updatedAt: now))
    #expect(note.text == "день рождения мамы")
    #expect(note.day == day)
  }

  @Test func anEmptyNoteIsNoNote() {
    #expect(DayNote.cleaned(day: day, text: "  \n ", updatedAt: now) == nil)
  }

  @Test func aNoteHasALimit() throws {
    let note = try #require(
      DayNote.cleaned(
        day: day, text: String(repeating: "я", count: DayNote.maxLength + 50), updatedAt: now)
    )
    #expect(note.text.count == DayNote.maxLength)
  }

  @Test func oneNotePerDayAndAnEmptyTextRemovesIt() {
    var notes = DayNotes()
    notes.set("первая", on: day, at: now)
    notes.set("вторая", on: day, at: now.addingTimeInterval(60))
    #expect(notes[day]?.text == "вторая")
    #expect(notes.all.count == 1)
    #expect(notes.set("", on: day, at: now) == nil)
    #expect(notes[day] == nil)
  }

  @Test func notesOfAStretchAreInOrder() {
    var notes = DayNotes()
    notes.set("c", on: DateOnly(year: 2026, month: 10, day: 20), at: now)
    notes.set("a", on: DateOnly(year: 2026, month: 10, day: 2), at: now)
    notes.set("b", on: DateOnly(year: 2026, month: 10, day: 12), at: now)
    notes.set("out", on: DateOnly(year: 2026, month: 11, day: 1), at: now)
    let found = notes.notes(
      in: DateOnly(year: 2026, month: 10, day: 1)...DateOnly(year: 2026, month: 10, day: 31))
    #expect(found.map(\.text) == ["a", "b", "c"])
  }

  @Test func twoRowsOfOneDayKeepTheLaterOne() {
    let older = DayNote.cleaned(day: day, text: "старая", updatedAt: now)!
    let newer = DayNote.cleaned(day: day, text: "новая", updatedAt: now.addingTimeInterval(5))!
    #expect(DayNotes([newer, older])[day]?.text == "новая")
    #expect(DayNotes([older, newer])[day]?.text == "новая")
  }

  @Test func theStoredNamesAreFixed() {
    #expect(DayNoteStorage.table == "day_notes")
    #expect(PendingDraft.tableName == "pending_drafts")
    #expect(PendingDraft.csvColumns == ["id", "text", "created_at", "resolved_at"])
  }

  @Test func aDraftIsAWaitingLine() throws {
    let draft = try #require(PendingDraft(text: " ужин с Машей, потом дописать ", createdAt: now))
    #expect(draft.isWaiting)
    #expect(draft.text == "ужин с Машей, потом дописать")
    #expect(PendingDraft(text: "   ", createdAt: now) == nil)
  }

  @Test func aDraftSurvivesTheArchive() throws {
    let draft = try #require(
      PendingDraft(text: "кофе", createdAt: now, resolvedAt: now.addingTimeInterval(9)))
    let back = try JSONDecoder().decode(PendingDraft.self, from: JSONEncoder().encode(draft))
    #expect(back == draft)
    #expect(!back.isWaiting)
  }
}
