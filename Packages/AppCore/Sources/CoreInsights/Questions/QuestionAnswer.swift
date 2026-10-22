import CoreAnalytics
import CoreKit
import CoreParse
import Foundation

/// One figure of an answer: a period and the money in it.
public struct QuestionFigure: Hashable, Sendable {
  public var period: Period
  public var total: AmountE4
  /// How many operations the figure is made of.
  public var operationCount: Int

  public init(period: Period, total: AmountE4, operationCount: Int) {
    self.period = period
    self.total = total
    self.operationCount = operationCount
  }
}

/// One line of «what grew» and «the largest»: a top-level category.
public struct QuestionAnswerItem: Hashable, Sendable {
  public var key: ReportKey
  public var amount: AmountE4
  /// What the category usually takes: the mean of the periods before. `nil` for «the
  /// largest».
  public var usual: AmountE4?

  /// By how much the period is above the usual.
  public var excess: AmountE4? { usual.map { amount - $0 } }

  public init(key: ReportKey, amount: AmountE4, usual: AmountE4? = nil) {
    self.key = key
    self.amount = amount
    self.usual = usual
  }
}

/// Where «Открыть в Аналитике» leads: the period and the filter that reproduce the answer.
public struct QuestionLink: Hashable, Sendable {
  public var period: Period
  public var filter: EntryFilter
  public var measure: QuestionMeasure

  public init(period: Period, filter: EntryFilter, measure: QuestionMeasure) {
    self.period = period
    self.filter = filter
    self.measure = measure
  }
}

/// The answer to a question: figures from the ledger, with the question as it was
/// understood. Nothing here is made up by a model.
public struct QuestionAnswer: Hashable, Sendable {
  public var question: ResolvedQuestion
  public var current: QuestionFigure
  /// The other side of a comparison.
  public var other: QuestionFigure?
  /// The comparison as a change of the first figure against the second.
  public var change: Change? { other.map { Change(current: current.total, previous: $0.total) } }
  /// An unfinished period was compared with the same part of the other (1–18 September with
  /// 1–18 August), not with the whole of it.
  public var comparedLikeForLike: Bool
  /// «What grew» and «the largest», the largest first.
  public var items: [QuestionAnswerItem]
  /// How many earlier periods «the usual» was taken from; zero means there was nothing to
  /// call usual.
  public var usualPeriods: Int
  /// The periods to offer under the answer when the question named none.
  public var periodLinks: [RelativePeriod]
  public var link: QuestionLink

  /// There was nothing at all to count in the period.
  public var hasNoOperations: Bool {
    current.operationCount == 0 && (other?.operationCount ?? 0) == 0 && items.isEmpty
  }
}

/// Answers a resolved question from the ledger, with the very rules of Analytics and
/// Reports: the same rows, the same period logic, the same sums.
public struct QuestionAnswerer: Sendable {
  public let ledger: Ledger
  public let today: DateOnly

  /// How many earlier periods the usual is taken from.
  public static let usualPeriodCount = 3
  public static let itemLimit = 5

  public init(ledger: Ledger, today: DateOnly) {
    self.ledger = ledger
    self.today = today
  }

  public func answer(_ question: ResolvedQuestion) -> QuestionAnswer {
    let subjects = question.terms.map(\.chosen)
    let measure = question.measure
    let period = question.period.period(today: today)
    let link = QuestionLink(
      period: period, filter: Self.filter(for: subjects, period: period), measure: measure)

    switch question.intent {
    case .howMuch:
      return QuestionAnswer(
        question: question, current: figure(period, subjects, measure), other: nil,
        comparedLikeForLike: false, items: [], usualPeriods: 0, periodLinks: question.periodLinks,
        link: link)
    case .compare:
      let otherPeriod = (question.comparePeriod ?? question.period.previous(today: today))
        .period(today: today)
      var spans = (current: period, other: otherPeriod)
      var likeForLike = false
      if !period.isComplete(today: today), otherPeriod.range == period.previous.range {
        let both = period.comparisonSpans(today: today)
        spans = (Period.covering(both.current), Period.covering(both.previous))
        likeForLike = true
      }
      return QuestionAnswer(
        question: question, current: figure(spans.current, subjects, measure),
        other: figure(spans.other, subjects, measure), comparedLikeForLike: likeForLike,
        items: [], usualPeriods: 0, periodLinks: [], link: link)
    case .biggest:
      let kind: CategoryKind = measure == .income ? .income : .expense
      let breakdown = CategoryBreakdown(ledger: ledger, period: period, kind: kind)
      let items = breakdown.topLevel.filter { $0.amount > .zero }.prefix(Self.itemLimit)
        .map { QuestionAnswerItem(key: $0.key, amount: $0.amount) }
      return QuestionAnswer(
        question: question, current: figure(period, [], measure), other: nil,
        comparedLikeForLike: false, items: items, usualPeriods: 0,
        periodLinks: question.periodLinks, link: link)
    case .whatGrew:
      let (items, used) = grown(in: period, measure: measure)
      return QuestionAnswer(
        question: question, current: figure(period, [], measure), other: nil,
        comparedLikeForLike: false, items: items, usualPeriods: used,
        periodLinks: question.periodLinks, link: link)
    }
  }

  // MARK: - One figure

