import CoreKit
import Foundation

/// What the entry line is for at the moment. A question is asked in its own mode, switched
/// by a button, so a line that happens to read like a question («сколько кофе 250») is
/// never taken for one, and a question is never taken for an expense.
public enum EntryLineMode: String, Hashable, Sendable, Codable, CaseIterable {
  case entry
  case question
}

/// What Enter does with the line.
public enum EntryLineAction: Hashable, Sendable {
  /// Parse the line as an operation and write it (after the usual questions).
  case recordEntry
  /// Answer the line. No operation is ever written.
  case askQuestion
}

public enum QuestionLineGuard {
  /// The mode alone decides. The text never does: that is the whole point of the mode.
  public static func action(for mode: EntryLineMode) -> EntryLineAction {
    mode == .question ? .askQuestion : .recordEntry
  }

  /// In the entry mode, should the line offer to switch to the question mode? A nudge that
  /// changes nothing by itself: it asks, it never switches and never reads the line as one.
  public static func offersQuestionMode(text: String, mode: EntryLineMode) -> Bool {
    mode == .entry && QuestionParser.looksLikeQuestion(text)
  }
}

// MARK: - When the free-form model may be asked

/// What the system says about the on-device language model.
public enum QuestionModelAvailability: String, Hashable, Sendable, Codable, CaseIterable {
  case available
  /// Apple Intelligence is switched off in the system settings.
  case notEnabled
  /// This Mac cannot run it.
  case deviceNotEligible
  /// The model is still being downloaded.
  case notReady
  /// The region or the language is not supported.
  case unsupported
}

public enum QuestionLanguage: String, Hashable, Sendable {
  case russian
  case english
  case other

  /// The script the question is mostly written in.
  public static func detect(_ text: String) -> QuestionLanguage {
    var cyrillic = 0
    var latin = 0
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x0400...0x04FF: cyrillic += 1
      case 0x41...0x5A, 0x61...0x7A: latin += 1
      default: break
      }
    }
    if cyrillic == 0, latin == 0 { return .other }
    return cyrillic >= latin ? .russian : .english
  }
}

public enum QuestionModelPolicy {
  /// The model is asked only when the own parser did not understand, the model is
  /// available, and the question is in English: it does not read Russian well enough to be
  /// trusted with a figure, and the templates cover Russian.
  public static func shouldAskModel(
    text: String, failure: QuestionFailure, availability: QuestionModelAvailability
  ) -> Bool {
    failure == .notUnderstood && availability == .available
      && QuestionLanguage.detect(text) == .english
  }
}

// MARK: - When nothing understood the question

/// Why the app could not answer and what to try, as keys of the string catalogue.
public struct QuestionFallback: Hashable, Sendable {
  /// «Не понял вопрос.»
  public var messageKey: String
  /// Shapes that work: «сколько на … в …», «сравни … с …».
  public var exampleKeys: [String]
  /// How to turn the model on, or why it is not there; `nil` when it needs no word.
  public var hintKey: String?

  public init(messageKey: String, exampleKeys: [String], hintKey: String?) {
    self.messageKey = messageKey
    self.exampleKeys = exampleKeys
    self.hintKey = hintKey
  }

  public static let examples = [
    "question.example.howMuch", "question.example.compare", "question.example.whatGrew",
  ]

  public static func make(
    for failure: QuestionFailure, availability: QuestionModelAvailability
  ) -> QuestionFallback {
    switch failure {
    case .empty:
      return QuestionFallback(
        messageKey: "question.fallback.empty", exampleKeys: examples, hintKey: nil)
    case .notUnderstood:
      let hint: String?
      switch availability {
      case .available: hint = nil
      case .notEnabled: hint = "question.hint.enableAppleIntelligence"
      case .deviceNotEligible: hint = "question.hint.deviceNotEligible"
      case .notReady: hint = "question.hint.modelNotReady"
      case .unsupported: hint = "question.hint.modelUnsupported"
      }
      return QuestionFallback(
        messageKey: "question.fallback.notUnderstood", exampleKeys: examples, hintKey: hint)
    }
  }
}
