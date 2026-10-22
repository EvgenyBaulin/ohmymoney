import CoreKit
import Foundation

/// One change made to many operations at once from the list.
///
/// Category, quality, «для кого» and event live on the parts, and a change of them reaches
/// every part of a split; place and payment method live on the operation itself.
public enum BulkEdit: Hashable, Sendable {
  /// The most specific category chosen: a subcategory, or a category on its own.
  case category(UUID)
  /// The parts filed under one of `from` move to `to`, as `category(to)` would move them;
  /// the other parts of a split keep their category and everything else. What deleting a
  /// used category does with its operations: each part has a category of its own.
  case refile(from: Set<UUID>, to: UUID)
  case quality(Quality)
  /// A group of people. A particular person the part named is dropped with it.
  case forWhom(ForWhom)
  /// A particular person. A part that was «me» becomes «other»: it is somebody else's now.
  case forPerson(UUID)
  /// `nil` takes the event away.
  case event(UUID?)
  case place(UUID?)
  /// The account. Every operation has one, so `nil` moves the operations to the main account
  /// rather than leaving them with none; the storage layer fills it in.
  case paymentMethod(UUID?)

  /// Whether the change is made to the parts, and so reaches every part of a split — the
  /// confirmation says that out loud. A re-filing reaches only the parts it names.
  public var editsParts: Bool {
    switch self {
    case .category, .refile, .quality, .forWhom, .forPerson, .event: true
    case .place, .paymentMethod: false
    }
  }

  /// Whether a change made to the parts is made to this one: to every part, except for a
  /// re-filing, which moves only the parts filed under the categories it names.
  public func reaches(_ part: TransactionPart) -> Bool {
    guard case .refile(let from, _) = self else { return true }
    return part.categoryId.map(from.contains) == true
  }
}

/// Why an operation, or some of its parts, stays as it was. The app turns each case into a
/// sentence of its own; the core never deals in words.
public enum BulkSkipReason: String, Hashable, Sendable, CaseIterable {
  /// A category of the other kind: an expense one for income, or the other way round.
  case otherKind
  /// The category chosen was archived — itself or its parent — or is gone from the
  /// dictionary since the choice was offered: nothing is filed into it any more.
  case retiredCategory
  /// Money a person gave back: it has no category, no quality and no «для кого».
  case moneyReturned
  /// A payment on a debt sits where the debt puts it (Loans, or nowhere).
  case debtPayment
  /// A contribution to a goal stays in Goals and stays good.
  case goalContribution
  /// Surcharges, Unknown and Loans belong to the app: nothing is moved out of them by hand
  /// in bulk, and nothing into them.
  case systemCategory
  /// Income and money given back are not rated.
  case noQuality
  /// A part paid for somebody else already names who owes it.
  case paidForSomebodyElse
  /// «где» stays empty on income.
  case incomeHasNoPlace
  /// A purchase on credit moved a debt when it was made; taking it back is a change of that
  /// debt, which belongs to the Debts section.
  case creditPurchase
  /// A purchase on credit whose debt is deleted but was paid: its payments were never
  /// spending — the purchase was —, so without it the money that left the account would be in
  /// no figure. The payments are deleted first.
  case creditPurchasePaid
  /// A reimbursement closed a part of the purchase: gone, it would leave that reimbursement
  /// closing nothing and its shortfall counted as my spending on a purchase that is not
  /// there. The reimbursement is deleted first — which opens the part again.
  case closedByReimbursement
  /// The kind of the operation has no such field: income has no event and no «на кого», money
  /// back has no place and no event.
  case fieldNotForKind
  /// Refunds take money back from the purchase: gone, it would leave them taking back from
  /// nothing. The refunds are deleted first, or together with it.
  case hasRefunds
  /// The account does not hold the operation's currency, and the rate needed to work out what
  /// it is charged is not known yet.
  case noRateForCharge
  /// The difference a count recorded: its account is the count's, and it never goes to «Цели»
  /// or a category of the app (`DifferenceEditRefusal`).
  case reconciliationDifference
}

/// An operation the change leaves alone, entirely or in part.
public struct BulkSkip: Hashable, Sendable {
  public var transactionId: UUID
  public var reason: BulkSkipReason
  /// Some parts of the operation change, and the parts with this reason do not.
  public var isPartial: Bool

