import AppCore
import Foundation
import FoundationModels
import NaturalLanguage
import Translation

/// The English name of a category made on the device: the system's language model where Apple
/// Intelligence is on, else the system's translator with a language the system has already
/// downloaded. Neither goes to the network on the app's behalf: the model is the on-device one
/// (never the cloud one), and a translator session made for installed languages never downloads
/// a language — a missing one leaves the name for a later pass.
struct AppleCategoryTranslator: CategoryNameTranslating {
  private static let english = Locale.Language(identifier: "en")

  /// The words the model is given before every name. The owner's names come in any language,
  /// with typos and words of their own; the answer is one name and nothing else.
  static let instructions = """
    You turn the name of a category of a personal finance app into its English name. \
    The name may be in any language, may have a typo or be a word of the owner's own: \
    answer with the most likely English name of such a category, one to four words, \
    with no quotes, no full stop and no explanation. If the name is already English, \
    repeat it with the typo fixed.
    """

  func isAvailable() async -> Bool {
    if Self.modelIsAvailable { return true }
    let availability = LanguageAvailability()
    for source in Self.sources(for: nil) {
      if await availability.status(from: source, to: Self.english) == .installed { return true }
    }
    return false
  }

  func english(for name: String) async -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if Self.modelIsAvailable, let answer = await Self.askModel(trimmed) { return answer }
    return await Self.translate(trimmed)
  }

  // MARK: The model

  private static var modelIsAvailable: Bool {
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
  }

  private static func askModel(_ name: String) async -> String? {
    let session = LanguageModelSession(instructions: instructions)
    guard let response = try? await session.respond(to: name) else { return nil }
    return response.content
  }

  // MARK: The translator

  private static func translate(_ name: String) async -> String? {
    // A name in English already is its own English name.
    if NLLanguageRecognizer.dominantLanguage(for: name) == .english { return name }
    let availability = LanguageAvailability()
    for source in sources(for: name) {
      guard await availability.status(from: source, to: english) == .installed else { continue }
      let session = TranslationSession(installedSource: source, target: english)
      if let response = try? await session.translate(name) { return response.targetText }
    }
    return nil
  }

  /// The languages other than English the name may be in, the likeliest first: what the name
  /// itself says (a short name says little), then the languages of the owner's system, then
  /// Russian — the language of the owner the app was made for.
  static func sources(for name: String?) -> [Locale.Language] {
    var codes: [String] = []
    if let name {
      let recognizer = NLLanguageRecognizer()
      recognizer.processString(name)
      let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        .filter { $0.value >= 0.2 }
        .sorted { $0.value > $1.value }
      codes += hypotheses.map(\.key.rawValue)
    }
    codes += Locale.preferredLanguages.compactMap {
      Locale.Language(identifier: $0).languageCode?.identifier
    }
    codes.append("ru")
    var seen: Set<String> = ["en"]
    return codes.compactMap { code in
      let base = Locale.Language(identifier: code).languageCode?.identifier ?? code
      guard seen.insert(base).inserted else { return nil }
      return Locale.Language(identifier: base)
    }
  }
}
