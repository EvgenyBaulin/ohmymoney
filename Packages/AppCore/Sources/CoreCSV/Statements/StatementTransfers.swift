import CoreKit
import Foundation

/// Who the owner is, as banks write it: phone numbers, the name in the form «Имя Отчество Ф»,
/// the numbers of the owner's own contracts and cards. Personal data: it is stored in the
/// database (so a new Mac imports at once) but never in a CSV export or a problem report, and
/// it prints as redacted so a log line cannot leak it.
public struct StatementIdentity: Sendable, Codable, Hashable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var phones: [String]
  public var names: [String]
  public var contractNumbers: [String]
  public var cardMasks: [String]

  public init(
    phones: [String] = [], names: [String] = [], contractNumbers: [String] = [],
    cardMasks: [String] = []
  ) {
    self.phones = phones
    self.names = names
    self.contractNumbers = contractNumbers
    self.cardMasks = cardMasks
  }

  public var description: String { "StatementIdentity(redacted)" }
  public var debugDescription: String { description }

  static func nameKey(_ name: String) -> String {
    NameKey.fold(StatementText.collapse(name.replacingOccurrences(of: ".", with: "")))
  }

  /// True when the other side of the operation is the owner: the phone, the name, the
  /// contract or the card is one of the owner's. Matching by the first letter of a surname
  /// is never used: relatives share it.
  public func owns(_ counterparty: StatementCounterparty) -> Bool {
    if let phone = counterparty.phone, !phone.isEmpty,
      phones.contains(where: { StatementText.phoneKey($0) == StatementText.phoneKey(phone) })
    {
      return true
    }
    if let name = counterparty.name, !name.isEmpty,
      names.contains(where: { Self.nameKey($0) == Self.nameKey(name) })
    {
      return true
    }
    if let contract = counterparty.contractRef, contractNumbers.contains(contract) { return true }
    if let mask = counterparty.cardMask {
      let key = StatementText.collapse(mask)
      if cardMasks.contains(where: { StatementText.collapse($0) == key }) { return true }
    }
    return false
  }
}

/// An operation together with the account it belongs to, for pairing across statements.
public struct StatementLeg: Sendable, Hashable {
  /// Position in the list given to the pairing; stable handle in the results.
  public var id: Int
  /// The account of the statement; two legs of one account never pair.
  public var accountKey: String
  public var bankName: String?
  /// Numbers by which this account is named by others: its contract and account numbers.
  public var ownReferences: Set<String>
  public var operation: ImportedOperation

  public init(
    id: Int, accountKey: String, bankName: String? = nil, ownReferences: Set<String> = [],
    operation: ImportedOperation
  ) {
    self.id = id
    self.accountKey = accountKey
    self.bankName = bankName
    self.ownReferences = ownReferences
    self.operation = operation
  }
}

public struct StatementTransferPair: Sendable, Hashable {
  public enum Strength: String, Sendable, Hashable {
    /// The bank names the other contract and the amounts and times agree.
    case explicit
    /// Equal amounts, opposite signs, a few minutes apart, nothing contradicts.
    case exact
    /// Equal amounts within two days: proposed with a tick the person confirms, never
    /// written alone.
    case soft
  }
  public var outgoing: Int
  public var incoming: Int
  public var strength: Strength
}

public struct StatementTransferResult: Sendable, Hashable {
  /// Explicit and exact pairs: safe to write as one transfer.
  public var pairs: [StatementTransferPair] = []
  /// Proposals that need a confirmation.
  public var softPairs: [StatementTransferPair] = []
  /// Groups of leg ids that fit one another equally well; the person picks.
  public var ambiguous: [[Int]] = []
}

public enum StatementTransferPairing {
  /// Largest gap in minutes for an explicit or exact pair.
  public static let exactWindowMinutes = 10
  /// Largest gap for a proposed pair.
  public static let softWindowMinutes = 48 * 60
  /// Without a time of day on either side, the gap in days for a proposed pair.
  public static let softWindowDaysWithoutTime = 2

  private static let transferKinds: Set<StatementOperationKind> = [
    .ownContractTransferOut, .ownContractTransferIn, .sbpTransferOut, .sbpTransferIn,
    .personTransferOut, .personTransferIn, .cardTransferOut, .unnamedTransferIn,
  ]

