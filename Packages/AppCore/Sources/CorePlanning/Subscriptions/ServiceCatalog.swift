import CoreKit
import Foundation

/// The kind of service a subscription is, for finding two of the same kind.
public enum ServiceType: String, Hashable, Sendable, Codable, CaseIterable {
  case music
  case video
  case cloud
  case books
  case assistant
  /// A type the owner may pick; it never groups anything.
  case other

  /// The key the app looks the word up by.
  public var key: String { "subscriptions.type." + rawValue }
}

/// A small built-in list of services by type. It is data of the release: it grows with
/// `version`, and the owner's own type always beats it.
public enum ServiceCatalog {
  /// Raised whenever the list changes.
  public static let version = 1

  /// Lowercased fragments of a name; the first type with a fragment inside the name wins.
  static let entries: [(type: ServiceType, fragments: [String])] = [
    (
      .music,
      [
        "яндекс музыка", "yandex music", "vk музыка", "vk music", "вк музыка", "spotify",
        "apple music", "youtube music", "звук", "zvuk", "deezer", "tidal", "boom",
      ]
    ),
    (
      .video,
      [
        "кинопоиск", "kinopoisk", "иви", "ivi", "okko", "netflix", "premier", "wink", "more.tv",
        "disney", "hbo", "youtube premium", "apple tv", "start", "kion",
      ]
    ),
    (
      .cloud,
      [
        "icloud", "google one", "google drive", "яндекс диск", "яндекс 360", "yandex 360",
        "yandex disk", "dropbox", "onedrive", "облако mail", "mail.ru cloud",
      ]
    ),
    (
      .books,
      ["литрес", "litres", "bookmate", "яндекс книги", "mybook", "storytel", "audible", "patefon"]
    ),
    (
      .assistant,
      ["chatgpt", "openai", "claude", "anthropic", "gemini", "copilot", "perplexity", "midjourney"]
    ),
  ]

  /// The type of a service by its name: the owner's own when he set one, else the catalogue's,
  /// else `nil`.
  public static func type(of name: String, override: ServiceType? = nil) -> ServiceType? {
    if let override { return override }
    let folded = name.lowercased()
    for entry in entries where entry.fragments.contains(where: { matches($0, in: folded) }) {
      return entry.type
    }
    return nil
  }

  /// A fragment of up to four letters would match inside any word («иви» in «привилегия»):
  /// short ones must stand as whole words.
  private static func matches(_ fragment: String, in text: String) -> Bool {
    guard fragment.count <= 5, !fragment.contains(" ") else { return text.contains(fragment) }
    let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "." }.map(String.init)
    return words.contains(fragment)
  }
}
