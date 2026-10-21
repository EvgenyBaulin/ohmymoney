import CoreKit
import Foundation

/// The pieces a document is cut into: an opening tag with its attributes, a closing tag,
/// or a run of character data.
enum XMLEvent: Equatable {
  case start(name: String, attributes: [String: String], isSelfClosing: Bool)
  case end(name: String)
  case text(String)
}

/// A forward scanner over the tags of a small, flat XML document.
///
/// `XMLParser` is Apple-only and behaves differently on Linux, where `AppCore` also has to
/// run, so the Bank of Russia feed is scanned by hand. The scanner understands exactly what
/// that feed uses — a prolog, elements, attributes and character data — plus comments,
/// CDATA and the five predefined entities, and it is indifferent to line breaks and to
/// extra whitespace inside tags. Anything it cannot make sense of raises
/// `CoreError.malformedExpression(position:)` with the scalar offset of the problem.
struct XMLTagScanner {
  private let scalars: [Unicode.Scalar]
  private var index: Int = 0

  init(_ text: String) {
    self.scalars = Array(text.unicodeScalars)
  }

  /// Offset the scanner stopped at, used for error reporting by the caller.
  var position: Int { index }

  var isAtEnd: Bool { index >= scalars.count }

  mutating func next() throws -> XMLEvent? {
    while index < scalars.count {
      if scalars[index] == "<" {
        if matches("<?") {
          try skip(until: "?>", from: index)
          continue
        }
        if matches("<!--") {
          try skip(until: "-->", from: index)
          continue
        }
        if matches("<![CDATA[") {
          let start = index + 9
          let end = try find("]]>", from: start)
          index = end + 3
          return .text(string(from: start, to: end))
        }
        if matches("<!") {
          let end = try find(">", from: index)
          index = end + 1
          continue
        }
        if matches("</") {
          return try readClosingTag()
        }
        return try readOpeningTag()
      }
      let start = index
      while index < scalars.count && scalars[index] != "<" {
        index += 1
      }
      return .text(try decodeEntities(from: start, to: index))
    }
    return nil
  }

  // MARK: - Tags

  private mutating func readClosingTag() throws -> XMLEvent {
    let origin = index
    index += 2
    let name = readName()
    guard !name.isEmpty else { throw CoreError.malformedExpression(position: origin) }
    skipWhitespace()
    guard index < scalars.count, scalars[index] == ">" else {
      throw CoreError.malformedExpression(position: index)
    }
    index += 1
    return .end(name: name)
  }

  private mutating func readOpeningTag() throws -> XMLEvent {
    let origin = index
    index += 1
    let name = readName()
    guard !name.isEmpty else { throw CoreError.malformedExpression(position: origin) }
    var attributes: [String: String] = [:]
    while true {
      skipWhitespace()
      guard index < scalars.count else { throw CoreError.malformedExpression(position: origin) }
      if scalars[index] == ">" {
        index += 1
        return .start(name: name, attributes: attributes, isSelfClosing: false)
      }
      if scalars[index] == "/" {
        index += 1
        guard index < scalars.count, scalars[index] == ">" else {
          throw CoreError.malformedExpression(position: index)
        }
        index += 1
        return .start(name: name, attributes: attributes, isSelfClosing: true)
      }
      let attributeStart = index
      let key = readName()
      guard !key.isEmpty else { throw CoreError.malformedExpression(position: attributeStart) }
      skipWhitespace()
      guard index < scalars.count, scalars[index] == "=" else {
        throw CoreError.malformedExpression(position: index)
      }
      index += 1
      skipWhitespace()
      guard index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" else {
        throw CoreError.malformedExpression(position: index)
      }
      let quote = scalars[index]
      index += 1
      let valueStart = index
      while index < scalars.count && scalars[index] != quote {
        index += 1
      }
      guard index < scalars.count else {
        throw CoreError.malformedExpression(position: attributeStart)
      }
      let value = try decodeEntities(from: valueStart, to: index)
      index += 1
      attributes[key] = value
    }
  }

  // MARK: - Primitives

  private mutating func readName() -> String {
    let start = index
    while index < scalars.count, isNameScalar(scalars[index]) {
      index += 1
    }
    return string(from: start, to: index)
  }

  private func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "_", "-", ".", ":":
      return true
    default:
      return scalar.value > 0x7F
    }
  }

  private mutating func skipWhitespace() {
    while index < scalars.count, isWhitespace(scalars[index]) {
      index += 1
    }
  }

  private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t"
  }

  private func matches(_ literal: String) -> Bool {
    let wanted = Array(literal.unicodeScalars)
    guard index + wanted.count <= scalars.count else { return false }
    for offset in 0..<wanted.count where scalars[index + offset] != wanted[offset] {
      return false
    }
    return true
  }

  private func find(_ literal: String, from start: Int) throws -> Int {
    let wanted = Array(literal.unicodeScalars)
    guard !wanted.isEmpty, scalars.count >= wanted.count else {
      throw CoreError.malformedExpression(position: start)
    }
    var cursor = start
    while cursor + wanted.count <= scalars.count {
      var hit = true
      for offset in 0..<wanted.count where scalars[cursor + offset] != wanted[offset] {
        hit = false
        break
      }
      if hit { return cursor }
      cursor += 1
    }
    throw CoreError.malformedExpression(position: start)
  }

  private mutating func skip(until literal: String, from start: Int) throws {
    index = try find(literal, from: start) + literal.unicodeScalars.count
  }

  private func string(from start: Int, to end: Int) -> String {
    var view = String.UnicodeScalarView()
    view.reserveCapacity(end - start)
    for offset in start..<end {
      view.append(scalars[offset])
    }
    return String(view)
  }

  /// Expands the five predefined entities and numeric character references.
  private func decodeEntities(from start: Int, to end: Int) throws -> String {
    var view = String.UnicodeScalarView()
    view.reserveCapacity(end - start)
    var cursor = start
    while cursor < end {
      guard scalars[cursor] == "&" else {
        view.append(scalars[cursor])
        cursor += 1
        continue
      }
      var terminator = cursor + 1
      while terminator < end, scalars[terminator] != ";", terminator - cursor <= 10 {
        terminator += 1
      }
      guard terminator < end, scalars[terminator] == ";" else {
        throw CoreError.malformedExpression(position: cursor)
      }
      let name = string(from: cursor + 1, to: terminator)
      switch name {
      case "amp": view.append("&")
      case "lt": view.append("<")
      case "gt": view.append(">")
      case "quot": view.append("\"")
      case "apos": view.append("'")
      default:
        guard name.hasPrefix("#") else { throw CoreError.malformedExpression(position: cursor) }
        let digits = String(name.dropFirst())
        let code: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
          code = UInt32(digits.dropFirst(), radix: 16)
        } else {
          code = UInt32(digits, radix: 10)
        }
        guard let value = code, let scalar = Unicode.Scalar(value) else {
          throw CoreError.malformedExpression(position: cursor)
        }
        view.append(scalar)
      }
      cursor = terminator + 1
    }
    return String(view)
  }
}
