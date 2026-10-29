import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The checks of «Знаешь ли ты». Each one asks one question about the owner's own spending.
public enum FactID: String, Hashable, Sendable, CaseIterable {
  case weekdayLowest, weekdayHighest
  case weekendHeavier, weekendLighter
  case firstHalfHeavier, secondHalfHeavier
  case afterIncomeHeavier
  case timeBiggestChecks, timeSmallestChecks
  case placeDearest, placeCheapest, placeMostVisited
  case categoryGrew, categoryShrank
  case checkGrew, checkShrank
  case purchasesMore, purchasesFewer
  case repeatedNote
  case goodShareGrew, badShareGrew
  case savingsGrew, savingsShrank
  case noSpendDaysMore, noSpendDaysFewer

  /// The key of the sentence in the String Catalog.
  public var key: String { "summaries.fact.\(rawValue)" }
}

/// One true and noticeable finding.
public struct KnowFact: Hashable, Sendable {
  public var id: FactID
  public var args: [SummaryArg]
  /// How far the finding is from the ordinary, in basis points of the ordinary.
  public var differenceBP: Int

  public var line: SummaryLine { SummaryLine(id.key, args) }
}

/// A set of 25 checks over the owner's spending. A check gives a finding only when it is true
/// and the difference it rests on is at least 20 % — a smaller difference is noise, not a
/// finding. Nothing here is random: the finding of the week is picked from the true ones by
/// the number of the week, so the same week always says the same thing and the weeks follow
/// one another through different checks.
public enum KnowYouFacts {
  /// The least difference that makes a finding, in basis points.
  public static let thresholdBP = 2_000
  /// The days the habits are read over.
  static let windowDays = 91
  /// The days «lately» and «before that» each cover.
  static let recentDays = 28
  /// The history the checks ask for, in days.
  static let minimumHistoryDays = 56
  static let minimumPurchases = 30

  /// Every check that is true for the days up to `end`, in the order of `FactID`.
  public static func facts(ledger: Ledger, through end: DateOnly) -> [KnowFact] {
    guard let context = Context(ledger: ledger, end: end) else { return [] }
    return FactID.allCases.compactMap { context.check($0) }
  }

  /// One check on its own.
  public static func check(_ id: FactID, ledger: Ledger, through end: DateOnly) -> KnowFact? {
    Context(ledger: ledger, end: end)?.check(id)
  }

  /// The finding of a week: judged on the days up to the end of the week.
  public static func find(ledger: Ledger, week: WeekKey) -> KnowFact? {
    let all = facts(ledger: ledger, through: week.end)
    guard !all.isEmpty else { return nil }
    return all[(week.start.dayNumber / 7) % all.count]
  }

  // MARK: - The data the checks read

  struct Purchase {
    var day: DateOnly
    var amount: Decimal
    var placeId: UUID?
    var categoryId: UUID?
    var note: String?
    var bucket: TimeBucket?
    var quality: Quality?
  }

  struct Context {
    let end: DateOnly
    let windowStart: DateOnly
    let purchases: [Purchase]
    let spendByDay: [DateOnly: Decimal]
    let incomeDays: Set<DateOnly>
    let ledger: Ledger

    var windowDayCount: Int { windowStart.days(to: end) + 1 }
    var recent: DayRange { DayRange(end.adding(days: -(recentDays - 1)), end) }
    var prior: DayRange {
      DayRange(end.adding(days: -(2 * recentDays - 1)), end.adding(days: -recentDays))
    }

