import Foundation

/// One version of one row, as some journal said it.
public struct RecordVersion: Hashable, Sendable, Codable {
  public var stamp: VersionStamp
  public var op: SyncOp
  public var fields: [String: SyncValue]
  public var base: VersionStamp?
  /// The versions this one settles besides `base` (see `SyncEntry.resolves`).
  public var resolves: [VersionStamp]? = nil
  /// Sequence of the file and place in it: two edits of one row in the same second by the same
  /// device still have a fixed order, so the winner never depends on which file came first.
  public var sequence: Int
  public var index: Int

  static func precedes(_ a: RecordVersion, _ b: RecordVersion) -> Bool {
    if a.stamp != b.stamp { return a.stamp < b.stamp }
    if a.sequence != b.sequence { return a.sequence < b.sequence }
    return a.index < b.index
  }
}

/// What a row is, once every version seen so far is weighed (see `SyncState.resolve`).
public struct ResolvedRecord: Hashable, Sendable {
  public var key: RecordKey
  public var winner: RecordVersion
  /// Versions made apart from the winner and lost to it: kept so a person can look at them.
  public var conflicts: [RecordVersion]

  public var isDeleted: Bool { winner.op == .deleted }
  public var fields: [String: SyncValue] { winner.fields }
}

struct AppliedFile: Hashable, Sendable, Codable {
  var byteCount: Int
  var checksum: UInt64
}

/// The ledger and the memory of the exchange on one device: which files are applied and every
/// version of every row they carried. It is a value, persisted by the app through
/// `SyncStateStore`; it never touches a disk or a database itself.
///
/// The rules, all of them functions of the *set* of versions — so the order in which files
/// arrive can not matter:
/// - the winner of a row is the version with the greatest (`updatedAt`, `deviceId`), then
///   (file sequence, place in file); a delete is a version like any other, so a newer update
///   brings a deleted row back and a newer delete removes it;
/// - a version is *superseded* when a later version names it (transitively) as its `base`;
///   every version that is not superseded and is not the winner is a conflict: an edit made
///   apart, which the winner overruled. Nothing is dropped.
public struct SyncState: Hashable, Sendable, Codable {
  var files: [String: AppliedFile] = [:]
  var versions: [RecordKey: [RecordVersion]] = [:]

  public init() {}

  public var appliedFileNames: Set<String> { Set(files.keys) }

  public func isApplied(name: String) -> Bool { files[name] != nil }

  /// Adds a file. Idempotent: the same file again changes nothing; the same name with other
  /// bytes is refused. Returns the rows whose resolved value changed.
  @discardableResult
  public mutating func ingest(
    _ file: JournalFile, name: String, bytes: Data
  ) throws -> Set<
    RecordKey
  > {
    guard SyncFormat.parse(fileName: name).map({ $0 == (file.deviceId, file.sequence) }) == true
    else { throw SyncError.nameMismatch }
    let fingerprint = AppliedFile(byteCount: bytes.count, checksum: Self.checksum(bytes))
    if let known = files[name] {
      guard known == fingerprint else { throw SyncError.fileChanged(name: name) }
      return []
    }
    var touched = Set<RecordKey>()
    var before: [RecordKey: ResolvedRecord?] = [:]
    for (index, entry) in file.entries.enumerated() {
      let key = entry.key
      if before[key] == nil { before[key] = .some(resolve(key)) }
      let version = RecordVersion(
        stamp: VersionStamp(updatedAt: entry.updatedAt, deviceId: file.deviceId),
        op: entry.op, fields: entry.fields, base: entry.base, resolves: entry.resolves,
        sequence: file.sequence, index: index)
      var list = versions[key, default: []]
      if !list.contains(version) {
        list.append(version)
        list.sort(by: RecordVersion.precedes)
      }
      versions[key] = list
      touched.insert(key)
    }
    files[name] = fingerprint
    return Set(touched.filter { resolve($0) != before[$0]! })
  }

  public func resolve(_ key: RecordKey) -> ResolvedRecord? {
    guard let list = versions[key], !list.isEmpty else { return nil }
    // Everything some version builds on is superseded. What an owner's choice settled
    // (`resolves`, and what that builds on) is also never the winner, however late its stamp:
    // the settling edit stands in its place. What an ordinary edit builds on may still win by
    // its stamp — a slow clock loses, but is not lost.
    var covered = Set<Int>()
    var settled = Set<Int>()
    for (i, v) in list.enumerated() {
      var visited = Set<Int>()
      var queue: [(VersionStamp, Bool)] =
        (v.base.map { [($0, false)] } ?? []) + (v.resolves ?? []).map { ($0, true) }
      while let (stamp, viaChoice) = queue.popLast() {
        for (j, u) in list.enumerated() where u.stamp == stamp && j != i {
          guard visited.insert(j * 2 + (viaChoice ? 1 : 0)).inserted else { continue }
          covered.insert(j)
          if viaChoice { settled.insert(j) }
          if let b = u.base { queue.append((b, viaChoice)) }
          queue.append(contentsOf: (u.resolves ?? []).map { ($0, true) })
        }
      }
    }
    var candidates = list.enumerated().filter { !settled.contains($0.offset) }.map(\.element)
    if candidates.isEmpty { candidates = list }
    var winner = candidates[0]
    for v in candidates where RecordVersion.precedes(winner, v) { winner = v }
    let conflicts = list.enumerated()
      .filter { !covered.contains($0.offset) && $0.element != winner }
      .map(\.element)
      .sorted { RecordVersion.precedes($1, $0) }
    return ResolvedRecord(key: key, winner: winner, conflicts: conflicts)
  }

  /// Every row that has a lost, unsuperseded version — what the conflict list shows.
  public func conflicts() -> [ResolvedRecord] {
    versions.keys.sorted().compactMap { resolve($0) }.filter { !$0.conflicts.isEmpty }
  }

  public func allRecords() -> [ResolvedRecord] {
    versions.keys.sorted().compactMap { resolve($0) }
  }

  /// FNV-1a, 64 bit: enough to notice a file that changed under its name; not a security tool.
  static func checksum(_ data: Data) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in data {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01b3
    }
    return h
  }
}
