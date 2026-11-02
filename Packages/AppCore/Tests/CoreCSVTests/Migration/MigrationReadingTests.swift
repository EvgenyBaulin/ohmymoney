import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// Compressed with zlib (raw DEFLATE, level 9) from known text, so the decoder is checked against
/// an independent encoder. Synthetic content only.
enum DeflateVectors {
  /// «Кофе 250; coffee 250 — ok», a fixed-Huffman block.
  static let fixed = "uzDrwr6LLRe2KhiZGlgrJOenpaWmgtgKjxqmKORnAwA="
  /// The same text in a stored block.
  static let stored = "AR8A4P/QmtC+0YTQtSAyNTA7IGNvZmZlZSAyNTAg4oCUIG9r"
  static let fixedText = "Кофе 250; coffee 250 — ok"

  /// 200 lines `i;Магазин i%17;(i*13%1000).50`, a dynamic-Huffman block.
  static var dynamicText: String {
    (0..<200).map { "\($0);Магазин \($0 % 17);\($0 * 13 % 1000).50\n" }.joined()
  }
  static let dynamic = """
    bZg9juxGDAZzn8InMPrjT5OErupDPMCBnfgOeyRzSDkZMthEBBZQlaSu4Xl+/vz59fNX/v3988/Pv7+f5/yh5zd8X8cD
    /gzoe0AP3c+Avwf8cHwG8j2QR+kz0O+BPlc/g/s9uI/5Z2DfA3sCn4F/D/zBkc8kvifxAFa3eMY9nrzJvv15/wlAigAG
    grwCLQgYFPIKbnHAAJFX4IUCg0VeQRQNDBx5hU4BgU1/RIUEPhUSFxPEIlEKCp2pkW4xIUyRZP1Q0FRJXkSIp0yKAkIy
    dTKKB+kUylQ46E6jzEWDbDHKWjjIF6N8iwfFYpStgPBZjHIUEcZiVE4hYVqMCvpV4cWoUEFhmUZFCgrPh+QRLSh8p1G5
    BYVtGhUvJuzTqEQh4ZhG9RQROdOoUgERTKPKxUNoGlUpHMLTqGp/O2QxqlY4RBej6sVD7mJUo4CILUYvioj4YvRSIZFY
    jF4uJnoWo1cLimIavbeg6HxInmsFRXkavV5QVKZRO/1J1WnUUEj0TqNGRURt+eBKAVGfRk2Lh8Y0ardw3DONmheNi8Wo
    ReG4tBj1UzwuL0YdBeTKYtS5iFxdjLr0OXMXo67F5Npi1K2gXJ9G3QvKnQ/J41FQ7EyjgYJimEaDionRNBpcSIyn0ZAi
    YjKNxi0gpsshasXD7jQa3ievLedoDXw7RYuFxaKTioWfxaYUC8ciU4uF0/Z2FgvnRaUVC5fFZBQL1ykSp1j4XQoIxcJt
    igR3h/gUCSkaHlMktGjEmSJhRSMwRcKLRtAUiSgawVMknaIRMkUSFY3QRSVx4Yi7uZTiEbbIpFtAwhebZJ1msegkf+Ps
    LEL5dJ0dLEq5AxWHplTuRsWZj0nGQ+fZkamVu1TzmVjqtmMV506x3L2KY9Msd7Li+FQrHa04Md3Km62zW/2R/7MV0668
    2bp0a6bF261LuGZcvOG6lGu+rW+5LumagfGm69KuWf9vu854zf+lb70u+ZqZ8fbrDNisgg5YzILNKuiCxUzYrAJ7q56m
    Yu2GxYzYvIuOWMyKzSroisXM2KyCzljMjrWsiSYzQ9azJhrMDNnIb2BzWUI2W6NDFkvJZm10yWJJWcqoaDRLy2Zx4P3F
    w4ti65jFrNnPZ7lzFkvPZnd00GIWbWZCFy1m0iLzovHMps376KbFjNrMhI5azKrNTOiqxczazITOWsyuzUzorsUMW8u8
    eH8MylTsHbaYZRvZF81lKduMjy5bLGmLbIwms7RtBki3LZa4zQTpuMVStxkhXbeYeZuKo/sWS+Dm2duFi5m4J3Oj8czG
    zeOmJ7qcvs1mJm6eNU1mJm7+1GkuM3HzK9RUZuLm+9tMZuKm2yYyEzczqnnMws2M6sDFUrhZI124WBL3s5FpJEvjJhN5
    twd3W0l05GKp3KySrlzMzP0sJbpzsYRulkmXLmbqZkh06sKW1RJ168K27VLHLmxZMFHXLmzZMVHnLmxZM1H3LmzZNJG/
    m5Vl2cSnydiyb+KOXtiyceKuXvi2cuLuXvi2c+IuX/i2dOJuX/i2deKuX/i2duLuX/i2d5IuYPi2eJJuYPiyeRJ+N0/L
    6km6guHL7kk6gxHL8km6gxHL9kk6hBHL+km6hBHL/kk7hRHLAkq7hRHLBkq7hRHLCkq7hRHbDko7hhHbEkrtXcptWyjt
    HP4P
    """

