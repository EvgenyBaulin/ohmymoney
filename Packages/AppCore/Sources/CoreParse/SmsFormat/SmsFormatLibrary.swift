import CoreKit
import Foundation

/// Where a format came from, in order of precedence: the owner's own beat the ones read from a
/// folder the owner chose, and those beat the ones the app is built with.
public enum SmsFormatSource: Int, Hashable, Sendable, Comparable, CaseIterable {
  case own
  case folder
  case builtIn

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A format in the library with what is known about its bank.
public struct SmsFormatEntry: Sendable {
  public var source: SmsFormatSource
  public var compiled: SmsCompiledFormat
  /// Names the bank texts come from; empty — any sender fits.
  public var senders: [String]
  public var bankName: String?

  public init?(
    _ format: SmsFormat, source: SmsFormatSource, senders: [String] = [], bankName: String? = nil
  ) {
    guard let compiled = SmsCompiledFormat(format) else { return nil }
    self.source = source
    self.compiled = compiled
    self.senders = senders
    self.bankName = bankName
  }

  public var format: SmsFormat { compiled.format }

  func fits(sender: String?) -> Bool {
    guard let sender, !senders.isEmpty else { return true }
    let key = sender.lowercased().filter { $0.isLetter || $0.isNumber }
    return senders.contains { $0.lowercased().filter { $0.isLetter || $0.isNumber } == key }
  }
}

/// One of the formats that read a text, when more than one in the same tier did.
public struct SmsFormatCandidate: Hashable, Sendable {
  public var formatId: String
  public var source: SmsFormatSource
  public var bankName: String?
  public var reading: SmsFormatReading
}

/// What the library makes of a text.
public enum SmsFormatOutcome: Sendable {
  /// One format (or several that read it the same) gave an operation.
  case operation(BankMessage)
  /// A format knows the text and it creates nothing — a code, an advert, a balance alone.
  case informational(SmsFormatReading)
  /// Two formats of the same tier read the text differently: the owner picks, once.
  case ambiguous([SmsFormatCandidate])
  /// No format fits; the general scan is for the caller.
  case noFormat
}

/// The pick the owner made between formats that both fit a text, remembered so the question is
/// asked once. The key is the set of formats, not the text.
public struct SmsFormatChoices: Hashable, Sendable, Codable {
  public static let settingsKey = "autoEntry.formatChoices"

  public private(set) var picks: [String: String] = [:]

  public init() {}

  static func key(for ids: [String]) -> String { ids.sorted().joined(separator: "|") }

  public func pick(among ids: [String]) -> String? {
    picks[Self.key(for: ids)].flatMap { ids.contains($0) ? $0 : nil }
  }

  public mutating func remember(_ pick: String, among ids: [String]) {
    guard ids.contains(pick) else { return }
    picks[Self.key(for: ids)] = pick
  }

  public func encoded() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
  }

  public static func decoded(_ text: String?) -> SmsFormatChoices {
    guard let data = text?.data(using: .utf8),
      let value = try? JSONDecoder().decode(SmsFormatChoices.self, from: data)
    else { return SmsFormatChoices() }
    return value
  }
}

/// All the formats at hand, in the order of precedence.
public struct SmsFormatLibrary: Sendable {
  public var entries: [SmsFormatEntry]

  public init(entries: [SmsFormatEntry] = []) {
    self.entries = entries
  }

  /// The formats of the app: compiled once.
  public static let builtIn = SmsFormatLibrary(
    entries: SmsBuiltInFormats.formats.compactMap { SmsFormatEntry($0, source: .builtIn) })

  /// This library with `more` added.
  public func adding(_ more: [SmsFormatEntry]) -> SmsFormatLibrary {
    SmsFormatLibrary(entries: entries + more)
  }

  /// The longest text a bank sends.
  static let longestText = 4_000

  public func outcome(
    for text: String, sender: String? = nil, choices: SmsFormatChoices = SmsFormatChoices(),
    today: DateOnly? = nil, defaultCurrency: CurrencyCode = .rub
  ) -> SmsFormatOutcome {
    guard !entries.isEmpty, !text.isEmpty, text.count <= Self.longestText else { return .noFormat }
    var byTier: [SmsFormatSource: [SmsFormatCandidate]] = [:]
    for entry in entries where entry.fits(sender: sender) {
      guard case .success(let reading)? = entry.compiled.read(
        text, defaultCurrency: defaultCurrency, today: today)
      else { continue }
      byTier[entry.source, default: []].append(
        SmsFormatCandidate(
          formatId: entry.format.id, source: entry.source, bankName: entry.bankName,
          reading: reading))
    }
    for tier in SmsFormatSource.allCases {
      guard var found = byTier[tier], !found.isEmpty else { continue }
      // Two formats that read the same figures are one reading, not a question.
      var seen: [SmsFormatReading] = []
      found = found.filter { candidate in
        var neutral = candidate.reading
        neutral.formatId = ""
        neutral.bank = .unknown
        guard !seen.contains(neutral) else { return false }
        seen.append(neutral)
        return true
      }
      var chosen = found.first
      if found.count > 1 {
        let ids = found.map(\.formatId)
        guard let picked = choices.pick(among: ids),
          let candidate = found.first(where: { $0.formatId == picked })
        else { return .ambiguous(found) }
        chosen = candidate
      }
      guard let reading = chosen?.reading else { continue }
      if let message = reading.message(source: text) { return .operation(message) }
      return .informational(reading)
    }
    return .noFormat
  }
}