  public init(transactionId: UUID, reason: BulkSkipReason, isPartial: Bool = false) {
    self.transactionId = transactionId
    self.reason = reason
    self.isPartial = isPartial
  }
}

/// What one operation comes to under a bulk change.
public enum BulkEditOutcome: Hashable, Sendable {
  /// The operation after the change. `keptParts` names why some of its parts stay as they
  /// were, when some do.
  case changed(TransactionEntry, keptParts: BulkSkipReason?)
  /// The change is already there: nothing to write.
  case unchanged
  case skipped(BulkSkipReason)

  public var changedEntry: TransactionEntry? {
    if case .changed(let entry, _) = self { return entry }
    return nil
  }
}

/// What a bulk change would do to the operations it was asked about: the confirmation is
/// written from it, before anything is stored.
public struct BulkEditPlan: Hashable, Sendable {
  /// The operations as they will be after the change — only those that really change.
  public var changed: [TransactionEntry]
  public var skipped: [BulkSkip]
  /// How many of the changed operations are split, when the change is made to the parts:
  /// it reaches every part of them.
  public var splitCount: Int

  public init(changed: [TransactionEntry] = [], skipped: [BulkSkip] = [], splitCount: Int = 0) {
    self.changed = changed
    self.skipped = skipped
    self.splitCount = splitCount
  }

  public var touchesSplit: Bool { splitCount > 0 }
  public var changedIds: [UUID] { changed.map(\.id) }
  /// Operations the change does not reach at all.
  public var fullySkipped: [BulkSkip] { skipped.filter { !$0.isPartial } }
  /// Operations that change, but not in every part.
  public var partlySkipped: [BulkSkip] { skipped.filter(\.isPartial) }
  public var isEmpty: Bool { changed.isEmpty }

  /// The reasons behind a list of skips, each once, in a fixed order.
  public static func reasons(of skips: [BulkSkip]) -> [BulkSkipReason] {
    let present = Set(skips.map(\.reason))
    return BulkSkipReason.allCases.filter(present.contains)
  }
}

/// The rules of changing many operations at once.
///
/// Operations are changed directly, never through a draft: when an operation was created
/// and which import it came from stay as they were, and so does everything the change does
/// not name. Part ids never change, so the links of a reimbursement survive both the change
/// and its undo.
///
/// * **Category** — only a live category of the operation's own kind: an expense one for an
///   expense or a refund, an income one for income. A category archived since it was
///   offered — or hanging under an archived parent — is refused, and so is one the
///   dictionary does not know. The source becomes `manual`. A quality
///   that did not come from my hand is worked out again for the new category — with my
///   history, so a description I rated keeps my rating; income has none. Goal
///   contributions, debt payments, money given back and parts in system categories are
///   left alone; system categories are never a target either.
/// * **Re-filing** — the same change of category, made only to the parts filed under the
///   categories named: the other parts of a split stay as they were, their source included.
/// * **Quality** — becomes mine (`manual`). Goal contributions stay good; income and money
///   given back have no quality.
/// * **For whom** — a group drops the person; a person keeps the group unless it was «me»,
///   which becomes «other». Parts paid for somebody else already name who owes them, and
///   money given back has no «для кого».
/// * **Event** — a purchase and a refund take one; income and money back have none.
/// * **Place** and **account** are fields of the operation. Income and money back get no
///   place. An account that does not hold the operation's currency is charged in its main
///   currency: a figure already in that currency stays — it may have been typed from the
///   statement —, otherwise it is worked out at the operation's rate and the rates of its day
///   (`AccountRules.prefillLeg`); a refund taken back from a purchase, at the rates of its day
///   alone (`RefundRules.prefillLeg`). A contribution to a goal is charged nothing.
public enum BulkEditRule {

  // MARK: - Planning

