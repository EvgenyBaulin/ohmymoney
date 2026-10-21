import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// How long the entry line takes on a line far longer than anyone types. The line is parsed on
/// every keystroke, so work that grows with the square of its length is a frozen window. Only
/// `make bench` runs this — in release, with `OHMYMONEY_BENCH=1`: a stopwatch in a debug build on a
/// shared CI runner measures the runner, not the parser.
@Suite("Performance of the entry line", .serialized, .enabled(if: ParseBench.isOn))
struct ParsePerformanceTests {
  @Test func aLongLineOfWords() {
    let short = ParseBench.measure("entry line, 500 words") {
      _ = Fixture.parse(ParseLoad.words(500))
    }
    let long = ParseBench.measure("entry line, 2 000 words") {
      _ = Fixture.parse(ParseLoad.words(2_000))
    }
    #expect(long.median < .milliseconds(250))
    // Four times the words may cost four times the time, with room for noise — not sixteen.
    #expect(long.median < short.median * 8)
  }

  @Test func aLongLineOfNumbers() {
    let short = ParseBench.measure("entry line, 100 numbers") {
      _ = Fixture.parse(ParseLoad.numbers(100))
    }
    let long = ParseBench.measure("entry line, 400 numbers") {
      _ = Fixture.parse(ParseLoad.numbers(400))
    }
    #expect(long.median < .milliseconds(250))
    #expect(long.median < short.median * 8)
  }
}

/// Long lines for the parser: the same in the functional test and in the measurement.
enum ParseLoad {
  /// «1 2 3 … n»: one run of numbers as long as the line.
  static func numbers(_ count: Int) -> String {
    (1...count).map { "\($0)" }.joined(separator: " ")
  }

  /// «кофе кофе … кофе 250»: the amount at the very end.
  static func words(_ count: Int) -> String {
    String(repeating: "кофе ", count: count) + "250"
  }
}

/// One warm-up and five measured runs on `ContinuousClock`; prints the median and the maximum.
enum ParseBench {
  static var isOn: Bool { ProcessInfo.processInfo.environment["OHMYMONEY_BENCH"] == "1" }

  struct Times {
    let median: Duration
    let max: Duration
  }

  @discardableResult
  static func measure(_ label: String, runs: Int = 5, _ work: () -> Void) -> Times {
    work()
    let clock = ContinuousClock()
    var times = (0..<runs).map { _ in clock.measure(work) }
    times.sort()
    let result = Times(median: times[runs / 2], max: times[runs - 1])
    print("bench · \(label): median \(text(result.median)), max \(text(result.max))")
    return result
  }

  /// Milliseconds with one decimal, in integers only.
  static func text(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let tenths = seconds * 10_000 + attoseconds / 100_000_000_000_000
    return "\(tenths / 10).\(tenths % 10) ms"
  }
}
