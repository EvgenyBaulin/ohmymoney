import Foundation
import Testing

@testable import CoreLog

/// One event, one line: time, level, category, name, our own message, then `key=value`.
@Suite("One event, one line")
struct LogLineTests {
  private let moment = Date(timeIntervalSince1970: 1_789_000_123.456)

  @Test func aLineCarriesTheWholeEventInOrder() {
    let event = LogEvent(
      at: moment, level: .error, category: .db, name: "migration.failed",
      message: "the migration did not finish",
      pairs: [
        LogPair("from", .count(1)), LogPair("to", .count(2)), LogPair("ms", .milliseconds(412)),
      ]
    )

    let line = LogLine.text(of: event, timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)

    #expect(
      line
        == "2026-09-10T03:28:43.456+03:00 error db migration.failed "
        + "\"the migration did not finish\" from=1 to=2 ms=412ms")
    #expect(line.split(separator: "\n").count == 1, "one event is one line")
  }

  /// Two frames as `Thread.callStackSymbols` gives them.
  private let frames = [
    "0   OhMyMoney.debug.dylib                   0x0000000104c2f1a8 "
      + "$s5OhMyMoney9AppLaunchO5startyyAA14AppEnvironmentCYaF + 1234",
    "1   AppKit                              0x000000018a1b2c3d -[NSApplication run] + 480",
  ]

  /// The only thing that may run to several lines, and it is indented so a reader can tell it
  /// from the next event.
  @Test func onlyAStackMakesALineMultiLine() {
    let event = LogEvent(
      at: moment, level: .error, category: .app, name: "error.caught", message: "caught",
      failure: frames.joined(separator: "\n"))

    let lines = LogLine.text(of: event, timeZone: .gmt).split(separator: "\n")

    #expect(lines.count == 3)
    #expect(lines[1] == "    " + frames[0])
    #expect(lines[2] == "    " + frames[1])
  }

  /// «Любая перехваченная ошибка: тип, … стек, если он есть» — a stack, not a description.
  /// The stack was the one field written raw, and the first `failure: String(describing:
  /// error)` would have carried what a database error quotes — the statement, its arguments,
  /// the owner's note among them — straight into the file. A line that is not a frame is
  /// written as `<not-a-frame>`.
  @Test func aDescriptionOfAnErrorIsNotWrittenAsAStack() {
    let description =
      "SQLite error 19: UNIQUE constraint failed: transactions.id - while executing "
      + "`INSERT INTO transactions (note) VALUES (?)` with arguments [\"Coffee with Alex\"]"
    let event = LogEvent(
      at: moment, level: .error, category: .db, name: "error.caught", message: "caught",
      failure: [frames[0], description, "Кофе с Сашей"].joined(separator: "\n"))

    let line = LogLine.text(of: event, timeZone: .gmt)

    #expect(!line.contains("Coffee"), "\(line)")
    #expect(!line.contains("Кофе"), "\(line)")
    // Strings on both sides: `#expect` types each side of `==` on its own, the literal alone
    // is an array of strings, and a slice of substrings against it is compared as two
    // `AnyHashable`s — never equal.
    #expect(
      line.split(separator: "\n").dropFirst().map(String.init)
        == ["    " + frames[0], "    <not-a-frame>", "    <not-a-frame>"])
  }

  #if canImport(Darwin)
    /// What the stack is meant to be passes the rule whole.
    @Test func aStackOfThisProcessIsWrittenWhole() {
      let stack = Thread.callStackSymbols
      #expect(!stack.isEmpty)
      for frame in stack { #expect(LogValue.isFrame(frame), "\(frame)") }
    }
  #endif

  /// A message of ours with a quote or a newline in it must not break the line apart.
  @Test func ourOwnMessageCannotBreakTheLine() {
    let event = LogEvent(
      at: moment, level: .info, category: .ui, name: "window.opened",
      message: "a \"quoted\" word\nand a new line")

    let line = LogLine.text(of: event, timeZone: .gmt)

    #expect(line.split(separator: "\n").count == 1)
    #expect(line.contains("\\\"quoted\\\""))
  }

  /// A carriage return breaks a line in half for every reader that splits on it — `less`,
  /// Console, a text editor opening the file — and so do the Unicode separators. The escape
  /// took only `\n`.
  @Test func noKindOfLineBreakInAMessageBreaksTheLine() {
    for breaker in ["\r", "\r\n", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}"] {
      let event = LogEvent(
        at: moment, level: .info, category: .ui, name: "window.opened",
        message: "one half\(breaker)the other half")

      let line = LogLine.text(of: event, timeZone: .gmt)

      #expect(
        !line.unicodeScalars.contains { CharacterSet.newlines.contains($0) },
        "\(breaker.unicodeScalars.map { String($0.value, radix: 16) }) is still in the line")
      #expect(line.contains("\"one half the other half\""), "\(line)")
    }
  }

  @Test func theStampCarriesMillisecondsAndTheOffset() {
    #expect(
      LogLine.stamp(moment, in: TimeZone(secondsFromGMT: -5 * 3600 - 1800)!)
        == "2026-09-09T18:58:43.456-05:30")
    #expect(LogLine.stamp(moment, in: .gmt) == "2026-09-10T00:28:43.456+00:00")
    #expect(
      LogLine.stamp(moment, in: TimeZone(secondsFromGMT: 14 * 3600)!)
        == "2026-09-10T14:28:43.456+14:00")
  }
}

/// What may stand on the right of `key=`. The type is the rule, not a reviewer's memory.
@Suite("What may stand on the right of key=")
struct LogValueTests {
  @Test func aValueOfOursIsWrittenPlainly() {
    #expect(LogValue.count(7).text == "7")
    #expect(LogValue.bytes(1_258_291).text == "1258291b")
    #expect(LogValue.milliseconds(412).text == "412ms")
    #expect(LogValue.flag(true).text == "yes")
    #expect(LogValue.token("cbr-mirror").text == "cbr-mirror")
    #expect(LogValue.version("macOS 26.0").text == "macOS 26.0")
  }

  /// A note, a name or a category cannot be passed off as a token: they are not short ASCII
  /// words of our own, and the log says so instead of writing them.
  @Test func somebodysWordsAreNotATokenAndAreNotWritten() {
    #expect(LogValue.token("Кофе").text == "<not-a-token>")
    #expect(LogValue.token("Coffee and a bun").text == "<not-a-token>")
    #expect(LogValue.token(String(repeating: "a", count: 25)).text == "<not-a-token>")
    #expect(LogValue.token("").text == "<not-a-token>")
    #expect(LogValue.version("Продукты").text == "<not-a-version>")
    #expect(LogPair("Категория", .count(1)).text == "<not-a-key>=1")
    #expect(LogValue.typeName("Кофе").text == "<not-a-type>")
    #expect(LogValue.typeName("Coffee and a bun").text == "<not-a-type>")
  }

  /// The type of a caught error is what a failure line has to say («тип»), and a name
  /// longer than a token came out `<not-a-token>`.
  @Test func theTypeOfAnErrorIsWrittenWhateverItsLength() {
    #expect(
      LogValue.error(ADatabaseMigrationThatStoppedHalfway()).text
        == "ADatabaseMigrationThatStoppedHalfway")
    #expect(LogValue.error(CancellationError()).text == "CancellationError")
    #expect(LogValue.typeName("Result<Int, Failure>").text == "Result<Int,Failure>")
  }

  private struct ADatabaseMigrationThatStoppedHalfway: Error {}
}