  /// Finds the two halves of transfers between the owner's accounts.
  ///
  /// Order: an explicit link first, then equal amount and time, then a proposal. A line goes
  /// into one pair only. Purchases never pair, so a refund of one thousand is not taken for
  /// «one thousand from yourself». When a bank names the receiving bank, only a leg of that
  /// bank can be the other half.
  public static func pair(_ legs: [StatementLeg]) -> StatementTransferResult {
    var result = StatementTransferResult()
    let candidates = legs.filter {
      transferKinds.contains($0.operation.kind) && $0.operation.status != .declined
    }
    let outs = candidates.filter { $0.operation.amount.isNegative }
    let ins = candidates.filter { !$0.operation.amount.isNegative && !$0.operation.amount.isZero }
    var used = Set<Int>()

    func compatible(_ o: StatementLeg, _ i: StatementLeg) -> Bool {
      o.accountKey != i.accountKey && o.operation.currency == i.operation.currency
        && o.operation.amount.magnitude == i.operation.amount.magnitude
        && bankAgrees(o.operation.counterparty.bankName, i.bankName)
    }
    func gap(_ o: StatementLeg, _ i: StatementLeg) -> Int? {
      StatementMoment.minutes(from: o.operation.moment, to: i.operation.moment).map(abs)
    }

    // Explicit links.
    for o in outs where o.operation.kind == .ownContractTransferOut {
      guard !used.contains(o.id), let reference = o.operation.counterparty.contractRef else {
        continue
      }
      let matches = ins.filter {
        !used.contains($0.id) && compatible(o, $0)
          && ($0.ownReferences.contains(reference)
            || $0.operation.counterparty.contractRef.map(o.ownReferences.contains) == true)
          && (gap(o, $0).map { $0 <= exactWindowMinutes }
            ?? (o.operation.moment.day == $0.operation.moment.day))
      }
      if matches.count == 1, let other = matches.first {
        result.pairs.append(
          StatementTransferPair(outgoing: o.id, incoming: other.id, strength: .explicit))
        used.insert(o.id)
        used.insert(other.id)
      }
    }

    // Equal amount and time. A pair stands only when each is the other's only nearest fit.
    func nearest(of leg: StatementLeg, in pool: [StatementLeg], outgoing: Bool) -> [StatementLeg] {
      let fits = pool.filter {
        !used.contains($0.id) && (outgoing ? compatible(leg, $0) : compatible($0, leg))
          && (gap(leg, $0).map { $0 <= exactWindowMinutes } ?? false)
      }
      guard let best = fits.compactMap({ gap(leg, $0) }).min() else { return [] }
      return fits.filter { gap(leg, $0) == best }
    }
    var exactIDs: [(Int, Int)] = []
    var ambiguousIDs = Set<Int>()
    for o in outs where !used.contains(o.id) {
      let forward = nearest(of: o, in: ins, outgoing: true)
      guard !forward.isEmpty else { continue }
      if forward.count == 1, let i = forward.first {
        let back = nearest(of: i, in: outs, outgoing: false)
        if back.count == 1 {
          exactIDs.append((o.id, i.id))
          continue
        }
      }
      ambiguousIDs.insert(o.id)
      forward.forEach { ambiguousIDs.insert($0.id) }
    }
    for (o, i) in exactIDs where !used.contains(o) && !used.contains(i) {
      result.pairs.append(StatementTransferPair(outgoing: o, incoming: i, strength: .exact))
      used.insert(o)
      used.insert(i)
    }
    let leftover = ambiguousIDs.subtracting(used)
    if !leftover.isEmpty { result.ambiguous = [leftover.sorted()] }

    // Proposals: one candidate on each side.
    func softFits(_ o: StatementLeg, _ i: StatementLeg) -> Bool {
      guard compatible(o, i) else { return false }
      if let minutes = gap(o, i) { return minutes <= softWindowMinutes }
      return abs(StatementMoment.days(from: o.operation.moment.day, to: i.operation.moment.day))
        <= softWindowDaysWithoutTime
    }
    let freeOuts = outs.filter { !used.contains($0.id) && !leftover.contains($0.id) }
    let freeIns = ins.filter { !used.contains($0.id) && !leftover.contains($0.id) }
    for o in freeOuts {
      let fits = freeIns.filter { softFits(o, $0) }
      guard fits.count == 1, let i = fits.first else { continue }
      guard freeOuts.filter({ softFits($0, i) }).count == 1 else { continue }
      result.softPairs.append(
        StatementTransferPair(outgoing: o.id, incoming: i.id, strength: .soft))
    }
    return result
  }

  /// A named receiving bank must be the bank of the other leg; a missing name on either side
  /// does not contradict.
  static func bankAgrees(_ named: String?, _ actual: String?) -> Bool {
    guard let named, let actual else { return true }
    let a = NameKey.fold(named)
    let b = NameKey.fold(actual)
    return a.isEmpty || b.isEmpty || a.contains(b) || b.contains(a)
  }
}

/// A transfer to an account of the owner that has no statement loaded.
public struct StatementOwnAccountQuestion: Sendable, Hashable {
  public var bankName: String?
  public var legIDs: [Int]
  public var total: AmountE4
}

/// Where an unpaired own transfer stands.
public struct StatementInTransit: Sendable, Hashable {
  /// Still within the wait: shown as money on its way.
  public var onTheWay: [Int] = []
  /// Waited long enough: asked about.
  public var overdue: [Int] = []
}

public enum StatementOwnTransfers {
  /// How long a sent transfer may wait for its arriving half before it is asked about.
  public static let inTransitWaitDays = 5

