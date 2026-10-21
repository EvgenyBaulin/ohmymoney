import CoreKit
import Foundation

/// Reads one line of the entry field. English and Russian are understood at the same time and
/// independently of the interface language.
///
/// Ambiguity is resolved by a fixed order of passes; every pass only sees the words no
/// earlier pass has claimed, and a claimed word can never reappear in the note:
///
///  1. **kind** — a leading "+" (glued to a word too: "+кэшбэк") or a kind word; the
///     longest phrase wins, so "возврат денег" is a reimbursement while a bare "возврат" is
///     a refund; "аванс" is income unless «за» names a job it pays for ("аванс за ремонт");
///     a kind word inside a longer known name ("Salary card") is left to the name;
///  2. **goal** and **debt** — only behind their marker ("цель" / "goal", "долг" / "loan"),
///     because a goal called "Отпуск" must not swallow the word in a note;
///  3. **for whom** — "для <имя>" / "for <name>", then the standalone words
///     ("друзьям", "family"…). A named person also sets `forWhom` to `.other`: the concrete
///     relation lives in the database, not in the line. A possessive or an article behind
///     a marker ("for my wife", "для моей мамы", "at the Ritz") goes with the marker. Money
///     back also reads "от <имя>" / "from <name>": whom the money came from;
///  4. **place** behind "в" / "at" — unless a known event or payment method stands there
///     ("в День рождения", "in cash"), which then takes the marker, or a time ("в среду",
///     "at 9am"), which stays in the note with it —, then known places,
///     events and payment methods anywhere in the line. Inside one pass the longest
///     dictionary spelling wins; on equal length the order is place, event, payment method.
///     A card names its account as well; it wins only with a longer spelling than the
///     account's, and only a card of the account already read, if one was;
///  5. **currency** — a word, a code or a symbol, including the forms glued to the number;
///     a code that is also an English word ("try", "gel", "amd") only glued to the number or
///     in capitals right after it; a name that is an ordinary word too («драма», «лира», "rub")
///     only glued to the number or right after it;
///  6. **date** — keywords, ISO, `12.09.2026` and `12.09`, in a year no more than twenty
///     years ahead of today and less than eighty back («2500-10-5» is a formula). A bare
///     `12.09` is read as a date only when the line still holds another number that can be
///     the amount, otherwise "кофе 12.09" would have no amount at all. A day the calendar does not have — «31.09»,
///     29 February of a common year — is taken as the date all the same and reported
///     (`dateProblem`): the line is refused with the reason instead of saving it as a number;
///  7. **amount** — the longest run of neighbouring unclaimed words that evaluates as an
///     expression; runs are tried left to right, so the first number of the line wins —
///     unless it is a count or a day ("2 шт", "3 ночи", "к 8 марта") and another number is
///     there. A "+" in front of it ("кэшбэк +250") is the sign of income when nothing else
///     named the kind. A word that multiplies with a glued `x` («250x2») is the amount only
///     when no other number is left: «доска 20x30 1500» costs 1 500;
///  8. **note** — everything left, joined by single spaces.
///
/// Between 4's marked place and its known names stands the **transfer**: a transfer word
/// («перевод», «перевёл», "transfer") with two accounts — by the name of the account, its bank
/// or its card — is a transfer from the first to the second («с»/«from» and «на»/«to» say
/// otherwise); with one account and a word no account answers to, a transfer the sheet has to
/// finish; with no account, one account alone, or a person the dictionary knows, the operation
/// it always was («перевод маше 500»).
///
/// After it, **whom an expense was paid for**: «за машу» (a person the dictionary knows),
/// «угостил машу» — a gift —, «пополам с машей»; the name in any case. A name the dictionary
/// does not know after «пополам с» is `unknownName`; after «за» or «угостил» it is no name at
/// all — «кофе за 300», «аванс за ремонт», «угостил кофе».
///
/// A name read behind its marker keeps the marker in its token — «для мамы», «в Пятёрочке»,
/// «цель Отпуск» — so an operation that has no such field (income has no place and no «на
/// кого») can give the very words back to its note.
public struct InputLineParser: Sendable {
  private let vocabulary: ParserVocabulary
  private let calendar: CalendarContext
  /// The owner's own currencies (`custom_currencies`): their codes and symbols are read too.
  private let catalog: CurrencyCatalog

  public init(
    vocabulary: ParserVocabulary, calendar: CalendarContext, catalog: CurrencyCatalog = .empty
  ) {
    self.vocabulary = vocabulary
    self.calendar = calendar
    self.catalog = catalog
  }

  /// `kind` is the kind the operation already has — chosen in the ↓ panel — for a line that
  /// names none: money back chosen there reads «от Ани» as whom it came from.
  public func parse(_ text: String, today: DateOnly, kind: TransactionKind? = nil) -> ParsedInput {
    var session = ParseSession(
      text: text, vocabulary: vocabulary, calendar: calendar, today: today, catalog: catalog)
    session.panelKind = kind
    session.run(readingTimeAndCashback: false)
    return session.finish()
  }

  /// Reads the line as `parse` does and, besides, the time of day and the cashback: «груша
  /// вчера в 18:09 325 кэшбек 9.76» costs 325, yesterday at 18:09, with 9.76 of cashback, and
  /// its note is «груша».
  ///
  /// The **time** — «18:09», «в 9:30», "at 6:09pm", "12am", "6:30 pm" — is read after the
  /// known names and before the currency, the date and the amount; «в» or "at" in front of it
  /// goes with it. A clock writes the minutes with two digits, so «2:1» and «18:09:30» are no
  /// times. A word of that shape whose hour or minute no clock shows («25:00», «24:00»,
  /// «18:61», "13pm", "0am") is `timeProblem`: the line is refused with the word, the way a
  /// day the calendar has not is, so a slip of the finger is not saved as a note. A time is
  /// never the amount, not even the only number of the line.
  ///
  /// The **cashback** is the number right behind its word («кэшбэк», «кэшбек», «кешбэк»,
  /// "cashback", "cash back"): money read by the rules of amounts typed by hand, or a percent
  /// («3%», «1,5 %», «7 процентов»). Money is read only when another number is left to be the
  /// amount: «кэшбэк 250» is the cashback that came, an amount of 250. A number signed with
  /// «+» or «−», zero, or a percent above a hundred is not read, and the words stay where
  /// they were. Income and money back have no cashback, so in them the word is not read
  /// either. The word without a number stays in the note.
  public func read(
    _ text: String, today: DateOnly, kind: TransactionKind? = nil
  ) -> InputLineReading {
    var session = ParseSession(
      text: text, vocabulary: vocabulary, calendar: calendar, today: today, catalog: catalog)
    session.panelKind = kind
    session.run(readingTimeAndCashback: true)
    return InputLineReading(
      parsed: session.finish(), timeOfDay: session.timeOfDay, timeProblem: session.timeProblem,
      timePhrase: session.timePhrase, cashback: session.cashback,
      cashbackPhrase: session.cashbackPhrase, selfEmployed: session.selfEmployed)
  }
}

/// Mutable state of one `parse` call. Kept apart from the parser itself so the parser stays
/// immutable and `Sendable`.
private struct ParseSession {
  struct Claim {
    let role: ParsedRole
    let text: String
    let start: Int
  }

