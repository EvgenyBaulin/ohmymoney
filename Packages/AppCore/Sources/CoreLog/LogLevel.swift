import Foundation

/// How much a line matters. In Debug everything is written, in Release `info` and above.
public enum LogLevel: String, Sendable, CaseIterable, Comparable, Codable {
  case debug
  case info
  case warning
  case error

  public var rank: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .warning: 2
    case .error: 3
    }
  }

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

  /// The lowest level a build writes.
  public static func threshold(isDebug: Bool) -> LogLevel { isDebug ? .debug : .info }

  /// An `error` is put on disk at once: the thing worth reading is the last line before a
  /// crash, and a buffered line is the one that never arrives.
  public var isFlushedAtOnce: Bool { self == .error }
}

/// The parts of the application a line can come from — the categories of `os.Logger` as well
/// (the subsystem is the bundle id, one category per part of the application).
public enum LogCategory: String, Sendable, CaseIterable, Codable {
  case app
  case ui
  case db
  case compute
  case rates
  case backup
  case archive
  case updates
}
