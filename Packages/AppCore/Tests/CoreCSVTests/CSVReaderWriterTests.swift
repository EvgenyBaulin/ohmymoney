import Foundation
import Testing

@testable import CoreCSV

@Suite("CSVWriter and CSVReader round-trip RFC 4180 data")
struct CSVReaderWriterTests {
  @Test func roundTripsPlainValues() throws {
    var writer = CSVWriter(columns: ["name", "amount"])
    writer.append(["Coffee", "150.5"])
    writer.append(["Groceries", "0"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows == [["name", "amount"], ["Coffee", "150.5"], ["Groceries", "0"]])
  }

  @Test func roundTripsAValueContainingAComma() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append(["milk, bread and eggs"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows == [["note"], ["milk, bread and eggs"]])
  }

  @Test func roundTripsAValueContainingAQuote() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append(["she said \"hello\""])

    let text = String(decoding: writer.data(), as: UTF8.self)
    #expect(text.contains("\"\"hello\"\""))

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows[1] == ["she said \"hello\""])
  }

  @Test func roundTripsAValueContainingANewline() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append(["first line\nsecond line"])
    writer.append(["plain"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows == [["note"], ["first line\nsecond line"], ["plain"]])
  }

  @Test func roundTripsRussianLetters() throws {
    var writer = CSVWriter(columns: ["категория", "заметка"])
    writer.append(["Продукты", "молоко, хлеб"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows == [["категория", "заметка"], ["Продукты", "молоко, хлеб"]])
  }

  @Test func roundTripsEmptyFields() throws {
    var writer = CSVWriter(columns: ["a", "b", "c"])
    writer.append(["", "middle", ""])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows == [["a", "b", "c"], ["", "middle", ""]])
  }

  @Test func writesNoByteOrderMark() throws {
    var writer = CSVWriter(columns: ["a"])
    writer.append(["1"])
    let bytes = [UInt8](writer.data())
    #expect(!(bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF))
  }

  @Test func skipsAByteOrderMarkOnInput() throws {
    let withBOM = Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n1,2\n".utf8)
    let rows = try CSVReader.rows(from: withBOM)
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test func readsCRLFAndLoneCRAsLineEndings() throws {
    let data = Data("a,b\r\n1,2\r3,4\n".utf8)
    let rows = try CSVReader.rows(from: data)
    #expect(rows == [["a", "b"], ["1", "2"], ["3", "4"]])
  }

  @Test func everyRowHasTheSameColumnCountAsTheHeader() throws {
    var writer = CSVWriter(columns: ["id", "name", "amount"])
    writer.append(["1", "Coffee", "150"])
    writer.append(["2", "", "0"])
    writer.append(["3", "Tea, black", "\"quoted\""])

    let rows = try CSVReader.rows(from: writer.data())
    let header = rows[0]
    for row in rows.dropFirst() {
      #expect(row.count == header.count)
    }
  }

  @Test func dictionariesAreKeyedByHeader() throws {
    var writer = CSVWriter(columns: ["id", "name"])
    writer.append(["1", "Coffee"])
    writer.append(["2", "Tea"])

    let dictionaries = try CSVReader.dictionaries(from: writer.data())
    #expect(dictionaries.count == 2)
    #expect(dictionaries[0] == ["id": "1", "name": "Coffee"])
    #expect(dictionaries[1] == ["id": "2", "name": "Tea"])
  }

  @Test func dictionariesThrowOnAMismatchedRowLength() throws {
    // A hand-written file, not produced by CSVWriter, with a short data row.
    let data = Data("id,name,amount\n1,Coffee\n".utf8)
    #expect(throws: CSVError.self) {
      _ = try CSVReader.dictionaries(from: data)
    }
  }

  /// A hand-edited copy (`make eval-model CSV=…`) can name a column twice. That is an error
  /// to report, not a crash: the reader must not trap on foreign input.
  @Test func dictionariesRefuseAColumnNamedTwice() throws {
    let data = Data("id,note,id\n1,Coffee,2\n".utf8)
    #expect(throws: CSVError.duplicateColumn(name: "id")) {
      _ = try CSVReader.dictionaries(from: data)
    }
    #expect(try CSVReader.rows(from: data) == [["id", "note", "id"], ["1", "Coffee", "2"]])
  }

  /// An editor that adds an empty last line, or a blank line between rows, makes no record:
  /// `pandas.read_csv` skips blank lines, and so does the reader. A quoted empty field is
  /// still a record.
  @Test func blankLinesAreSkippedAsPandasSkipsThem() throws {
    let data = Data("id,name\n1,Coffee\n\n2,Tea\n\n".utf8)
    #expect(
      try CSVReader.dictionaries(from: data) == [
        ["id": "1", "name": "Coffee"], ["id": "2", "name": "Tea"],
      ])
    let crlf = Data("id,name\r\n\r\n1,Coffee\r\n\r\n".utf8)
    #expect(try CSVReader.rows(from: crlf) == [["id", "name"], ["1", "Coffee"]])
    #expect(try CSVReader.rows(from: Data("note\n\"\"\n\n".utf8)) == [["note"], [""]])
  }

  /// The other side of the same rule: a one-column row whose value is empty would be a blank
  /// line, and a blank line is no record. The writer quotes it, so it reads back.
  @Test func aLoneEmptyFieldIsWrittenQuoted() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append([""])
    writer.append(["x"])
    #expect(String(decoding: writer.data(), as: UTF8.self) == "note\n\"\"\nx\n")
    #expect(try CSVReader.dictionaries(from: writer.data()) == [["note": ""], ["note": "x"]])
  }

  @Test func headerOnlyFileHasNoDictionaries() throws {
    let writer = CSVWriter(columns: ["id", "name"])
    let dictionaries = try CSVReader.dictionaries(from: writer.data())
    #expect(dictionaries.isEmpty)
  }

  @Test func fileWithoutATrailingNewlineStillParses() throws {
    let data = Data("a,b\n1,2".utf8)
    let rows = try CSVReader.rows(from: data)
    #expect(rows == [["a", "b"], ["1", "2"]])
  }

  @Test func quotesAValueThatCarriesAWindowsLineBreak() throws {
    // Swift merges "\r\n" into a single Character, so a Character-level search for "\n"
    // or "\r" does not find it. The value still has to be quoted, otherwise the row
    // splits in two and every note pasted from a Windows program loses its shape.
    var writer = CSVWriter(columns: ["idx", "note"])
    writer.append(["1", "first line\r\nsecond line"])
    writer.append(["2", "plain"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(
      rows == [["idx", "note"], ["1", "first line\r\nsecond line"], ["2", "plain"]])
  }

  @Test func quotesASeparatorThatCarriesACombiningMark() throws {
    // A combining mark glues itself to the character before it, so "," followed by
    // U+0301 is one Character that is not equal to ",". The comma is still a comma in
    // the bytes, so the field has to be quoted.
    var writer = CSVWriter(columns: ["note"])
    writer.append(["a,\u{0301}b"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows.count == 2)
    #expect(rows[1].count == 1)
    #expect(Array(rows[1][0].unicodeScalars) == Array("a,\u{0301}b".unicodeScalars))
  }

  @Test func escapesAQuoteThatCarriesACombiningMark() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append(["a\"\u{0301}b"])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows.count == 2)
    #expect(Array(rows[1][0].unicodeScalars) == Array("a\"\u{0301}b".unicodeScalars))
  }

  @Test func aQuotedEmptyFieldIsARowEvenWithoutATrailingBreak() throws {
    // Python's csv module reads this as one header and one empty data row; so must we,
    // or the last row of a one-column file saved without a final newline is lost.
    let data = Data("note\n\"\"".utf8)
    #expect(try CSVReader.rows(from: data) == [["note"], [""]])
    #expect(try CSVReader.dictionaries(from: data) == [["note": ""]])
  }

  @Test func keepsValuesMadeOfSpacesAndDistinguishesThemFromEmpty() throws {
    var writer = CSVWriter(columns: ["a", "b", "c"])
    writer.append(["", " ", "   "])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows[1] == ["", " ", "   "])
  }

  @Test func readsAFieldOfAMegabyte() throws {
    let long = String(repeating: "x", count: 1_048_576)
    var writer = CSVWriter(columns: ["id", "note"])
    writer.append(["1", long])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(rows[1][1].count == 1_048_576)
    #expect(rows[1][1] == long)
  }

  @Test func aFileWithNothingButAByteOrderMarkHasNoRows() throws {
    #expect(try CSVReader.rows(from: Data([0xEF, 0xBB, 0xBF])).isEmpty)
    #expect(try CSVReader.dictionaries(from: Data([0xEF, 0xBB, 0xBF])).isEmpty)
  }

  @Test func bytesThatAreNotUTF8AreRejected() {
    #expect(throws: CSVError.invalidEncoding) {
      _ = try CSVReader.rows(from: Data([0x61, 0xFF, 0x62]))
    }
  }

  @Test func writtenBytesKeepTheExactScalarsTheyWereGiven() throws {
    // Decomposed text must survive unchanged: normalising it would quietly rewrite what
    // the owner typed, and `==` on String would not even notice.
    let decomposed = "e\u{0301}clair"
    var writer = CSVWriter(columns: ["name"])
    writer.append([decomposed])

    let rows = try CSVReader.rows(from: writer.data())
    #expect(Array(rows[1][0].unicodeScalars) == Array(decomposed.unicodeScalars))
  }

  @Test func aTableWithNoRowsIsJustItsHeader() throws {
    let data = CSVWriter(columns: ["id", "name"]).data()
    #expect(String(decoding: data, as: UTF8.self) == "id,name\n")
    #expect(try CSVReader.rows(from: data) == [["id", "name"]])
  }
}