  var words: [InputWord]
  let vocabulary: ParserVocabulary
  let calendar: CalendarContext
  let today: DateOnly
  var result = ParsedInput()
  var claims: [Claim] = []
  /// The kind the operation already has, for a line that names none.
  var panelKind: TransactionKind?
  var timeOfDay: TimeOfDay?
  var timeProblem: String?
  var timePhrase: String?
  var cashback: CashbackReading?
  var cashbackPhrase: String?
  let catalog: CurrencyCatalog
  /// «смз» was read.
  var selfEmployed = false

  init(
    text: String, vocabulary: ParserVocabulary, calendar: CalendarContext, today: DateOnly,
    catalog: CurrencyCatalog = .empty
  ) {
    self.words = InputWord.split(text)
    self.vocabulary = vocabulary
    self.calendar = calendar
    self.today = today
    self.catalog = catalog
  }

  /// Every pass in its order. The time and the cashback are read only for `read`, after the
  /// known names — a name the dictionary knows keeps its words — and before the currency, the
  /// date and the amount, which must not take their numbers.
  mutating func run(readingTimeAndCashback: Bool) {
    readKind()
    readSelfEmployed()
    readGoalAndDebt()
    readPeople()
    readMarkedPlace()
    readTransfer()
    readWithoutCard()
    readPayingFor()
    readKnownNames()
    if readingTimeAndCashback {
      readTime()
      readCashback()
    }
    readCurrency()
    readDate()
    readAmount()
  }

  // MARK: - Claims

  mutating func claim(_ range: Range<Int>, as role: ParsedRole?, text: String? = nil) {
    guard !range.isEmpty, range.upperBound <= words.count else { return }
    if let role {
      let body = text ?? range.map { words[$0].original }.joined(separator: " ")
      claims.append(Claim(role: role, text: body, start: words[range.lowerBound].start))
    }
    for index in range {
      words[index].claimed = true
    }
  }

  mutating func claim(_ index: Int, as role: ParsedRole?, text: String? = nil) {
    claim(index..<(index + 1), as: role, text: text)
  }

  // MARK: - Dictionary matching

  func matches(_ parts: [String], at index: Int, loose: Bool) -> Bool {
    guard !parts.isEmpty, index >= 0, index + parts.count <= words.count else { return false }
    for offset in 0..<parts.count {
      let word = words[index + offset]
      guard !word.claimed else { return false }
      // Behind a marker every word of a name is declined, not only a one-word name's:
      // «в Азбуке вкуса», «для Анны Петровой».
      let equal =
        loose
        ? TextNormalizer.looselyEqual(word.normalized, parts[offset])
        : word.normalized == parts[offset]
      guard equal else { return false }
    }
    return true
  }

  /// Longest spelling of any entry that starts exactly at `index`.
  func bestMatch(
    _ entries: [ParserVocabulary.Entry], at index: Int, loose: Bool
  ) -> (entry: ParserVocabulary.Entry, range: Range<Int>)? {
    var best: (entry: ParserVocabulary.Entry, range: Range<Int>)?
    for entry in entries {
      for spelling in entry.spellings {
        let parts = spelling.split(separator: " ").map { TextNormalizer.normalized(String($0)) }
        guard matches(parts, at: index, loose: loose) else { continue }
        if best == nil || parts.count > best!.range.count {
          best = (entry, index..<(index + parts.count))
        }
      }
    }
    return best
  }

  // MARK: - Passes

  mutating func readKind() {
    if let first = words.first, first.amountText.first == "+" {
      result.kind = .income
      if first.amountText == "+" {
        claim(0, as: .kind, text: first.original)
      } else {
        claims.append(Claim(role: .kind, text: "+", start: first.start))
        // Glued to a word, the sign is read and the word is what stands behind it: «+кэшбэк»
        // leaves «кэшбэк» in the note, «+Пятёрочка» is the place. A number keeps its sign.
        if !isAmountish(first), let sign = first.original.firstIndex(of: "+") {
          var rest = first.original
          rest.remove(at: sign)
          words[0] = InputWord(original: rest, start: first.start + 1)
        }
      }
    }
    for phrase in Lexicon.kindPhrases {
      for index in words.indices where matches(phrase.words, at: index, loose: false) {
        if phrase.words.count == 1, Lexicon.russianAdvanceWords.contains(phrase.words[0]),
          paysForAJob(after: index + 1)
        {
          continue
        }
        if isInsideALongerName(index..<(index + phrase.words.count)) { continue }
        result.kind = phrase.meaning
        claim(index..<(index + phrase.words.count), as: .kind)
        return
      }
    }
  }

  /// «смз 15000»: income of the self-employed. Read after the kind, and only while the line names
  /// income or no kind at all: «возврат смз 500» is a refund, and «смз» stays in its note. A word
  /// inside a longer known name belongs to the name.
  mutating func readSelfEmployed() {
    guard result.kind == .expense || result.kind == .income else { return }
    if result.kind == .expense, claims.contains(where: { $0.role == .kind }) { return }
    guard
      let index = words.indices.first(where: {
        !words[$0].claimed && Lexicon.selfEmployedWords.contains(words[$0].normalized)
      }), !isInsideALongerName(index..<(index + 1))
    else { return }
    result.kind = .income
    selfEmployed = true
    claim(index, as: .kind)
  }

  /// «со счёта», «счётом», "from account": the money leaves the account itself, not its card
  /// (`ParsedInput.withoutCard`). Not in a transfer, which names its accounts by itself, and not
  /// inside a longer name the dictionaries know.
  mutating func readWithoutCard() {
    guard result.transfer == nil else { return }
    for phrase in Lexicon.withoutCardPhrases {
      for index in words.indices where matches(phrase, at: index, loose: false) {
        let range = index..<(index + phrase.count)
        if isInsideALongerName(range) { continue }
        result.withoutCard = true
        claim(range, as: .paymentMethod)
        return
      }
    }
  }

  /// A kind word that is part of a longer name the dictionaries know belongs to the name, the
  /// way the longer spelling wins inside every other pass: «Salary card» is a payment method,
  /// «Кафе Доход» a place — not income with the rest of the name left in the note.
  private func isInsideALongerName(_ range: Range<Int>) -> Bool {
    let lists = [
      vocabulary.places, vocabulary.events, vocabulary.paymentMethods, vocabulary.goals,
      vocabulary.debts, vocabulary.people, vocabulary.cards.map(\.entry),
    ]
    // Only a name that can reach the phrase is looked up: a long line is not walked whole
    // for every kind word in it.
    let longest =
      lists.joined().flatMap(\.spellings)
      .map { $0.split(separator: " ").count }.max() ?? 0
    guard longest > range.count else { return false }
    for start in max(0, range.upperBound - longest)...range.lowerBound {
      for entries in lists {
        guard let match = bestMatch(entries, at: start, loose: false) else { continue }
        if match.range.upperBound >= range.upperBound, match.range.count > range.count {
          return true
        }
      }
    }
    return false
  }

  /// «за» and what it pays for behind an advance: «аванс за ремонт» is a prepayment. A month
  /// or a number there ("аванс за сентябрь", "аванс за 2 недели") keeps it the salary's.
  private func paysForAJob(after index: Int) -> Bool {
    guard index < words.count, !words[index].claimed,
      words[index].normalized == Lexicon.russianAdvanceMarker
    else { return false }
    var next = index + 1
    if next < words.count, Lexicon.determiners.contains(words[next].normalized) { next += 1 }
    guard next < words.count, !words[next].normalized.isEmpty, !isAmountish(words[next]) else {
      return false
    }
    return !Lexicon.russianSalaryPeriods.contains(words[next].normalized)
  }

