import CoreKit
import Foundation

/// What money back that already came in means once the part it closed changes its rubles.
///
/// A part's rubles change after the money came back when the purchase is edited by hand (its
/// rate, what the card was charged), when the bank's rate of a provisional purchase is refined,
/// or when the money-back sheet corrects the purchase's rate. The money that came back does not
/// change, so the links, the surplus of each money back and the owner's own spending on the
/// part (a shortfall or a remainder written off — the companions) are balanced again, in the
/// same write:
///
/// * a part still waiting that the money now covers closes, and what the money covered above
///   it is income in «Доплаты» (a provisional 266.73 ₽ refined to 265.07 ₽ with 266 ₽ back:
///   closed, 0.93 ₽ of income); within the tolerance of the drift it closes with nothing written
///   (refined to 266.23 ₽: closed, the 0.23 ₽ is drift);
/// * a closed part that got cheaper first lowers the owner's own spending on it, then gives the
///   rubles its links no longer need to their money backs' surpluses, the newest money back
///   first (1,840 ₽ closed by 2,000 ₽, edited to 1,800 ₽: link 1,800, surplus 200);
/// * a closed part that got dearer first takes from those surpluses, the newest money back first
///   (edited to 1,900 ₽: link 1,900, surplus 100); what is still missing is drift within the
///   tolerance, the owner's own spending when the part was settled by hand, or else the part
///   waits for the rest again — it never falls short by itself.
///
/// Money back in the part's own currency — dollars back for a part paid in dollars — covered
/// dollars, not rubles: its links hold the part's rubles for those dollars, and the rubles
/// between the day of the purchase and the day the money came are drift. Such a link follows
/// the part's new rubles in proportion (20 $ at 92 closed by exactly 20 $, charged 1,900 ₽
/// later: link 1,900, still closed, nothing owed and nothing earned); it never gives rubles to
/// a surplus, takes them from one, or reopens the part. Only the money in rubles or in a third
/// currency is balanced again, against what the part's own-currency money leaves of it.
///
/// For every money back in rubles or in a third currency, its links and its surplus add up to
/// what they did: the money that came back is written once, whatever the part now costs.
public enum MoneyBackSettlement {
  /// One live link of a money back to the part, in rubles.
  public struct Link: Hashable, Sendable {
    public var id: UUID
    public var moneyBackId: UUID
    public var amountRubE4: AmountE4

    public init(id: UUID, moneyBackId: UUID, amountRubE4: AmountE4) {
      self.id = id
      self.moneyBackId = moneyBackId
      self.amountRubE4 = amountRubE4
    }
  }

  /// A live money back as the re-balancing needs it.
  public struct MoneyBackState: Hashable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var currency: CurrencyCode
    public var amountE4: AmountE4
    public var amountRubE4: AmountE4
    /// The rubles of its live surplus; zero when it has none.
    public var surplusRubE4: AmountE4

