import AppCore
import Foundation
import Testing

/// The count the archive checks its manifest by and the rows the CSV reader reads are one and
/// the same number for any text at all — not only for files the export wrote: drawn texts of
/// quotes, commas, every kind of line break, blank lines, byte-order marks at the start and
/// further in, letters of several bytes. A file another program wrote is read by the reader,
/// so a count that differs from it refuses an archive that is right, or lets a wrong one by.
@Suite("The archive counts CSV rows exactly as the reader reads them")
struct CSVRowCountPropertyTests {
  /// Rows the reader reads, the header not counted; nil when it cannot read the text at all.
  private static func readerRows(_ data: Data) -> Int? {
    guard let rows = try? CSVReader.rows(from: data) else { return nil }
    return max(0, rows.count - 1)
  }

  @Test func theCountIsTheReadersOnDrawnTexts() {
    let pieces = [
      "a", "b,c", ",", "\"", "\"\"", "\n", "\r", "\r\n", "\n\n", " ", "é", "🎂", "\u{FEFF}",
      "\u{2028}", "\t", "\"x,\ny\"",
    ]
    var random = SeededRandom(seed: 20_260_926)
    var compared = 0
    for round in 0..<5_000 {
      var text = random.chance(1, outOf: 4) ? "\u{FEFF}" : ""
      for _ in 0..<random.int(in: 0...24) {
        text += pieces[random.int(in: 0..<pieces.count)]
      }
      let data = Data(text.utf8)
      guard let rows = Self.readerRows(data) else { continue }
      compared += 1
      #expect(
        ArchiveOpener.countCSVRows(data) == rows, "round \(round): «\(text.debugDescription)»")
    }
    #expect(compared == 5_000)
  }

  /// Bytes drawn at random — broken UTF-8 included: wherever the reader reads the text, the
  /// count agrees with it; where it cannot, the count still ends without a fault.
  @Test func theCountIsTheReadersOnDrawnBytes() {
    let pieces: [[UInt8]] = [
      [0x22], [0x2C], [0x0A], [0x0D], [0x41], [0x20], [0xEF, 0xBB, 0xBF], [0xC3, 0xA9],
      [0x22, 0x22],
    ]
    let broken: [[UInt8]] = [[0xFF], [0xC3], [0xEF, 0xBB]]
    var random = SeededRandom(seed: 7_331)
    var compared = 0
    for round in 0..<5_000 {
      var data = Data()
      for _ in 0..<random.int(in: 0...40) {
        let piece =
          random.chance(1, outOf: 60)
          ? broken[random.int(in: 0..<broken.count)] : pieces[random.int(in: 0..<pieces.count)]
        data.append(contentsOf: piece)
      }
      let counted = ArchiveOpener.countCSVRows(data)
      guard let rows = Self.readerRows(data) else { continue }
      compared += 1
      #expect(counted == rows, "round \(round): \(Array(data))")
    }
    #expect(compared > 2_000)
  }
}
