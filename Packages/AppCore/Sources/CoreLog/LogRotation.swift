import Foundation

/// Five files of two megabytes, the oldest thrown away.
///
/// The arithmetic lives here, apart from the writing: which file a line goes to, when the
/// files are rolled round, what each is renamed to and what is dropped. It is the part that
/// has to be the same on every platform, and the part worth testing without a disk.
public struct LogRotation: Hashable, Sendable {
  public var maximumBytes: Int
  public var keep: Int
  public var base: String

  public init(maximumBytes: Int = 2 * 1024 * 1024, keep: Int = 5, base: String = "ohmymoney.log") {
    self.maximumBytes = maximumBytes
    self.keep = keep
    self.base = base
  }

  /// `ohmymoney.log`, `ohmymoney.1.log`, … `ohmymoney.4.log`: the live one has no number, and the
  /// numbers grow with age.
  public func name(at index: Int) -> String {
    guard index > 0 else { return base }
    guard let dot = base.lastIndex(of: ".") else { return "\(base).\(index)" }
    return base[..<dot] + ".\(index)" + base[dot...]
  }

  /// All the names this rotation ever uses, newest first.
  public var names: [String] { (0..<keep).map(name(at:)) }

  public func shouldRoll(current: Int, adding: Int) -> Bool {
    current > 0 && current + adding > maximumBytes
  }

  /// The renames one roll needs, in the order they must happen: the oldest first, so nothing
  /// is written over something that has not moved yet.
  public func renames() -> [(from: String, to: String)] {
    (1..<keep).reversed().map { (from: name(at: $0 - 1), to: name(at: $0)) }
  }

  /// What falls off the end and is deleted before the renames.
  public func dropped() -> [String] { [name(at: keep - 1)] }
}