    init?(ledger: Ledger, end: DateOnly) {
      guard let first = ledger.firstDay, first.days(to: end) + 1 >= minimumHistoryDays else {
        return nil
      }
      self.ledger = ledger
      self.end = end
      windowStart = max(first, end.adding(days: -(windowDays - 1)))
      var purchases: [Purchase] = []
      var spend: [DateOnly: Decimal] = [:]
      var income: Set<DateOnly> = []
      let range = DayRange(windowStart, end)
      var byTransaction: [UUID: Int] = [:]
      for row in ledger.rows(in: range) {
        if row.kind == .income { income.insert(row.day) }
        guard row.contribution.raw > 0, row.link?.isBookkeeping != true,
          row.systemRole != .goals, row.systemRole != .loans
        else { continue }
        let amount = row.contribution.decimal
        spend[row.day, default: 0] += amount
        if let index = byTransaction[row.transactionId] {
          purchases[index].amount += amount
          continue
        }
        let transaction = ledger.entry(row.transactionId)?.transaction
        let time = transaction.map {
          ledger.calendar.timeOfDay($0.occurredAt, recordedIn: $0.timeZoneId)
        }
        // A time of exactly 12:00 is the one an operation gets when nobody said when.
        let bucket = time.flatMap { $0.hour == 12 && $0.minute == 0 ? nil : TimeBucket(hour: $0.hour) }
        let note = transaction?.note.map(Self.normalised).flatMap { $0.isEmpty ? nil : $0 }
        byTransaction[row.transactionId] = purchases.count
        purchases.append(
          Purchase(
            day: row.day, amount: amount, placeId: row.placeId, categoryId: row.rootCategoryId,
            note: note, bucket: bucket, quality: row.quality))
      }
      guard purchases.count >= minimumPurchases else { return nil }
      self.purchases = purchases
      spendByDay = spend
      incomeDays = income
    }