  mutating func readGoalAndDebt() {
    result.goalId = readMarked(
      markers: Lexicon.goalMarkers, entries: vocabulary.goals, role: .goal)
    result.debtId = readMarked(
      markers: Lexicon.debtMarkers, entries: vocabulary.debts, role: .debt)
  }

  /// A goal or a debt: the marker word plus the name. The name usually follows the marker,
  /// but "Ипотека 30000 кредит" also works — and a name that is itself the marker
  /// ("ипотека") is matched on the marker word.
  private mutating func readMarked(
    markers: Set<String>, entries: [ParserVocabulary.Entry], role: ParsedRole
  ) -> UUID? {
    guard !entries.isEmpty else { return nil }
    for index in words.indices where !words[index].claimed {
      guard markers.contains(words[index].normalized) else { continue }
      if let match = bestMatch(entries, at: index + 1, loose: true) {
        let phrase = index..<match.range.upperBound
        claim(phrase, as: role, text: marked(phrase))
        return match.entry.id
      }
      for other in words.indices where !words[other].claimed {
        guard let match = bestMatch(entries, at: other, loose: false) else { continue }
        if !match.range.contains(index) { claim(index, as: nil) }
        claim(match.range, as: role)
        return match.entry.id
      }
    }
    return nil
  }

  /// Where the name behind the marker at `marker` starts: the next word, or the one after it
  /// when the next word is a possessive or an article ("for my wife", "для моей мамы",
  /// "at the Ritz") — such a word belongs to the marker, it is never a name. Nil when nothing
  /// readable is left, so "for my" at the end of a line stays in the note.
  func nameStart(after marker: Int) -> Int? {
    var next = marker + 1
    if next < words.count, !words[next].claimed,
      Lexicon.determiners.contains(words[next].normalized)
    {
      next += 1
    }
    guard next < words.count, !words[next].claimed, !words[next].normalized.isEmpty else {
      return nil
    }
    return next
  }

  /// The words of a marker and the name behind it, as typed: «для моей мамы», «в Пятёрочке».
  func marked(_ range: Range<Int>) -> String {
    words[range].map(\.original).joined(separator: " ")
  }

  /// A dictionary name behind the marker. A name that itself begins with the article
  /// ("The Ritz") is tried first, as written; then the name after the article.
  func bestMatch(
    _ entries: [ParserVocabulary.Entry], behind marker: Int, from start: Int
  ) -> (entry: ParserVocabulary.Entry, range: Range<Int>)? {
    if start > marker + 1, let whole = bestMatch(entries, at: marker + 1, loose: true) {
      return whole
    }
    return bestMatch(entries, at: start, loose: true)
  }

  mutating func readPeople() {
    // Money back names whom it came from — «от Ани», "from Anya" — as well as «для Ани»,
    // whether the line says it is money back or the panel chose it for a line that names no
    // kind. In any other line «от» is a word of the note.
    let namesKind = claims.contains { $0.role == .kind }
    let isMoneyBack =
      result.kind == .reimbursement || (!namesKind && panelKind == .reimbursement)
    let markers =
      isMoneyBack ? Lexicon.personMarkers.union(Lexicon.fromMarkers) : Lexicon.personMarkers
    for index in words.indices where !words[index].claimed {
      guard markers.contains(words[index].normalized), !isInsideAKnownName(index),
        let next = nameStart(after: index)
      else { continue }
      if let forWhom = Lexicon.forWhomWords[words[next].normalized] {
        result.forWhom = forWhom
        claim(index..<(next + 1), as: .forWhom, text: marked(index..<(next + 1)))
        break
      }
      if let match = bestMatch(vocabulary.people, behind: index, from: next) {
        result.personId = match.entry.id
        result.forWhom = result.forWhom ?? .other
        let phrase = index..<match.range.upperBound
        claim(phrase, as: .person, text: marked(phrase))
        break
      }
      // A number, a currency, a time ("for lunch") or a name the dictionary knows as
      // something else ("for her birthday") is not a new person.
      guard !isAmountish(words[next]), currencyAffix(in: words[next].amountText) == nil,
        !Lexicon.timeWords.contains(words[next].normalized),
        !knowsOtherName(behind: index, from: next)
      else { continue }
      // "для семьи", "для мамы": behind a marker the word is declined. Its forms are listed,
      // not guessed from a stem — «Жени» is a name, not «жены». A known person still wins.
      if let forWhom = Lexicon.declinedForWhomWords[words[next].normalized] {
        result.forWhom = forWhom
        claim(index..<(next + 1), as: .forWhom, text: marked(index..<(next + 1)))
        break
      }
      let name = TextNormalizer.trimmingEdgePunctuation(words[next].original)
      result.unknownPersonName = name
      result.unknownPersonPhrase = phrase(from: index, to: next, name: name)
      result.forWhom = result.forWhom ?? .other
      claim(index..<(next + 1), as: .person, text: marked(index..<(next + 1)))
      break
    }
    guard result.forWhom == nil else { return }
    for index in words.indices where !words[index].claimed {
      guard let forWhom = Lexicon.forWhomWords[words[index].normalized] else { continue }
      result.forWhom = forWhom
      claim(index, as: .forWhom, text: words[index].original)
      return
    }
  }

  /// The words from the marker to an unknown name, as typed: «для Пети», «at the Ritz» —
  /// a possessive or an article between them goes with the marker (`nameStart`), so the
  /// note the app gives them back to reads as the line did.
  private func phrase(from marker: Int, to start: Int, name: String) -> String {
    (words[marker..<start].map(\.original) + [name]).joined(separator: " ")
  }

  /// The word at `index` is inside the name of a known account, card, place or event that
  /// starts before it — «для» of «Карта для поездок» — and marks nobody.
  private func isInsideAKnownName(_ index: Int) -> Bool {
    let entries =
      vocabulary.paymentMethods + vocabulary.cards.map(\.entry) + vocabulary.places
      + vocabulary.events
    return (0..<index).contains { start in
      !words[start].claimed
        && [false, true].contains { loose in
          bestMatch(entries, at: start, loose: loose)?.range.contains(index) == true
        }
    }
  }

  /// A known place, event, payment method or card starts behind the marker.
  private func knowsOtherName(behind marker: Int, from start: Int) -> Bool {
    [
      vocabulary.places, vocabulary.events, vocabulary.paymentMethods,
      vocabulary.cards.map(\.entry),
    ].contains { entries in
      bestMatch(entries, behind: marker, from: start) != nil
    }
  }

  mutating func readMarkedPlace() {
    for index in words.indices where !words[index].claimed {
      guard Lexicon.placeMarkers.contains(words[index].normalized),
        let next = nameStart(after: index)
      else { continue }
      if let match = bestMatch(vocabulary.places, behind: index, from: next) {
        result.placeId = match.entry.id
        let phrase = index..<match.range.upperBound
        claim(phrase, as: .place, text: marked(phrase))
        return
      }
      // "в День рождения", "in cash": the marker is a plain preposition in front of a known
      // event or payment method, which takes the marker with it — a place may still follow.
      if readMarkedName(after: index, from: next) { continue }
      // An unknown place, but only if the next word is not something else we can read, nor
      // a time: "в среду", "в январе", "в 12:30", "at 9am" say when, not where.
      guard !isAmountish(words[next]), currencyAffix(in: words[next].amountText) == nil,
        Lexicon.forWhomWords[words[next].normalized] == nil,
        dateReading(
          from: words[next].normalized, written: words[next].original,
          allowDayMonth: false) == nil,
        !Lexicon.datePhrases.contains(where: { matches($0.words, at: next, loose: false) }),
        !Lexicon.timeWords.contains(words[next].normalized),
        !isClockTime(words[next].normalized)
      else { continue }
      let name = TextNormalizer.trimmingEdgePunctuation(words[next].original)
      result.unknownPlaceName = name
      result.unknownPlacePhrase = phrase(from: index, to: next, name: name)
      claim(index..<(next + 1), as: .place, text: marked(index..<(next + 1)))
      return
    }
  }

