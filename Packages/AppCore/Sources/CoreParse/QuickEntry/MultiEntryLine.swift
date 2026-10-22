import CoreKit
import Foundation

/// Several operations in one line, split by «;»: «кофе 250; метро 62; обед 450». Each part is
/// read on its own, as if it were typed alone — a date, a card or an account written in one part
/// belongs to that part and to no other.
public struct MultiEntryReading: Hashable, Sendable {
  public struct Part: Hashable, Sendable {
    public var text: String
    public var parsed: ParsedInput
  }

  public var parts: [Part]
  /// The line had more parts than `MultiEntryLine.maxParts`; the rest are not read.
  public var truncated: Bool

  /// More than one part: the line is a batch, written by one step and undone by one ⌘Z.
  public var isBatch: Bool { parts.count > 1 }

  /// Every part can be saved. A batch is written whole or not at all.
  public var isSaveable: Bool {
    !parts.isEmpty && !truncated && parts.allSatisfy(\.parsed.isSaveable)
  }

  /// The first part that cannot be saved — the one to show the reason for.
  public var firstProblem: Int? { parts.firstIndex(where: { !$0.parsed.isSaveable }) }
}

public enum MultiEntryLine {
  /// A line of more parts than anyone types is a paste of something else.
  public static let maxParts = 30

  /// The parts of the line: trimmed, the empty ones (a «;» at the end, «;;») dropped.
  public static func split(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == ";" || $0 == "；" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  public static func containsSeparator(_ text: String) -> Bool {
    text.contains(";") || text.contains("；")
  }

  public static func read(
    _ text: String, parser: InputLineParser, today: DateOnly, kind: TransactionKind? = nil
  ) -> MultiEntryReading {
    let all = split(text)
    let used = all.prefix(maxParts)
    return MultiEntryReading(
      parts: used.map { part in
        MultiEntryReading.Part(text: part, parsed: parser.parse(part, today: today, kind: kind))
      },
      truncated: all.count > maxParts)
  }
}
