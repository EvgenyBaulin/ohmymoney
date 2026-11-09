import CoreKit
import Foundation

extension InputWord {
  /// The bilingual path is unchanged. Other languages additionally accept local decimal digits,
  /// thousand words, and adjacent keywords and numbers on keyboards that omit word spaces.
  static func localizedSplit(
    _ text: String, lexicon: EntryLexicon, vocabulary: ParserVocabulary
  ) -> [InputWord] {
    guard let local = lexicon.localized else { return split(text) }
    let protected =
      vocabulary.people + vocabulary.places + vocabulary.paymentMethods
      + vocabulary.events + vocabulary.goals + vocabulary.debts + vocabulary.cards.map(\.entry)
    let names = Set(protected.flatMap(\.spellings).map(TextNormalizer.normalized))
    let compact: Set<StarterLanguage> = [.chineseSimplified, .chineseTraditional, .ja, .ko, .th]
    let keywords = [
      local.today, local.yesterday, local.dayBeforeYesterday, local.income, local.salary,
      local.expense, local.refund, local.reimbursement, local.transfer, local.debt, local.goal,
      local.from, local.to,
    ].flatMap(EntryLanguageWords.alternatives).filter { !$0.contains(" ") }
      .sorted { $0.count > $1.count }
    var result: [InputWord] = []
    for word in split(text) {
      let parts: [InputWord]
      if compact.contains(lexicon.language), !names.contains(word.normalized) {
        parts = compactParts(word, keywords: keywords, names: names, lexicon: lexicon)
      } else {
        parts = [word]
      }
      for var part in parts {
        part.amountText =
          lexicon.isThousand(part.normalized) ? "k" : lexicon.amountText(part.amountText)
        result.append(part)
      }
    }
    return result
  }

  private static func compactParts(
    _ word: InputWord, keywords: [String], names: Set<String>, lexicon: EntryLexicon
  ) -> [InputWord] {
    let characters = Array(word.original)
    let knownNames = names.sorted { $0.count > $1.count }
    var cursor = 0
    var parts: [InputWord] = []
    while cursor < characters.count {
      let rest = String(characters[cursor...])
      if let name = knownNames.first(where: { rest.lowercased().hasPrefix($0) }) {
        parts.append(
          InputWord(
            original: String(characters[cursor..<(cursor + name.count)]),
            start: word.start + cursor))
        cursor += name.count
      } else if let keyword = keywords.first(where: { rest.lowercased().hasPrefix($0) }) {
        parts.append(
          InputWord(
            original: String(characters[cursor..<(cursor + keyword.count)]),
            start: word.start + cursor))
        cursor += keyword.count
      } else {
        // Keep an unknown name or note whole. A trailing amount can still stand next to it.
        let numeric =
          lexicon.amountText(String(characters[cursor])).first.map {
            ExpressionLexer.isDigit($0) || ExpressionLexer.operatorKind($0) != nil
          } ?? false
        var end = cursor + 1
        while end < characters.count {
          let next =
            lexicon.amountText(String(characters[end])).first.map {
              ExpressionLexer.isDigit($0) || ExpressionLexer.operatorKind($0) != nil
                || ExpressionLexer.decimalSeparators.contains($0)
            } ?? false
          if next != numeric { break }
          if !numeric,
            keywords.contains(where: { String(characters[end...]).lowercased().hasPrefix($0) })
          {
            break
          }
          end += 1
        }
        parts.append(
          InputWord(original: String(characters[cursor..<end]), start: word.start + cursor))
        cursor = end
      }
    }
    return parts
  }
}
