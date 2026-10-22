import CoreAnalytics
import CoreKit
import Foundation

/// An expensive subscription nobody has marked as used for a long time.
public struct UnusedSubscription: Hashable, Sendable, Identifiable {
  public var paymentId: UUID
  public var yearlyRub: AmountE4
  /// The latest «пользовался»; `nil` — never marked since the owner began marking.
  public var lastUsed: DateOnly?
  public var id: UUID { paymentId }
}

/// Two or more running subscriptions of one type: «Две музыки … — 598 ₽ в месяц».
public struct DuplicateGroup: Hashable, Sendable, Identifiable {
  public var type: ServiceType
  /// Priciest first.
  public var paymentIds: [UUID]
  public var monthlyRub: AmountE4
  /// What cancelling all but the priciest would save a year (a conservative figure).
  public var savingYearlyRub: AmountE4
  public var id: String { type.rawValue }
}

/// «Что можно отменить»: both signs, and what dropping them would save.
public struct CancelAdvice: Hashable, Sendable {
  public var unused: [UnusedSubscription]
  public var duplicates: [DuplicateGroup]
  /// A year's saving if every suggestion were taken, each subscription counted once.
  public var savingYearlyRub: AmountE4

  public var isEmpty: Bool { unused.isEmpty && duplicates.isEmpty }
}

public struct CancelAdviceOptions: Hashable, Sendable {
  /// «Дорогая»: a year's cost in rubles from this.
  public var expensiveYearlyRub: AmountE4
  /// «Давно»: days without a mark.
  public var unusedDays: Int

  public init(expensiveYearlyRub: AmountE4 = AmountE4(whole: 6_000), unusedDays: Int = 60) {
    self.expensiveYearlyRub = expensiveYearlyRub
    self.unusedDays = unusedDays
  }
}

public enum CancelAdvisor {

  /// The advice for the running `lines`.
  ///
  /// * Unused: yearly cost at or above the threshold, no «нужна», not already cancelled, and
  ///   no mark for `unusedDays` days. Marks are optional: until the owner has been marking for
  ///   at least `unusedDays` days (his earliest mark of any subscription is that old) a
  ///   subscription without marks is not judged — it would be every one of them.
  /// * Duplicates: two or more of one type — the owner's own type, else the catalogue's — except
  ///   those marked «нужна» and unless the owner kept exactly this group («нужны оба»); a new
  ///   subscription of the type brings the offer back.
  public static func advise(
    lines: [SubscriptionLine], subscriptions: SubscriptionBook, today: DateOnly,
    options: CancelAdviceOptions = CancelAdviceOptions()
  ) -> CancelAdvice {
    let candidates = lines.filter { line in
      line.payment.endDate == nil && subscriptions.terms(of: line.id)?.needed != true
    }

    // Unused.
    let earliestMark = subscriptions.usage.map(\.day).min()
    let marking = earliestMark.map { $0.days(to: today) >= options.unusedDays } ?? false
    var unused: [UnusedSubscription] = []
    if marking {
      for line in candidates {
        guard let yearly = line.yearlyRub, yearly >= options.expensiveYearlyRub else { continue }
        let last = subscriptions.usage.filter { $0.paymentId == line.id && $0.day <= today }
          .map(\.day).max()
        if let last, last.days(to: today) < options.unusedDays { continue }
        unused.append(UnusedSubscription(paymentId: line.id, yearlyRub: yearly, lastUsed: last))
      }
      unused.sort {
        ($1.yearlyRub, $0.paymentId.uuidString) < ($0.yearlyRub, $1.paymentId.uuidString)
      }
    }

    // Duplicates.
    var byType: [ServiceType: [SubscriptionLine]] = [:]
    for line in candidates {
      guard let type = line.type, type != .other else { continue }
      byType[type, default: []].append(line)
    }
    var duplicates: [DuplicateGroup] = []
    for (type, members) in byType where members.count >= 2 {
      let ids = Set(members.map(\.id))
      if subscriptions.keepGroups.contains(where: {
        $0.type == type && $0.paymentIds.isSuperset(of: ids)
      }) {
        continue
      }
      let ordered = members.sorted { left, right in
        let first = left.yearlyRub ?? .zero
        let second = right.yearlyRub ?? .zero
        if first != second { return first > second }
        return left.id.uuidString < right.id.uuidString
      }
      duplicates.append(
        DuplicateGroup(
          type: type, paymentIds: ordered.map(\.id),
          monthlyRub: AmountE4.sum(ordered.compactMap(\.monthlyRub)),
          savingYearlyRub: AmountE4.sum(ordered.dropFirst().compactMap(\.yearlyRub))))
    }
    duplicates.sort { $0.type.rawValue < $1.type.rawValue }

    // Saving: every subscription once.
    var dropped = Set(unused.map(\.paymentId))
    for group in duplicates { dropped.formUnion(group.paymentIds.dropFirst()) }
    let saving = AmountE4.sum(lines.filter { dropped.contains($0.id) }.compactMap(\.yearlyRub))
    return CancelAdvice(unused: unused, duplicates: duplicates, savingYearlyRub: saving)
  }

  /// «Нужны оба»: the group the owner keeps, to store as a `KeepGroup`. A group of the same
  /// type already kept is widened rather than doubled.
  public static func keeping(
    _ group: DuplicateGroup, in keepGroups: [KeepGroup]
  ) -> [KeepGroup] {
    var result = keepGroups
    let ids = Set(group.paymentIds)
    if let index = result.firstIndex(where: {
      $0.type == group.type && !$0.paymentIds.isDisjoint(with: ids)
    }) {
      result[index].paymentIds.formUnion(ids)
    } else {
      result.append(KeepGroup(type: group.type, paymentIds: ids))
    }
    return result
  }
}
