import CoreKit
import Foundation

/// Metadata found in the requested HTML. An image is an address, never a request to fetch it.
public struct ProductPageMetadata: Hashable, Sendable {
  public var name: String?
  public var priceE4: AmountE4?
  public var currency: CurrencyCode?
  public var imageURL: URL?

  public init(
    name: String? = nil, priceE4: AmountE4? = nil, currency: CurrencyCode? = nil,
    imageURL: URL? = nil
  ) {
    self.name = name
    self.priceE4 = priceE4
    self.currency = currency
    self.imageURL = imageURL
  }

  /// A partial page leaves existing values alone. A price requires its currency alongside it.
  public func applying(to original: Wish) -> Wish {
    var wish = original
    if let name { wish.name = name }
    if let priceE4, let currency {
      wish.priceE4 = priceE4
      wish.currency = currency
    }
    return wish
  }
}

/// Pure extraction from one supplied page; no scripts, linked documents or images are loaded.
public enum ProductPageParser {
  public static func parse(_ html: String, pageURL: URL) -> ProductPageMetadata? {
    let withoutComments = removing("(?s)<!--.*?-->", from: html)
    let markup = removing(
      "(?is)<(?:script|style)\\b[^>]*>.*?</(?:script|style)\\s*>",
      from: withoutComments)
    var graph: [String: String] = [:]
    for match in matches("(?is)<meta\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>", markup) {
      let attributes = attributes(match[1])
      if let key = attributes["property"] ?? attributes["name"],
        let content = attributes["content"]
      {
        graph[key.lowercased()] = unescape(content)
      }
    }
    var result = metadata(
      name: graph["og:title"], price: graph["product:price:amount"] ?? graph["og:price:amount"],
      currency: graph["product:price:currency"] ?? graph["og:price:currency"],
      image: graph["og:image"] ?? graph["og:image:url"], pageURL: pageURL)
    for script in matches("(?is)<script\\b([^>]*)>(.*?)</script\\s*>", withoutComments) {
      guard attributes(script[1])["type"]?.lowercased() == "application/ld+json",
        let data = script[2].data(using: .utf8),
        let node = try? JSONDecoder().decode(Node.self, from: data),
        let product = product(in: node)
      else { continue }
      let offers = product["offers"]?.objects.first
      let structured = metadata(
        name: product["name"]?.text,
        price: offers?["price"]?.text ?? offers?["lowPrice"]?.text,
        currency: offers?["priceCurrency"]?.text,
        image: product["image"]?.image, pageURL: pageURL)
      result = merging(structured, over: result)
      break
    }
    result = merging(result, over: microdata(markup, pageURL: pageURL))
    guard result.name != nil || result.priceE4 != nil || result.imageURL != nil else { return nil }
    return result
  }

  private static func merging(
    _ preferred: ProductPageMetadata, over fallback: ProductPageMetadata
  ) -> ProductPageMetadata {
    let hasPrice = preferred.priceE4 != nil && preferred.currency != nil
    let fallbackPrice = fallback.priceE4 != nil && fallback.currency != nil
    return ProductPageMetadata(
      name: preferred.name ?? fallback.name,
      priceE4: hasPrice ? preferred.priceE4 : (fallbackPrice ? fallback.priceE4 : nil),
      currency: hasPrice ? preferred.currency : (fallbackPrice ? fallback.currency : nil),
      imageURL: preferred.imageURL ?? fallback.imageURL)
  }

  private static func metadata(
    name: String?, price: String?, currency: String?, image: String?, pageURL: URL
  ) -> ProductPageMetadata {
    let code = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let validCode = code.flatMap {
      matches("^[A-Z]{3}$", $0).isEmpty ? nil : CurrencyCode($0)
    }
    let value = price?.trimmingCharacters(in: .whitespacesAndNewlines)
    let amount = value.flatMap { text -> AmountE4? in
      guard !matches("^[0-9]+(?:[.,][0-9]{1,4})?$", text).isEmpty,
        let decimal = Decimal(
          string: text.replacingOccurrences(of: ",", with: "."),
          locale: Locale(identifier: "en_US_POSIX")), decimal >= 0
      else { return nil }
      return try? AmountE4(decimal: decimal)
    }
    let title = name.map(unescape)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = image.flatMap { URL(string: unescape($0), relativeTo: pageURL)?.absoluteURL }
    let safeImage = url.flatMap { url -> URL? in
      guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, url.user == nil, url.password == nil
      else { return nil }
      return url
    }
    return ProductPageMetadata(
      name: title?.isEmpty == false ? title : nil,
      priceE4: validCode == nil ? nil : amount, currency: amount == nil ? nil : validCode,
      imageURL: safeImage)
  }

