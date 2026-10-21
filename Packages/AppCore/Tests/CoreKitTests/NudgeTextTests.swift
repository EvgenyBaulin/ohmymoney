import Foundation
import Testing

@testable import CoreKit

/// «Верни, когда сможешь»: a polite text from a template, and the owner's edit kept as one.
@Suite("Nudge text: fields, phrases, the edit as a template")
struct NudgeTextTests {
  static let template = "{имя}, привет! Вернёшь {сумма}[ за {за что}][ до {дата}], когда сможешь?"

  @Test func fieldsAreFilledAndEmptyPhrasesLeft() {
    #expect(
      NudgeText.make(
        template: Self.template, name: "Аня", amount: "2,000 ₽", reason: "билеты", day: "1 ноября")
        == "Аня, привет! Вернёшь 2,000 ₽ за билеты до 1 ноября, когда сможешь?")
    #expect(
      NudgeText.make(template: Self.template, name: "Аня", amount: "2,000 ₽", reason: nil, day: nil)
        == "Аня, привет! Вернёшь 2,000 ₽, когда сможешь?")
    #expect(
      NudgeText.make(
        template: "Hi {name}, could you send {amount} for {for}?", name: "Ann", amount: "$20",
        reason: nil, day: nil) == "Hi Ann, could you send $20 for?")
    #expect(
      NudgeText.make(
        template: "Hi {name}, {amount}[ for {for}]?", name: "Ann", amount: "$20", reason: "tickets",
        day: nil) == "Hi Ann, $20 for tickets?")
  }

  @Test func theEditBecomesTheTemplate() {
    let values = NudgeText.Values(name: "Аня", amount: "2,000 ₽", reason: "билеты", day: nil)
    let edited = "Аня, напоминаю про 2,000 ₽ за билеты 🙂"
    let template = NudgeText.template(fromEdited: edited, values: values)
    #expect(template == "{имя}, напоминаю про {сумма} за {за что} 🙂")
    #expect(
      NudgeText.make(template: template, name: "Борис", amount: "500 ₽", reason: "кофе", day: nil)
        == "Борис, напоминаю про 500 ₽ за кофе 🙂")
    let english = NudgeText.template(
      fromEdited: "Ann, the $20 please", values: NudgeText.Values(name: "Ann", amount: "$20"))
    #expect(english == "{name}, the {amount} please")
  }
}
