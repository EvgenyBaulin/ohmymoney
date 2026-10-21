import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Random lines put together from parts whose meaning is known — words of a note, an amount
/// written every way a person types one, a currency, a date, a place, a person, the sign of
/// income — in a random order. Whatever the order, the parser gives every part back: the amount
/// and its currency, the day, the place, the person, and the note with the very words of the
/// note in the order they were typed.
@Suite("Random lines give back what they were made of")
struct LinePropertyTests {
  @Test("Every part of a random line is read, whatever the order")
  func everyPartIsRead() {
    var dice = LineDice(seed: 20_261_006)
    var failures = 0
    for _ in 0..<20_000 {
      let line = RandomLine(dice: &dice)
      let parsed = Fixture.parse(line.text)
      var problems: [String] = []
      if parsed.amount != line.amount {
        problems.append("amount \(parsed.amount.map { "\($0)" } ?? "nil") ≠ \(line.amount)")
      }
      if parsed.currency?.code != line.currency {
        problems.append("currency \(parsed.currency?.code ?? "nil") ≠ \(line.currency ?? "nil")")
      }
      if parsed.date != line.date {
        problems.append("date \(parsed.date.map { "\($0)" } ?? "nil")")
      }
      if parsed.placeId != line.place { problems.append("place") }
      if parsed.personId != line.person { problems.append("person") }
      if parsed.kind != line.kind { problems.append("kind \(parsed.kind)") }
      if parsed.note != line.note { problems.append("note «\(parsed.note)» ≠ «\(line.note)»") }
      // The amount the line shows before Enter is the amount it saves.
      if let canonical = parsed.amountCanonicalText, let amount = parsed.amount,
        (try? ExpressionEvaluator.evaluate(canonical)) != amount
      {
        problems.append("canonical «\(canonical)» is not \(amount)")
      }
      guard !problems.isEmpty else { continue }
      failures += 1
      if failures <= 25 {
        Issue.record("«\(line.text)»: \(problems.joined(separator: "; "))")
      }
    }
    #expect(failures == 0, "\(failures) lines read wrong")
  }
}

/// One random line and what it says.
private struct RandomLine {
  var text = ""
  var amount: Decimal
  var currency: String?
  var date: DateOnly?
  var place: UUID?
  var person: UUID?
  var kind: TransactionKind = .expense
  var note = ""

  init(dice: inout LineDice) {
    var pieces: [String] = []
    var noteWords: [String] = []
    for _ in 0..<dice.below(3) {
      noteWords.append(
        dice.pick(["кофе", "такси", "подарок", "книга", "coffee", "groceries", "билеты", "шарф"]))
    }
    // The amount, with the currency glued to it or standing beside it.
    let written = Self.amount(&dice)
    amount = written.value
    var amountWord = written.text
    var currencyWord: String?
    switch dice.below(9) {
    case 0:
      amountWord += "₽"
      currency = "RUB"
    case 1:
      amountWord = "$" + amountWord
      currency = "USD"
    case 2:
      amountWord += "€"
      currency = "EUR"
    case 3:
      currencyWord = dice.pick(["руб", "рублей", "р"])
      currency = "RUB"
    case 4:
      currencyWord = dice.pick(["usd", "USD", "долларов", "bucks"])
      currency = "USD"
    case 5:
      currencyWord = dice.pick(["евро", "EUR", "euro"])
      currency = "EUR"
    default: break
    }
    if dice.below(6) == 0 {
      amountWord = "+" + amountWord
      kind = .income
    }
    // A currency word goes right behind the amount: elsewhere it is free to stand, but one in
    // capitals ahead of the number is a word like any other.
    pieces.append(currencyWord.map { amountWord + " " + $0 } ?? amountWord)
    switch dice.below(7) {
    case 0:
      pieces.append("вчера")
      date = DateOnly(year: 2026, month: 9, day: 17)
    case 1:
      pieces.append("позавчера")
      date = DateOnly(year: 2026, month: 9, day: 16)
    case 2:
      pieces.append("12.09")
      date = DateOnly(year: 2026, month: 9, day: 12)
    case 3:
      pieces.append("2026-09-10")
      date = DateOnly(year: 2026, month: 9, day: 10)
    case 4:
      pieces.append("31.12.2025")
      date = DateOnly(year: 2025, month: 12, day: 31)
    default: break
    }
    switch dice.below(5) {
    case 0:
      pieces.append(dice.pick(["в Пятёрочке", "в пятерочке", "Пятёрочка", "at Starbucks"]))
      place = Fixture.pyaterochka
      if pieces.last == "at Starbucks" { place = Fixture.starbucks }
    case 1:
      pieces.append("в Азбуке вкуса")
      place = Fixture.azbuka
    default: break
    }
    if kind != .income || dice.below(2) == 0 {
      switch dice.below(5) {
      case 0:
        pieces.append(dice.pick(["для Ани", "для Маши"]))
        person = pieces.last == "для Ани" ? Fixture.anya : Fixture.masha
      case 1:
        pieces.append("for John")
        person = Fixture.john
      default: break
      }
    }
    // The note keeps its words in order, so they go into the line in order as well; every
    // other piece lands in a random gap between them.
    var slots: [[String]] = Array(repeating: [], count: noteWords.count + 1)
    for piece in pieces {
      slots[dice.below(slots.count)].append(piece)
    }
    var all: [String] = []
    for (index, slot) in slots.enumerated() {
      all += slot
      if index < noteWords.count { all.append(noteWords[index]) }
    }
    // A sign of income is read only at the start or glued to the amount; a «+» glued to the
    // amount wherever it stands is enough.
    text = all.joined(separator: " ")
    note = noteWords.joined(separator: " ")
  }

