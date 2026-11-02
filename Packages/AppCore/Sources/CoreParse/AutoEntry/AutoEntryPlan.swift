import CoreKit
import Foundation

/// What becomes of a text of a bank once it is read. Pure: the app hands in what it knows —
/// the mode, whether the ledger has the operation, whether the card's account is hidden, what
/// the owner allows notifications to say — and does what this says.
public enum AutoEntryPlan {
  /// What is done with the operation.
  public enum Action: Hashable, Sendable {
    /// The ledger has it already (typed by hand, or the same text passed on twice): nothing is
    /// written and nothing offered.
    case skipDuplicate
    /// Written at once, through the steps of the entry line.
    case write
    /// Kept as a draft («Запишу потом») and offered in a notification.
    case propose
  }

  /// What a notification may say about an operation of a hidden account (the owner's choice of
  /// «Что показывают уведомления»).
  public enum HiddenAccountNotices: Hashable, Sendable {
    /// Nothing at all — the default.
    case silent
    /// «Операция по скрытому счёту», with neither the shop nor the amount.
    case anonymous
    /// As any other operation.
    case full
  }

  /// The notification about the operation.
  public enum Notice: Hashable, Sendable {
    case none
    /// The shop, and the amount when `saysAmount`.
    case named(saysAmount: Bool)
    /// Neither the shop nor the amount.
    case anonymous
  }

  public static func action(mode: AutoEntryMode, isDuplicate: Bool) -> Action {
    if isDuplicate { return .skipDuplicate }
    return mode == .immediate ? .write : .propose
  }

  /// A write that the entry line would have stopped for a choice or a question — no category
  /// said, a card past its limit, the same amount a minute ago — is not answered for the owner:
  /// the operation is offered instead.
  public static func afterWrite(succeeded: Bool) -> Action {
    succeeded ? .write : .propose
  }

  public static func notice(
    for action: Action, hiddenAccount: Bool, hidden: HiddenAccountNotices, amountsHidden: Bool,
    amountsAlways: Bool
  ) -> Notice {
    guard action != .skipDuplicate else { return .none }
    if hiddenAccount {
      switch hidden {
      case .silent: return .none
      case .anonymous: return .anonymous
      case .full: return .named(saysAmount: true)
      }
    }
    return .named(saysAmount: amountsAlways || !amountsHidden)
  }
}

/// The balance a bank text reports against the balance of the account in the ledger. A
/// difference is only a hint — «В банке 12 300 ₽, в приложении 12 150 ₽ — сверить?»: a count is
/// the owner's decision and is never made on the way.
public enum BankBalanceCheck {
  public struct Mismatch: Hashable, Sendable {
    /// What the bank says is on the account.
    public var bank: Money
    /// What the ledger says, with this operation in it.
    public var ledger: Money
    /// `bank − ledger`.
    public var difference: AmountE4 { bank.amount - ledger.amount }
  }

  /// `ledger` is the balance of the account in the text's currency as the books have it now;
  /// `includesOperation` — the operation is already in it (a duplicate, or written before the
  /// figures were worked out again). A credit card reports what is available with its limit, not
  /// the money on it, and is not compared. Nor is an operation in another currency than the
  /// balance — dollars spent from a ruble card: what it took in rubles is the bank's rate, which
  /// the books know only from the statement.
  public static func compare(
    reported: Money?, ledger: AmountE4?, includesOperation: Bool, operation: BankOperation,
    amount: Money, isCredit: Bool
  ) -> Mismatch? {
    guard let reported, let ledger, !isCredit, amount.currency == reported.currency else {
      return nil
    }
    var expected = ledger
    if !includesOperation {
      switch operation.kind {
      case .expense: expected = expected - amount.amount
      case .income, .refund, .reimbursement: expected = expected + amount.amount
      }
    }
    guard expected != reported.amount else { return nil }
    return Mismatch(bank: reported, ledger: Money(amount: expected, currency: reported.currency))
  }
}

/// The texts of the last minutes, by fingerprint: the SMS and the push of one purchase come
/// seconds apart, before the figures that would show the first one written are worked out
/// again. Held in memory only — it is not a record of the messages.
public struct AutoEntryRecent: Sendable {
  public static let window: TimeInterval = 10 * 60

  private var seen: [(fingerprint: String, at: Date)] = []

  public init() {}

  /// Whether the same text came in the last minutes; the text is remembered either way.
  public mutating func repeats(_ fingerprint: String, at now: Date) -> Bool {
    seen.removeAll { now.timeIntervalSince($0.at) > Self.window || $0.at > now }
    let repeated = seen.contains { $0.fingerprint == fingerprint }
    if !repeated { seen.append((fingerprint, now)) }
    return repeated
  }
}