  /// A known event, payment method or card behind the place marker at `marker`: the longer
  /// spelling wins, on equal length the event, then the account (the order of
  /// `readKnownNames`).
  private mutating func readMarkedName(after marker: Int, from start: Int) -> Bool {
    var winner: (role: ParsedRole, entry: ParserVocabulary.Entry, range: Range<Int>)?
    if result.eventId == nil,
      let match = bestMatch(vocabulary.events, behind: marker, from: start)
    {
      winner = (.event, match.entry, match.range)
    }
    if result.paymentMethodId == nil,
      let match = bestMatch(vocabulary.paymentMethods, behind: marker, from: start),
      match.range.count > (winner?.range.count ?? 0)
    {
      winner = (.paymentMethod, match.entry, match.range)
    }
    var card: CardReading?
    if let found = cardReading(behind: marker, from: start),
      found.range.count > (winner?.range.count ?? 0)
    {
      card = found
    }
    if let card {
      take(card)
      claim(
        marker..<card.range.upperBound, as: .paymentMethod,
        text: marked(marker..<card.range.upperBound))
      return true
    }
    guard let winner else { return false }
    if winner.role == .event {
      result.eventId = winner.entry.id
    } else {
      result.paymentMethodId = winner.entry.id
    }
    claim(
      marker..<winner.range.upperBound, as: winner.role,
      text: marked(marker..<winner.range.upperBound))
    return true
  }

  /// A card the line names, with the account it belongs to. Two live cards of one account
  /// spelled alike name the account alone (`card` nil); spelled alike on two accounts, they
  /// name nothing and are not a reading at all.
  struct CardReading {
    let card: UUID?
    let accountId: UUID
    let range: Range<Int>
  }

  /// The card whose longest spelling starts at `index`, while none is read yet and the line
  /// names no other account than the card's.
  private func cardReading(at index: Int, loose: Bool) -> CardReading? {
    guard result.cardId == nil, !vocabulary.cards.isEmpty else { return nil }
    var length = 0
    var found: [ParserVocabulary.CardEntry] = []
    for card in vocabulary.cards {
      guard let match = bestMatch([card.entry], at: index, loose: loose) else { continue }
      if match.range.count > length {
        length = match.range.count
        found = [card]
      } else if match.range.count == length, !found.contains(card) {
        found.append(card)
      }
    }
    guard let first = found.first else { return nil }
    let accounts = Set(found.map(\.accountId))
    guard accounts.count == 1 else { return nil }
    guard result.paymentMethodId == nil || result.paymentMethodId == first.accountId else {
      return nil
    }
    let distinct = Set(found.map(\.entry.id))
    return CardReading(
      card: distinct.count == 1 ? first.entry.id : nil, accountId: first.accountId,
      range: index..<(index + length))
  }

  /// The same behind a marker: a name that begins with the article is tried as written first.
  private func cardReading(behind marker: Int, from start: Int) -> CardReading? {
    if start > marker + 1, let whole = cardReading(at: marker + 1, loose: true) { return whole }
    return cardReading(at: start, loose: true)
  }

  /// A card read: it names its account too.
  private mutating func take(_ card: CardReading) {
    result.cardId = card.card
    result.paymentMethodId = card.accountId
  }

  /// A transfer between accounts (see the type's comment). Runs after the people, so a person
  /// the dictionary knows keeps the line an operation, and before the known names, so both
  /// accounts are read here and not the first one alone.
  mutating func readTransfer() {
    guard
      let word = words.indices.first(where: {
        !words[$0].claimed && Lexicon.transferWords.contains(words[$0].normalized)
      }),
      result.personId == nil, result.unknownPersonName == nil, result.goalId == nil,
      result.debtId == nil, !claims.contains(where: { $0.role == .kind })
    else { return }

    struct Side {
      var account: UUID
      var card: UUID?
      var range: Range<Int>
      var marker: Int?
    }
    let markers = Lexicon.transferFromMarkers.union(Lexicon.transferToMarkers)
    var sides: [Side] = []
    // Every word that named an account, the same one twice included.
    var named = Set<Int>()
    // An account the place marker read already: «перевод 5000 сбер в т-банк».
    if let account = result.paymentMethodId,
      let read = claims.firstIndex(where: { $0.role == .paymentMethod }),
      let at = words.indices.first(where: { words[$0].start == claims[read].start })
    {
      let marker = markers.contains(words[at].normalized) ? at : nil
      sides.append(
        Side(account: account, card: result.cardId, range: at..<(at + 1), marker: marker))
    }
    var index = 0
    while index < words.count {
      guard !words[index].claimed, index != word else {
        index += 1
        continue
      }
      let marker = index > 0 && markers.contains(words[index - 1].normalized) ? index - 1 : nil
      let loose = marker != nil
      var best: Side?
      if let match = bestMatch(vocabulary.paymentMethods, at: index, loose: loose) {
        best = Side(account: match.entry.id, card: nil, range: match.range, marker: marker)
      }
      for card in vocabulary.cards {
        guard let match = bestMatch([card.entry], at: index, loose: loose),
          match.range.count > (best?.range.count ?? 0)
        else { continue }
        best = Side(
          account: card.accountId, card: card.entry.id, range: match.range, marker: marker)
      }
      if let best {
        named.formUnion(best.range)
        if !sides.contains(where: { $0.account == best.account }) { sides.append(best) }
        index = best.range.upperBound
      } else {
        index += 1
      }
    }
    guard !sides.isEmpty else { return }

    var unknown: (index: Int, marker: Int?)?
    if sides.count == 1 {
      // One account: a transfer only when a word stands where the other one would — a word
      // that is no number, no currency, no date, no «for whom» and no other known name.
      for candidate in words.indices
      where !words[candidate].claimed && candidate != word
        && !sides[0].range.contains(candidate) && !named.contains(candidate)
        && sides[0].marker != candidate
        && !markers.contains(words[candidate].normalized) && !isAmountish(words[candidate])
        && currencyAffix(in: words[candidate].amountText) == nil
        && customCurrency(at: candidate) == nil
        && Lexicon.forWhomWords[words[candidate].normalized] == nil
        && !Lexicon.datePhrases.contains(where: { matches($0.words, at: candidate, loose: false) })
      {
        let marker =
          candidate > 0 && markers.contains(words[candidate - 1].normalized) ? candidate - 1 : nil
        unknown = (candidate, marker)
        break
      }
      guard unknown != nil else { return }
    }

    // Who is who: a «с»/«на» decides; otherwise the order of the line.
    func isFrom(_ marker: Int?) -> Bool? {
      guard let marker else { return nil }
      return Lexicon.transferFromMarkers.contains(words[marker].normalized)
    }
    var from: Side?
    var to: Side?
    for side in sides.prefix(2) {
      switch isFrom(side.marker) {
      case true?: from = from ?? side
      case false?: to = to ?? side
      case nil: break
      }
    }
    for side in sides.prefix(2) where from?.account != side.account && to?.account != side.account {
      if from == nil, isFrom(unknown?.marker) != true {
        from = side
      } else if to == nil {
        to = side
      } else {
        from = from ?? side
      }
    }

    var reading = TransferReading(
      fromAccountId: from?.account, fromCardId: from?.card, toAccountId: to?.account,
      toCardId: to?.card)
    claim(word, as: .kind)
    for side in [from, to].compactMap({ $0 }) {
      let range = (side.marker ?? side.range.lowerBound)..<side.range.upperBound
      if !words[side.range.lowerBound].claimed {
        claim(range, as: .paymentMethod, text: marked(range))
      } else if let marker = side.marker, !words[marker].claimed {
        claim(marker, as: nil)
      }
    }
    if let unknown {
      reading.unknownName = TextNormalizer.trimmingEdgePunctuation(words[unknown.index].original)
      let range = (unknown.marker ?? unknown.index)..<(unknown.index + 1)
      claim(range, as: .paymentMethod, text: marked(range))
    }
    result.transfer = reading
    result.paymentMethodId = from?.account
    result.cardId = from?.card
  }

