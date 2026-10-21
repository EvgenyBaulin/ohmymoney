import CoreKit
import Foundation

/// What money a person gives back on a debt owed to me does to that debt.
public struct DebtRepaymentOutcome: Hashable, Sendable {
  /// The `payment` line of what the debt took, in its currency; `nil` when it took nothing.
  public var line: DebtEntry?
  /// What the debt took, in its currency.
  public var applied: AmountE4
  /// The debt is paid off and closes in the same write.
  public var closes: Bool
  /// What came back above the debt: income in «Доплаты»; `nil` below one kopeck.
  public var surplus: SurchargeIncome?

  public init(line: DebtEntry?, applied: AmountE4, closes: Bool, surplus: SurchargeIncome?) {
    self.line = line
    self.applied = applied
    self.closes = closes
    self.surplus = surplus
  }
}

extension DebtRules {
  /// Why a repayment cannot be worked out.
  public enum RepaymentError: Error, Equatable, Sendable {
    /// Not a debt owed to me, or money that grows it rather than pays it.
    case notARepayment
    /// The money is not in the debt's currency: it is converted first (`convert`).
    case otherCurrency
  }

  /// Money a person gives back on a debt owed to me — from the entry line, the money-back sheet
  /// or the Debts form alike: the balance takes what it can, the debt closes once it is covered,
  /// and what is over is income in «Доплаты», on the account the money came onto.
  ///
  /// Маша owes 1,000 ₽ and gives 1,700 ₽ back: the line is −1,000 ₽, the debt closes, 700 ₽
  /// are income. 600 ₽ back: −600 ₽, 400 ₽ still owed. A debt at zero takes nothing: all of it
  /// is income.
  ///
  /// With exactly the balance the debt closes unless the Debts form's «Закрыть долг» was
  /// switched off (`closeWhenPaidOff`); above it, it always closes.
  ///
  /// The surplus's rubles are the operation's rubles less the rubles of what the debt took,
  /// valued at `rubPerUnit` — the rate the money was converted at in the sheet — or else at
  /// the operation's own rubles per unit, to four decimals as a rate is written: 10,000 ₽ that
  /// came as 111.1111 $ are 90 a dollar, so 100 $ owed are 9,000 ₽ and 1,000 ₽ are over, not
  /// 999.9991 ₽. It is in the currency that moved on the account: in rubles when the account
  /// got rubles, otherwise the units over in the operation's currency.
  public static func repayment(
    on debt: Debt, by operation: Transaction, balance: AmountE4, date: DateOnly?,
    description: String? = nil, rubPerUnit: Decimal? = nil, closeWhenPaidOff: Bool = true,
    entryId: UUID = UUID()
  ) throws -> DebtRepaymentOutcome {
    guard debt.direction == .owedToMe, !operationGrows(operation.kind, debt) else {
      throw RepaymentError.notARepayment
    }
    guard operation.currency == debt.currency else { throw RepaymentError.otherCurrency }
    let amount = operation.amountE4
    guard amount.raw > 0 else { throw DebtError.negativeAmount }

    let owed = max(balance, .zero)
    let applied = min(amount, owed)
    let closes = owed.isZero || amount > owed || (amount == owed && closeWhenPaidOff)
    let line =
      applied.raw > 0
      ? makeEntry(
        id: entryId, debtId: debt.id, kind: .payment, amountE4: applied, date: date,
        description: description, transactionId: operation.id)
      : nil

    let amountRub = operation.amountRubE4
    let appliedRub: AmountE4
    if applied == amount {
      appliedRub = amountRub
    } else {
      let rate = rubPerUnit ?? DecimalMath.round(amountRub.decimal / amount.decimal, scale: 4)
      appliedRub = min(amountRub, (try? AmountE4(decimal: applied.decimal * rate)) ?? amountRub)
    }
    let surplusRub = amountRub - appliedRub
    guard surplusRub >= MoneyBack.crumb else {
      return DebtRepaymentOutcome(line: line, applied: applied, closes: closes, surplus: nil)
    }
    let moved = operation.movedMoney
    let surplus: SurchargeIncome
    if moved.currency == .rub {
      surplus = SurchargeIncome(
        amountE4: surplusRub, currency: .rub, amountRubE4: surplusRub,
        accountId: operation.paymentMethodId)
    } else {
      surplus = SurchargeIncome(
        amountE4: amount - applied, currency: operation.currency, amountRubE4: surplusRub,
        accountId: operation.paymentMethodId)
    }
    return DebtRepaymentOutcome(line: line, applied: applied, closes: closes, surplus: surplus)
  }

  /// Rubles one unit of the debt cost me: the rubles of the money lent over its amount — a
  /// `borrowed` line with an operation counts that operation's rubles; one without an operation
  /// counts what left the account when that was rubles. 9,000 ₽ lent as 100 $ and 1,850 ₽ more
  /// as 20 $ → 90.4167. `nil` when nothing says (then the bank's rate of the day is used), and
  /// for a debt in rubles.
  public static func costRate(
    of debt: Debt, journal: [DebtEntry], operations: [UUID: Transaction]
  ) -> Decimal? {
    guard debt.currency != .rub else { return nil }
    var units = Decimal(0)
    var rubles = Decimal(0)
    for line in journal where line.debtId == debt.id && line.kind == .borrowed {
      let amount = line.amountE4.magnitude
      guard amount.raw > 0 else { continue }
      if let operationId = line.transactionId {
        guard let operation = operations[operationId], !operation.isDeleted,
          operation.currency == debt.currency, operation.amountRubE4.raw > 0
        else { continue }
        units += amount.decimal
        rubles += operation.amountRubE4.decimal * amount.decimal / operation.amountE4.decimal
      } else if line.accountCurrency == .rub, let leg = line.accountAmountE4, leg.raw > 0 {
        units += amount.decimal
        rubles += leg.magnitude.decimal
      }
    }
    guard units > 0, rubles > 0 else { return nil }
    return DecimalMath.round(rubles / units, scale: 4)
  }

  /// `money` — worth `moneyRubPerUnit` rubles a unit, 1 for rubles — in units of the debt at
  /// `debtRubPerUnit`, to four decimals, half away from zero: 10,000 ₽ for a debt in dollars at
  /// 90 are 111.1111 $. `nil` for a rate that is not above zero.
  public static func convert(
    _ money: AmountE4, moneyRubPerUnit: Decimal, debtRubPerUnit: Decimal
  ) -> AmountE4? {
    guard moneyRubPerUnit > 0, debtRubPerUnit > 0 else { return nil }
    return try? AmountE4(decimal: money.decimal * moneyRubPerUnit / debtRubPerUnit)
  }
}
