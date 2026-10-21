import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A dictionary that looks like a small but realistic database: Russian and English names,
/// aliases, one multi-word name in every list. Tests never touch the real database.
enum Fixture {
  static func id(_ tail: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(tail)")!
  }

  static let anya = id("01")
  static let masha = id("02")
  static let john = id("03")
  static let annaPetrova = id("04")

  static let pyaterochka = id("11")
  static let starbucks = id("12")
  static let azbuka = id("13")

  static let tinkoff = id("21")
  static let cash = id("22")

  static let birthday = id("31")
  static let georgiaTrip = id("32")

  static let flatGoal = id("41")
  static let macbookGoal = id("42")

  static let mortgage = id("51")
  static let carLoan = id("52")

  static let vocabulary = ParserVocabulary(
    people: [
      .init(id: anya, name: "Аня", aliases: ["Anya"]),
      .init(id: masha, name: "Маша"),
      .init(id: john, name: "John", aliases: ["Johnny"]),
      .init(id: annaPetrova, name: "Анна Петрова"),
    ],
    places: [
      .init(id: pyaterochka, name: "Пятёрочка", aliases: ["пятёрка"]),
      .init(id: starbucks, name: "Starbucks", aliases: ["Старбакс"]),
      .init(id: azbuka, name: "Азбука вкуса"),
    ],
    paymentMethods: [
      .init(id: tinkoff, name: "Тинькофф", aliases: ["тинек"]),
      .init(id: cash, name: "Cash", aliases: ["наличные"]),
    ],
    events: [
      .init(id: birthday, name: "День рождения", aliases: ["birthday"]),
      .init(id: georgiaTrip, name: "Trip to Georgia"),
    ],
    goals: [
      .init(id: flatGoal, name: "Квартира"),
      .init(id: macbookGoal, name: "MacBook", aliases: ["мак"]),
    ],
    debts: [
      .init(id: mortgage, name: "Ипотека"),
      .init(id: carLoan, name: "Car loan", aliases: ["car"]),
    ]
  )

  /// Fixed so no test depends on the current date, and UTC so none depends on the zone.
  static let today = DateOnly(year: 2026, month: 9, day: 18)
  static let parser = InputLineParser(vocabulary: vocabulary, calendar: .utc)

  static func parse(_ line: String) -> ParsedInput {
    parser.parse(line, today: today)
  }
}

func dec(_ text: String) -> Decimal {
  Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

/// One row of the parser table. Written with a builder so a case reads like a sentence and
/// everything left out is expected to be `nil`.
struct LineCase: Sendable, CustomTestStringConvertible {
  var line: String
  var amount: Decimal?
  var expression: String?
  var kind: TransactionKind = .expense
  var currency: String?
  var date: String?
  var forWhom: ForWhom?
  var personId: UUID?
  var placeId: UUID?
  var eventId: UUID?
  var paymentMethodId: UUID?
  var goalId: UUID?
  var debtId: UUID?
  var unknownPerson: String?
  var unknownPlace: String?
  var note: String = ""

  init(_ line: String) {
    self.line = line
  }

  var testDescription: String { line }

  func amount(_ value: String) -> Self { with { $0.amount = dec(value) } }
  func expression(_ value: String) -> Self { with { $0.expression = value } }
  func kind(_ value: TransactionKind) -> Self { with { $0.kind = value } }
  func currency(_ value: String) -> Self { with { $0.currency = value } }
  func date(_ value: String) -> Self { with { $0.date = value } }
  func forWhom(_ value: ForWhom) -> Self { with { $0.forWhom = value } }
  func person(_ value: UUID) -> Self { with { $0.personId = value } }
  func place(_ value: UUID) -> Self { with { $0.placeId = value } }
  func event(_ value: UUID) -> Self { with { $0.eventId = value } }
  func payment(_ value: UUID) -> Self { with { $0.paymentMethodId = value } }
  func goal(_ value: UUID) -> Self { with { $0.goalId = value } }
  func debt(_ value: UUID) -> Self { with { $0.debtId = value } }
  func unknownPerson(_ value: String) -> Self { with { $0.unknownPerson = value } }
  func unknownPlace(_ value: String) -> Self { with { $0.unknownPlace = value } }
  func note(_ value: String) -> Self { with { $0.note = value } }

  private func with(_ change: (inout Self) -> Void) -> Self {
    var copy = self
    change(&copy)
    return copy
  }
}