  /// The person whose name starts at `index`, in any case (`TextNormalizer.samePerson`).
  private func personMatch(at index: Int) -> (id: UUID, range: Range<Int>)? {
    var best: (id: UUID, range: Range<Int>)?
    for entry in vocabulary.people {
      for spelling in entry.spellings {
        let parts = spelling.split(separator: " ").map { TextNormalizer.normalized(String($0)) }
        guard index + parts.count <= words.count,
          parts.indices.allSatisfy({ offset in
            !words[index + offset].claimed
              && TextNormalizer.samePerson(words[index + offset].normalized, parts[offset])
          })
        else { continue }
        if best == nil || parts.count > best!.range.count {
          best = (entry.id, index..<(index + parts.count))
        }
      }
    }
    return best
  }

  /// «за машу», «угостил машу», «пополам с машей» (see the type's comment).
  mutating func readPayingFor() {
    guard result.transfer == nil, result.kind == .expense,
      panelKind == nil || panelKind == .expense, result.goalId == nil, result.debtId == nil
    else { return }
    for index in words.indices where !words[index].claimed {
      let word = words[index].normalized
      var way: PayingForReading.Way?
      var nameAt = index + 1
      if Lexicon.halfWords.contains(word), index + 1 < words.count,
        Lexicon.withWords.contains(words[index + 1].normalized)
      {
        way = .half
        nameAt = index + 2
      } else if Lexicon.giftWords.contains(word) {
        way = .gift
      } else if Lexicon.paidForMarkers.contains(word) {
        way = .forSomebody
      }
      guard let way, nameAt < words.count, !words[nameAt].claimed else { continue }
      if let person = personMatch(at: nameAt) {
        result.payingFor = PayingForReading(way: way, personId: person.id)
        let phrase = index..<person.range.upperBound
        claim(phrase, as: .person, text: marked(phrase))
        return
      }
      // «за» or «угостил» before anything but a known person are words of the note: «кофе за
      // 300», «угостил кофе». Only «пополам с» names somebody whoever they are.
      guard way == .half else { continue }
      let next = words[nameAt]
      guard !isAmountish(next), currencyAffix(in: next.amountText) == nil,
        !Lexicon.timeWords.contains(next.normalized)
      else { continue }
      let name = TextNormalizer.trimmingEdgePunctuation(next.original)
      result.payingFor = PayingForReading(way: way, unknownName: name)
      result.unknownPersonName = result.unknownPersonName ?? name
      let phrase = index..<(nameAt + 1)
      result.unknownPersonPhrase = result.unknownPersonPhrase ?? marked(phrase)
      claim(phrase, as: .person, text: marked(phrase))
      return
    }
  }

  /// Places, events and payment methods written without any marker. Inside one position
  /// the longest spelling wins; on equal length the order is place, event, payment method.
  mutating func readKnownNames() {
    for index in words.indices where !words[index].claimed {
      var winner: (role: ParsedRole, entry: ParserVocabulary.Entry, range: Range<Int>)?
      if result.placeId == nil,
        let match = bestMatch(vocabulary.places, at: index, loose: false)
      {
        winner = (.place, match.entry, match.range)
      }
      if result.eventId == nil,
        let match = bestMatch(vocabulary.events, at: index, loose: false),
        match.range.count > (winner?.range.count ?? 0)
      {
        winner = (.event, match.entry, match.range)
      }
      if result.paymentMethodId == nil,
        let match = bestMatch(vocabulary.paymentMethods, at: index, loose: false),
        match.range.count > (winner?.range.count ?? 0)
      {
        winner = (.paymentMethod, match.entry, match.range)
      }
      // A card wins only with a longer spelling: on a tie the account's own name is the
      // account («сбер» of «Сбер» and of its card «Сбер»).
      if let card = cardReading(at: index, loose: false),
        card.range.count > (winner?.range.count ?? 0)
      {
        take(card)
        claim(card.range, as: .paymentMethod)
        continue
      }
      // The account of the card read before it: its name says nothing new and leaves the note.
      if winner == nil, result.cardId != nil, let account = result.paymentMethodId,
        let match = bestMatch(vocabulary.paymentMethods, at: index, loose: false),
        match.entry.id == account
      {
        claim(match.range, as: nil)
        continue
      }
      guard let winner else { continue }
      switch winner.role {
      case .place: result.placeId = winner.entry.id
      case .event: result.eventId = winner.entry.id
      default: result.paymentMethodId = winner.entry.id
      }
      claim(winner.range, as: winner.role)
    }
  }

  /// The first word written as a time on a clock, with «в» / "at" in front of it and "am" /
  /// "pm" standing behind it (see `InputLineParser.read`).
  mutating func readTime() {
    for index in words.indices where !words[index].claimed {
      let next = index + 1
      let meridiemWord =
        next < words.count && !words[next].claimed
        ? Self.meridiem(of: words[next].normalized) : nil
      guard let reading = clockReading(words[index].normalized, meridiem: meridiemWord) else {
        continue
      }
      var start = index
      if index > 0, !words[index - 1].claimed,
        Lexicon.timeMarkers.contains(words[index - 1].normalized)
      {
        start = index - 1
      }
      let end = meridiemWord == nil ? next : next + 1
      let phrase = marked(start..<end)
      switch reading {
      case .time(let time): timeOfDay = time
      case .impossible:
        timeProblem = (index..<end).map {
          TextNormalizer.trimmingEdgePunctuation(words[$0].original)
        }.joined(separator: " ")
      }
      timePhrase = phrase
      claim(start..<end, as: .date, text: phrase)
      return
    }
  }

  enum ClockReading {
    case time(TimeOfDay)
    /// Shaped as a time, but no clock shows it.
    case impossible
  }

  /// "am" or "pm" as a word of its own, or nil.
  static func meridiem(of word: String) -> Bool? {
    switch word {
    case "am", "a.m": false
    case "pm", "p.m": true
    default: nil
    }
  }

  /// A word written as a time: «18:09» and «9:30» on a 24-hour clock, «6:09pm», «9am», and
  /// «6:30» or «6» followed by the word `meridiem` (true for "pm") on a 12-hour one. Nil for
  /// a word of any other shape.
  func clockReading(_ text: String, meridiem: Bool?) -> ClockReading? {
    var body = Substring(text)
    var afternoon = meridiem
    if afternoon == nil, body.count > 2 {
      if body.hasSuffix("am") { afternoon = false }
      if body.hasSuffix("pm") { afternoon = true }
      if afternoon != nil { body = body.dropLast(2) }
    }
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard allDigits(parts), (1...2).contains(parts[0].count), let hour = Int(parts[0]) else {
      return nil
    }
    var minute = 0
    switch parts.count {
    case 1:
      guard afternoon != nil else { return nil }
    case 2:
      guard parts[1].count == 2, let minutes = Int(parts[1]) else { return nil }
      minute = minutes
    default:
      return nil
    }
    guard (0...59).contains(minute) else { return .impossible }
    guard let afternoon else {
      return (0...23).contains(hour) ? .time(TimeOfDay(hour: hour, minute: minute)) : .impossible
    }
    guard (1...12).contains(hour) else { return .impossible }
    return .time(TimeOfDay(hour: hour % 12 + (afternoon ? 12 : 0), minute: minute))
  }

