import AppCore
import Foundation

/// Everything the Subscriptions screen shows, counted once for the data on screen: the running
/// subscriptions with what each costs, the totals, what could be cancelled, the notices, and per
/// line the comparison of a year with twelve months, the shares of the people, the use, the band
/// of a floating amount and the history of the price. Every figure is the core's; the page only
/// gathers them, so a test reads the very numbers the screen shows.
struct SubscriptionsPage: Sendable {
  /// One rise or fall of a price, with the part of it the exchange rate did when the
  /// subscription is paid in another currency.
  struct PriceStep: Hashable, Sendable, Identifiable {
    var date: DateOnly
    var oldPrice: AmountE4
    var newPrice: AmountE4
    var split: PriceChangeSplit?
    var id: DateOnly { date }
  }

  /// One running subscription and everything that goes with its line.
  struct Row: Identifiable, Sendable {
    var line: SubscriptionLine
    var terms: SubscriptionTerms?
    var comparison: BillingComparison?
    var family: FamilyShare?
    var usage: UsageValue
    var band: FloatingBand?
    var steps: [PriceStep]
    /// An expensive subscription nobody marked as used for a long time.
    var isUnused: Bool
    var id: UUID { line.id }
  }

  var rows: [Row]
  var totals: SubscriptionTotals
  /// A year's cost over 365 days, in rubles.
  var perDayRub: AmountE4
  var advice: CancelAdvice
  var notices: [SubscriptionNotice]
  /// Candidates found in the purchases that are the one line of the App Store, which cannot be
  /// laid out by the app.
  var appStoreCandidates: [SubscriptionCandidate]
  var today: DateOnly

  func row(_ id: UUID) -> Row? { rows.first { $0.id == id } }

  /// The page for the data of `snapshot`.
  static func build(_ snapshot: DataSnapshot) -> SubscriptionsPage {
    build(
      book: snapshot.dataset.planning, subscriptions: snapshot.dataset.subscriptions,
      ledger: snapshot.ledger, rates: snapshot.context.dayRates,
      rubPerUnit: snapshot.context.rubPerUnit, matches: snapshot.planning.matches,
      candidates: snapshot.planning.candidates, today: snapshot.today)
  }

  static func build(
    book: PlanningBook, subscriptions: SubscriptionBook, ledger: Ledger, rates: DayRates,
    rubPerUnit: [CurrencyCode: Decimal], matches: ScheduledMatches = .empty,
    candidates: [SubscriptionCandidate] = [], today: DateOnly,
    options: CancelAdviceOptions = CancelAdviceOptions()
  ) -> SubscriptionsPage {
    let lines = SubscriptionCosts.lines(
      book: book, subscriptions: subscriptions, today: today, rubPerUnit: rubPerUnit)
    let totals = SubscriptionCosts.totals(of: lines)
    let advice = CancelAdvisor.advise(
      lines: lines, subscriptions: subscriptions, today: today, options: options)
    let unused = Set(advice.unused.map(\.paymentId))
    let rows = lines.map { line -> Row in
      let payment = line.payment
      let terms = subscriptions.terms(of: payment.id)
      let band: FloatingBand? =
        terms?.floating == true
        ? FloatingAmount.band(
          payment: payment, terms: terms,
          history: FloatingAmount.charges(of: payment, ledger: ledger, today: today).map(\.amount))
        : nil
      return Row(
        line: line, terms: terms,
        comparison: BillingComparisons.compare(payment: payment, terms: terms, price: line.price),
        family: line.people.isEmpty
          ? nil
          : FamilyShares.split(
            line.price, people: line.people, ownerUses: terms?.ownerUses ?? true),
        usage: SubscriptionUsage.value(
          paymentId: payment.id, monthlyRub: line.monthlyRub, marks: subscriptions.usage,
          today: today),
        band: band, steps: steps(of: payment, prices: book.prices, rates: rates),
        isUnused: unused.contains(payment.id))
    }
    let notices =
      (SubscriptionWatch.notices(
        book: book, subscriptions: subscriptions, today: today, matches: matches)
      + FloatingAmount.notices(
        book: book, subscriptions: subscriptions, ledger: ledger, today: today))
      .sorted { ($0.day, $0.id) < ($1.day, $1.id) }
    return SubscriptionsPage(
      rows: rows, totals: totals, perDayRub: SubscriptionCosts.perDay(yearlyRub: totals.yearlyRub),
      advice: advice, notices: notices,
      appStoreCandidates: candidates.filter { AppStoreBilling.isAppleBilling($0) },
      today: today)
  }

  /// The changes of the price of a payment, oldest first: each row of the history that differs
  /// from the one before it.
  static func steps(
    of payment: ScheduledPayment, prices: [SubscriptionPrice], rates: DayRates
  ) -> [PriceStep] {
    let own = prices.filter { $0.paymentId == payment.id }.sorted { $0.date < $1.date }
    var steps: [PriceStep] = []
    for (index, row) in own.enumerated() where index > 0 {
      let before = own[index - 1]
      guard before.amountE4 != row.amountE4 else { continue }
      steps.append(
        PriceStep(
          date: row.date, oldPrice: before.amountE4, newPrice: row.amountE4,
          split: PriceChangeSplits.split(
            payment: payment, prices: own, rates: rates, from: before.date, to: row.date)))
    }
    return steps
  }

  /// The notices not put away on this Mac.
  func shownNotices(dismissed: Set<String>) -> [SubscriptionNotice] {
    notices.filter { !dismissed.contains($0.id) }
  }
}

extension AnalysisFacade {
  /// The page of the Subscriptions screen, off the main thread and kept per version of the data.
  func subscriptionsPage(_ snapshot: DataSnapshot) async throws -> SubscriptionsPage {
    try await core.cached("subs.page", snapshot) { SubscriptionsPage.build(snapshot) }
  }
}

extension SubscriptionAnalysisFacade {
  /// «Стоит посмотреть» of the subscriptions: trials ending, yearly charges ahead and floating
  /// amounts outside their band, soonest first.
  func allNotices(_ snapshot: DataSnapshot) async throws -> [SubscriptionNotice] {
    try await core.cached("subs.allNotices", snapshot) {
      let watch = SubscriptionWatch.notices(
        book: snapshot.dataset.planning, subscriptions: snapshot.dataset.subscriptions,
        today: snapshot.today, matches: snapshot.planning.matches)
      let floating = FloatingAmount.notices(
        book: snapshot.dataset.planning, subscriptions: snapshot.dataset.subscriptions,
        ledger: snapshot.ledger, today: snapshot.today)
      return (watch + floating).sorted { ($0.day, $0.id) < ($1.day, $1.id) }
    }
  }
}