  /// `accounts`, `rates` and `calendar` work out what an account is charged for an operation
  /// in a currency it does not hold; without the account in `accounts` the operation only
  /// changes its account.
  public static func plan(
    _ edit: BulkEdit,
    entries: [TransactionEntry],
    tree: CategoryTree,
    history: ManualQualityHistory = .empty,
    accounts: [PaymentMethod] = [],
    rates: DayRates = .empty,
    calendar: CalendarContext = .utc
  ) -> BulkEditPlan {
    var plan = BulkEditPlan()
    for entry in entries {
      switch apply(
        edit, to: entry, tree: tree, history: history, accounts: accounts, rates: rates,
        calendar: calendar)
      {
      case .changed(let changed, let keptParts):
        plan.changed.append(changed)
        if edit.editsParts, changed.isSplit, entry.parts.allSatisfy(edit.reaches) {
          plan.splitCount += 1
        }
        if let keptParts {
          plan.skipped.append(
            BulkSkip(transactionId: entry.id, reason: keptParts, isPartial: true))
        }
      case .unchanged:
        continue
      case .skipped(let reason):
        plan.skipped.append(BulkSkip(transactionId: entry.id, reason: reason))
      }
    }
    return plan
  }

  /// Deleting is a plan too: a purchase on credit is left for the Debts section, a purchase
  /// a reimbursement closed a part of is left while that reimbursement is there, everything
  /// else goes — with what it drags along, which the storage layer takes care of.
  ///
  /// A closed part is one whose status is `returned`: a live reimbursement closes it, since
  /// deleting a reimbursement opens the parts no other live one still closes. The store asks
  /// this of the rows as they are inside the write, so a reimbursement recorded or deleted a
  /// moment ago counts.
  ///
  /// A purchase refunds take money back from stays too, unless every one of those refunds
  /// goes in the same deletion: `refunds` are the refunds of the whole ledger.
  ///
  /// A purchase on credit stays while its debt is there. Once the debt is deleted
  /// (`deletedDebts`) the purchase goes like any other — unless something ever paid that debt
  /// (`paidDebts`, `DebtRules.paidDebts`): «Телефон» 60,000 ₽ on credit with 3 × 5,000 ₽ paid
  /// stays spending of 60,000 ₽, or the 15,000 ₽ that left the card would be in no figure.
  public static func deletion(
    of entries: [TransactionEntry], refunds: RefundIndex = .empty,
    deletedDebts: Set<UUID> = [], paidDebts: Set<UUID> = []
  ) -> BulkEditPlan {
    var plan = BulkEditPlan()
    let deleted = Set(entries.map(\.id))
    for entry in entries {
      let refundedBy = entry.parts.flatMap { refunds.refunds(ofPart: $0.id) }
      if let debt = entry.transaction.creditDebtId, !deletedDebts.contains(debt) {
        plan.skipped.append(BulkSkip(transactionId: entry.id, reason: .creditPurchase))
      } else if let debt = entry.transaction.creditDebtId, paidDebts.contains(debt) {
        plan.skipped.append(BulkSkip(transactionId: entry.id, reason: .creditPurchasePaid))
      } else if entry.parts.contains(where: { $0.reimbursementStatus == .returned }) {
        plan.skipped.append(BulkSkip(transactionId: entry.id, reason: .closedByReimbursement))
      } else if refundedBy.contains(where: { !deleted.contains($0) }) {
        plan.skipped.append(BulkSkip(transactionId: entry.id, reason: .hasRefunds))
      } else {
        plan.changed.append(entry)
      }
    }
    return plan
  }

  // MARK: - One operation

