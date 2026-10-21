import AppCore
import AppDatabase
import Foundation

/// A new bank written with its first account: what came of it, and the account to pick.
struct BankCreation: Hashable, Sendable {
  var outcome: AccountActionOutcome
  /// The account the bank started with; `nil` when nothing was written.
  var accountId: UUID?
}

/// The actions on the banks: a new bank with its account and card, a rename, the archive and
/// «Вернуть», a merge, a deletion. Each is one `PlanningChange` — one write, one step of ⌘Z — but a
/// deletion, which is for good, as the deletion of a group or of an account is (`AccountRepository`).
///
/// A bank owns no money: the accounts under it keep the balances, the operations and the counts,
/// and an account keeps its own name, so the entry line reads what it read before. An account
/// deleted leaves its bank where it was; a bank is deleted only with no account under it, and goes
/// to the archive once every account under it has.
extension AccountActions {
  // MARK: Reading

  /// Every bank, archived ones too, in the owner's order.
  var banks: [Bank] { (try? environment.accounts?.banks(includeArchived: true)) ?? [] }

  // MARK: One step of ⌘Z

  /// A new bank with its first account — called like the bank, a card, in the default currency —
  /// and the card of that account, called like the bank too: one write, one step of ⌘Z. The
  /// account is checked as any new account is, so a name an account or a card already answers to
  /// is refused in words, and one in the archive offers to come back.
  func createBank(named name: String, books: AccountBooks) -> BankCreation {
    let all = self.all
    let banks = self.banks
    let kit = BankRules.startingKit(
      named: name, currency: environment.defaultCurrency, accounts: all, banks: banks)
    if let refusal = Self.refusal(saving: kit.bank, among: banks) {
      return BankCreation(outcome: .refused(refusal), accountId: nil)
    }
    if let refusal = Self.refusal(
      saving: kit.account, previous: nil, books: books, enabled: enabledCurrencies, all: all,
      groups: groups, cards: cards)
    {
      return BankCreation(outcome: .refused(refusal), accountId: nil)
    }
    if let card = kit.card,
      CardRules.validate(card, previous: nil, cards: cards, accounts: all + [kit.account])
        .first != nil
    {
      return BankCreation(outcome: .refused(.nameTaken), accountId: nil)
    }
    let rows = PlanningRows(
      paymentMethods: [kit.account], cards: kit.card.map { [$0] } ?? [], banks: [kit.bank])
    let outcome = apply(PlanningChange(upsert: rows, at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "banks.created", .db, "a bank was made with its account and card",
        [LogPair("bank", .id(kit.bank.id)), LogPair("account", .id(kit.account.id))])
    }
    return BankCreation(outcome: outcome, accountId: outcome == .done ? kit.account.id : nil)
  }

  /// Saves a new bank alone or an edit of one: the name. A bank of a name a live bank has is
  /// refused.
  func save(bank: Bank) -> AccountActionOutcome {
    var bank = bank
    bank.name = bank.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let banks = self.banks
    if let refusal = Self.refusal(saving: bank, among: banks) { return .refused(refusal) }
    if !banks.contains(where: { $0.id == bank.id }) {
      bank.sort = BankRules.sortForNewBank(among: banks.filter { !$0.archived })
    }
    return apply(PlanningChange(upsert: PlanningRows(banks: [bank]), at: environment.now()))
  }

  /// A bank goes to the archive once every account under it has.
  func archiveBank(_ id: UUID) -> AccountActionOutcome {
    guard var bank = banks.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard !bank.archived else { return .done }
    guard BankRules.canBeArchived(id, among: all) else { return .refused(.bankHasLiveAccounts) }
    bank.archived = true
    return apply(PlanningChange(upsert: PlanningRows(banks: [bank]), at: environment.now()))
  }

