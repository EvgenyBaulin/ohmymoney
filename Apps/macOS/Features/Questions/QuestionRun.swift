import AppCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// A question understood and counted: how it was read, the figures, and whether the language
/// model had a hand in reading it. The figures are always the ledger's.
struct QuestionAnswered: Sendable {
  var resolved: ResolvedQuestion
  var answer: QuestionAnswer
  var viaModel = false
}

enum QuestionOutcome: Sendable {
  case answered(QuestionAnswered)
  case failed(QuestionFallback)
}

/// The on-device language model, behind a seam the tests replace. It is only ever asked to
/// turn the words of a question into a query (`ModelQueryInput`); what it says is checked
/// against the owner's names before any figure is made of it.
protocol QuestionModelGateway: Sendable {
  var availability: QuestionModelAvailability { get }
  func query(_ input: ModelQueryInput) async -> ModelQueryOutput?
}

/// What the system offers: Foundation Models on this device, if Apple Intelligence is on.
struct SystemQuestionModel: QuestionModelGateway {
  var availability: QuestionModelAvailability {
    #if canImport(FoundationModels)
      switch SystemLanguageModel.default.availability {
      case .available: return .available
      case .unavailable(let reason):
        switch reason {
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .deviceNotEligible: return .deviceNotEligible
        case .modelNotReady: return .notReady
        @unknown default: return .unsupported
        }
      @unknown default: return .unsupported
      }
    #else
      return .deviceNotEligible
    #endif
  }

  func query(_ input: ModelQueryInput) async -> ModelQueryOutput? {
    #if canImport(FoundationModels)
      guard availability == .available else { return nil }
      let session = LanguageModelSession()
      guard let reply = try? await session.respond(to: input.prompt) else { return nil }
      return ModelQueryOutput.decode(reply: reply.content)
    #else
      return nil
    #endif
  }
}

/// A gateway that is never there: the tests, and a device the model is not on.
struct NoQuestionModel: QuestionModelGateway {
  var availability: QuestionModelAvailability = .deviceNotEligible
  func query(_ input: ModelQueryInput) async -> ModelQueryOutput? { nil }
}

enum QuestionRun {
  /// From the line of text to an answer: the own parser first, the model only when the parser
  /// did not understand and the policy lets it (`QuestionModelPolicy`); when nothing did, the
  /// reason and the shapes that work.
  static func run(
    text: String, ledger: Ledger, today: DateOnly, gateway: any QuestionModelGateway
  ) async -> QuestionOutcome {
    let desk = QuestionDesk(ledger: ledger, today: today)
    switch desk.resolve(text) {
    case .success(let resolved):
      return .answered(
        QuestionAnswered(
          resolved: resolved, answer: desk.answerer.answer(resolved), viaModel: false))
    case .failure(let failure):
      let availability = gateway.availability
      if QuestionModelPolicy.shouldAskModel(
        text: text, failure: failure, availability: availability),
        let output = await gateway.query(
          ModelQueryInput(question: text, catalog: desk.catalog, today: today)),
        case .success(let resolved) = ModelQueryValidator.validate(
          output, catalog: desk.catalog, today: today)
      {
        return .answered(
          QuestionAnswered(
            resolved: resolved, answer: desk.answerer.answer(resolved), viaModel: true))
      }
      return .failed(QuestionFallback.make(for: failure, availability: availability))
    }
  }

  /// The same question counted again after the owner corrected a part of it.
  static func recount(
    _ resolved: ResolvedQuestion, ledger: Ledger, today: DateOnly, viaModel: Bool
  ) -> QuestionAnswered {
    QuestionAnswered(
      resolved: resolved,
      answer: QuestionAnswerer(ledger: ledger, today: today).answer(resolved),
      viaModel: viaModel)
  }
}
