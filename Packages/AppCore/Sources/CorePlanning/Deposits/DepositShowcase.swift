import CoreAnalytics
import CoreKit
import Foundation

/// One deposit of the showcase: a product of a bank with the rate it is offered at and the
/// conditions that matter for choosing it. The built-in entries are data of the app (they change
/// with a release); the owner's own are `deposit_offers`.
///
/// Every field the source did not state is `nil` and reads as «unknown», never as zero or as
/// «no»: a rate that is `nil` is shown as «уточните на сайте банка».
public struct DepositShowcaseEntry: Identifiable, Hashable, Sendable {
  public enum Origin: Hashable, Sendable {
    case builtIn
    case own(UUID)
  }

  public var id: String
  public var origin: Origin
  public var bankName: String
  /// The name of the product as the bank calls it; empty for an offer typed by the owner.
  public var product: String
  /// Yearly rate in percent; `nil`: not known.
  public var ratePercent: Decimal?
  /// The rate is the highest the bank states («до 13,5 %»), reached only on its conditions.
  public var rateIsMaximum: Bool
  public var termMinMonths: Int?
  public var termMaxMonths: Int?
  public var minAmountE4: AmountE4?
  public var maxAmountE4: AmountE4?
  public var newClientOnly: Bool
  public var needsSubscription: Bool
  /// May be topped up; `nil`: the source does not say.
  public var topup: Bool?
  /// The day the rate was read from the bank.
  public var rateOn: DateOnly
  public var note: String?

  public init(
    id: String, origin: Origin = .builtIn, bankName: String, product: String = "",
    ratePercent: Decimal? = nil, rateIsMaximum: Bool = false, termMinMonths: Int? = nil,
    termMaxMonths: Int? = nil, minAmountE4: AmountE4? = nil, maxAmountE4: AmountE4? = nil,
    newClientOnly: Bool = false, needsSubscription: Bool = false, topup: Bool? = nil,
    rateOn: DateOnly, note: String? = nil
  ) {
    self.id = id
    self.origin = origin
    self.bankName = bankName
    self.product = product
    self.ratePercent = ratePercent
    self.rateIsMaximum = rateIsMaximum
    self.termMinMonths = termMinMonths
    self.termMaxMonths = termMaxMonths
    self.minAmountE4 = minAmountE4
    self.maxAmountE4 = maxAmountE4
    self.newClientOnly = newClientOnly
    self.needsSubscription = needsSubscription
    self.topup = topup
    self.rateOn = rateOn
    self.note = note
  }

  /// The entry of an offer the owner typed in: its one term is both ends of the range.
  public init(_ offer: DepositOffer) {
    self.init(
      id: "own:\(offer.id.uuidString)", origin: .own(offer.id), bankName: offer.bankName,
      ratePercent: offer.ratePercent, termMinMonths: offer.termMonths,
      termMaxMonths: offer.termMonths, minAmountE4: offer.minAmountE4,
      maxAmountE4: offer.maxAmountE4, newClientOnly: offer.newClientOnly,
      needsSubscription: offer.needsSubscription, topup: offer.topup, rateOn: offer.rateOn,
      note: offer.note)
  }

  /// Whether the rate is older than `DepositShowcase.staleAfterDays` on `today`: it may have
  /// changed since.
  public func isStale(on today: DateOnly) -> Bool {
    rateOn.days(to: today) > DepositShowcase.staleAfterDays
  }
}

/// What the owner narrows the showcase by. A field left `nil` narrows nothing. An entry whose
/// source did not state a bound is not ruled out by it, but one that does not say whether it can
/// be topped up is ruled out when a top-up is required.
public struct DepositFilter: Hashable, Sendable {
  public var termMonths: Int?
  public var amountE4: AmountE4?
  public var requiresTopup: Bool

  public init(termMonths: Int? = nil, amountE4: AmountE4? = nil, requiresTopup: Bool = false) {
    self.termMonths = termMonths
    self.amountE4 = amountE4
    self.requiresTopup = requiresTopup
  }

  public static let none = DepositFilter()

  public func admits(_ entry: DepositShowcaseEntry) -> Bool {
    if let term = termMonths {
      if let low = entry.termMinMonths, term < low { return false }
      if let high = entry.termMaxMonths, term > high { return false }
    }
    if let amount = amountE4 {
      if let low = entry.minAmountE4, amount < low { return false }
      if let high = entry.maxAmountE4, amount > high { return false }
    }
    if requiresTopup, entry.topup != true { return false }
    return true
  }
}

/// The showcase of deposits: the entries built into the app and the owner's own, narrowed and
/// sorted by rate. Nothing here is advice: it lists what banks publish, with the day it was read.
public enum DepositShowcase {
  /// A rate read longer ago than this is shown grey, «могла измениться».
  public static let staleAfterDays = 30

  /// Entries sorted by rate, the highest first; ones without a rate last, then by bank name and
  /// id, so the order is the same on every launch.
  public static func sorted(_ entries: [DepositShowcaseEntry]) -> [DepositShowcaseEntry] {
    entries.sorted { left, right in
      switch (left.ratePercent, right.ratePercent) {
      case (let a?, let b?) where a != b: return a > b
      case (nil, _?): return false
      case (_?, nil): return true
      default:
        return (left.bankName.lowercased(), left.id) < (right.bankName.lowercased(), right.id)
      }
    }
  }

  /// The entries a filter admits, by rate.
  public static func entries(
    builtIn: [DepositShowcaseEntry] = DepositShowcaseData.entries, own: [DepositOffer] = [],
    filter: DepositFilter = .none
  ) -> [DepositShowcaseEntry] {
    let all = builtIn + own.filter { !$0.archived }.map(DepositShowcaseEntry.init)
    return sorted(all.filter(filter.admits))
  }
}

extension Dataset {
  public static let depositOffersKey = "planning.depositOffers"

  /// The deposit offers the owner typed into the showcase, archived ones included.
  public var depositOffers: [DepositOffer] {
    get { extras.value(Self.depositOffersKey) ?? [] }
    set { extras.set(newValue, for: Self.depositOffersKey) }
  }
}
