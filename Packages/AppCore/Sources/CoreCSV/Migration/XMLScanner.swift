import Foundation

/// The few XML events a spreadsheet's parts need: an element opens (with its attributes), closes,
/// or text appears. Namespace prefixes are dropped (`x:row` is `row`). It is not a validating
/// parser and does not try to be one: Foundation's XML parser is missing from the Linux build the
/// core must keep, and a sheet is plain, machine-written XML.
enum XMLEvent: Equatable {
  case open(name: String, attributes: [String: String], selfClosing: Bool)
  case close(name: String)
  case text(String)
}

enum XMLScanner {
  /// Calls `handle` for every event of the document in order.
  static func scan(_ bytes: [UInt8], _ handle: (XMLEvent) -> Void) {
    var index = 0
    let count = bytes.count
    while index < count {
      if bytes[index] != UInt8(ascii: "<") {
        let start = index
        while index < count, bytes[index] != UInt8(ascii: "<") { index += 1 }
        handle(.text(decodeEntities(bytes[start..<index])))
        continue
      }
      // `<!-- … -->`, `<![CDATA[ … ]]>`, `<!DOCTYPE …>` and `<? … ?>`.
      if starts(bytes, index, "<!--") {
        index = find(bytes, from: index + 4, "-->").map { $0 + 3 } ?? count
        continue
      }
      if starts(bytes, index, "<![CDATA[") {
        let end = find(bytes, from: index + 9, "]]>") ?? count
        handle(.text(String(decoding: bytes[(index + 9)..<end], as: UTF8.self)))
        index = min(count, end + 3)
        continue
      }
      if index + 1 < count,
        bytes[index + 1] == UInt8(ascii: "?") || bytes[index + 1] == UInt8(ascii: "!")
      {
        while index < count, bytes[index] != UInt8(ascii: ">") { index += 1 }
        index += 1
        continue
      }
      // A tag: find its end outside quoted attribute values.
      var end = index + 1
      var quote: UInt8 = 0
      while end < count {
        let byte = bytes[end]
        if quote != 0 {
          if byte == quote { quote = 0 }
        } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
          quote = byte
        } else if byte == UInt8(ascii: ">") {
          break
        }
        end += 1
      }
      guard end < count else { return }
      handle(tag(bytes[(index + 1)..<end]))
      index = end + 1
    }
  }

  private static func tag(_ body: ArraySlice<UInt8>) -> XMLEvent {
    var slice = body
    if slice.first == UInt8(ascii: "/") {
      slice = slice.dropFirst()
      let name = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
      return .close(name: localName(name))
    }
    var selfClosing = false
    if slice.last == UInt8(ascii: "/") {
      selfClosing = true
      slice = slice.dropLast()
    }
    var cursor = slice.startIndex
    while cursor < slice.endIndex, !isSpace(slice[cursor]) { cursor += 1 }
    let name = localName(String(decoding: slice[slice.startIndex..<cursor], as: UTF8.self))
    var attributes: [String: String] = [:]
    while cursor < slice.endIndex {
      while cursor < slice.endIndex, isSpace(slice[cursor]) { cursor += 1 }
      let keyStart = cursor
      while cursor < slice.endIndex, slice[cursor] != UInt8(ascii: "="), !isSpace(slice[cursor]) {
        cursor += 1
      }
      let key = String(decoding: slice[keyStart..<cursor], as: UTF8.self)
      while cursor < slice.endIndex,
        slice[cursor] != UInt8(ascii: "\"")
          && slice[cursor] != UInt8(ascii: "'")
      {
        cursor += 1
      }
      guard cursor < slice.endIndex else { break }
      let quote = slice[cursor]
      cursor += 1
      let valueStart = cursor
      while cursor < slice.endIndex, slice[cursor] != quote { cursor += 1 }
      if !key.isEmpty {
        attributes[localName(key)] = decodeEntities(slice[valueStart..<min(cursor, slice.endIndex)])
      }
      cursor += 1
    }
    return .open(name: name, attributes: attributes, selfClosing: selfClosing)
  }

  private static func localName(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
  }

  private static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }

  private static func starts(_ bytes: [UInt8], _ at: Int, _ text: String) -> Bool {
    let pattern = Array(text.utf8)
    guard at + pattern.count <= bytes.count else { return false }
    return Array(bytes[at..<at + pattern.count]) == pattern
  }

  private static func find(_ bytes: [UInt8], from: Int, _ text: String) -> Int? {
    let pattern = Array(text.utf8)
    var index = from
    while index + pattern.count <= bytes.count {
      if bytes[index] == pattern[0], Array(bytes[index..<index + pattern.count]) == pattern {
        return index
      }
      index += 1
    }
    return nil
  }

  /// `&amp; &lt; &gt; &quot; &apos;` and numeric references, decimal and hexadecimal.
  static func decodeEntities(_ bytes: ArraySlice<UInt8>) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    guard text.contains("&") else { return text }
    var result = ""
    var rest = Substring(text)
    while let amp = rest.firstIndex(of: "&") {
      result += rest[rest.startIndex..<amp]
      guard let semicolon = rest[amp...].firstIndex(of: ";"),
        rest.distance(from: amp, to: semicolon) <= 10
      else {
        result += "&"
        rest = rest[rest.index(after: amp)...]
        continue
      }
      let name = rest[rest.index(after: amp)..<semicolon]
      var replacement: String?
      switch name {
      case "amp": replacement = "&"
      case "lt": replacement = "<"
      case "gt": replacement = ">"
      case "quot": replacement = "\""
      case "apos": replacement = "'"
      default:
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
          replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map {
            String(Character($0))
          }
        } else if name.hasPrefix("#") {
          replacement = UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init).map {
            String(Character($0))
          }
        }
      }
      if let replacement {
        result += replacement
        rest = rest[rest.index(after: semicolon)...]
      } else {
        result += "&"
        rest = rest[rest.index(after: amp)...]
      }
    }
    result += rest
    return result
  }
}
