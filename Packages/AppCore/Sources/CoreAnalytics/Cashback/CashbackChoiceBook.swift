import CoreKit
import Foundation

/// The bank's monthly choice as the database keeps it: each bank's table «категория банка →
/// ваша» and the offers typed for the months. It rides in the dataset's extras, so the screens
/// read it with everything else.
public struct CashbackChoiceBook: Hashable, Sendable {
  public var mappings: [BankCategoryMapping]
  public var offers: [CashbackOffer]

  public init(mappings: [BankCategoryMapping] = [], offers: [CashbackOffer] = []) {
    self.mappings = mappings
    self.offers = offers
  }

  public static let empty = CashbackChoiceBook()
  /// The key of the book in `DatasetExtras`.
  public static let extrasKey = "cashback.choice"

  public func mappings(ofBank bankId: UUID?) -> [BankCategoryMapping] {
    guard let bankId else { return [] }
    return mappings.filter { $0.bankId == bankId }
  }

  public func offers(of accountId: UUID, month: MonthKey) -> [CashbackOffer] {
    offers.filter { $0.accountId == accountId && $0.month == month }
  }
}

extension Dataset {
  /// The bank's monthly choice; empty when the store put none in.
  public var cashbackChoice: CashbackChoiceBook {
    get { extras.value(CashbackChoiceBook.extrasKey) ?? .empty }
    set { extras.set(newValue, for: CashbackChoiceBook.extrasKey) }
  }
}
