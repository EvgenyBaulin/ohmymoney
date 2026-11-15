import CoreKit
import Foundation

/// What a link to an electronic receipt (a message from a shop, an e-mail, a QR code that holds
/// a link instead of the fiscal fields) tells without opening the page.
public enum ReceiptLinkReading: Hashable, Sendable {
  /// The link carries the sum and the moment too: a receipt like one read from the paper code.
  case receipt(ReceiptQR)
  /// The link carries only the numbers that identify the receipt. No operation can be made of
  /// it (the page would have to be opened, which this app never does), but the receipt can be
  /// recognised as already recorded.
  case keyOnly(ReceiptNumbers)
}

public enum ReceiptLinkParser {
  /// Reads the first link in `text` that names a receipt. Nothing is fetched: only the address
  /// itself is looked at. Anything else — a loyalty or tip link, a tracking address, plain words
  /// — is `nil`.
  public static func read(_ text: String) -> ReceiptLinkReading? {
    for token in links(in: text) {
      if let reading = reading(ofLink: token) { return reading }
    }
    // A bare code (`t=…&s=…&fn=…`) is not a link, but the paper code parses the same way.
    if let receipt = ReceiptQRParser.parse(text) { return .receipt(receipt) }
    return nil
  }

  /// The words of `text` that start an address, cleaned of the brackets, quotes and sentence
  /// punctuation that mail and messages put around it.
  static func links(in text: String) -> [String] {
    let separators = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: "<>\"'()[]{}«»"))
    return text.components(separatedBy: separators).compactMap { word in
      let lowered = word.lowercased()
      guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
      var cleaned = word.replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&#38;", with: "&")
      while let last = cleaned.last, ".,;:!".contains(last) { cleaned.removeLast() }
      return cleaned
    }
  }

  private static func reading(ofLink link: String) -> ReceiptLinkReading? {
    // The query may sit after a `#` (a hash route) or before it; the fragment of a plain link
    // is not part of the last value.
    var address = link
    if let hash = address.firstIndex(of: "#") {
      let fragment = address[address.index(after: hash)...]
      address = fragment.contains("?") ? String(fragment) : String(address[..<hash])
    }
    if let receipt = ReceiptQRParser.parse(address) { return .receipt(receipt) }
    let values = query(of: address)
    if let numbers = ReceiptNumbers(
      fiscalDrive: values["fn"], documentNumber: values["i"], fiscalSign: values["fp"])
    {
      return .keyOnly(numbers)
    }
    return pathKey(of: address).map(ReceiptLinkReading.keyOnly)
  }

  /// `…/rec/<fn>/<i>/<fp>`: a sixteen-digit drive number followed by the document number and the
  /// sign. The drive number's length is what tells it from the numbers of any other address.
  private static func pathKey(of address: String) -> ReceiptNumbers? {
    guard let url = URL(string: address) else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    for index in parts.indices where index + 2 < parts.count {
      let drive = parts[index]
      guard drive.count == 16, drive.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
      if let numbers = ReceiptNumbers(
        fiscalDrive: drive, documentNumber: parts[index + 1], fiscalSign: parts[index + 2])
      {
        return numbers
      }
    }
    return nil
  }

  private static func query(of address: String) -> [String: String] {
    guard let question = address.lastIndex(of: "?") else { return [:] }
    var values: [String: String] = [:]
    for pair in address[address.index(after: question)...].split(separator: "&") {
      let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard halves.count == 2 else { continue }
      let key = halves[0].trimmingCharacters(in: .whitespaces).lowercased()
      if values[key] == nil {
        values[key] = (String(halves[1]).removingPercentEncoding ?? String(halves[1]))
          .trimmingCharacters(in: .whitespaces)
      }
    }
    return values
  }
}