  private static func microdata(_ html: String, pageURL: URL) -> ProductPageMetadata {
    // Only the first Product scope supplies fields. Offers may be nested inside that scope.
    let tokens = matches(
      "(?is)<(/?)([a-z][a-z0-9:-]*)\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>([^<]*)", html)
    var depth = 0
    var productDepth: Int?
    var ignoredDepth: Int?
    var titleDepth: Int?
    var titleParts: [String] = []
    var values: [String: String] = [:]
    let voidTags: Set<String> = [
      "meta", "img", "link", "input", "br", "hr", "source", "area", "embed", "wbr",
    ]
    for token in tokens {
      let tag = token[2].lowercased()
      if token[1] == "/" {
        depth = max(0, depth - 1)
        if let titleDepth {
          if depth < titleDepth {
            values["name"] = titleParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
          } else {
            titleParts.append(unescape(token[4]))
          }
        }
        if titleDepth.map({ depth < $0 }) == true { titleDepth = nil }
        if ignoredDepth.map({ depth < $0 }) == true { ignoredDepth = nil }
        if let productDepth, depth < productDepth { break }
        continue
      }
      let attrs = attributes(token[3])
      let isVoid = voidTags.contains(tag) || token[3].hasSuffix("/")
      if !isVoid { depth += 1 }
      if productDepth == nil,
        attrs["itemtype"]?.split(separator: " ").contains(where: {
          $0 == "https://schema.org/Product" || $0 == "http://schema.org/Product"
        }) == true
      {
        productDepth = depth
      }
      guard productDepth != nil else { continue }
      if ignoredDepth != nil { continue }
      if let type = attrs["itemtype"], depth != productDepth,
        !type.hasSuffix("/Offer"), !type.hasSuffix("/AggregateOffer")
      {
        if !isVoid { ignoredDepth = depth }
        continue
      }
      if titleDepth != nil { titleParts.append(unescape(token[4])) }
      guard let props = attrs["itemprop"] else { continue }
      for prop in props.split(separator: " ").map(String.init) {
        guard ["name", "price", "priceCurrency", "image"].contains(prop), values[prop] == nil else {
          continue
        }
        let text = attrs["content"] ?? attrs["src"] ?? attrs["href"] ?? token[4]
        if prop == "name", attrs["content"] == nil, !isVoid {
          titleDepth = depth
          titleParts = [unescape(token[4])]
        }
        values[prop] = unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    if titleDepth != nil {
      values["name"] = titleParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return metadata(
      name: values["name"], price: values["price"],
      currency: values["priceCurrency"], image: values["image"], pageURL: pageURL)
  }

  private static func attributes(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for match in matches(
      "([a-zA-Z_:][a-zA-Z0-9_.:-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", text)
    {
      result[match[1].lowercased()] = match[2...4].first { !$0.isEmpty } ?? ""
    }
    return result
  }

  private static func removing(_ pattern: String, from text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    return regex.stringByReplacingMatches(
      in: text,
      range: NSRange(text.startIndex..., in: text), withTemplate: "")
  }

  private static func matches(_ pattern: String, _ text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
      (0..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : ns.substring(with: range)
      }
    }
  }

  private static func unescape(_ text: String) -> String {
    var result = text
    let entities = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " "]
    for (name, value) in entities {
      result = result.replacingOccurrences(of: "&\(name);", with: value)
    }
    for match in matches("&#(x[0-9a-fA-F]+|[0-9]+);", result).reversed() {
      let digits = match[1]
      let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
      if let number, let scalar = UnicodeScalar(number) {
        result = result.replacingOccurrences(of: match[0], with: String(scalar))
      }
    }
    return result.replacingOccurrences(of: "&amp;", with: "&")
  }

  private static func product(in node: Node) -> [String: Node]? {
    for object in node.objects {
      if object["@type"]?.texts.contains(where: {
        $0 == "Product" || $0 == "https://schema.org/Product" || $0 == "http://schema.org/Product"
      }) == true {
        return object
      }
      if let graph = object["@graph"], let found = product(in: graph) { return found }
    }
    return nil
  }

  /// Decimal decoding keeps JSON prices exact rather than passing them through binary money.
  private indirect enum Node: Decodable {
    case object([String: Node]), array([Node]), string(String), number(Decimal), other

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode([String: Node].self) {
        self = .object(value)
      } else if let value = try? container.decode([Node].self) {
        self = .array(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode(Decimal.self) {
        self = .number(value)
      } else {
        self = .other
      }
    }

    var objects: [[String: Node]] {
      switch self {
      case .object(let value): [value]
      case .array(let values): values.flatMap(\.objects)
      default: []
      }
    }
    var text: String? {
      switch self {
      case .string(let value): value
      case .number(let value): NSDecimalNumber(decimal: value).stringValue
      default: nil
      }
    }
    var texts: [String] {
      if case .array(let values) = self { return values.compactMap(\.text) }
      return text.map { [$0] } ?? []
    }
    var image: String? {
      if case .array(let values) = self { return values.first?.image }
      if case .object(let value) = self { return value["url"]?.text ?? value["contentUrl"]?.text }
      return text
    }
  }
}