    static func normalised(_ text: String) -> String {
      NameKey.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Helpers

    func total(_ items: some Sequence<Purchase>) -> Decimal {
      items.reduce(0) { $0 + $1.amount }
    }

    func fact(_ id: FactID, _ args: [SummaryArg], _ differenceBP: Int?) -> KnowFact? {
      guard let differenceBP, differenceBP >= thresholdBP else { return nil }
      return KnowFact(id: id, args: args, differenceBP: differenceBP)
    }

    func percentArg(_ basisPoints: Int) -> SummaryArg { .percent(SummaryMath.percent(basisPoints)) }

    /// The days of the window with their spending (zero for a quiet day).
    var days: [(day: DateOnly, spend: Decimal)] {
      DayRange(windowStart, end).days.map { ($0, spendByDay[$0] ?? 0) }
    }

    func average(of selected: [(day: DateOnly, spend: Decimal)]) -> Decimal? {
      guard !selected.isEmpty else { return nil }
      return selected.reduce(0) { $0 + $1.spend } / Decimal(selected.count)
    }

    func inRange(_ range: DayRange) -> [Purchase] { purchases.filter { range.contains($0.day) } }

    /// The difference of `value` below `base`, in basis points of `base`.
    func below(_ value: Decimal, _ base: Decimal) -> Int? {
      SummaryMath.changeBP(value, base: base).map { -$0 }
    }

    func above(_ value: Decimal, _ base: Decimal) -> Int? {
      SummaryMath.changeBP(value, base: base)
    }

    // MARK: Checks

    func check(_ id: FactID) -> KnowFact? {
      switch id {
      case .weekdayLowest, .weekdayHighest: return weekday(id)
      case .weekendHeavier, .weekendLighter: return weekend(id)
      case .firstHalfHeavier, .secondHalfHeavier: return halves(id)
      case .afterIncomeHeavier: return afterIncome()
      case .timeBiggestChecks, .timeSmallestChecks: return timeOfDay(id)
      case .placeDearest, .placeCheapest: return placeChecks(id)
      case .placeMostVisited: return mostVisited()
      case .categoryGrew, .categoryShrank: return categoryMove(id)
      case .checkGrew, .checkShrank: return averageCheck(id)
      case .purchasesMore, .purchasesFewer: return purchaseCount(id)
      case .repeatedNote: return repeatedNote()
      case .goodShareGrew, .badShareGrew: return qualityShare(id)
      case .savingsGrew, .savingsShrank: return savings(id)
      case .noSpendDaysMore, .noSpendDaysFewer: return quietDays(id)
      }
    }

    private func weekday(_ id: FactID) -> KnowFact? {
      guard let overall = average(of: days) else { return nil }
      var best: (weekday: Int, mean: Decimal)?
      for weekday in 1...7 {
        let own = days.filter { $0.day.weekday == weekday }
        guard own.count >= 4, let mean = average(of: own) else { continue }
        if let current = best {
          let better = id == .weekdayLowest ? mean < current.mean : mean > current.mean
          if better { best = (weekday, mean) }
        } else {
          best = (weekday, mean)
        }
      }
      guard let best else { return nil }
      let difference = id == .weekdayLowest ? below(best.mean, overall) : above(best.mean, overall)
      return fact(id, [.weekday(best.weekday), percentArg(difference ?? 0)], difference)
    }

    private func weekend(_ id: FactID) -> KnowFact? {
      guard let weekend = average(of: days.filter { $0.day.weekday >= 6 }),
        let weekdays = average(of: days.filter { $0.day.weekday < 6 })
      else { return nil }
      let difference = id == .weekendHeavier ? above(weekend, weekdays) : below(weekend, weekdays)
      return fact(id, [percentArg(difference ?? 0)], difference)
    }

    private func halves(_ id: FactID) -> KnowFact? {
      let first = days.filter { $0.day.day <= 15 }
      let second = days.filter { $0.day.day > 15 }
      guard first.count >= 10, second.count >= 10, let one = average(of: first),
        let two = average(of: second)
      else { return nil }
      let difference = id == .firstHalfHeavier ? above(one, two) : above(two, one)
      return fact(id, [percentArg(difference ?? 0)], difference)
    }

    private func afterIncome() -> KnowFact? {
      guard incomeDays.count >= 3 else { return nil }
      let near = days.filter { entry in
        (0...2).contains { incomeDays.contains(entry.day.adding(days: -$0)) }
      }
      let others = days.filter { entry in
        !(0...2).contains { incomeDays.contains(entry.day.adding(days: -$0)) }
      }
      guard near.count >= 6, others.count >= 6, let one = average(of: near),
        let two = average(of: others)
      else { return nil }
      let difference = above(one, two)
      return fact(.afterIncomeHeavier, [percentArg(difference ?? 0)], difference)
    }

    private func timeOfDay(_ id: FactID) -> KnowFact? {
      let timed = purchases.filter { $0.bucket != nil }
      guard timed.count >= 20 else { return nil }
      let overall = total(timed) / Decimal(timed.count)
      var best: (bucket: TimeBucket, mean: Decimal)?
      for bucket in TimeBucket.allCases {
        let own = timed.filter { $0.bucket == bucket }
        guard own.count >= 5 else { continue }
        let mean = total(own) / Decimal(own.count)
        if let current = best {
          let better = id == .timeBiggestChecks ? mean > current.mean : mean < current.mean
          if better { best = (bucket, mean) }
        } else {
          best = (bucket, mean)
        }
      }
      guard let best else { return nil }
      let difference =
        id == .timeBiggestChecks ? above(best.mean, overall) : below(best.mean, overall)
      return fact(id, [.timeOfDay(best.bucket), percentArg(difference ?? 0)], difference)
    }

    private func placeChecks(_ id: FactID) -> KnowFact? {
      let placed = purchases.filter { $0.placeId != nil }
      guard !placed.isEmpty else { return nil }
      let overall = total(purchases) / Decimal(purchases.count)
      let groups = Dictionary(grouping: placed, by: { $0.placeId! }).filter { $0.value.count >= 3 }
      var best: (place: UUID, mean: Decimal)?
      for (place, items) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        let mean = total(items) / Decimal(items.count)
        if let current = best {
          let better = id == .placeDearest ? mean > current.mean : mean < current.mean
          if better { best = (place, mean) }
        } else {
          best = (place, mean)
        }
      }
      guard let best else { return nil }
      let difference = id == .placeDearest ? above(best.mean, overall) : below(best.mean, overall)
      return fact(id, [.place(best.place), percentArg(difference ?? 0)], difference)
    }

    private func mostVisited() -> KnowFact? {
      let counts = Dictionary(grouping: purchases.compactMap(\.placeId), by: { $0 })
        .map { (place: $0.key, count: $0.value.count) }
        .sorted { ($0.count, $1.place.uuidString) > ($1.count, $0.place.uuidString) }
      guard counts.count >= 2, counts[0].count >= 4 else { return nil }
      let difference = SummaryMath.changeBP(Decimal(counts[0].count), base: Decimal(counts[1].count))
      return fact(.placeMostVisited, [.place(counts[0].place), .count(counts[0].count)], difference)
    }

