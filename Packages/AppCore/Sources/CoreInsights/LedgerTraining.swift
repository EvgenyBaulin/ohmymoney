import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreModel
import Foundation

/// The ledger as the model sees it.
///
/// `CoreModel` knows a flat list of rows and nothing about accounting — that is what lets
/// `make eval-model` read a CSV export without the ledger. This is the one place that knows
/// both, and all it does is carry the facts across.
public enum LedgerTraining {
  public static func rows(of dataset: Dataset, calendar: CalendarContext) -> [CategoryTraining.Row]
  {
    let tree = CategoryTree(dataset.categories)
    // A refund taken back from a live purchase carries the purchase part's category and its
    // source because the app copied them there: the owner filed the purchase, once, and the
    // model learns it once. A refund of no purchase is filed by the owner and teaches.
    let refunds = RefundIndex(entries: dataset.entries, debts: dataset.debtsById)
    var rows: [CategoryTraining.Row] = []
    for entry in dataset.entries {
      let transaction = entry.transaction
      let day = calendar.day(of: transaction.occurredAt)
      for part in entry.parts where !refunds.isLinked(refundPart: part.id) {
        let category = part.categoryId.flatMap { id in dataset.categories.first { $0.id == id } }
        // A subcategory of Goals is a goal's own: the role of the root counts as much as the
        // role of the category itself.
        let role =
          category?.systemRole
          ?? category?.parentId.flatMap { parent in
            dataset.categories.first { $0.id == parent }?.systemRole
          }
        rows.append(
          CategoryTraining.Row(
            partId: part.id, categoryId: part.categoryId, systemRole: role,
            categorySource: part.categorySource, externalId: transaction.externalId,
            isDeleted: transaction.deletedAt != nil,
            query: query(entry: entry, part: part, day: day, calendar: calendar, tree: tree)))
      }
    }
    return rows
  }

  public static func examples(of dataset: Dataset, calendar: CalendarContext) -> [CategoryExample] {
    CategoryTraining.examples(from: rows(of: dataset, calendar: calendar))
  }

  /// What the model is taught with about a saved part: the question `rows(of:calendar:)`
  /// puts to it, and the one `query(draft:calendar:)` asks the moment the part is typed — the
  /// ↓ panel asks through that, about the draft as the save writes it
  /// (`EntryDraftModel.modelQuery`). If these two ever differ the model answers a question it
  /// was never taught.
  public static func query(
    entry: TransactionEntry, part: TransactionPart, day: DateOnly, calendar: CalendarContext,
    tree: CategoryTree
  ) -> CategoryQuery {
    query(
      day: day, calendar: calendar, kind: entry.transaction.kind,
      text: part.note ?? entry.transaction.note, placeId: entry.transaction.placeId,
      paymentMethodId: entry.transaction.paymentMethodId, forWhom: part.forWhom,
      forPersonId: part.forPersonId, rubles: part.amountRubE4)
  }

  /// What the entry line asks the model about the draft it holds (`EntryDraftModel`): the
  /// question the model is taught with once the draft is saved — if the two ever differ, the
  /// model answers something it was never taught.
  ///
  /// The first part is asked about, with the whole amount while it has none of its own yet.
  /// The amount is in rubles, as the saved part keeps it: a foreign draft is converted with
  /// its rate the way the save converts it (`TransactionDraft.materialize`), and one with no
  /// rate yet is asked about with its amount as it stands, the nearest there is.
  public static func query(draft: TransactionDraft, calendar: CalendarContext) -> CategoryQuery? {
    guard let part = draft.parts.first else { return nil }
    let convert: (AmountE4) throws -> AmountE4 = { amount in
      guard draft.currency != .rub, let rate = draft.rate, rate > 0 else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    }
    let rubles: AmountE4
    if !part.amount.isZero, draft.isBalanced,
      let saved = try? draft.materialize(now: draft.occurredAt, rublesConverter: convert)
    {
      rubles = saved.parts[0].amountRubE4
    } else {
      let amount = part.amount.isZero ? draft.amount : part.amount
      rubles = (try? convert(amount)) ?? amount
    }
    return query(
      day: calendar.day(of: draft.occurredAt), calendar: calendar, kind: draft.kind,
      text: part.note ?? draft.note, placeId: draft.placeId,
      paymentMethodId: draft.paymentMethodId, forWhom: part.forWhom,
      forPersonId: part.forPersonId, rubles: rubles)
  }

  /// The one place a question is put together, for both.
  private static func query(
    day: DateOnly, calendar: CalendarContext, kind: TransactionKind, text: String?,
    placeId: UUID?, paymentMethodId: UUID?, forWhom: ForWhom, forPersonId: UUID?,
    rubles: AmountE4
  ) -> CategoryQuery {
    CategoryQuery(
      day: day, weekday: calendar.weekdayIndex(day), kind: kind == .income ? .income : .expense,
      text: text ?? "", placeId: placeId, paymentMethodId: paymentMethodId,
      forWhom: forWhom.rawValue, forPersonId: forPersonId, amountWhole: rubles.wholeRubles)
  }
}
