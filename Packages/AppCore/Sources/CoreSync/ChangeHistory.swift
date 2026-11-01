import Foundation

/// One line of the change journal a database keeps for ever (`sync_history`): a row as it stood
/// after one change, when, and on which device. The whole row, never a diff, the way a journal
/// file carries it, so the history of a row reads without anything else.
public struct ChangeRecord: Hashable, Sendable, Codable {
  /// The order of the journal on this device; ties of the same second keep it.
  public var seq: Int64
  public var key: RecordKey
  public var op: SyncOp
  public var at: SyncInstant
  public var deviceId: String
  /// The name the device had when the change was made; empty when nobody knew it.
  public var deviceName: String
  public var fields: [String: SyncValue]

  public init(
    seq: Int64, key: RecordKey, op: SyncOp, at: SyncInstant, deviceId: String,
    deviceName: String, fields: [String: SyncValue]
  ) {
    self.seq = seq
    self.key = key
    self.op = op
    self.at = at
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.fields = fields
  }

  public var isDeleted: Bool { op == .deleted || ChangeHistory.isSoftDeleted(fields) }
}

/// What the history tab of an operation shows: the changes of the operation and of its parts,
/// one event per device and second, newest first.
public struct HistoryEvent: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case created
    case edited
    case deleted
    /// Deleted before, back now (an undo, or an edit of another device made after the delete).
    case restored
  }

  public var kind: Kind
  public var at: SyncInstant
  public var deviceId: String
  public var deviceName: String
  public var changes: [FieldChange]
  /// The first journal line of the event: a stable id for a list.
  public var id: Int64

  public init(
    kind: Kind, at: SyncInstant, deviceId: String, deviceName: String, changes: [FieldChange],
    id: Int64
  ) {
    self.kind = kind
    self.at = at
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.changes = changes
    self.id = id
  }
}

/// One field that changed: of the operation itself, or of one of its parts.
public struct FieldChange: Hashable, Sendable {
  public enum Scope: Hashable, Sendable {
    case operation
    case part(String)
  }

  public enum Change: Hashable, Sendable {
    case value(before: SyncValue, after: SyncValue)
    /// A part that appeared (a split, a new part); its fields are `after`.
    case partAdded
    case partRemoved
  }

  public var scope: Scope
  /// The column; empty for `partAdded` and `partRemoved`.
  public var field: String
  public var change: Change

  public init(scope: Scope, field: String, change: Change) {
    self.scope = scope
    self.field = field
    self.change = change
  }
}

public enum ChangeHistory {
  /// The tables an operation is made of.
  public static let operationTable = "transactions"
  public static let partTable = "transaction_parts"
  public static let partOwnerField = "transaction_id"

  /// Columns that change with every write and tell the owner nothing: never shown as a change.
  public static let bookkeepingFields: Set<String> = ["updated_at", "created_at", "deleted_at"]

  /// A row whose `deleted_at` holds a moment is deleted, whatever the op of its line says.
  public static func isSoftDeleted(_ fields: [String: SyncValue]) -> Bool {
    if case .string = fields["deleted_at"] ?? .null { return true }
    return false
  }

  /// What a new line of the journal says about a row that changed, or `nil` when there is
  /// nothing to write: the row stands exactly as the last line of it says (a save that changed
  /// nothing, a trigger fired twice). `current` is the row now, `nil` when it is gone.
  public static func op(
    current: [String: SyncValue]?, last: ChangeRecord?
  ) -> SyncOp? {
    guard let current else {
      if let last, last.op == .deleted, last.fields.isEmpty { return nil }
      return last == nil ? nil : .deleted
    }
    if let last, last.fields == current, !(last.op == .deleted && !isSoftDeleted(current)) {
      return nil
    }
    if isSoftDeleted(current) { return .deleted }
    return last == nil ? .created : .updated
  }

  /// The history of one operation from the journal: its own lines and the lines of every row
  /// that was a part of it at any time, newest event first. Lines of other rows are ignored.
  public static func events(
    forOperation id: String, records: [ChangeRecord]
  ) -> [HistoryEvent] {
    let partIds = Set(
      records.filter {
        $0.key.table == partTable && $0.fields[partOwnerField] == .string(id)
      }.map(\.key.uuid))
    let relevant = records.filter {
      ($0.key.table == operationTable && $0.key.uuid == id)
        || ($0.key.table == partTable && partIds.contains($0.key.uuid))
    }
    .sorted { ($0.at, $0.seq) < ($1.at, $1.seq) }

    var last: [RecordKey: ChangeRecord] = [:]
    var events: [HistoryEvent] = []
    for record in relevant {
      let previous = last[record.key]
      last[record.key] = record
      let scope: FieldChange.Scope =
        record.key.table == operationTable ? .operation : .part(record.key.uuid)
      var changes: [FieldChange] = []
      var kind: HistoryEvent.Kind?
      switch scope {
      case .operation:
        if previous == nil {
          kind = record.isDeleted ? .deleted : .created
        } else if let previous, previous.isDeleted != record.isDeleted {
          kind = record.isDeleted ? .deleted : .restored
        }
        if let previous, !record.isDeleted {
          changes = diff(previous.fields, record.fields, scope: scope)
        }
      case .part:
        let wasLive = previous.map { !$0.isDeleted } ?? false
        if record.isDeleted {
          if wasLive { changes = [FieldChange(scope: scope, field: "", change: .partRemoved)] }
        } else if !wasLive {
          changes = [FieldChange(scope: scope, field: "", change: .partAdded)]
        } else if let previous {
          changes = diff(previous.fields, record.fields, scope: scope)
        }
      }
      if kind == nil && changes.isEmpty { continue }
      if var open = events.last, open.deviceId == record.deviceId, open.at == record.at {
        open.changes += changes
        if let kind, open.kind == .edited { open.kind = kind }
        events[events.count - 1] = open
      } else {
        events.append(
          HistoryEvent(
            kind: kind ?? .edited, at: record.at, deviceId: record.deviceId,
            deviceName: record.deviceName, changes: changes, id: record.seq))
      }
    }
    // The lines of a new operation's parts come in the same second: they make it, they are not
    // edits of it.
    for index in events.indices where events[index].kind == .created {
      events[index].changes.removeAll()
    }
    return events.reversed()
  }

  /// The fields that differ, bookkeeping columns left out, by name.
  static func diff(
    _ before: [String: SyncValue], _ after: [String: SyncValue], scope: FieldChange.Scope
  ) -> [FieldChange] {
    Set(before.keys).union(after.keys).subtracting(bookkeepingFields).sorted()
      .compactMap { name in
        let old = before[name] ?? .null
        let new = after[name] ?? .null
        guard old != new else { return nil }
        return FieldChange(scope: scope, field: name, change: .value(before: old, after: new))
      }
  }

  /// The journal lines a database that kept no journal of its own can start from: every
  /// version of every row the exchange has seen, in the order the exchange weighs them, each
  /// device named as its newest file names it.
  public static func records(from state: SyncState) -> [ChangeRecord] {
    var out: [ChangeRecord] = []
    for key in state.versions.keys.sorted() {
      for version in state.versions(of: key) {
        out.append(
          ChangeRecord(
            seq: 0, key: key, op: version.op, at: version.stamp.updatedAt,
            deviceId: version.stamp.deviceId,
            deviceName: state.deviceName(of: version.stamp.deviceId) ?? "",
            fields: version.fields))
      }
    }
    out.sort {
      ($0.at, $0.deviceId, $0.key) < ($1.at, $1.deviceId, $1.key)
    }
    for index in out.indices { out[index].seq = Int64(index + 1) }
    return out
  }
}
