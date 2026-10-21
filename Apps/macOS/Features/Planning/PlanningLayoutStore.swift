import AppCore
import Foundation
import Observation

/// How the Planning screen is laid out on this Mac: the order of its blocks
/// (`planning.blockOrder`, carried by the transfer archive like the tiles of Overview) and how
/// many of the nearest items a long block shows — one choice for all blocks
/// (`planning.listLength`) and one a block may set for itself from its header
/// (`planning.listLength.<block>`), neither carried. Habits of the owner, kept in `UserDefaults`
/// and never a step of ⌘Z. Whether a block is collapsed is not kept at all: every launch opens
/// every block.
@MainActor
@Observable
final class PlanningLayoutStore {
  nonisolated static let orderKey = "planning.blockOrder"
  nonisolated static let lengthKey = "planning.listLength"

  /// The key of a block's own length.
  nonisolated static func lengthKey(for block: PlanningBlock) -> String {
    "\(lengthKey).\(block.rawValue)"
  }

  /// The layout of the app, on the standard defaults. A test makes its own on a suite.
  static let shared = PlanningLayoutStore(defaults: .standard)

  @ObservationIgnored let defaults: UserDefaults

  /// Every block once, in the order the owner set.
  private(set) var order: [PlanningBlock]
  /// The length every long block shows unless it has its own.
  private(set) var length: PlanningListLength
  /// The lengths blocks set for themselves.
  private(set) var own: [PlanningBlock: PlanningListLength]

  init(defaults: UserDefaults) {
    self.defaults = defaults
    order = PlanningBlocks.decode(defaults.string(forKey: Self.orderKey))
    length =
      PlanningListLength(stored: defaults.string(forKey: Self.lengthKey))
      ?? PlanningListLength.standard
    var own: [PlanningBlock: PlanningListLength] = [:]
    for block in PlanningBlock.allCases where block.hasShortList {
      if let value = PlanningListLength(stored: defaults.string(forKey: Self.lengthKey(for: block)))
      {
        own[block] = value
      }
    }
    self.own = own
  }

  // MARK: The order

  func setOrder(_ blocks: [PlanningBlock]) {
    let sanitized = PlanningBlocks.sanitized(blocks)
    guard sanitized != order else { return }
    order = sanitized
    defaults.set(PlanningBlocks.encode(sanitized), forKey: Self.orderKey)
  }

  /// `block` dropped onto the place of `target`. Returns whether anything moved.
  @discardableResult
  func drop(_ block: PlanningBlock, onto target: PlanningBlock) -> Bool {
    let dropped = PlanningBlocks.dropping(block, onto: target, in: order)
    guard dropped != order else { return false }
    setOrder(dropped)
    return true
  }

  /// «Выше» (`by: -1`) and «Ниже» (`by: 1`).
  func move(_ block: PlanningBlock, by step: Int) {
    setOrder(PlanningBlocks.moving(block, by: step, in: order))
  }

  func canMove(_ block: PlanningBlock, by step: Int) -> Bool {
    PlanningBlocks.canMove(block, by: step, in: order)
  }

  /// «Как было»: the standard order.
  func resetOrder() {
    setOrder(PlanningBlocks.standard)
  }

  // MARK: How many items

  /// What `block` shows: its own length, else the one of all blocks.
  func length(of block: PlanningBlock) -> PlanningListLength {
    PlanningListLength.effective(own: own[block], global: length)
  }

  func setLength(_ value: PlanningListLength) {
    guard value != length else { return }
    length = value
    defaults.set(value.stored, forKey: Self.lengthKey)
  }

  /// A block's own length; `nil` — «Как в настройках».
  func ownLength(of block: PlanningBlock) -> PlanningListLength? { own[block] }

  func setOwnLength(_ value: PlanningListLength?, for block: PlanningBlock) {
    guard own[block] != value else { return }
    own[block] = value
    if let value {
      defaults.set(value.stored, forKey: Self.lengthKey(for: block))
    } else {
      defaults.removeObject(forKey: Self.lengthKey(for: block))
    }
  }

  // MARK: The archive

  /// The order as the archive's `settings.json` carries it: read as an order before it is
  /// written, whatever the defaults hold.
  nonisolated static func portableOrder(in defaults: UserDefaults) -> String {
    PlanningBlocks.encode(PlanningBlocks.decode(defaults.string(forKey: orderKey)))
  }

  /// The order an archive carries, put into `defaults` as an order of every block once: a block
  /// this build does not know goes, one it lacks takes its standard place. Nothing when the
  /// archive carries none.
  nonisolated static func applyPortable(_ values: [String: String], to defaults: UserDefaults) {
    guard let stored = values[orderKey] else { return }
    defaults.set(PlanningBlocks.encode(PlanningBlocks.decode(stored)), forKey: orderKey)
  }
}
