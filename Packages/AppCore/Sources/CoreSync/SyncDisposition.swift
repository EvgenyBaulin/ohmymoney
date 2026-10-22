import Foundation

/// What this device does with a row once every version of it is known.
///
/// The rule of the owner's own book: a version made apart from one of mine never overwrites
/// mine. It waits in the list of conflicts until I choose, and nothing of it reaches the sums
/// meanwhile. A version that was made *on top of* mine (it names mine as its base, or settles
/// it) is the next version of the row, not a conflict, and is taken.
public enum SyncDisposition: Hashable, Sendable {
  /// Every version that is not superseded is mine: nothing to take.
  case keepLocal
  /// No version of mine stands apart from the winner: take the winner.
  case applyWinner
  /// A version of mine and a version of another device were made apart: take neither.
  case conflict
}

extension ResolvedRecord {
  /// The versions nothing builds on: the winner and the conflicts, latest first.
  public var heads: [RecordVersion] { [winner] + conflicts }

  public func disposition(ownDeviceId: String) -> SyncDisposition {
    let heads = self.heads
    let mine = heads.contains { $0.stamp.deviceId == ownDeviceId }
    let theirs = heads.contains { $0.stamp.deviceId != ownDeviceId }
    if !theirs { return .keepLocal }
    return mine ? .conflict : .applyWinner
  }
}

/// A row on which two devices made different versions apart from each other.
public struct DeviceConflict: Hashable, Sendable {
  public var key: RecordKey
  /// My latest version of it.
  public var mine: RecordVersion
  /// The latest version of another device.
  public var theirs: RecordVersion
  /// Every version of both sides that is still not settled, to be settled by one choice.
  public var unsettled: [VersionStamp]
  /// The names of the fields on which the two versions differ, sorted. A delete counts as
  /// differing in every field the other side has.
  public var differingFields: [String]

  static func differing(_ a: RecordVersion, _ b: RecordVersion) -> [String] {
    let names = Set(a.fields.keys).union(b.fields.keys)
    var out = names.filter { a.fields[$0] != b.fields[$0] }
    if (a.op == .deleted) != (b.op == .deleted) { out.insert("deleted") }
    return out.sorted()
  }
}

extension SyncState {
  /// The rows waiting for the owner's choice on this device, in key order.
  public func openConflicts(ownDeviceId: String) -> [DeviceConflict] {
    versions.keys.sorted().compactMap { key in
      guard let record = resolve(key),
        record.disposition(ownDeviceId: ownDeviceId) == .conflict
      else { return nil }
      let heads = record.heads
      guard let mine = heads.first(where: { $0.stamp.deviceId == ownDeviceId }),
        let theirs = heads.first(where: { $0.stamp.deviceId != ownDeviceId })
      else { return nil }
      return DeviceConflict(
        key: key, mine: mine, theirs: theirs, unsettled: heads.map(\.stamp),
        differingFields: DeviceConflict.differing(mine, theirs))
    }
  }
}
