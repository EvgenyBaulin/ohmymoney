import CoreKit
import Foundation

/// Whether the hidden accounts are shown. The app starts covered, goes back to covered whenever
/// the lock is taken on or the owner presses «Скрыть», and is revealed only after Touch ID or
/// the password of the Mac. Never stored: a restart is a cover.
public enum PrivacyVisibility: String, Hashable, Sendable, CaseIterable {
  case covered
  case revealed
}

/// The accounts lists with the hidden ones taken out, the totals left as they were.
public struct CoveredAccounts: Hashable, Sendable {
  /// The lists to draw: no hidden account, no section that only held hidden accounts; every
  /// total still holds all the money.
  public var snapshot: AccountsSnapshot
  /// «Всего» holds money that lies in a hidden account: the screen says «часть скрыта» next to
  /// it and does not say how much.
  public var partHidden: Bool
  /// The groups whose total holds hidden money; `nil` stands for the accounts of no group.
  public var sectionsWithHiddenPart: Set<UUID?>

  public func isPartHidden(_ section: AccountsSnapshot.Section) -> Bool {
    sectionsWithHiddenPart.contains(section.group?.id)
  }
}

extension HiddenAccounts {
  /// Takes the hidden accounts off the lists of `accounts`. Totals are not summed again, so
  /// they keep all the money; a section left with no visible account is dropped, because its
  /// total alone would give the hidden amount away.
  public func cover(_ accounts: AccountsSnapshot) -> CoveredAccounts {
    guard !isEmpty else {
      return CoveredAccounts(snapshot: accounts, partHidden: false, sectionsWithHiddenPart: [])
    }
    var copy = accounts
    var marked: Set<UUID?> = []
    var inSummaryHidden = false
    copy.sections = accounts.sections.compactMap { section in
      let visible = section.accounts.filter { !isHidden($0.account.id) }
      guard visible.count != section.accounts.count else { return section }
      marked.insert(section.group?.id)
      if section.inSummary { inSummaryHidden = true }
      guard !visible.isEmpty else { return nil }
      var kept = section
      kept.accounts = visible
      return kept
    }
    copy.unanchored = accounts.unanchored.filter { !isHidden($0.accountId) }
    return CoveredAccounts(
      snapshot: copy, partHidden: inSummaryHidden, sectionsWithHiddenPart: marked)
  }

  /// What the account pickers offer: with the hidden accounts left out while covered.
  public func offered(_ accounts: [PaymentMethod], visibility: PrivacyVisibility) -> [PaymentMethod]
  {
    guard visibility == .covered, !isEmpty else { return accounts }
    return accounts.filter { !isHidden($0.id) }
  }

  /// The ids of the accounts a dataset marks hidden.
  public init(accounts: [PaymentMethod]) {
    self.init(ids: accounts.filter(\.hidden).map(\.id))
  }
}

extension HiddenAccounts {
  /// The ids of the cards of the hidden accounts.
  public func cardIds(in cards: [PaymentCard]) -> Set<UUID> {
    Set(cards.filter { ids.contains($0.accountId) }.map(\.id))
  }
}
