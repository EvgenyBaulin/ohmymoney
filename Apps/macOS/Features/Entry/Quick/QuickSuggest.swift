import AppCore
import Foundation

/// Places offered while a line is typed («пят» → «Пятёрочка, обычно ~1 200 ₽»), and what a tap
/// on one puts into the line. Pure.
enum QuickSuggest {
  /// The word being typed at the end of the line, when it is a word of letters and the line has
  /// not got to its amount yet: «кофе пят» → «пят», «кофе 250» → nothing.
  static func prefix(of line: String) -> String? {
    guard let last = line.split(separator: " ", omittingEmptySubsequences: true).last else {
      return nil
    }
    // A line that ends in a space starts a new word: nothing to complete yet.
    guard !line.hasSuffix(" ") else { return nil }
    let word = String(last)
    guard word.count >= 2, word.allSatisfy({ $0.isLetter }) else { return nil }
    return word
  }

  /// The line after a tap on `suggestion`: the half-typed word becomes the place, and the usual
  /// amount follows unless the line has a number already.
  static func line(
    afterChoosing suggestion: PlaceSuggestion, in line: String, prefix: String
  ) -> String {
    var head = line
    if head.hasSuffix(prefix) { head = String(head.dropLast(prefix.count)) }
    var result = head + suggestion.name
    let hasNumber = head.contains(where: \.isNumber)
    if !hasNumber, let usual = suggestion.usual {
      result += " " + NumberText.plain(usual.amount.decimal)
      if usual.currency != .rub { result += " " + usual.currency.code }
    }
    return result
  }

  /// The unused part of a template chip with a blank: «Такси до работы — ? ₽» puts
  /// «Такси до работы » in the line, ready for the amount.
  static func lineForBlank(_ template: Template) -> String? {
    guard TemplateBlank.isBlank(template), let prefix = TemplateBlank.prefix(of: template.text)
    else { return nil }
    return prefix.hasSuffix(" ") ? prefix : prefix + " "
  }

  /// The history of the habits for the chips: what was written, when.
  static func habits(
    of entries: [TransactionEntry], limit: Int = 4_000
  ) -> [HabitEvent] {
    var events: [HabitEvent] = []
    for entry in entries.reversed() {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        let note = transaction.note, !note.isEmpty
      else { continue }
      events.append(
        HabitEvent(
          label: HabitOrdering.label(of: note), occurredAt: transaction.occurredAt,
          timeZoneId: transaction.timeZoneId))
      if events.count >= limit { break }
    }
    return events
  }
}

/// «ой, 350»: what the app says and does for a correction line. Pure; the screen asks, the store
/// writes.
enum QuickCorrection {
  struct Offer: Equatable {
    /// The operation as it is now.
    var before: TransactionEntry
    /// The operation after the correction.
    var after: TransactionEntry
    /// Written longer ago than an hour: the owner is told so before he agrees (answer 15).
    var isStale: Bool
  }

  enum Outcome: Equatable {
    case offer(Offer)
    case nothingToCorrect
    case refused(CorrectedAmount.Refusal)
  }

  /// The parts something leans on: a part a refund takes back from, or money back closes.
  static func leanedParts(in dataset: Dataset) -> Set<UUID> {
    var leaned = Set<UUID>()
    for entry in dataset.entries where !entry.transaction.isDeleted {
      for part in entry.parts {
        if let target = part.refundOfPartId { leaned.insert(target) }
      }
    }
    for link in dataset.links { leaned.insert(link.partId) }
    return leaned
  }

  static func outcome(
    for correction: AmountCorrection, in dataset: Dataset, now: Date
  ) -> Outcome {
    let target = CorrectionTarget.find(in: dataset.entries, now: now)
    let entry: TransactionEntry
    let stale: Bool
    switch target {
    case .none: return .nothingToCorrect
    case .recent(let found): (entry, stale) = (found, false)
    case .stale(let found): (entry, stale) = (found, true)
    }
    let result = CorrectedAmount.apply(
      entry, amount: correction.amount, currency: correction.currency,
      expression: correction.expression, leaned: leanedParts(in: dataset), now: now)
    switch result {
    case .success(let after): return .offer(Offer(before: entry, after: after, isStale: stale))
    case .failure(let refusal): return .refused(refusal)
    }
  }

  /// The key of the words for a refusal (table «QuickEntry»).
  static func key(of refusal: CorrectedAmount.Refusal) -> String {
    switch refusal {
    case .notAnAmount: "quick.correction.refused.amount"
    case .otherCurrency: "quick.correction.refused.currency"
    case .noRate: "quick.correction.refused.rate"
    case .accountAmountUnknown: "quick.correction.refused.account"
    case .debtOperation: "quick.correction.refused.debt"
    case .moneyBack: "quick.correction.refused.moneyBack"
    case .settledParts, .partsLeanedOn: "quick.correction.refused.parts"
    }
  }
}