  /// The number right behind the cashback word (see `InputLineParser.read`).
  mutating func readCashback() {
    let namesKind = claims.contains { $0.role == .kind }
    let kind = namesKind || panelKind == nil ? result.kind : panelKind
    guard kind != .income, kind != .reimbursement, result.transfer == nil else { return }
    for index in words.indices where !words[index].claimed {
      var next = index + 1
      if !Lexicon.cashbackWords.contains(words[index].normalized) {
        guard
          let phrase = Lexicon.cashbackPhrases.first(where: {
            matches($0, at: index, loose: false)
          })
        else { continue }
        next = index + phrase.count
      }
      guard next < words.count, !words[next].claimed else { continue }
      let number = words[next]
      // A percent: «3%», or «3» and «%» / «процентов» behind it.
      var text = number.amountText
      var end = next + 1
      var percent = false
      if text.hasSuffix("%") {
        text.removeLast()
        percent = true
      } else if end < words.count, !words[end].claimed,
        Lexicon.percentWords.contains(words[end].normalized)
      {
        end += 1
        percent = true
      }
      guard let first = text.first, ExpressionLexer.isDigit(first),
        let value = try? ExpressionEvaluator.evaluate(text), value > 0
      else { continue }
      if percent {
        guard value <= 100 else { continue }
        cashback = .percent(value)
      } else {
        // Money only while another number is left to be the amount.
        guard isAmountish(number), amountCandidates().contains(where: { $0 != next }) else {
          continue
        }
        cashback = .amount(value)
      }
      cashbackPhrase = marked(index..<end)
      claim(index..<end, as: nil)
      return
    }
  }

  mutating func readCurrency() {
    guard result.currency == nil else { return }
    for index in words.indices where !words[index].claimed {
      if let custom = customCurrency(at: index) {
        result.currency = custom.code
        if custom.residual.isEmpty {
          claim(index, as: .currency, text: words[index].original)
        } else {
          words[index].amountText = custom.residual
          claims.append(Claim(role: .currency, text: custom.text, start: words[index].start))
        }
        return
      }
      guard let affix = currencyAffix(in: words[index].amountText) else { continue }
      guard
        vocabulary.enabledCurrencies.isEmpty
          || vocabulary.enabledCurrencies.contains(affix.code)
      else {
        // Off in the settings. Glued to the number it is set aside the way a word of its own
        // is: "250usd" still has the amount 250, and "usd" stays in the note.
        if !affix.residual.isEmpty {
          words[index].amountText = affix.residual
          words[index].ignoredCurrency = affix.text
        }
        continue
      }
      guard !affix.residual.isEmpty || standsAsCurrency(index) else { continue }
      result.currency = affix.code
      if affix.residual.isEmpty {
        claim(index, as: .currency, text: words[index].original)
      } else {
        words[index].amountText = affix.residual
        claims.append(Claim(role: .currency, text: affix.text, start: words[index].start))
      }
      return
    }
  }

  /// A currency of the owner's own (`CurrencyCatalog`, not archived) — a currency of the bank
  /// is never one. Its code reads in capitals wherever it stands («ZZT 100», «100 ZZT»), in any
  /// case glued to the number or right after it («100zzt», «100 zzt»); its symbol only glued to
  /// the number, in front or behind («★100», «100★»), like the symbols of the bank's currencies.
  /// `residual` is what is left of the word for the amount.
  private func customCurrency(
    at index: Int
  ) -> (code: CurrencyCode, residual: String, text: String)? {
    let currencies = catalog.active
    guard !currencies.isEmpty else { return nil }
    let raw = words[index].amountText.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let written = TextNormalizer.trimmingEdgePunctuation(words[index].original)
    func code(_ letters: String) -> CurrencyCode? {
      guard letters.count == 3 else { return nil }
      return currencies.first { $0.code.code == letters.uppercased() }?.code
    }
    if let found = code(written) {
      let capitals = written == written.uppercased()
      return capitals || followsANumber(index) ? (found, "", written) : nil
    }
    let characters = Array(raw)
    // Glued: letters behind the number or in front of it.
    var cut = characters.count
    while cut > 0, characters[cut - 1].isLetter { cut -= 1 }
    if cut > 0, cut < characters.count, let found = code(String(characters[cut...])),
      characters[..<cut].contains(where: ExpressionLexer.isDigit)
    {
      return (found, String(characters[..<cut]), String(characters[cut...]))
    }
    var start = 0
    while start < characters.count, characters[start].isLetter { start += 1 }
    if start > 0, start < characters.count, let found = code(String(characters[..<start])),
      characters[start...].contains(where: ExpressionLexer.isDigit)
    {
      return (found, String(characters[start...]), String(characters[..<start]))
    }
    for currency in currencies {
      guard let symbol = catalog.symbol(currency.code), !symbol.isEmpty else { continue }
      let lowered = raw.lowercased()
      let mark = symbol.lowercased()
      if lowered.hasPrefix(mark), lowered.count > mark.count {
        let residual = String(raw.dropFirst(symbol.count))
        if residual.contains(where: ExpressionLexer.isDigit),
          !residual.contains(where: \.isLetter)
        {
          return (currency.code, residual, String(raw.prefix(symbol.count)))
        }
      }
      if lowered.hasSuffix(mark), lowered.count > mark.count {
        let residual = String(raw.dropLast(symbol.count))
        if residual.contains(where: ExpressionLexer.isDigit),
          !residual.contains(where: \.isLetter)
        {
          return (currency.code, residual, String(raw.suffix(symbol.count)))
        }
      }
    }
    return nil
  }

  /// A code that is also an everyday word ("try", "gel", "amd") stands for its currency only
  /// written in capitals right after a number: "ужин 250 TRY" is in lira, "coffee 250 try new
  /// latte" and "видеокарта AMD 25000" are not. A currency name that is an ordinary word too
  /// («драма», «лира», "rub", "dram") stands for it right after a number in any case — «билет 900
  /// драм», "кофе 250 rub" —, and a code in capitals anywhere ("RUB 250"); «кино драма 500» is
  /// a film. Every other currency word counts wherever it stands.
  private func standsAsCurrency(_ index: Int) -> Bool {
    let written = TextNormalizer.trimmingEdgePunctuation(words[index].original)
    let normalized = TextNormalizer.normalized(written)
    let capitals = written == written.uppercased()
    if Lexicon.wordlikeCurrencyCodes.contains(normalized) {
      return capitals && followsANumber(index)
    }
    if Lexicon.wordlikeCurrencyNames.contains(normalized) {
      let code = capitals && written.count == 3 && written.allSatisfy(\.isASCII)
      return code || followsANumber(index)
    }
    return true
  }

  /// The word in front of `index` is a number nothing has claimed yet.
  private func followsANumber(_ index: Int) -> Bool {
    guard index > 0 else { return false }
    let before = words[index - 1]
    return !before.claimed && isAmountish(before)
      && before.amountText.contains(where: ExpressionLexer.isDigit)
  }

