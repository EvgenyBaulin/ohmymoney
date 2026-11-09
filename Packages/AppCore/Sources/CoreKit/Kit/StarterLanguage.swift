import Foundation

/// Languages available for the first-launch category data and entry-line vocabulary.
public enum StarterLanguage: String, CaseIterable, Sendable, Hashable {
  case ru, en, uk, be, kk, uz, ky, tg, hy, ka, az, de, fr, es, it
  case portuguesePortugal = "pt-PT"
  case pl, cs, nl, tr
  case chineseSimplified = "zh-Hans"
  case chineseTraditional = "zh-Hant"
  case ja, ko, vi, id, th, hi
  case portugueseBrazil = "pt-BR"
  case ar, he

  /// Accepts language tags and system locale identifiers; unsupported languages use English.
  public init(identifier: String) {
    let tag = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    let parts = tag.split(separator: "-").map(String.init)
    if parts.first == "pt" {
      self = parts.contains("br") ? .portugueseBrazil : .portuguesePortugal
    } else if parts.first == "zh" {
      self =
        parts.contains("hant") || !Set(parts).isDisjoint(with: ["tw", "hk", "mo"])
        ? .chineseTraditional : .chineseSimplified
    } else {
      self = Self(rawValue: parts.first ?? "") ?? .en
    }
  }

  public var translationVerification: TranslationVerification {
    self == .ru || self == .en ? .original : .notVerifiedByNativeSpeaker
  }
}

/// Quality metadata travels with the seed text, rather than becoming part of a category name.
public enum TranslationVerification: String, Sendable, Hashable {
  case original
  case notVerifiedByNativeSpeaker = "not verified by a native speaker"
}

public struct StarterTranslation: Sendable, Hashable {
  public let text: String
  public let verification: TranslationVerification

  public init(text: String, verification: TranslationVerification) {
    self.text = text
    self.verification = verification
  }
}
