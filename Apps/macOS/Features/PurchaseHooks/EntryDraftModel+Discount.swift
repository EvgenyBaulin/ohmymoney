import AppCore
import Foundation

extension EntryDraftModel {
  /// «скидка 300», "discount 300": the money the line says the price fell by goes into «Скидка»
  /// as if typed there. A discount picked in the panel is not overwritten, and a line that stops
  /// naming one takes back what it wrote. Only a purchase has a discount.
  func takeTheDiscount(of reading: InputLineReading) {
    let told: AmountE4? =
      draft.kind == .expense
      ? reading.discount.flatMap { try? AmountE4(decimal: $0) }.flatMap { $0.raw > 0 ? $0 : nil }
      : nil
    if draft.discountE4 == nil || draft.discountE4 == discountFromTheLine {
      draft.discountE4 = told
      discountFromTheLine = told
    }
  }
}