  static func bytes(_ base64: String) -> [UInt8] {
    [UInt8](Data(base64Encoded: base64.filter { !$0.isWhitespace }) ?? Data())
  }
}

@Suite("Raw DEFLATE is read back exactly, and a broken stream never traps")
struct InflateTests {
  @Test func fixedHuffmanBlock() throws {
    let out = try Inflate.decompress(DeflateVectors.bytes(DeflateVectors.fixed))
    #expect(String(decoding: out, as: UTF8.self) == DeflateVectors.fixedText)
  }

  @Test func storedBlock() throws {
    let out = try Inflate.decompress(DeflateVectors.bytes(DeflateVectors.stored))
    #expect(String(decoding: out, as: UTF8.self) == DeflateVectors.fixedText)
  }

  @Test func dynamicHuffmanBlock() throws {
    let compressed = DeflateVectors.bytes(DeflateVectors.dynamic)
    #expect((compressed[0] >> 1) & 3 == 2)
    let out = try Inflate.decompress(compressed)
    #expect(String(decoding: out, as: UTF8.self) == DeflateVectors.dynamicText)
  }

  @Test func truncatedAndCorruptStreamsThrow() {
    let compressed = DeflateVectors.bytes(DeflateVectors.dynamic)
    #expect(throws: InflateError.self) { try Inflate.decompress(Array(compressed.prefix(40))) }
    #expect(throws: InflateError.self) { try Inflate.decompress([0xFF, 0xFF, 0xFF]) }
    #expect(throws: InflateError.self) { try Inflate.decompress([]) }
  }

  @Test func outputPastTheLimitIsRefused() {
    let compressed = DeflateVectors.bytes(DeflateVectors.dynamic)
    #expect(throws: InflateError.tooLarge) { try Inflate.decompress(compressed, limit: 100) }
  }
}

/// A workbook written by Python's zipfile to a stream it cannot seek, so every entry carries
/// the «sizes follow the data» flag with zeros in its local header, as Excel writes them. The
/// first sheet in the workbook is the second file (`sheet2.xml`, through the relations); it has a
/// gap in its rows, a missing cell, shared strings with rich-text runs and entities, an inline
/// string, a boolean, a built-in and a custom date format, and binary fractions in numbers.
enum XLSXFixture {
  static let workbook = """
    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\
    AAAABwAHAM8BAAARBwAAAAA=
    """

  static var data: Data { Data(base64Encoded: workbook.filter { !$0.isWhitespace }) ?? Data() }
}

@Suite("An Excel workbook reads into rows of text without zlib or an XML library")
struct XLSXReaderTests {
  @Test func firstSheetIsFollowedThroughTheRelations() throws {
    let zip = try ZipEntries([UInt8](XLSXFixture.data))
    let rows = try XLSXReader.firstSheet(zip)
    #expect(rows.count == 4)
    #expect(rows[0] == ["Дата", "Сумма", "Категория", "Описание"])
  }