    public init(
      id: UUID, occurredAt: Date, currency: CurrencyCode, amountE4: AmountE4,
      amountRubE4: AmountE4, surplusRubE4: AmountE4 = .zero
    ) {
      self.id = id
      self.occurredAt = occurredAt
      self.currency = currency
      self.amountE4 = amountE4
      self.amountRubE4 = amountRubE4
      self.surplusRubE4 = surplusRubE4
    }
  }

  /// The owner's own spending on the part: a shortfall of a money back or a remainder written
  /// off, in rubles.
  public struct Companion: Hashable, Sendable {
    public var id: UUID
    public var amountRubE4: AmountE4

    public init(id: UUID, amountRubE4: AmountE4) {
      self.id = id
      self.amountRubE4 = amountRubE4
    }
  }

  /// A part paid for somebody else, with its new rubles and what settled it so far.
  public struct PartState: Hashable, Sendable {
    public var partId: UUID
    /// The part's rubles as they are now.
    public var amountRubE4: AmountE4
    public var status: ReimbursementStatus
    /// A currency other than rubles is involved — the part's or a money back's: the tolerance of
    /// rate drift applies.
    public var foreignInvolved: Bool
    public var links: [Link]
    public var companions: [Companion]
    /// The currency the part was paid in.
    public var currency: CurrencyCode
    /// The part's rubles before they changed; `nil` when unknown — links of money in the part's
    /// own currency then stay as they are.
    public var previousAmountRubE4: AmountE4?

    public init(
      partId: UUID, amountRubE4: AmountE4, status: ReimbursementStatus, foreignInvolved: Bool,
      links: [Link], companions: [Companion] = [], currency: CurrencyCode = .rub,
      previousAmountRubE4: AmountE4? = nil
    ) {
      self.partId = partId
      self.amountRubE4 = amountRubE4
      self.status = status
      self.foreignInvolved = foreignInvolved
      self.links = links
      self.companions = companions
      self.currency = currency
      self.previousAmountRubE4 = previousAmountRubE4
    }
  }

  /// What changes; everything not named stays.
  public struct Outcome: Hashable, Sendable {
    public var status: ReimbursementStatus
    /// Link → its new rubles.
    public var links: [UUID: AmountE4]
    /// Money back → the new rubles of its surplus; zero: the surplus goes.
    public var surplusRub: [UUID: AmountE4]
    /// Companion → its new rubles; zero: it goes.
    public var companions: [UUID: AmountE4]
    /// The status the part came in with, to tell a change of it.
    public var statusBefore: ReimbursementStatus

    public init(
      status: ReimbursementStatus, links: [UUID: AmountE4] = [:],
      surplusRub: [UUID: AmountE4] = [:], companions: [UUID: AmountE4] = [:],
      statusBefore: ReimbursementStatus? = nil
    ) {
      self.status = status
      self.links = links
      self.surplusRub = surplusRub
      self.companions = companions
      self.statusBefore = statusBefore ?? status
    }

    public var isUnchanged: Bool {
      status == statusBefore && links.isEmpty && surplusRub.isEmpty && companions.isEmpty
    }
  }

  /// The part balanced again against the money that came back for it. `moneyBacks` holds at
  /// least every money back the part's links name; their surpluses are read from it. Money backs
  /// are taken newest first — by moment, then by id.
  public static func settle(_ part: PartState, moneyBacks: [UUID: MoneyBackState]) -> Outcome {
    let before = part.status
    guard part.status != .writtenOff, !part.links.isEmpty else {
      return Outcome(status: part.status, statusBefore: before)
    }
    // Money in the part's own currency covered its units: the rubles of its links follow the
    // part's in proportion, and that share of the part is settled whatever the rate.
    let inUnits =
      part.currency == .rub
      ? [] : part.links.filter { moneyBacks[$0.moneyBackId]?.currency == part.currency }
    let unitLinkIds = Set(inUnits.map(\.id))
    let inRubles = part.links.filter { !unitLinkIds.contains($0.id) }
    var unitShares: [UUID: AmountE4] = [:]
    var unitsCover = AmountE4.sum(inUnits.map(\.amountRubE4))
    if !inUnits.isEmpty, let previous = part.previousAmountRubE4, previous.raw > 0,
      previous != part.amountRubE4
    {
      let was = unitsCover
      // All of the part covered stays all of it, to the unit.
      let now =
        was == previous
        ? part.amountRubE4
        : (try? AmountE4(decimal: was.decimal * part.amountRubE4.decimal / previous.decimal))
          ?? was
      let shares = now.allocated(proportionallyTo: inUnits.map(\.amountRubE4), outOf: was)
      for (link, share) in zip(inUnits, shares) where share != link.amountRubE4 {
        unitShares[link.id] = share
      }
      unitsCover = now
    }
    guard !inRubles.isEmpty else {
      return Outcome(status: part.status, links: unitShares, statusBefore: before)
    }

    // What is left of the part to the money in rubles or in a third currency.
    let price = max(part.amountRubE4 - unitsCover, .zero)
    let covered = AmountE4.sum(inRubles.map(\.amountRubE4))
    let own = AmountE4.sum(part.companions.map(\.amountRubE4))
    let tolerance = MoneyBack.tolerance(
      partRub: part.amountRubE4, foreignInvolved: part.foreignInvolved)

    var links = Dictionary(
      inRubles.map { ($0.id, $0.amountRubE4) }, uniquingKeysWith: { first, _ in first })
    var surpluses: [UUID: AmountE4] = [:]
    for link in inRubles {
      surpluses[link.moneyBackId] = moneyBacks[link.moneyBackId]?.surplusRubE4 ?? .zero
    }
    // The part's links, the newest money back first.
    let newestFirst = inRubles.sorted { first, second in
      let a = moneyBacks[first.moneyBackId]
      let b = moneyBacks[second.moneyBackId]
      let aAt = a?.occurredAt ?? .distantPast
      let bAt = b?.occurredAt ?? .distantPast
      if aAt != bAt { return aAt > bAt }
      if first.moneyBackId != second.moneyBackId {
        return first.moneyBackId.uuidString > second.moneyBackId.uuidString
      }
      return first.id.uuidString > second.id.uuidString
    }
    var companions = Dictionary(
      part.companions.map { ($0.id, $0.amountRubE4) }, uniquingKeysWith: { first, _ in first })

    /// Takes `amount` off the links, newest first, into their money backs' surpluses.
    func giveBack(_ amount: AmountE4) {
      var left = amount
      for link in newestFirst where left.raw > 0 {
        let has = links[link.id] ?? .zero
        let take = min(has, left)
        guard take.raw > 0 else { continue }
        links[link.id] = has - take
        surpluses[link.moneyBackId, default: .zero] += take
        left = left - take
      }
    }

    var status = part.status
    switch part.status {
    case .writtenOff:
      break
    case .expected:
      if price <= covered {
        status = .returned
        giveBack(covered - price)
      } else if price - covered <= tolerance {
        status = .returned
      }
    case .returned:
      let need = price - covered - own
      if need.raw < 0 {
        var cheaper = -need
        for companion in part.companions where cheaper.raw > 0 {
          let has = companions[companion.id] ?? .zero
          let take = min(has, cheaper)
          companions[companion.id] = has - take
          cheaper = cheaper - take
        }
        giveBack(cheaper)
      } else if need.raw > 0 {
        var dearer = need
        var taken: Set<UUID> = []
        for link in newestFirst where dearer.raw > 0 && !taken.contains(link.moneyBackId) {
          taken.insert(link.moneyBackId)
          let spare = surpluses[link.moneyBackId] ?? .zero
          let take = min(spare, dearer)
          guard take.raw > 0 else { continue }
          surpluses[link.moneyBackId] = spare - take
          links[link.id, default: .zero] += take
          dearer = dearer - take
        }
        if dearer > tolerance {
          if let first = part.companions.first {
            companions[first.id, default: .zero] += dearer
          } else {
            status = .expected
          }
        }
      }
    }

    var outcome = Outcome(status: status, links: unitShares, statusBefore: before)
    for link in inRubles where links[link.id] != link.amountRubE4 {
      outcome.links[link.id] = links[link.id] ?? .zero
    }
    for (moneyBackId, surplus) in surpluses
    where surplus != (moneyBacks[moneyBackId]?.surplusRubE4 ?? .zero) {
      outcome.surplusRub[moneyBackId] = surplus
    }
    for companion in part.companions where companions[companion.id] != companion.amountRubE4 {
      outcome.companions[companion.id] = companions[companion.id] ?? .zero
    }
    return outcome
  }

  /// A surplus of `rub` rubles in the money back's own currency, at its own rate: rubles for
  /// money back in rubles, otherwise the rubles over its rubles per unit, to four decimals.
  public static func surplusAmount(rub: AmountE4, of moneyBack: MoneyBackState) -> AmountE4 {
    guard moneyBack.currency != .rub, moneyBack.amountE4.raw > 0, moneyBack.amountRubE4.raw > 0
    else { return rub }
    let exact = rub.decimal * moneyBack.amountE4.decimal / moneyBack.amountRubE4.decimal
    return (try? AmountE4(decimal: exact)) ?? rub
  }
}
