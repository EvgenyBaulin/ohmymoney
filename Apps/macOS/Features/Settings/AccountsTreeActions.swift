import AppCore
import AppDatabase
import Foundation

/// What the tree of «Настройки → Счета» does to several accounts at once — a drag, «В группу…»,
/// «Скрыть», «В архив» — each one change and one step of ⌘Z, refused as a whole when one of the
/// accounts cannot follow.
extension AccountActions {
  /// A drag in the tree (`AccountsTree.drop`): the account goes to the group of the place it was
  /// dropped at, and every account shown in the groups is numbered 1…n in the new order, the
  /// main account staying first.
  func place(_ drop: AccountsTree.Drop) -> AccountActionOutcome {
    let all = self.all
    guard var account = all.first(where: { $0.id == drop.accountId && !$0.archived }) else {
      return .refused(.notFound)
    }
    if account.isDefault, let refusal = mainRefusal(into: drop.groupId) { return .refused(refusal) }
    account.groupId = drop.groupId
    var byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    byId[account.id] = account
    let listed = drop.order.compactMap { byId[$0] }
    let rest = ordered(all).filter { !drop.order.contains($0.id) }
    var list = listed + rest
    if let main = list.firstIndex(where: \.isDefault), main != 0 {
      list.insert(list.remove(at: main), at: 0)
    }
    for position in list.indices { list[position].sort = position + 1 }
    let old = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let changed = list.filter { old[$0.id] != $0 }
    guard !changed.isEmpty else { return .done }
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: changed), at: environment.now()))
  }

  /// «В группу…»: the accounts go to `groupId` (`nil`: no group) together.
  func moveToGroup(_ ids: Set<UUID>, _ groupId: UUID?) -> AccountActionOutcome {
    let moving = all.filter { ids.contains($0.id) && !$0.archived && $0.groupId != groupId }
    guard !moving.isEmpty else { return .done }
    if moving.contains(where: \.isDefault), let refusal = mainRefusal(into: groupId) {
      return .refused(refusal)
    }
    let changed = moving.map { account -> PaymentMethod in
      var account = account
      account.groupId = groupId
      return account
    }
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: changed), at: environment.now()))
  }

  /// «Скрыть» / «Показать»: the accounts are hidden or shown together.
  func setHidden(_ ids: Set<UUID>, _ hidden: Bool) -> AccountActionOutcome {
    let changed = all.filter { ids.contains($0.id) && $0.hidden != hidden }.map { account in
      var account = account
      account.hidden = hidden
      return account
    }
    guard !changed.isEmpty else { return .done }
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: changed), at: environment.now()))
  }

  /// «В архив» for several accounts: together, or none. The main account asks who takes over,
  /// and money on an account asks where it goes — questions of one account, so with several
  /// picked they are refused and the note says why.
  func archive(_ ids: Set<UUID>, books: AccountBooks) -> AccountActionOutcome {
    let all = self.all
    let picked = all.filter { ids.contains($0.id) && !$0.archived }
    guard !picked.isEmpty else { return .done }
    if picked.contains(where: \.isDefault) { return .refused(.needsNewMain) }
    if picked.count == all.filter({ !$0.archived }).count { return .refused(.lastLiveAccount) }
    for account in picked {
      if let refusal = archiveRefusal(account, books: books) { return .refused(refusal) }
    }
    let changed = picked.map { account -> PaymentMethod in
      var account = account
      account.archived = true
      return account
    }
    return apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: changed), at: environment.now()))
  }

  /// The main account stays in the summary: it never goes to a group left out of it.
  private func mainRefusal(into groupId: UUID?) -> AccountRefusal? {
    guard let groupId, let group = groups.first(where: { $0.id == groupId }), !group.inSummary
    else { return nil }
    return .mainInExcludedGroup
  }
}