  mutating func readDate() {
    guard result.date == nil else { return }
    for phrase in Lexicon.datePhrases {
      for index in words.indices where matches(phrase.words, at: index, loose: false) {
        result.date = calendar.adding(days: phrase.meaning, to: today)
        claim(index..<(index + phrase.words.count), as: .date)
        return
      }
    }
    // Gathered once: asking per word would walk the whole line for every word of it. A count
    // or a day of the month («2 шт», «к 8 марта») is no amount while another number is there,
    // so it leaves none behind a day-shaped number: «круассаны 2 шт 3.10» costs 3.10.
    let amounts = amountCandidates().filter { !isCountOrDay($0) }
    for index in words.indices where !words[index].claimed {
      let allowDayMonth = amounts.contains { $0 != index }
      guard
        let reading = dateReading(
          from: words[index].normalized, written: words[index].original,
          allowDayMonth: allowDayMonth)
      else { continue }
      switch reading {
      case .day(let day): result.date = day
      case .problem(let problem): result.dateProblem = problem
      }
      claim(index, as: .date, text: words[index].original)
      return
    }
  }

  mutating func readAmount() {
    guard result.amount == nil else { return }
    let aside = countsAndDays()
    // A word multiplied with a glued `x` — «250x2» — is the amount only when no other number
    // is left to be it: «доска 20x30 1500» is a board of 20 by 30 that costs 1 500.
    let plainNumberLeft = words.indices.contains { index in
      !words[index].claimed && isAmountish(words[index]) && !aside.contains(index)
        && !ExpressionLexer.hasGluedTimes(words[index].amountText)
        && words[index].amountText.contains(where: ExpressionLexer.isDigit)
    }
    func readable(_ index: Int) -> Bool {
      !words[index].claimed && isAmountish(words[index]) && !aside.contains(index)
        && !(plainNumberLeft && ExpressionLexer.hasGluedTimes(words[index].amountText))
    }
    var index = 0
    while index < words.count {
      guard readable(index) else {
        index += 1
        continue
      }
      var end = index
      while end + 1 < words.count, readable(end + 1) {
        end += 1
      }
      if readAmount(in: index...end) { return }
      index = end + 1
    }
  }

  /// Numbers that say how many or which day rather than how much: in front of a unit or a
  /// span of time ("2 шт", "1,5 кг", "3 ночи"), of a month ("к 8 марта") or behind an English
  /// one ("March 8"). They stay in the note while the line holds another number to be the
  /// amount; the only number of a line is still its amount.
  private func countsAndDays() -> Set<Int> {
    let numbers = amountCandidates()
    let aside = numbers.filter(isCountOrDay)
    return aside.count < numbers.count ? aside : []
  }

  /// Whether the number at `index` says how many or which day: a unit or a span of time behind
  /// it, or an English month in front of it.
  private func isCountOrDay(_ index: Int) -> Bool {
    let unit =
      index + 1 < words.count && !words[index + 1].claimed
      && Lexicon.wordsAfterACount.contains(words[index + 1].normalized)
    let month =
      index > 0 && !words[index - 1].claimed
      && Lexicon.monthsBeforeADay.contains(words[index - 1].normalized)
    return unit || month
  }

  /// How many neighbouring words one amount may span. A number grouped by spaces
  /// ("1 250 000,50") and a formula written with spaces around its signs both stay well
  /// inside this; the ceiling is what keeps a pasted wall of numbers from costing the
  /// square of its length in evaluated candidates.
  private static let amountWindow = 12

  /// Longest sub-run first, so "1 250,50" beats "1". A candidate must start with a word
  /// that holds a digit or an opening bracket: otherwise "кофе - 250" would become −250.
  /// A negative result is not an amount either — the sign of an operation comes from its
  /// kind, so "кофе 100-250" must not quietly save an expense of −150.
  ///
  /// A candidate that reads as a whole formula but cannot be an amount — it divides by zero,
  /// comes out negative or is larger than one amount may be — takes every shorter piece of
  /// itself down with it: "10" of "кофе 10 / 0" is not what was typed. A number next to it is
  /// still free to be the amount. When nothing is found, `amountProblem` says why.
  private mutating func readAmount(in run: ClosedRange<Int>) -> Bool {
    var refused: [Range<Int>] = []
    for length in stride(from: min(run.count, Self.amountWindow), through: 1, by: -1) {
      for start in run.lowerBound...(run.upperBound - length + 1) {
        let head = words[start].amountText
        guard head.contains(where: { ExpressionLexer.isDigit($0) || $0 == "(" }) else { continue }
        let range = start..<(start + length)
        guard
          !refused.contains(where: {
            $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound
          })
        else { continue }
        let candidate = range.map { words[$0].amountText }.joined(separator: " ")
        let value: Decimal
        do {
          value = try ExpressionEvaluator.evaluate(candidate)
        } catch {
          guard let problem = Self.problem(of: error) else {
            remember(.malformed)
            continue
          }
          remember(problem)
          refused.append(range)
          continue
        }
        guard value >= 0 else {
          remember(.negative)
          refused.append(range)
          continue
        }
        result.amount = value
        result.amountProblem = nil
        result.amountCanonicalText = ExpressionEvaluator.canonical(candidate)
        if ExpressionEvaluator.isFormula(candidate) {
          result.amountExpression = candidate
        }
        if candidate.first == "+" { readSignOfTheAmount() }
        claim(range, as: .amount, text: candidate)
        return true
      }
    }
    return false
  }

  /// A «+» in front of the amount is the sign of income wherever the amount stands: «кэшбэк
  /// +250» is income as «+250 кэшбэк» is. A kind word says more and keeps its kind; so do a
  /// goal and a debt, where «+5000» is what is added.
  private mutating func readSignOfTheAmount() {
    guard !claims.contains(where: { $0.role == .kind }), result.goalId == nil,
      result.debtId == nil
    else { return }
    result.kind = .income
  }

  /// A formula that was read whole but has no acceptable value; nil for one that cannot be
  /// read at all, which is what every too-long candidate of a run is.
  private static func problem(of error: any Error) -> ParsedInput.AmountProblem? {
    switch error as? CoreError {
    case .divisionByZero: .divisionByZero
    case .amountOutOfRange: .tooLarge
    default: nil
    }
  }

  /// Keeps the first reason a formula was refused; an unreadable one only until a readable
  /// one is refused.
  private mutating func remember(_ problem: ParsedInput.AmountProblem) {
    guard let kept = result.amountProblem else {
      result.amountProblem = problem
      return
    }
    if kept == .malformed, problem != .malformed { result.amountProblem = problem }
  }

  mutating func finish() -> ParsedInput {
    let leftovers: [(text: String, start: Int)] = words.compactMap { word in
      guard word.claimed else { return word.normalized.isEmpty ? nil : (word.original, word.start) }
      return word.ignoredCurrency.map { ($0, word.start) }
    }
    let note = leftovers.map(\.text).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    result.note = note
    if let first = leftovers.first, !note.isEmpty {
      claims.append(Claim(role: .note, text: note, start: first.start))
    }
    result.tokens =
      claims
      .sorted { $0.start < $1.start }
      .map { ParsedToken(role: $0.role, text: $0.text) }
    return result
  }

  // MARK: - Helpers

