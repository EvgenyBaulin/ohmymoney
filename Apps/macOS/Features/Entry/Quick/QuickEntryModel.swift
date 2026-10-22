import AppCore
import AppDatabase
import Foundation
import Observation

/// The quick-entry helpers of the entry line, kept in one place so the bar itself only asks
/// them three things: what changed in the line (a paste, a word being typed), what Return means
/// for this line (a correction, a list with «;», a tip, «повторить вчера»), and what was
/// written. Everything it offers shows above the line in `QuickEntryStrip`; every sheet it asks
/// for is presented by `quickEntrySheets`.
@MainActor
@Observable
final class QuickEntryModel {
  // MARK: What is offered

  /// A text of a bank was pasted: what it said, and what is asked about its card.
  var bank: BankOffer?
  /// «ой, 350»: the corrected operation waits for «Исправить».
  var correction: QuickCorrection.Offer?
  /// Why the last thing did not happen (key of table «QuickEntry»).
  var failure: String?
  /// What was done, in the words of the interface, until the next keystroke.
  var notice: String?
  /// The places that begin like the word being typed, and the word they complete.
  var suggestions: [PlaceSuggestion] = []
  var suggestionPrefix: String?
  /// The parts of a «;» line that wait their turn, each written like a line of its own.
  var waitingParts: [String] = []
  /// The tip of a line «кафе 2000 чай 200», added as a part when the line is written.
  var tip: TipReading?
  /// The part the tip was laid as, and the bill without it (`applyTip`).
  @ObservationIgnored var tipPartId: UUID?
  @ObservationIgnored var tipBase: AmountE4?

  // MARK: Sheets

  var billList: BillList?
  var repeatRequest: RepeatRequest?
  var cardAsk: CardAsk?
  var showsDrafts = false
  var showsReconcile = false

  let drafts = DraftsModel()

  @ObservationIgnored private var historyCache: (version: Int, history: [PlacePurchase])?

  // MARK: Requests (sheets)

  struct BillList: Identifiable {
    let id = UUID()
    var candidates: [BankImportCandidate]
    var skipped: Int
  }

  struct RepeatRequest: Identifiable {
    let id = UUID()
    var proposals: [RepeatProposal]
    var day: DateOnly
  }

  /// «Какая это карта?»: the digits of a text no card has yet.
  struct CardAsk: Identifiable {
    let id = UUID()
    var last4: String
    var candidates: [CardDigits]
  }

  // MARK: The line changed

  /// The line changed from `old` to `new`. A chunk of a text of a bank is read as the owner's
  /// answers say: one text fills the line with what it says, a list opens the sheet with ticks,
  /// anything else stays as pasted. Returns the text the line should hold instead, or `nil`.
  func lineChanged(
    old: String, new: String, environment: AppEnvironment, compute: ComputeStore
  ) -> String? {
    failure = nil
    if new.isEmpty {
      // What was just done stays on show until the next line is started.
      bank = nil
      correction = nil
      suggestions = []
      suggestionPrefix = nil
      tip = nil
      tipPartId = nil
      tipBase = nil
      return nil
    }
    notice = nil
    if let chunk = QuickPaste.inserted(old: old, new: new) {
      switch QuickPaste.decide(chunk: chunk, today: environment.today) {
      case .plain:
        break
      case .message(let message):
        let offer = QuickBank.offer(
          for: message, cards: compute.snapshot?.dataset.cards ?? [],
          places: environment.vocabulary.places, parser: parser(environment),
          today: environment.today)
        bank = offer
        suggestions = []
        return offer.line
      case .list(let items):
        let candidates = QuickBank.candidates(
          items, entries: compute.snapshot?.dataset.entries ?? [],
          calendar: environment.calendar, today: environment.today)
        guard !candidates.isEmpty else { return nil }
        billList = BillList(
          candidates: candidates, skipped: items.count - candidates.count)
        return old
      }
    }
    updateSuggestions(for: new, environment: environment, compute: compute)
    return nil
  }

  private func updateSuggestions(
    for line: String, environment: AppEnvironment, compute: ComputeStore
  ) {
    guard let snapshot = compute.snapshot, let prefix = QuickSuggest.prefix(of: line) else {
      suggestions = []
      suggestionPrefix = nil
      return
    }
    let version = snapshot.version.cacheKey
    if historyCache?.version != version {
      historyCache = (version, QuickEntryFacade.placeHistory(snapshot))
    }
    suggestionPrefix = prefix
    suggestions = PlaceSuggestions.suggest(
      prefix: prefix, places: environment.vocabulary.places,
      history: historyCache?.history ?? [], limit: 4)
  }

  func choose(_ suggestion: PlaceSuggestion, in line: String) -> String {
    let result = QuickSuggest.line(
      afterChoosing: suggestion, in: line, prefix: suggestionPrefix ?? "")
    suggestions = []
    return result
  }

  /// The data the screens read, or — before the first read has landed — the latest operations
  /// of the database: a correction or a repeat asked at once after the start still has its
  /// answer.
  private func dataset(_ environment: AppEnvironment, _ compute: ComputeStore) -> Dataset {
    if let dataset = compute.snapshot?.dataset { return dataset }
    return Dataset(entries: (try? environment.transactions?.recentEntries(limit: 2_000)) ?? [])
  }

  func parser(_ environment: AppEnvironment) -> InputLineParser {
    InputLineParser(
      vocabulary: environment.vocabulary, calendar: environment.calendar,
      catalog: environment.currencyCatalog)
  }

  // MARK: Return

  enum Interception: Equatable {
    /// Carry on with this text as the line (it may be a part of the one typed); the field is
    /// changed to it when `replacesText`.
    case proceed(String, replacesText: Bool)
    /// The line was taken: a question, a sheet or a refusal shows above it.
    case handled
  }

