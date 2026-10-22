import CoreKit
import Foundation

/// The day a bank text names: «вчера», «12 октября», «12.10», «12.10.2026». A push usually
/// names none (it is about now), a row of a history always does.
enum BankDates {
  struct Hit {
    var day: DateOnly
    var span: ScanSpan
  }

  private static let months: [(stems: [String], month: Int)] = [
    (["января", "янв"], 1), (["февраля", "фев"], 2), (["марта", "мар"], 3),
    (["апреля", "апр"], 4), (["мая"], 5), (["июня", "июн"], 6), (["июля", "июл"], 7),
    (["августа", "авг"], 8), (["сентября", "сен"], 9), (["октября", "окт"], 10),
    (["ноября", "ноя"], 11), (["декабря", "дек"], 12),
  ]

  static func find(in scan: BankScan, taken: [Bool], today: DateOnly?) -> Hit? {
    if let today {
      for (word, back) in [("позавчера", 2), ("вчера", 1), ("сегодня", 0)] {
        if let span = scan.find(word), !taken[span.start..<span.end].contains(true) {
          return Hit(day: CalendarContext.utc.adding(days: -back, to: today), span: span)
        }
      }
    }
    var index = 0
    while index < scan.count {
      guard scan.isDigit(index), !scan.isDigit(index - 1), !taken[index],
        index == 0 || !scan.chars[index - 1].isLetter
      else {
        index += 1
        continue
      }
      var end = index
      while scan.isDigit(end), end - index < 2 { end += 1 }
      guard !scan.isDigit(end), end < scan.count, !taken[end],
        let day = Int(scan.string(ScanSpan(start: index, end: end)))
      else {
        while scan.isDigit(index) { index += 1 }
        continue
      }
      if scan.chars[end] == "." {
        if let hit = numeric(scan, day: day, from: index, dotAt: end, taken: taken, today: today) {
          return hit
        }
      } else if scan.chars[end] == " ",
        let hit = named(scan, day: day, from: index, wordAt: end + 1, taken: taken, today: today)
      {
        return hit
      }
      while scan.isDigit(index) { index += 1 }
    }
    return nil
  }

  /// «12.10», «12.10.26», «12.10.2026».
  private static func numeric(
    _ scan: BankScan, day: Int, from start: Int, dotAt dot: Int, taken: [Bool], today: DateOnly?
  ) -> Hit? {
    var monthEnd = dot + 1
    while scan.isDigit(monthEnd), monthEnd - dot - 1 < 2 { monthEnd += 1 }
    guard monthEnd > dot + 1, !scan.isDigit(monthEnd),
      let month = Int(scan.string(ScanSpan(start: dot + 1, end: monthEnd))),
      !taken[start..<monthEnd].contains(true)
    else { return nil }
    var end = monthEnd
    var year: Int?
    if end < scan.count, scan.chars[end] == ".", scan.isDigit(end + 1) {
      var yearEnd = end + 1
      while scan.isDigit(yearEnd) { yearEnd += 1 }
      let digits = yearEnd - end - 1
      if digits == 2 || digits == 4, !taken[end..<yearEnd].contains(true),
        let value = Int(scan.string(ScanSpan(start: end + 1, end: yearEnd)))
      {
        year = digits == 2 ? 2000 + value : value
        end = yearEnd
      }
    }
    guard let resolved = resolve(day: day, month: month, year: year, today: today) else {
      return nil
    }
    return Hit(day: resolved, span: ScanSpan(start: start, end: end))
  }

  /// «12 октября», «12 окт», «12 октября 2025».
  private static func named(
    _ scan: BankScan, day: Int, from start: Int, wordAt wordStart: Int, taken: [Bool],
    today: DateOnly?
  ) -> Hit? {
    var wordEnd = wordStart
    while wordEnd < scan.count, scan.chars[wordEnd].isLetter { wordEnd += 1 }
    guard wordEnd > wordStart, !taken[wordStart..<wordEnd].contains(true) else { return nil }
    let word = String(scan.low[wordStart..<wordEnd])
    guard let month = months.first(where: { $0.stems.contains(word) })?.month else { return nil }
    var end = wordEnd
    var year: Int?
    if end + 4 < scan.count, scan.chars[end] == " ", scan.isDigit(end + 1), scan.isDigit(end + 4),
      !scan.isDigit(end + 5), let value = Int(scan.string(ScanSpan(start: end + 1, end: end + 5))),
      !taken[end..<(end + 5)].contains(true)
    {
      year = value
      end += 5
    }
    guard let resolved = resolve(day: day, month: month, year: year, today: today) else {
      return nil
    }
    return Hit(day: resolved, span: ScanSpan(start: start, end: end))
  }

  /// A day with no year is the latest one that is not after `today`: a history copied in
  /// January that says «28 декабря» means last year.
  private static func resolve(day: Int, month: Int, year: Int?, today: DateOnly?) -> DateOnly? {
    guard (1...12).contains(month), day >= 1 else { return nil }
    func valid(_ year: Int) -> DateOnly? {
      guard (1990...2100).contains(year) else { return nil }
      guard day <= CalendarContext.utc.daysInMonth(MonthKey(year: year, month: month)) else {
        return nil
      }
      return DateOnly(year: year, month: month, day: day)
    }
    if let year { return valid(year) }
    guard let today else { return nil }
    if let thisYear = valid(today.year), thisYear <= today { return thisYear }
    return valid(today.year - 1)
  }
}
