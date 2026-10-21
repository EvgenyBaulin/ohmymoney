import AppCore
import XCTest

@testable import OhMyMoney

/// A chip enters a line, and Enter saves what the line says: so a template made of what a line
/// was read as — its note, amount and currency — gives the same note, amount and currency back
/// through the line of its chip. Random lines of words, counts («2 шт», «3 бутылки»), a refused
/// formula anywhere in the note, a multiplication, and an amount written every way, in rubles
/// and abroad.
final class TemplateLinePropertyTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var parser: InputLineParser { InputLineParser(vocabulary: .empty, calendar: .utc) }

  /// SplitMix64: the same seed gives the same lines, so a failure repeats.
  private struct Dice {
    var state: UInt64
    mutating func below(_ bound: Int) -> Int {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((mixed ^ (mixed >> 31)) % UInt64(bound))
    }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
  }

  func testAChipGivesBackWhatItsTemplateWasMadeOf() {
    var failures: [String] = []
    for seed in UInt64(1)...3_000 {
      var dice = Dice(state: seed)
      var words: [String] = []
      // A note may end in a refused formula («обед 100-250»): the chip must not let its amount
      // join it into «100-250 250», one formula by the space that groups thousands.
      for _ in 0...dice.below(3) {
        words.append(
          dice.pick([
            "круассаны", "кофе", "обед", "2 шт", "3 бутылки", "1,5 кг", "доска 20x30",
            "к 8 марта", "lunch", "2 pcs", "100-250",
          ]))
      }
      let whole = dice.pick([1, 2, 3, 5, 12, 25, 31, 250, 1_500, 12_000])
      let cents = dice.pick([0, 0, 1, 5, 9, 10, 12, 50, 99])
      let amount = cents == 0 ? "\(whole)" : "\(whole).\(String(format: "%02d", cents))"
      let currency = dice.pick(["", " EUR", " USD", " руб"])
      words.insert(amount + currency, at: dice.below(words.count + 1))
      let original = words.joined(separator: " ")
      let read = parser.parse(original, today: today)
      guard let value = read.amount, let units = try? AmountE4(decimal: value), read.date == nil
      else { continue }
      let template = Template(
        text: read.note, amountE4: units, currency: read.currency.flatMap { $0 == .rub ? nil : $0 })
      let line = Templates.line(for: template, categories: [])
      let again = parser.parse(line, today: today)
      if again.amount != value || again.note != template.text || again.date != nil
        || (again.currency ?? .rub) != (template.currency ?? .rub)
      {
        failures.append(
          "«\(original)» → «\(line)»: amount \(again.amount.map { "\($0)" } ?? "nil"), "
            + "note «\(again.note)», date \(again.date.map { "\($0)" } ?? "nil")")
      }
    }
    XCTAssertEqual(failures.count, 0, failures.prefix(15).joined(separator: "\n"))
  }
}