  /// What Return means for `text`. A correction asks first; «повторить вчера» opens its sheet;
  /// a «;» line is written part by part, the first now; a tip is remembered for the commit.
  func intercept(
    _ text: String, environment: AppEnvironment, compute: ComputeStore
  ) -> Interception {
    failure = nil
    let kind = QuickLine.classify(text, parser: parser(environment), today: environment.today)
    switch kind {
    case .ordinary:
      tip = nil
      return .proceed(text, replacesText: false)
    case .correction(let correction):
      switch QuickCorrection.outcome(
        for: correction, in: dataset(environment, compute), now: environment.now())
      {
      case .offer(let offer): self.correction = offer
      case .nothingToCorrect: failure = "quick.correction.none"
      case .refused(let refusal): failure = QuickCorrection.key(of: refusal)
      }
      return .handled
    case .repeatYesterday:
      openRepeat(
        from: environment.calendar.adding(days: -1, to: environment.today), environment, compute)
      return .handled
    case .several(let parts, _):
      waitingParts = Array(parts.dropFirst())
      tip = nil
      return .proceed(parts[0], replacesText: true)
    case .tip(let reading):
      tip = reading
      return .proceed(reading.baseLine, replacesText: false)
    }
  }

  /// Whether a «;» line still has parts waiting to be written.
  var hasNextPart: Bool { !waitingParts.isEmpty }

  /// The next part of a «;» line, once the one before it is written.
  func nextPart() -> String? {
    guard !waitingParts.isEmpty else { return nil }
    return waitingParts.removeFirst()
  }

  func dropWaitingParts() { waitingParts = [] }

  // MARK: Correction

  /// «Исправить»: the operation is written again with the new amount, one step of ⌘Z.
  @discardableResult
  func applyCorrection(environment: AppEnvironment, store: TransactionsStore) -> Bool {
    guard let offer = correction else { return false }
    correction = nil
    switch store.saveEdit(offer.after, calendar: environment.calendar) {
    case .saved:
      notice = QuickText.t("quick.correction.done", environment)
      return true
    default:
      failure = "quick.correction.failed"
      return false
    }
  }

  // MARK: Repeat yesterday

  func openRepeat(
    from source: DateOnly, _ environment: AppEnvironment, _ compute: ComputeStore
  ) {
    let proposals = RepeatDay.proposals(
      from: dataset(environment, compute).entries, on: source, to: environment.today,
      calendar: environment.calendar)
    guard !proposals.isEmpty else {
      failure = "quick.repeat.none"
      return
    }
    repeatRequest = RepeatRequest(proposals: proposals, day: source)
  }

  // MARK: Writing several operations as one step

  /// Writes the drafts as new operations in one write and one ⌘Z. Drafts whose rate is missing
  /// are left out and counted. Returns how many were written and how many were not.
  func write(
    _ drafts: [TransactionDraft], environment: AppEnvironment, store: TransactionsStore
  ) -> (written: Int, left: Int) {
    var entries: [TransactionEntry] = []
    var left = 0
    for var draft in drafts {
      environment.applyRate(to: &draft)
      do {
        entries.append(
          try draft.materialize(
            now: environment.now(), rublesConverter: environment.rublesConverter(for: draft)))
      } catch {
        left += 1
      }
    }
    guard !entries.isEmpty else { return (0, left) }
    guard store.apply(PlanningChange(created: entries, at: environment.now())) else {
      return (0, drafts.count)
    }
    return (entries.count, left)
  }

  // MARK: A list from the bank

  /// The drafts of the ticked pieces of a pasted list, each filed as the entry line files its
  /// own: the category the history and the model give, «Не помню» when they give none.
  func drafts(
    for candidates: [BankImportCandidate], environment: AppEnvironment, compute: ComputeStore
  ) -> [TransactionDraft] {
    var result: [TransactionDraft] = []
    for candidate in candidates where candidate.isSelected {
      let message = candidate.message
      let offer = QuickBank.offer(
        for: message, cards: compute.snapshot?.dataset.cards ?? [],
        places: environment.vocabulary.places, parser: parser(environment),
        today: environment.today)
      let model = EntryDraftModel(environment: environment)
      model.assisted = true
      model.reload()
      model.prepareForPanel(today: environment.today)
      let reading = CoreLineInterpreter(
        vocabulary: environment.vocabulary, calendar: environment.calendar,
        catalog: environment.currencyCatalog
      ).read(offer.line, today: environment.today, kind: nil)
      guard let typed = reading.parsed.amount, let amount = try? AmountE4(decimal: typed)
      else { continue }
      model.apply(reading, amount: amount, today: environment.today, text: offer.line)
      if let day = message.day {
        let time = message.time ?? environment.calendar.timeOfDay(environment.now())
        model.draft.occurredAt = environment.calendar.moment(
          day, hour: time.hour, minute: time.minute)
      } else if let time = message.time {
        model.draft.occurredAt = environment.calendar.moment(
          environment.today, hour: time.hour, minute: time.minute)
      }
      let wanted: CategoryKind = model.draft.kind == .income ? .income : .expense
      if model.gapToAsk() == .category,
        let unknown = model.categories.first(where: {
          $0.systemRole == .unknown && $0.kind == wanted
        })
      {
        model.draft.parts[0].categoryId = unknown.id
      }
      result.append(model.draftForSaving)
    }
    return result
  }

  // MARK: Drafts

  /// «Запишу потом» for the line.
  func keepForLater(_ text: String, environment: AppEnvironment) -> Bool {
    let kept = drafts.keep(text, now: environment.now())
    if kept {
      notice = QuickText.t("quick.draft.kept", environment)
    } else {
      failure = "quick.draft.failed"
    }
    return kept
  }
}