  /// The money of the period that belongs to the subjects. Spending is my expenses by date
  /// (the contribution of each row, as every table of Analytics sums it); income is taken by
  /// the month it is for when the period is whole months.
  func figure(
    _ period: Period, _ subjects: [QuestionSubject], _ measure: QuestionMeasure
  )
    -> QuestionFigure
  {
    let rows: [LedgerRow]
    let amount: (LedgerRow) -> AmountE4
    switch measure {
    case .spending:
      rows = ledger.rows(in: period.range).filter { !$0.contribution.isZero }
      amount = { $0.contribution }
    case .income:
      rows = ledger.incomeRows(in: period)
      amount = { $0.amountRubE4 }
    }
    let matcher = RowMatcher(subjects: subjects, ledger: ledger)
    var total = AmountE4.zero
    var operations = Set<UUID>()
    for row in rows where matcher.matches(row) {
      total += amount(row)
      operations.insert(row.transactionId)
    }
    return QuestionFigure(period: period, total: total, operationCount: operations.count)
  }

  // MARK: - What grew beyond the usual

  /// The top-level categories of the period that are above the mean of the periods before,
  /// the largest excess first; and how many earlier periods the mean was made of.
  private func grown(in period: Period, measure: QuestionMeasure) -> ([QuestionAnswerItem], Int) {
    let kind: CategoryKind = measure == .income ? .income : .expense
    let spans = period.comparisonSpans(today: today)
    let currentPeriod = period.isComplete(today: today) ? period : Period.covering(spans.current)
    let current = CategoryBreakdown(ledger: ledger, period: currentPeriod, kind: kind).topLevel

    var earlier: [[ReportKey: AmountE4]] = []
    var before = period
    for step in 1...Self.usualPeriodCount {
      before = before.previous
      guard let first = ledger.firstDay, before.end >= first else { break }
      var span = before.range
      if !period.isComplete(today: today) {
        span = DayRange(before.start, min(before.end, shiftedBack(spans.current.end, step, period)))
      }
      let nodes = CategoryBreakdown(ledger: ledger, period: Period.covering(span), kind: kind)
        .topLevel
      earlier.append(Dictionary(nodes.map { ($0.key, $0.amount) }, uniquingKeysWith: +))
    }
    guard !earlier.isEmpty else { return ([], 0) }

    var items: [QuestionAnswerItem] = []
    for node in current where node.amount > .zero {
      let sum = AmountE4.sum(earlier.map { $0[node.key] ?? .zero })
      let mean =
        (try? DecimalMath.int64(rounding: Decimal(sum.raw) / Decimal(earlier.count)))
        ?? 0
      let item = QuestionAnswerItem(key: node.key, amount: node.amount, usual: AmountE4(raw: mean))
      if let excess = item.excess, excess > .zero { items.append(item) }
    }
    items.sort { left, right in
      let (a, b) = (left.excess ?? .zero, right.excess ?? .zero)
      if a != b { return a > b }
      return left.key.description < right.key.description
    }
    return (Array(items.prefix(Self.itemLimit)), earlier.count)
  }

  /// The last day of an unfinished period, moved back by `steps` periods.
  private func shiftedBack(_ day: DateOnly, _ steps: Int, _ period: Period) -> DateOnly {
    switch period.kind {
    case .month: return day.adding(months: -steps)
    case .year, .twelveMonths: return day.adding(months: -12 * steps)
    case .days: return day.adding(days: -period.range.dayCount * steps)
    }
  }

  // MARK: - The link

  static func filter(for subjects: [QuestionSubject], period: Period) -> EntryFilter {
    var filter = EntryFilter(period: period)
    var words: [String] = []
    for subject in subjects {
      switch subject {
      case .category(let id, _): filter.categoryId = id
      case .subcategory(let id, _, _): filter.subcategoryId = id
      case .place(let id, _): filter.placeId = id
      case .person(let id, _): filter.personId = id
      case .event(let id, _): filter.eventId = id
      case .paymentMethod(let id, _): filter.paymentMethodId = id
      case .text(let text): words.append(text)
      }
    }
    filter.text = words.joined(separator: " ")
    return filter
  }
}

/// Decides whether a row belongs to the subjects of a question; every subject must hold.
struct RowMatcher {
  private let subjects: [QuestionSubject]
  private let words: [[String]]
  private let ledger: Ledger

  init(subjects: [QuestionSubject], ledger: Ledger) {
    self.subjects = subjects
    self.ledger = ledger
    self.words = subjects.map { subject in
      if case .text(let text) = subject {
        return NameKey.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
      }
      return []
    }
  }

  func matches(_ row: LedgerRow) -> Bool {
    for (index, subject) in subjects.enumerated() {
      switch subject {
      case .category(let id, _):
        if row.categoryId != id && row.rootCategoryId != id { return false }
      case .subcategory(let id, _, _):
        if row.categoryId != id { return false }
      case .place(let id, _):
        if row.placeId != id { return false }
      case .person(let id, _):
        if row.forPersonId != id && row.debtorPersonId != id { return false }
      case .event(let id, _):
        if row.eventId != id { return false }
      case .paymentMethod(let id, _):
        if row.paymentMethodId != id { return false }
      case .text:
        guard let key = ledger.searchKey(of: row.transactionId),
          words[index].allSatisfy({ key.contains($0) })
        else { return false }
      }
    }
    return true
  }
}