  /// Outgoing transfers to the owner's own account (by identity) that found no pair, grouped
  /// by the receiving bank: one question per bank instead of one per line.
  public static func toAccountsWithoutStatement(
    legs: [StatementLeg], paired: Set<Int>, identity: StatementIdentity
  ) -> [StatementOwnAccountQuestion] {
    var groups: [String: [StatementLeg]] = [:]
    var order: [String] = []
    for leg in legs
    where !paired.contains(leg.id) && leg.operation.amount.isNegative
      && leg.operation.status != .declined && identity.owns(leg.operation.counterparty)
    {
      let key = NameKey.fold(leg.operation.counterparty.bankName ?? "")
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(leg)
    }
    return order.map { key in
      let group = groups[key] ?? []
      return StatementOwnAccountQuestion(
        bankName: group.first?.operation.counterparty.bankName, legIDs: group.map(\.id),
        total: AmountE4.sum(group.map { $0.operation.amount.magnitude }))
    }
  }

  /// Splits unpaired outgoing own transfers into «on the way» and «overdue» by the age of
  /// the send on `today`.
  public static func inTransit(
    unpairedOutgoing legs: [StatementLeg], today: DateOnly
  ) -> StatementInTransit {
    var result = StatementInTransit()
    for leg in legs {
      let age = StatementMoment.days(from: leg.operation.moment.day, to: today)
      if age <= inTransitWaitDays {
        result.onTheWay.append(leg.id)
      } else {
        result.overdue.append(leg.id)
      }
    }
    return result
  }
}

/// What the person is asked about an operation nothing else could place.
public enum StatementQuestionTopic: String, Sendable, Hashable, Codable {
  /// A person on the other side: expense, gift, debt, income, own account?
  case person
  /// Money in with no sender named.
  case unknownIncomingSource
  /// A loan received or repaid: «is this a loan?».
  case loan
  /// Contract income that may be self-employed income; only asked when that is switched on.
  case selfEmployedIncome
  /// A place the category model is not sure about.
  case merchant
  /// A card of unknown owner.
  case unknownCard
}

/// A group of like operations answered with one decision.
public struct StatementQuestionGroup: Sendable, Hashable {
  public var topic: StatementQuestionTopic
  /// The grouping key: phone, else name, else the folded place.
  public var key: String
  public var indices: [Int]
  public var total: AmountE4
  public var from: DateOnly
  public var to: DateOnly
  /// Messages of the transfers, to suggest an answer («С Днём Рождения!»).
  public var messages: [String]
  /// The «remember» tick is on for places and off for people: one person may be a debt today
  /// and a gift tomorrow.
  public var rememberByDefault: Bool
}

public enum StatementQuestions {
  /// Groups the operations that remain after pairing and remembered rules. `isAnswered`
  /// stands for the person's rules and the category model, which live elsewhere.
  public static func group(
    operations: [ImportedOperation], selfEmploymentEnabled: Bool,
    isAnswered: (ImportedOperation) -> Bool = { _ in false }
  ) -> [StatementQuestionGroup] {
    var groups: [String: StatementQuestionGroup] = [:]
    var order: [String] = []
    for (index, operation) in operations.enumerated()
    where operation.status != .declined && !isAnswered(operation) {
      guard let topic = topic(of: operation, selfEmploymentEnabled: selfEmploymentEnabled) else {
        continue
      }
      let cp = operation.counterparty
      let raw =
        cp.phone.map(StatementText.phoneKey) ?? cp.name.map(StatementIdentity.nameKey)
        ?? operation.placeKey
      let key = topic.rawValue + "|" + raw
      if groups[key] == nil {
        order.append(key)
        groups[key] = StatementQuestionGroup(
          topic: topic, key: raw, indices: [], total: .zero, from: operation.moment.day,
          to: operation.moment.day, messages: [],
          rememberByDefault: topic != .person && topic != .unknownIncomingSource)
      }
      var group = groups[key]!
      group.indices.append(index)
      group.total += operation.amount
      group.from = min(group.from, operation.moment.day)
      group.to = max(group.to, operation.moment.day)
      if let message = operation.message, !message.isEmpty, !group.messages.contains(message) {
        group.messages.append(message)
      }
      groups[key] = group
    }
    return order.compactMap { groups[$0] }
  }

  static func topic(
    of operation: ImportedOperation, selfEmploymentEnabled: Bool
  )
    -> StatementQuestionTopic?
  {
    switch operation.kind {
    case .personTransferOut, .personTransferIn, .sbpTransferOut: return .person
    case .sbpTransferIn, .unnamedTransferIn: return .unknownIncomingSource
    case .loanProceeds, .loanRepayment: return .loan
    case .contractIncome: return selfEmploymentEnabled ? .selfEmployedIncome : nil
    case .cardTransferOut: return .unknownCard
    case .purchase, .servicePayment, .rawCardLine, .cardCredit, .unknown: return .merchant
    default: return nil
    }
  }
}