  private func isAmountish(_ word: InputWord) -> Bool {
    let text = word.amountText
    guard !text.isEmpty else { return false }
    let characters = Array(text)
    return characters.indices.allSatisfy { index in
      let character = characters[index]
      return ExpressionLexer.isDigit(character)
        || ExpressionLexer.operatorKind(character) != nil
        || ExpressionLexer.decimalSeparators.contains(character)
        || ExpressionLexer.thousandSuffixes.contains(character)
        || ExpressionLexer.isSpace(character)
        || ExpressionLexer.isGluedTimes(characters, at: index)
    }
  }

  /// Positions of the unclaimed words that still hold a number.
  private func amountCandidates() -> Set<Int> {
    var found: Set<Int> = []
    for index in words.indices where !words[index].claimed && isAmountish(words[index]) {
      if words[index].amountText.contains(where: ExpressionLexer.isDigit) { found.insert(index) }
    }
    return found
  }

  /// A time of day as written: "12:30", "9am", "11:45pm".
  private func isClockTime(_ text: String) -> Bool {
    var body = Substring(text)
    let meridiem = body.hasSuffix("am") || body.hasSuffix("pm")
    if meridiem { body = body.dropLast(2) }
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard allDigits(parts), (1...2).contains(parts[0].count) else { return false }
    switch parts.count {
    case 1: return meridiem
    case 2: return parts[1].count == 2
    default: return false
    }
  }

  /// What a word written as a date says: the day, or why the calendar has no such day.
  enum DateReading {
    case day(DateOnly)
    case problem(ParsedInput.DateProblem)
  }

  /// `today` / `сегодня` are handled by the phrase table; this reads the written forms:
  /// ISO `2026-09-12`, `12.09.2026`, `12.09.26` and the bare `12.09` (a two-digit month).
  ///
  /// A word is taken for a date by its shape: a day from 1 to 31 and a month from 1 to 12.
  /// Such a word whose day the month does not have — «31.09», «30.02», «2026-04-31», 29
  /// February of a common year — is a date all the same, one that cannot be: `.problem`, so
  /// the line says why instead of saving «31.09» as a price. A month above 12, a day of 0 or
  /// above 31 is no date at all — «12.13», «1.50», «0.09» stay numbers. `written` is the word as
  /// typed, for the reason.
  func dateReading(from text: String, written: String, allowDayMonth: Bool) -> DateReading? {
    let shown = TextNormalizer.trimmingEdgePunctuation(written)
    if text.contains("-") {
      let parts = text.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].count == 4, parts[1].count <= 2, parts[2].count <= 2,
        allDigits(parts), let year = Int(parts[0]), let month = Int(parts[1]),
        let day = Int(parts[2])
      else { return nil }
      return reading(year: year, month: month, day: day, written: shown)
    }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard allDigits(parts), parts[0].count <= 2 else { return nil }
    if parts.count == 3 {
      guard parts[1].count <= 2, let day = Int(parts[0]), let month = Int(parts[1]),
        var year = Int(parts[2])
      else { return nil }
      if parts[2].count <= 2 { year = nearestYear(endingIn: year) }
      return reading(year: year, month: month, day: day, written: shown)
    }
    // A bare day and month writes the month with two digits, the way the spec shows it
    // («12.09», and «1.09»): one digit after the point is a fraction — «молоко 1.5 90» is one
    // and a half, not the first of May.
    guard allowDayMonth, parts.count == 2, parts[1].count == 2,
      let day = Int(parts[0]), let month = Int(parts[1])
    else { return nil }
    // The year is the latest one that does not put the day into the future: this year when
    // the day and month are not after today's, else the last. 29 February of a year that has
    // none is not looked for years back: the line says that year has no such day.
    let year = (month, day) <= (today.month, today.day) ? today.year : today.year - 1
    return reading(year: year, month: month, day: day, written: shown)
  }

  /// A day and month shaped as a date: the day, the problem of a day the month lacks, or nil
  /// when the shape is not a date's.
  private func reading(year: Int, month: Int, day: Int, written: String) -> DateReading? {
    guard (1...12).contains(month), (1...31).contains(day), plausibleYears.contains(year) else {
      return nil
    }
    if let valid = validated(year: year, month: month, day: day) { return .day(valid) }
    if month == 2 && day == 29 {
      return .problem(.notInYear(day: day, month: month, year: year))
    }
    return .problem(.noSuchDate(written: written))
  }

  /// The years a written date may fall in: the window a two-digit year is read in
  /// (`nearestYear`), so «12.09.46» and «12.09.2046» are the same day. A year outside it is no
  /// operation's date — «ужин 2500-10-5» is a formula, not a dinner five centuries ahead —
  /// and the word is read as if it had never looked like a date.
  private var plausibleYears: ClosedRange<Int> {
    (today.year - 79)...(today.year + 20)
  }

  /// The year a two-digit year means: the one ending in those digits that lies no more than
  /// twenty years after this one and less than eighty before it, the window date parsers
  /// commonly use — «12.09.99» is 1999, «12.09.30» is 2030, never a century ahead.
  private func nearestYear(endingIn twoDigits: Int) -> Int {
    var year = today.year - today.year % 100 + twoDigits
    if year > today.year + 20 { year -= 100 }
    if year <= today.year - 80 { year += 100 }
    return year
  }

  private func allDigits(_ parts: [Substring]) -> Bool {
    !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(ExpressionLexer.isDigit) }
  }

  private func validated(year: Int, month: Int, day: Int) -> DateOnly? {
    guard (1...12).contains(month), day >= 1, year >= 1900, year <= 9999 else { return nil }
    guard day <= calendar.daysInMonth(MonthKey(year: year, month: month)) else { return nil }
    return DateOnly(year: year, month: month, day: day)
  }

  /// Recognises a currency written as a word, a code or a symbol, glued to the amount or
  /// standing on its own. Returns what is left of the word for the amount pass.
  private func currencyAffix(
    in raw: String
  ) -> (code: CurrencyCode, residual: String, text: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if let code = Lexicon.currencyWords[TextNormalizer.normalized(trimmed)] {
      return (CurrencyCode(code), "", trimmed)
    }
    let characters = Array(trimmed)
    if characters.count == 1, let code = Lexicon.currencySymbols[characters[0]] {
      return (CurrencyCode(code), "", trimmed)
    }
    if let code = Lexicon.currencySymbols[characters[0]] {
      let residual = String(characters.dropFirst())
      if residual.contains(where: ExpressionLexer.isDigit) {
        return (CurrencyCode(code), residual, String(characters[0]))
      }
    }
    // The sign of income written before the symbol: "+$500" is "+500" in dollars, as "+500$".
    let sign = ExpressionLexer.operatorKind(characters[0])
    if characters.count > 2, sign == .plus || sign == .minus,
      let code = Lexicon.currencySymbols[characters[1]]
    {
      let residual = String(characters[0]) + String(characters.dropFirst(2))
      if residual.contains(where: ExpressionLexer.isDigit) {
        return (CurrencyCode(code), residual, String(characters[1]))
      }
    }
    if let last = characters.last, let code = Lexicon.currencySymbols[last] {
      let residual = String(characters.dropLast())
      if residual.contains(where: ExpressionLexer.isDigit) {
        return (CurrencyCode(code), residual, String(last))
      }
    }
    var cut = characters.count
    while cut > 0, characters[cut - 1].isLetter { cut -= 1 }
    guard cut > 0, cut < characters.count else { return nil }
    let letters = String(characters[cut...])
    let residual = String(characters[..<cut])
    guard let code = Lexicon.currencyWords[TextNormalizer.normalized(letters)],
      residual.contains(where: ExpressionLexer.isDigit)
    else { return nil }
    return (CurrencyCode(code), residual, letters)
  }
}