  /// The change applied to one operation. The storage layer calls this on the row as it is
  /// in the database at the moment of writing, not on the copy the list showed.
  public static func apply(
    _ edit: BulkEdit,
    to entry: TransactionEntry,
    tree: CategoryTree,
    history: ManualQualityHistory = .empty,
    accounts: [PaymentMethod] = [],
    rates: DayRates = .empty,
    calendar: CalendarContext = .utc
  ) -> BulkEditOutcome {
    let transaction = entry.transaction
    if let reason = refusal(of: edit, for: transaction, tree: tree) {
      return .skipped(reason)
    }

    var edited = entry
    var keptParts: BulkSkipReason?
    switch edit {
    case .place(let placeId):
      edited.transaction.placeId = placeId
    case .paymentMethod(let methodId):
      let account =
        methodId.flatMap { id in accounts.first { $0.id == id } }
        ?? (methodId == nil ? accounts.first { $0.isDefault && !$0.archived } : nil)
      edited.transaction.paymentMethodId = methodId ?? account?.id
      if let account {
        guard
          let charged = charge(
            of: entry, on: account, tree: tree, rates: rates, calendar: calendar)
        else { return .skipped(.noRateForCharge) }
        edited.transaction.accountCurrency = charged?.currency
        edited.transaction.accountAmountE4 = charged?.amount
      }
      // A card belongs to its own account: moved to another, the operation names none. The
      // cashback typed for it stays only while the money it was typed in still moves.
      if edited.transaction.paymentMethodId != transaction.paymentMethodId {
        edited.transaction.cardId = nil
      }
      edited.transaction.cashback = edited.transaction.keptCashback
    case .category, .refile, .quality, .forWhom, .forPerson, .event:
      var reached = 0
      for index in edited.parts.indices where edit.reaches(edited.parts[index]) {
        if let reason = refusal(of: edit, for: edited.parts[index], tree: tree) {
          keptParts = keptParts ?? reason
          continue
        }
        reached += 1
        change(&edited.parts[index], by: edit, in: transaction, tree: tree, history: history)
      }
      if reached == 0, let keptParts { return .skipped(keptParts) }
    }

    guard edited != entry else { return .unchanged }
    return .changed(edited, keptParts: keptParts)
  }

  /// What `entry` is charged on `account`: `.some(nil)` when nothing is charged apart — the
  /// account holds the currency, or the operation only moves money into a goal —, the figure
  /// otherwise, and `nil` when it cannot be worked out.
  private static func charge(
    of entry: TransactionEntry, on account: PaymentMethod, tree: CategoryTree, rates: DayRates,
    calendar: CalendarContext
  ) -> (currency: CurrencyCode, amount: AmountE4)?? {
    let transaction = entry.transaction
    if KindFields.isGoalOnly(entry, tree: tree) { return .some(nil) }
    guard let leg = AccountRules.legCurrency(for: transaction.currency, account: account) else {
      return .some(nil)
    }
    if transaction.accountCurrency == leg, let kept = transaction.accountAmountE4 {
      return (leg, kept)
    }
    let day = calendar.day(of: transaction.occurredAt)
    // A refund taken back from a purchase carries the purchase's rate for its rubles, but the
    // account received it at the rates of the refund's own day.
    if RefundRules.takesBack(entry) {
      return RefundRules.prefillLeg(
        amount: transaction.amountE4, currency: transaction.currency, day: day,
        account: account, rates: rates
      ).map { (leg, $0) }
    }
    // A leg in rubles is the operation's rubles, so moving it changes no ruble figure.
    if leg == .rub { return (leg, transaction.amountRubE4) }
    guard
      let amount = AccountRules.prefillLeg(
        amount: transaction.amountE4, currency: transaction.currency, rate: transaction.rate,
        day: day, account: account, rates: rates)
    else { return nil }
    return (leg, amount)
  }

