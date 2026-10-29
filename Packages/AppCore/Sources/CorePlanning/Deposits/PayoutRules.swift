import CoreKit
import Foundation

/// Dividends and coupons: an expected income that says what it is (`payoutKind`), which holding
/// it comes from (`assetId`, an asset of kind `investment`) and which account the money is to
/// reach (`paymentMethodId`). It is closed by money the same way as any expected income; a coupon
/// that comes twice a year is a recurring expected income.
public enum PayoutRules {
  /// The holdings a payout can name: investments not sold or written off, by name. The one
  /// already named stays on the list even when it is gone, so editing an old payout loses nothing.
  public static func holdings(
    _ assets: [Asset], keeping kept: UUID? = nil, today: DateOnly
  )
    -> [Asset]
  {
    assets.filter { $0.kind == .investment && (!$0.isDisposed(on: today) || $0.id == kept) }
      .sorted {
        ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString)
      }
  }

  /// The income as it is written: a holding only with a payout kind, and only an investment that
  /// exists; an ordinary income carries neither.
  public static func normalized(_ income: ExpectedIncome, assets: [Asset]) -> ExpectedIncome {
    var income = income
    guard income.payoutKind != nil else {
      income.assetId = nil
      return income
    }
    if let id = income.assetId, !assets.contains(where: { $0.id == id && $0.kind == .investment }) {
      income.assetId = nil
    }
    return income
  }

  /// A new payout of a holding, as «Ожидаемая выплата…» of its card starts it: in the holding's
  /// currency, due today until another day is picked, named after the holding.
  public static func draft(
    for asset: Asset, kind: PayoutKind = .dividend, today: DateOnly
  ) -> ExpectedIncome {
    ExpectedIncome(
      name: asset.name, kind: .oneOff, totalE4: .zero, currency: asset.currency, dueDate: today,
      payoutKind: kind, assetId: asset.id)
  }
}