  /// «Вернуть» for a bank: refused while a live bank has taken its name.
  func restoreBank(_ id: UUID) -> AccountActionOutcome {
    let banks = self.banks
    guard var bank = banks.first(where: { $0.id == id }) else { return .refused(.notFound) }
    guard bank.archived else { return .done }
    bank.archived = false
    if let refusal = Self.refusal(saving: bank, among: banks) { return .refused(refusal) }
    return apply(PlanningChange(upsert: PlanningRows(banks: [bank]), at: environment.now()))
  }

  // MARK: Merging

  /// The banks `bank` can be merged into: the other live banks, in list order.
  func mergeTargets(for bank: Bank) -> [Bank] {
    BankMerge.targets(for: bank, banks: banks, locale: environment.language.locale)
  }

  /// The merge of `id` into `keptId`, worked out for the question before it is written.
  func bankMergePlan(_ id: UUID, into keptId: UUID) -> Result<BankMergePlan, BankMergeIssue> {
    BankMerge.plan(merging: id, into: keptId, banks: banks, accounts: all)
  }

  /// «Объединить с…» of a bank: every account under it, archived ones too, is filed under
  /// `keptId`, which keeps its name, and the bank is deleted — one write and one step of ⌘Z. No
  /// money moves and no account changes its name, so the entry line reads what it read before;
  /// the lists name the accounts by how many stand under the kept bank now. Two accounts of the
  /// banks can be merged afterwards, as accounts of one bank.
  func mergeBank(_ id: UUID, into keptId: UUID) -> AccountActionOutcome {
    let plan: BankMergePlan
    switch bankMergePlan(id, into: keptId) {
    case .failure(let issue): return .refused(.bankMerge(issue))
    case .success(let worked): plan = worked
    }
    let outcome = apply(
      PlanningChange(
        upsert: PlanningRows(paymentMethods: plan.movedAccounts),
        delete: PlanningRowIDs(banks: [plan.merged.id]), at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "banks.merged", .db, "a bank was merged into another",
        [
          LogPair("bank", .id(plan.merged.id)), LogPair("into", .id(plan.kept.id)),
          LogPair("accounts", .count(plan.movedAccounts.count)),
        ])
    }
    return outcome
  }

  // MARK: For good

  /// Deletes a bank no account is filed under, archived accounts included, for good; the ⌘Z
  /// history is forgotten after it.
  func deleteBank(_ id: UUID) -> AccountActionOutcome {
    guard let repository = environment.accounts else { return .failed }
    do {
      try repository.deleteBank(id)
    } catch AccountWriteError.bankInUse {
      return .refused(.bankInUse)
    } catch AccountWriteError.notFound {
      return .refused(.notFound)
    } catch {
      AppLog.error(
        "accounts.deleteBank", .db, "a bank was not deleted",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return .failed
    }
    settleForGood()
    return .done
  }

  // MARK: Where an account goes

  /// The bank an account comes back under from the archive, and the bank rows that has to
  /// write: the bank it was filed under, brought back from the archive with it unless a live bank
  /// has taken its name; an account left without a bank goes under the live bank of its name, or
  /// under a bank made for it.
  func bank(
    forRestoring account: PaymentMethod
  ) -> Result<(bankId: UUID, rows: [Bank]), AccountRefusal> {
    let banks = self.banks
    if let id = account.bankId, var bank = banks.first(where: { $0.id == id }) {
      guard bank.archived else { return .success((bank.id, [])) }
      bank.archived = false
      if let refusal = Self.refusal(saving: bank, among: banks) { return .failure(refusal) }
      return .success((bank.id, [bank]))
    }
    let choice = BankRules.bank(forNewAccountNamed: account.name, among: banks)
    return .success((choice.bank.id, choice.isNew ? [choice.bank] : []))
  }

  // MARK: Rules

  /// What keeps `bank` from being saved among `banks`, the first thing only.
  static func refusal(saving bank: Bank, among banks: [Bank]) -> AccountRefusal? {
    for issue in BankRules.validate(bank, among: banks) {
      switch issue {
      case .emptyName: return .emptyName
      case .nameTaken: return .bankNameTaken
      }
    }
    return nil
  }
}