  @Test func cellsAreTypedAndPlacedByReference() throws {
    let rows = try XLSXReader.firstSheet(try ZipEntries([UInt8](XLSXFixture.data)))
    // Built-in date format 14; a binary fraction rounded to four places; rich text with an entity.
    #expect(rows[1] == ["2024-01-01", "-350.1", "Кафе & бар", "Латте"])
    // A custom date format with a time; a numeric character reference.
    #expect(rows[2] == ["2024-01-02 12:00", "120000", "Зарплата №1"])
    // A missing cell stays empty; an exponent; a boolean.
    #expect(rows[3] == ["2024-01-03", "-0.015", "", "TRUE"])
  }

  @Test func theWorkbookReadsAsATableWithItsHeader() {
    guard
      case .table(let table, _) = MigrationTableReader.read(XLSXFixture.data, fileName: "x.xlsx")
    else {
      Issue.record("not a table")
      return
    }
    #expect(table.header == ["Дата", "Сумма", "Категория", "Описание"])
    #expect(table.rows.count == 3)
  }

  @Test func serialDatesOfBothEpochs() {
    #expect(XLSXReader.serialDate(45292, date1904: false) == "2024-01-01")
    #expect(
      XLSXReader.serialDate(Decimal(string: "45292.75")!, date1904: false) == "2024-01-01 18:00")
    #expect(XLSXReader.serialDate(43830, date1904: true) == "2024-01-01")
    #expect(XLSXReader.serialDate(0, date1904: false) == nil)
  }

  @Test func dateFormatsAreRecognised() {
    #expect(XLSXReader.isDateFormat(id: 14, code: nil))
    #expect(!XLSXReader.isDateFormat(id: 4, code: nil))
    #expect(XLSXReader.isDateFormat(id: 164, code: "dd/mm/yyyy"))
    #expect(!XLSXReader.isDateFormat(id: 165, code: "#,##0.00\"р.\""))
    #expect(!XLSXReader.isDateFormat(id: 166, code: "[Red]0.00"))
  }

  @Test func columnReferences() {
    #expect(XLSXReader.columnIndex("A1") == 0)
    #expect(XLSXReader.columnIndex("Z9") == 25)
    #expect(XLSXReader.columnIndex("AA10") == 26)
    #expect(XLSXReader.columnIndex("12") == nil)
  }

  @Test func xmlEntitiesAreDecoded() {
    let text = XMLScanner.decodeEntities(ArraySlice("a &amp; b &lt;&#1078;&#x416;&bogus; &".utf8))
    #expect(text == "a & b <жЖ&bogus; &")
  }
}

@Suite("Files that are not tables say what they are")
struct MigrationFileKindTests {
  @Test func numbersAndOldExcelAreNamed() {
    #expect(MigrationTableReader.read(Data([1, 2, 3]), fileName: "Бюджет.numbers") == .numbers)
    #expect(
      MigrationTableReader.read(Data([0xD0, 0xCF, 0x11, 0xE0, 0, 0]), fileName: "old.xls")
        == .legacyExcel)
    #expect(MigrationTableReader.read(Data("just words".utf8)) == .unreadable)
  }

  @Test func csvWithSemicolonsTitleRowAndLegacyEncoding() throws {
    let text = "Экспорт за 2024 год\n\nДата;Сумма;Категория\n01.02.2024;-350,50;Кафе\n"
    var bytes: [UInt8] = []
    // windows-1251 for the Cyrillic letters this text uses.
    for scalar in text.unicodeScalars {
      if scalar.value >= 0x410, scalar.value <= 0x44F {
        bytes.append(UInt8(scalar.value - 0x410 + 0xC0))
      } else {
        bytes.append(UInt8(scalar.value))
      }
    }
    guard case .table(let table, let legacy) = MigrationTableReader.read(Data(bytes)) else {
      Issue.record("not a table")
      return
    }
    #expect(legacy)
    #expect(table.header == ["Дата", "Сумма", "Категория"])
    #expect(table.skippedAbove == 1)
    #expect(table.rows == [["01.02.2024", "-350,50", "Кафе"]])
  }

  @Test func utf16TabSeparatedText() {
    let text = "Date\tAmount\tCategory\n2024-02-01\t-12.50\tCafe\n"
    var bytes: [UInt8] = [0xFF, 0xFE]
    for unit in text.utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
    guard case .table(let table, _) = MigrationTableReader.read(Data(bytes)) else {
      Issue.record("not a table")
      return
    }
    #expect(table.header == ["Date", "Amount", "Category"])
    #expect(table.rows.first == ["2024-02-01", "-12.50", "Cafe"])
  }

  @Test func signatureIgnoresCaseAndBlanks() {
    let a = MigrationTable(header: ["Дата", " Сумма "], rows: [])
    let b = MigrationTable(header: ["дата", "СУММА"], rows: [])
    let c = MigrationTable(header: ["дата", "сумма", "счёт"], rows: [])
    #expect(a.signature == b.signature)
    #expect(a.signature != c.signature)
  }
}