  /// An amount and one way of writing it.
  static func amount(_ dice: inout LineDice) -> (value: Decimal, text: String) {
    let whole = Int64(1 + dice.below(dice.below(2) == 0 ? 2_000 : 5_000_000))
    let cents = dice.below(3) == 0 ? Int64(dice.below(100)) : 0
    let value = Decimal(whole) + Decimal(cents) / 100
    let fraction = cents == 0 ? "" : String(format: "%02lld", cents)
    let digits = String(whole)
    func grouped(_ separator: String) -> String {
      var groups: [String] = []
      var rest = Substring(digits)
      while rest.count > 3 {
        groups.insert(String(rest.suffix(3)), at: 0)
        rest = rest.dropLast(3)
      }
      groups.insert(String(rest), at: 0)
      return groups.joined(separator: separator)
    }
    switch dice.below(8) {
    case 0:
      // «12.09» is a day once the line holds another number: a point only where no date reads.
      let point = whole > 31 ? "." : ","
      return (value, fraction.isEmpty ? digits : digits + point + fraction)
    case 1:
      return (value, fraction.isEmpty ? digits : digits + "," + fraction)
    case 2:
      return (value, grouped(",") + (fraction.isEmpty ? "" : "." + fraction))
    case 3:
      return (value, grouped(" ") + (fraction.isEmpty ? "" : "," + fraction))
    case 4:
      // Dots between thousands only when there are two of them or more, else it is a fraction.
      let text = grouped(".")
      guard text.filter({ $0 == "." }).count >= 2 else {
        return (value, fraction.isEmpty ? digits : digits + "," + fraction)
      }
      return (value, text + (fraction.isEmpty ? "" : "," + fraction))
    case 5:
      // In thousands: «2k», «1,5к», «2.25k».
      let thousands = Int64(1 + dice.below(500))
      let tenths = Int64(dice.below(10))
      let text =
        tenths == 0
        ? "\(thousands)\(dice.pick(["k", "к", "K"]))"
        : "\(thousands)\(dice.pick([",", "."]))\(tenths)\(dice.pick(["k", "к"]))"
      return (Decimal(thousands * 1_000 + tenths * 100), text)
    case 6:
      let first = Int64(1 + dice.below(10_000))
      let second = Int64(1 + dice.below(10_000))
      return (
        Decimal(first + second), "\(first)\(dice.pick(["+", " + "]))\(second)"
      )
    default:
      let price = Int64(1 + dice.below(5_000))
      let count = Int64(2 + dice.below(9))
      return (Decimal(price * count), "\(price)\(dice.pick(["x", "х", "*", "×"]))\(count)")
    }
  }
}

/// A seeded generator (SplitMix64): every run sees the same lines, so a failure repeats.
private struct LineDice {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }

  mutating func below(_ bound: Int) -> Int {
    Int(next() % UInt64(bound))
  }

  mutating func pick(_ choices: [String]) -> String {
    choices[below(choices.count)]
  }
}