    private func categoryMove(_ id: FactID) -> KnowFact? {
      func sums(_ items: [Purchase]) -> [UUID: Decimal] {
        var result: [UUID: Decimal] = [:]
        for item in items {
          if let category = item.categoryId { result[category, default: 0] += item.amount }
        }
        return result
      }
      let now = sums(inRange(recent))
      let before = sums(inRange(prior))
      let priorTotal = before.values.reduce(0, +)
      guard priorTotal > 0 else { return nil }
      var best: (category: UUID, delta: Decimal, difference: Int)?
      for category in Set(now.keys).union(before.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
        let after = now[category] ?? 0
        let was = before[category] ?? 0
        let delta = id == .categoryGrew ? after - was : was - after
        // A move of a few roubles in a rarely bought category is not a finding.
        guard was > 0, delta > 0, delta * 100 >= priorTotal * 3 else { continue }
        guard let difference = Optional(SummaryMath.shareBP(delta, of: was)),
          difference >= thresholdBP
        else { continue }
        if best == nil || delta > best!.delta { best = (category, delta, difference) }
      }
      guard let best else { return nil }
      return fact(id, [.category(best.category), percentArg(best.difference)], best.difference)
    }

    private func averageCheck(_ id: FactID) -> KnowFact? {
      let now = inRange(recent)
      let before = inRange(prior)
      guard now.count >= 5, before.count >= 5 else { return nil }
      let mean = total(now) / Decimal(now.count)
      let base = total(before) / Decimal(before.count)
      let difference = id == .checkGrew ? above(mean, base) : below(mean, base)
      return fact(id, [percentArg(difference ?? 0)], difference)
    }

    private func purchaseCount(_ id: FactID) -> KnowFact? {
      let now = inRange(recent).count
      let before = inRange(prior).count
      guard before >= 5 else { return nil }
      let difference =
        id == .purchasesMore
        ? SummaryMath.changeBP(Decimal(now), base: Decimal(before))
        : SummaryMath.shareBP(Decimal(before - now), of: Decimal(before))
      return fact(id, [percentArg(difference ?? 0), .count(now)], difference)
    }

    private func repeatedNote() -> KnowFact? {
      let counts = Dictionary(grouping: purchases.compactMap(\.note), by: { $0 })
        .map { (note: $0.key, count: $0.value.count) }
        .sorted { ($0.count, $1.note) > ($1.count, $0.note) }
      guard let top = counts.first, top.count >= 4 else { return nil }
      let difference =
        counts.count > 1
        ? SummaryMath.changeBP(Decimal(top.count), base: Decimal(counts[1].count)) : 10_000
      return fact(.repeatedNote, [.name(top.note), .count(top.count)], difference)
    }

    private func qualityShare(_ id: FactID) -> KnowFact? {
      let wanted: Quality = id == .goodShareGrew ? .good : .bad
      func share(_ items: [Purchase]) -> Decimal? {
        let all = total(items)
        guard all > 0 else { return nil }
        return total(items.filter { $0.quality == wanted }) / all
      }
      guard let now = share(inRange(recent)), let before = share(inRange(prior)), before > 0
      else { return nil }
      let difference = above(now, before)
      return fact(id, [percentArg(SummaryMath.whole(now * 10_000)), percentArg(difference ?? 0)], difference)
    }

    private func savings(_ id: FactID) -> KnowFact? {
      func rate(_ range: DayRange) -> Decimal? {
        let came = AmountE4.sum(
          ledger.rows(in: range).lazy.filter { $0.kind == .income }.map(\.amountRubE4))
        guard came.raw > 0 else { return nil }
        return (came - ledger.expenses(in: range)).decimal / came.decimal
      }
      guard let now = rate(recent), let before = rate(prior), before > 0 else { return nil }
      let difference = id == .savingsGrew ? above(now, before) : below(now, before)
      return fact(id, [percentArg(SummaryMath.whole(now * 10_000)), percentArg(difference ?? 0)], difference)
    }

    private func quietDays(_ id: FactID) -> KnowFact? {
      func quiet(_ range: DayRange) -> Int { range.days.filter { (spendByDay[$0] ?? 0) == 0 }.count }
      let now = quiet(recent)
      let before = quiet(prior)
      guard before > 0 || now > 0 else { return nil }
      let more = id == .noSpendDaysMore
      guard (more ? now - before : before - now) >= 2 else { return nil }
      let difference =
        more
        ? SummaryMath.changeBP(Decimal(now), base: Decimal(before))
        : SummaryMath.shareBP(Decimal(before - now), of: Decimal(before))
      return fact(id, [.count(now), .count(before)], difference ?? (more ? 10_000 : nil))
    }
  }
}