  /// Puts back what a bulk change may have changed, taken from the snapshot made before
  /// it, onto the operation as it is now. Everything else — a part written off since, a
  /// rate refined since — stays as the database has it: undo takes back my change, not
  /// the changes that came after it. The account comes back with what it was charged, so an
  /// operation never stays on its old account with the charge of the new one, and with the card
  /// and the cashback a move to another account took away: the card is one of that account's.
  public static func revert(
    _ current: TransactionEntry, to snapshot: TransactionEntry
  ) -> TransactionEntry {
    var reverted = current
    reverted.transaction.placeId = snapshot.transaction.placeId
    reverted.transaction.paymentMethodId = snapshot.transaction.paymentMethodId
    reverted.transaction.accountCurrency = snapshot.transaction.accountCurrency
    reverted.transaction.accountAmountE4 = snapshot.transaction.accountAmountE4
    reverted.transaction.cardId = snapshot.transaction.cardId
    reverted.transaction.cashback = snapshot.transaction.cashback
    reverted.transaction.isOneOff = snapshot.transaction.isOneOff
    let before = Dictionary(
      snapshot.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for index in reverted.parts.indices {
      guard let old = before[reverted.parts[index].id] else { continue }
      reverted.parts[index].categoryId = old.categoryId
      reverted.parts[index].categorySource = old.categorySource
      reverted.parts[index].quality = old.quality
      reverted.parts[index].qualitySource = old.qualitySource
      reverted.parts[index].forWhom = old.forWhom
      reverted.parts[index].forPersonId = old.forPersonId
      reverted.parts[index].eventId = old.eventId
    }
    return reverted
  }

  // MARK: - Refusals

  /// Why the operation as a whole cannot take the change.
  private static func refusal(
    of edit: BulkEdit, for transaction: Transaction, tree: CategoryTree
  ) -> BulkSkipReason? {
    if OperationEditRule.isReconcileDifference(transaction) {
      switch edit {
      case .paymentMethod:
        return .reconciliationDifference
      case .category(let categoryId), .refile(_, to: let categoryId):
        if tree.systemRole(of: categoryId) != nil { return .reconciliationDifference }
      case .quality, .forWhom, .forPerson, .event, .place:
        break
      }
    }
    switch edit {
    case .category(let categoryId), .refile(_, to: let categoryId):
      if transaction.kind == .reimbursement { return .moneyReturned }
      if transaction.debtId != nil { return .debtPayment }
      guard let target = tree[categoryId], isLive(target, in: tree) else {
        return .retiredCategory
      }
      if tree.systemRole(of: target.id) != nil { return .systemCategory }
      if target.kind != transaction.kind.categoryKind { return .otherKind }
      return nil
    case .quality:
      return transaction.kind.hasQuality ? nil : .noQuality
    case .forWhom, .forPerson:
      switch transaction.kind {
      case .reimbursement: return .moneyReturned
      case .income: return .fieldNotForKind
      case .expense, .refund: return nil
      }
    case .place:
      switch transaction.kind {
      case .income: return .incomeHasNoPlace
      case .reimbursement: return .fieldNotForKind
      case .expense, .refund: return nil
      }
    case .event:
      return KindFields.fields(of: transaction.kind).contains(.event) ? nil : .fieldNotForKind
    case .paymentMethod:
      return nil
    }
  }

  /// A category that can still be chosen: neither it nor the category it hangs on has been
  /// archived. The popover offers only those, but the dictionary may change while it is
  /// open.
  private static func isLive(_ category: CoreKit.Category, in tree: CategoryTree) -> Bool {
    guard !category.archived else { return false }
    return !(tree.parent(of: category.id)?.archived ?? false)
  }

  /// Why one part cannot take a change the operation as a whole accepts.
  private static func refusal(
    of edit: BulkEdit, for part: TransactionPart, tree: CategoryTree
  ) -> BulkSkipReason? {
    switch edit {
    case .category, .refile:
      if QualityResolver.isGoalContribution(
        goalId: part.goalId, categoryId: part.categoryId, categories: tree)
      {
        return .goalContribution
      }
      return tree.systemRole(of: part.categoryId) == nil ? nil : .systemCategory
    case .quality:
      return QualityResolver.canRateByHand(
        goalId: part.goalId, categoryId: part.categoryId, categories: tree)
        ? nil : .goalContribution
    case .forWhom, .forPerson:
      return part.reimbursable ? .paidForSomebodyElse : nil
    case .event, .place, .paymentMethod:
      return nil
    }
  }

  // MARK: - Changing a part

  private static func change(
    _ part: inout TransactionPart,
    by edit: BulkEdit,
    in transaction: Transaction,
    tree: CategoryTree,
    history: ManualQualityHistory
  ) {
    switch edit {
    case .category(let categoryId), .refile(_, to: let categoryId):
      part.categoryId = categoryId
      part.categorySource = .manual
      guard transaction.kind.hasQuality else {
        part.quality = nil
        part.qualitySource = nil
        return
      }
      // A rating I set by hand stays; anything else follows the new category, unless my
      // history remembers the description (rule 2 before rule 3).
      let decision = QualityResolver.resolve(
        part: part, in: transaction, categories: tree, history: history)
      part.quality = decision.quality
      part.qualitySource = decision.source
    case .quality(let quality):
      part.quality = quality
      part.qualitySource = .manual
    case .forWhom(let forWhom):
      part.forWhom = forWhom
      part.forPersonId = nil
    case .forPerson(let personId):
      part.forPersonId = personId
      if part.forWhom == .me { part.forWhom = .other }
    case .event(let eventId):
      part.eventId = eventId
    case .place, .paymentMethod:
      break
    }
  }
}
