import AppCore
import SwiftUI

/// The mark «Налоговый вычет» of the operation being entered or edited: one kind for every part.
/// The parts keep the kind on their own (`PartDraft.taxDeduction`), so an edit that does not touch
/// the field writes back what each part had.
@MainActor
enum TaxDeductionMark {
  /// The kind every part shares; `nil` when none is marked or the parts differ.
  static func shared(_ draft: TransactionDraft) -> TaxDeductionKind? {
    guard let first = draft.parts.first?.taxDeduction else { return nil }
    return draft.parts.allSatisfy { $0.taxDeduction == first } ? first : nil
  }

  /// Every part takes `kind`; `nil` takes the mark away. Only a kind a part may carry is set.
  static func set(_ kind: TaxDeductionKind?, on draft: inout TransactionDraft) {
    let allowed = kind.flatMap { TaxDeductionKind.partKinds.contains($0) ? $0 : nil }
    // An operation of one part may have none written yet: the mark needs the part to sit on.
    if draft.parts.isEmpty && allowed != nil { draft.normalizeSinglePart() }
    for index in draft.parts.indices { draft.parts[index].taxDeduction = allowed }
  }

  static func binding(_ model: EntryDraftModel) -> Binding<TaxDeductionKind?> {
    Binding(
      get: { shared(model.draft) },
      set: { kind in set(kind, on: &model.draft) })
  }
}
