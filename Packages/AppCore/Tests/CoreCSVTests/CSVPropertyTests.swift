import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// A deterministic source of draws for the tests of this target, the same on every platform.
struct CSVDraws {
  private var state: UInt64

  init(seed: UInt64) {
    // Mixed once, so neighbouring seeds do not give one stream shifted by a step.
    state = seed
    state = next()
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
  }

  mutating func chance(_ numerator: Int, _ denominator: Int) -> Bool {
    int(1...denominator) <= numerator
  }

  mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }

  /// A text made of what a CSV file has to carry through: separators, quotes, every kind of
  /// line break, combining marks, emoji, a byte-order mark inside, spaces, nothing at all.
  mutating func text() -> String {
    let pieces = [
      "a", "Б", ",", "\"", "\n", "\r", "\r\n", " ", "\t", "e\u{301}", "\u{301}", "🎂", "🇷🇺",
      "\u{FEFF}", ";", "'", "\\", "0", "-1.5", "\u{0}", "\u{2028}", "ё", "",
    ]
    return (0..<int(0...6)).map { _ in pick(pieces) }.joined()
  }
}

/// The CSV writer and reader are each other's inverse on anything a cell can hold; amounts,
/// instants and breakdowns are written so that they read back exactly.
@Suite("CSV files drawn at random read back as they were written")
struct CSVPropertyTests {
  /// Tables of drawn texts: every cell comes back exactly, header included, in any shape of
  /// table — one column or twelve, no rows or many, cells empty or made of line breaks.
  @Test(arguments: Array(UInt64(1)...UInt64(300)))
  func aDrawnTableReadsBackCellForCell(seed: UInt64) throws {
    var draws = CSVDraws(seed: seed)
    let width = draws.int(1...12)
    let header = (0..<width).map { "c\($0)" }
    var writer = CSVWriter(columns: header)
    var rows: [[String]] = []
    for _ in 0..<draws.int(0...15) {
      let row = (0..<width).map { _ in draws.text() }
      writer.append(row)
      rows.append(row)
    }
    let data = writer.data()
    let read = try CSVReader.rows(from: data)
    #expect(read == [header] + rows, "seed \(seed)")
    let dictionaries = try CSVReader.dictionaries(from: data)
    #expect(dictionaries.count == rows.count)
    for (dictionary, row) in zip(dictionaries, rows) {
      #expect(header.map { dictionary[$0] } == row)
    }
  }

  /// Bytes that are not a CSV file — drawn at random, UTF-8 or not — never stop the reader:
  /// it gives rows or says why it cannot.
  @Test func anyBytesAreReadOrRefusedNeverTrapped() {
    var draws = CSVDraws(seed: 77)
    for _ in 0..<2_000 {
      let bytes = (0..<draws.int(0...64)).map { _ in
        draws.chance(1, 2)
          ? UInt8(draws.pick([0x22, 0x2C, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]))
          : UInt8(truncatingIfNeeded: draws.next())
      }
      _ = try? CSVReader.rows(from: Data(bytes))
      _ = try? CSVReader.dictionaries(from: Data(bytes))
    }
  }

  /// Every amount the database can hold is written as a decimal that is exactly the stored
  /// units over ten thousand: read back and multiplied, it is the stored integer again.
  @Test func everyStoredAmountIsWrittenExactly() throws {
    var draws = CSVDraws(seed: 5)
    var raws: [Int64] = [
      0, 1, -1, 9_999, 10_000, -10_001, Int64.max, Int64.min + 1, 1_000_000_000_000 * 10_000,
    ]
    for _ in 0..<3_000 {
      raws.append(Int64(bitPattern: draws.next()) >> Int64(draws.int(0...62)))
    }
    for raw in raws {
      let text = CSVValue.string(amount: AmountE4(raw: raw))
      #expect(!text.contains("e") && !text.contains("E") && !text.contains(","), "\(raw) → \(text)")
      let value = try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
      #expect(value * 10_000 == Decimal(raw), "\(raw) → \(text)")
      #expect(text == "0" || !text.hasSuffix(".") && !(text.contains(".") && text.hasSuffix("0")))
    }
  }

  /// An instant is written to the second in UTC, and read back as that second: the instant
  /// with its fraction of a second dropped, before 1970 as after.
  @Test func everyInstantReadsBackToItsSecond() throws {
    var draws = CSVDraws(seed: 6)
    var instants: [Double] = [0, -0.25, 0.999, 1_789_000_000.5, -2_208_988_800, 253_402_300_799]
    for _ in 0..<3_000 {
      instants.append(
        Double(draws.int(-2_000_000_000...4_000_000_000)) + Double(draws.int(0...999)) / 1_000)
    }
    for seconds in instants {
      let date = Date(timeIntervalSince1970: seconds)
      let text = CSVValue.string(instant: date)
      let back = try #require(CSVValue.instant(text), "\(seconds) → \(text)")
      #expect(back.timeIntervalSince1970 == seconds.rounded(.down), "\(seconds) → \(text)")
    }
  }

  /// A breakdown of a reconciliation is one JSON text that reads back line for line: codes,
  /// stored amounts of any size and sign, rates of any number of digits or none.
  @Test func aBreakdownReadsBackLineForLine() {
    var draws = CSVDraws(seed: 7)
    for round in 0..<500 {
      let lines = (0..<draws.int(1...4)).map { _ in
        ReconciliationAmount(
          currency: CurrencyCode(draws.pick(["RUB", "USD", "KZT", "JPY"])),
          amountE4: AmountE4(raw: Int64(bitPattern: draws.next()) >> 8),
          rubPerUnit: draws.chance(1, 4)
            ? nil
            : Decimal(string: draws.pick(["81.4321", "0.000123456789", "15", "56.2349", "1e3"])),
          rubE4: AmountE4(raw: Int64(bitPattern: draws.next()) >> 8))
      }
      let text = ReconciliationBreakdown.json(lines)
      #expect(ReconciliationBreakdown.amounts(fromJSON: text) == lines, "round \(round)")
      #expect(ReconciliationBreakdown.json(ReconciliationBreakdown.amounts(fromJSON: text)) == text)
    }
  }
}
