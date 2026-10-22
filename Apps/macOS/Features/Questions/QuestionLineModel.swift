import AppCore
import Foundation
import Observation

/// The question line: the mode of the entry line in which Enter asks instead of writing, the
/// answer on screen, and the questions asked lately. It has no way to write an operation: it
/// holds the ledger's snapshot for reading and nothing else, so a question can never become a
/// spending (`QuestionLineGuard`).
@MainActor
@Observable
final class QuestionLineModel {
  enum Phase {
    case idle
    /// The data is not read yet, or the question is being counted.
    case asking
    case answered(QuestionAnswered)
    case failed(QuestionFallback)
  }

  /// The mode of the line, switched by a button; the text never switches it.
  private(set) var mode: EntryLineMode = .entry
  private(set) var phase: Phase = .idle
  private(set) var history: QuestionHistory
  /// What was asked, as typed, for «ещё раз» and the title of the card.
  private(set) var asked = ""

  @ObservationIgnored private let gateway: any QuestionModelGateway
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var task: Task<Void, Never>?

  init(
    gateway: any QuestionModelGateway = SystemQuestionModel(),
    defaults: UserDefaults = .standard
  ) {
    self.gateway = gateway
    self.defaults = defaults
    history = QuestionsStorage.loadHistory(defaults)
  }

  var isActive: Bool { mode == .question }

  /// What Enter does with the line in the mode it is in.
  var action: EntryLineAction { QuestionLineGuard.action(for: mode) }

  var availability: QuestionModelAvailability { gateway.availability }

  func setMode(_ mode: EntryLineMode) {
    guard mode != self.mode else { return }
    self.mode = mode
    if mode == .entry { clear() }
  }

  func toggle() { setMode(mode == .question ? .entry : .question) }

  /// The answer goes away, and a question still being counted is dropped.
  func clear() {
    task?.cancel()
    task = nil
    phase = .idle
    asked = ""
  }

  /// The line was edited: an answer to the earlier text stays until the next Enter, a failure
  /// goes.
  func textChanged() {
    if case .failed = phase { phase = .idle }
  }

  // MARK: Asking

  /// Asks `text` of the data the pipeline holds. Counted off the main thread; a newer question
  /// replaces the one still running. Without data yet it waits for the pipeline.
  func ask(_ text: String, compute: ComputeStore, now: Date = Date()) {
    guard let snapshot = compute.snapshot else {
      waiting = text
      phase = .asking
      return
    }
    waiting = nil
    ask(text, ledger: snapshot.ledger, today: snapshot.today, now: now)
  }

  /// The data arrived while a question waited for it: it is asked now.
  func askWaiting(compute: ComputeStore) {
    guard let text = waiting, compute.snapshot != nil else { return }
    ask(text, compute: compute)
  }

  @ObservationIgnored private var waiting: String?

  func ask(_ text: String, ledger: Ledger, today: DateOnly, now: Date = Date()) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    task?.cancel()
    asked = trimmed
    if !trimmed.isEmpty { remember(trimmed, now) }
    phase = .asking
    let gateway = gateway
    task = Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) {
        await QuestionRun.run(text: trimmed, ledger: ledger, today: today, gateway: gateway)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.finish(outcome)
    }
  }

  /// Waits for the answer in progress; the tests call this instead of sleeping.
  func settle() async {
    await task?.value
  }

  private func finish(_ outcome: QuestionOutcome) {
    switch outcome {
    case .answered(let answered): phase = .answered(answered)
    case .failed(let fallback): phase = .failed(fallback)
    }
  }

  private func remember(_ text: String, _ now: Date) {
    history = history.recording(text, at: now)
    QuestionsStorage.save(history, defaults)
  }

  func forget(_ item: QuestionHistory.Item) {
    history = history.removing(item)
    QuestionsStorage.save(history, defaults)
  }

  func clearHistory() {
    history = .empty
    QuestionsStorage.save(history, defaults)
  }

  // MARK: Correcting what was understood

  /// The answer on screen, if there is one.
  var answered: QuestionAnswered? {
    if case .answered(let answered) = phase { return answered }
    return nil
  }

  /// «Понял так: категория «Такси»» — another reading of a term.
  func choose(
    _ subject: QuestionSubject, forTermAt index: Int, ledger: Ledger, today: DateOnly
  ) {
    guard let current = answered else { return }
    recount(current.resolved.choosing(subject, forTermAt: index), current, ledger, today)
  }

  /// «прошлый месяц», «последние 30 дней» under the answer, or a period from the card.
  func choose(period: RelativePeriod, ledger: Ledger, today: DateOnly) {
    guard let current = answered else { return }
    recount(current.resolved.with(period: period), current, ledger, today)
  }

  func choose(measure: QuestionMeasure, ledger: Ledger, today: DateOnly) {
    guard let current = answered, current.resolved.measure != measure else { return }
    var resolved = current.resolved
    resolved.parsed.measure = measure
    recount(resolved, current, ledger, today)
  }

  private func recount(
    _ resolved: ResolvedQuestion, _ current: QuestionAnswered, _ ledger: Ledger, _ today: DateOnly
  ) {
    task?.cancel()
    let viaModel = current.viaModel
    task = Task { [weak self] in
      let counted = await Task.detached(priority: .userInitiated) {
        QuestionRun.recount(resolved, ledger: ledger, today: today, viaModel: viaModel)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.phase = .answered(counted)
    }
  }
}
