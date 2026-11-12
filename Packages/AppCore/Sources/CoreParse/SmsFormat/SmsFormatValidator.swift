import CoreKit
import Foundation

/// The rules a format has to meet before it is used — one for each, each with its own test.
public enum SmsFormatValidator {
  /// What is wrong with `format`; empty when nothing is. `others` are the other formats of the
  /// same bank: an example must not fit any of them, or one text would have two readings.
  public static func problems(
    of format: SmsFormat, among others: [SmsFormat] = []
  ) -> [SmsFormatProblem] {
    var found: [SmsFormatProblem] = []
    if format.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
      return [.missingPattern]
    }
    guard let compiled = SmsCompiledFormat(format) else { return [.invalidPattern] }
    if format.columns.isEmpty { return [.missingColumns] }

    var seen = Set<String>()
    for column in format.columns where column != .skip {
      if !seen.insert(column.name).inserted { found.append(.duplicateColumn(column.name)) }
      if case .date(let pattern) = column, !SmsFormatNumbers.isValidDatePattern(pattern) {
        found.append(.badDateFormat(pattern))
      }
    }
    if compiled.groupCount != format.columns.count {
      found.append(
        .groupCountMismatch(groups: compiled.groupCount, columns: format.columns.count))
    }
    if format.examples.isEmpty { found.append(.noExamples) }
    // A format that cannot be read is not tried against its examples: every one would fail.
    guard found.isEmpty else { return found }

    let rivals = others.filter { $0.id != format.id && $0.bank == format.bank }
      .compactMap(SmsCompiledFormat.init)
    for (index, example) in format.examples.enumerated() {
      let number = index + 1
      guard let result = compiled.read(example, today: Self.checkDay) else {
        found.append(.exampleDoesNotMatch(number))
        continue
      }
      if case .failure(let failure) = result {
        found.append(.exampleUnreadable(number, column: failure.column))
      }
      for rival in rivals where rival.matches(example) {
        found.append(.exampleMatchesOther(number, other: rival.format.id))
      }
    }
    return found
  }

  /// Every format against the others of its bank; only the ones with problems are listed.
  public static func problems(ofSet formats: [SmsFormat]) -> [String: [SmsFormatProblem]] {
    var out: [String: [SmsFormatProblem]] = [:]
    for format in formats {
      let found = problems(of: format, among: formats)
      if !found.isEmpty { out[format.id] = found }
    }
    return out
  }

  /// A day for formats whose date has no year; examples are checked on it.
  static let checkDay = DateOnly(year: 2026, month: 6, day: 15)
}