@Suite("Amounts and dates of other applications")
struct MigrationValueTests {
  private func amount(_ text: String) -> Int64? { MigrationAmounts.parse(text)?.amount.raw }

  @Test func amountsInEveryCommonShape() {
    #expect(amount("-1 234,56") == -12_345_600)
    #expect(amount("1,234.56") == 12_345_600)
    #expect(amount("1.234,56") == 12_345_600)
    #expect(amount("(1 234,56)") == -12_345_600)
    #expect(amount("1,500") == 15_000_000)
    #expect(amount("1,5") == 15_000)
    #expect(amount("350") == 3_500_000)
    #expect(amount("−350 ₽") == -3_500_000)
    #expect(amount("1\u{00A0}000,00") == 10_000_000)
    #expect(amount("1 250 000") == 12_500_000_000)
    #expect(amount("-0.015") == -150)
  }

  @Test func currencyOfTheCell() {
    #expect(MigrationAmounts.parse("$12.50")?.currency == .usd)
    #expect(MigrationAmounts.parse("12.50 USD")?.currency == .usd)
    #expect(MigrationAmounts.parse("1 234 руб.")?.currency == .rub)
    #expect(MigrationAmounts.parse("5 000 ₸")?.currency == CurrencyCode("KZT"))
    #expect(MigrationAmounts.parse("350")?.currency == nil)
  }

  @Test func notAmounts() {
    #expect(amount("") == nil)
    #expect(amount("Кафе") == nil)
    #expect(amount("12 5") == nil)
    #expect(amount("1-2") == nil)
    #expect(amount("01.02.2024") == nil)
  }

  @Test func dates() {
    let may1 = DateOnly(year: 2023, month: 5, day: 1)
    #expect(MigrationDates.parse("2023-05-01", order: .dayFirst)?.day == may1)
    #expect(MigrationDates.parse("01.05.2023", order: .monthFirst)?.day == may1)
    #expect(MigrationDates.parse("01.05.23", order: .dayFirst)?.day == may1)
    #expect(MigrationDates.parse("5/1/2023", order: .monthFirst)?.day == may1)
    #expect(MigrationDates.parse("1/5/2023", order: .dayFirst)?.day == may1)
    let timed = MigrationDates.parse("2023-05-01T14:05:00Z", order: .dayFirst)
    #expect(timed?.minuteOfDay == 14 * 60 + 5)
    #expect(MigrationDates.parse("5/1/2023 2:05 PM", order: .monthFirst)?.minuteOfDay == 845)
    #expect(MigrationDates.parse("5/1/2023 12:10 AM", order: .monthFirst)?.minuteOfDay == 10)
    #expect(MigrationDates.parse("01.05.2023", order: .dayFirst)?.minuteOfDay == nil)
  }

  @Test func notDates() {
    #expect(MigrationDates.parse("31.02.2023", order: .dayFirst) == nil)
    #expect(MigrationDates.parse("1 234,56", order: .dayFirst) == nil)
    #expect(MigrationDates.parse("Кафе 12.05.2023", order: .dayFirst) == nil)
    #expect(MigrationDates.parse("350", order: .dayFirst) == nil)
  }

  @Test func theOrderIsDecidedForTheWholeColumn() {
    #expect(MigrationDates.order(for: ["03/04/2023", "13/04/2023"]) == .dayFirst)
    #expect(MigrationDates.order(for: ["03/04/2023", "04/13/2023"]) == .monthFirst)
    #expect(MigrationDates.order(for: ["03/04/2023"]) == .dayFirst)
    #expect(MigrationDates.order(for: ["2023-04-13"]) == .dayFirst)
  }
}
