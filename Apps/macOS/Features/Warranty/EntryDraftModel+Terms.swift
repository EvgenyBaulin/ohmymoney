import AppCore
import Foundation

extension EntryDraftModel {
  /// «гарантия 2г», «возврат 14д»: the span the line names, counted from the day of the purchase,
  /// goes into «Гарантия до» and «Вернуть можно до» as if picked there. A day picked in the panel
  /// is not overwritten, and a line that stops naming the span takes back what it wrote. Only a
  /// purchase has these fields.
  func takeTheTerms(of reading: InputLineReading) {
    let purchased = draft.kind == .expense
    let day = calendar.day(of: draft.occurredAt)
    let warranty = purchased ? reading.warranty.map { WarrantyTerms.end(of: $0, from: day) } : nil
    let returned = purchased ? reading.returnTerm.map { WarrantyTerms.end(of: $0, from: day) } : nil
    if draft.warrantyUntil == nil || draft.warrantyUntil == warrantyFromTheLine {
      draft.warrantyUntil = warranty
      warrantyFromTheLine = warranty
    }
    if draft.returnUntil == nil || draft.returnUntil == returnFromTheLine {
      draft.returnUntil = returned
      returnFromTheLine = returned
    }
  }
}
