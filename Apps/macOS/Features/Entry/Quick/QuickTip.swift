import AppCore
import Foundation

/// «кафе 2000 чай 200»: the bill and the tip are two parts of one operation, the tip filed in
/// the subcategory «Чаевые» under the category of the bill. A pure plan, so a test reads it.
enum QuickTip {
  struct Placement: Equatable {
    /// The subcategory the tip goes to.
    var category: CoreKit.Category
    /// It does not exist yet: the app makes it under the category of the bill.
    var isNew: Bool
  }

  /// Where the tip of a bill filed under `billCategory` goes. `nil` when the bill has no
  /// category yet (the line asks for one first).
  static func placement(
    billCategory: UUID?, in categories: [CoreKit.Category]
  ) -> Placement? {
    guard let billCategory, let bill = categories.first(where: { $0.id == billCategory }) else {
      return nil
    }
    var top = bill
    while let parent = top.parentId, let up = categories.first(where: { $0.id == parent }) {
      top = up
    }
    // The bill itself is the tip subcategory: nothing to add.
    let wanted = NameKey.fold(TipReading.subcategoryName)
    if NameKey.fold(bill.name) == wanted { return Placement(category: bill, isNew: false) }
    if let existing = categories.first(where: {
      $0.parentId == top.id && !$0.archived && NameKey.fold($0.name) == wanted
    }) {
      return Placement(category: existing, isNew: false)
    }
    let made = CoreKit.Category(parentId: top.id, kind: top.kind, name: TipReading.subcategoryName)
    return Placement(category: made, isNew: true)
  }
}

extension QuickEntryModel {
  /// Back to the bill alone, if a Return before this one laid the tip: the line is read afresh
  /// over one part, not over a split.
  func collapseTip(on model: EntryDraftModel) {
    guard let part = tipPartId else { return }
    model.draft.parts.removeAll { $0.id == part }
    tipPartId = nil
    if let base = tipBase { model.draft.amount = base }
  }

  /// Lays the tip of the line on the panel's operation as a second part. The bill keeps its
  /// amount, the operation grows by the tip — a tip is paid on top of the bill. Asked again on
  /// every Return of the same line, so a part laid before is taken off first.
  ///
  /// Returns `false` when the bill has no category yet: the line stops for it, and the next
  /// Return lays the tip.
  @discardableResult
  func applyTip(to model: EntryDraftModel, environment: AppEnvironment) -> Bool {
    guard let tip else { return true }
    collapseTip(on: model)
    guard model.draft.parts.count == 1,
      let placement = QuickTip.placement(
        billCategory: model.draft.parts[0].categoryId, in: model.categories),
      let split = tip.parts(base: model.draft.amount)
    else { return false }
    if placement.isNew {
      guard
        AppEnvironment.attempt(
          "tip.category", on: environment.references,
          {
            try $0.save(placement.category)
          })
      else { return false }
      model.reload()
    }
    tipBase = split.base
    model.draft.amount = split.base + split.tip
    model.draft.parts[0].amount = split.base
    model.addPart()
    guard let last = model.draft.parts.indices.last else { return false }
    model.draft.parts[last].amount = split.tip
    model.draft.parts[last].categoryId = placement.category.id
    tipPartId = model.draft.parts[last].id
    return true
  }
}
