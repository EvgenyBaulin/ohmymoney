import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// What `make migration-dry-run` says about an error: the domain and the codes, never the
/// message or a path, and a line of advice when the codes say why — the privacy protection of
/// macOS (Full Disk Access) or the file's own permissions.
@Suite("The words of the dry run about an error")
struct DryRunTextTests {
  /// The copy of another app's container refused by macOS, as `FileManager.copyItem` reports
  /// it: a Cocoa «no permission to read» over the POSIX `EPERM`.
  private var refusedCopy: NSError {
    NSError(
      domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
      userInfo: [
        NSFilePathErrorKey: "/Users/owner/Library/Containers/app/Data/finance.sqlite",
        NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
      ])
  }

  @Test func aCocoaErrorGivesItsDomainAndCodes() {
    #expect(DryRunText.describe(refusedCopy) == "NSCocoaErrorDomain 257 (NSPOSIXErrorDomain 1)")
    #expect(
      DryRunText.describe(NSError(domain: NSCocoaErrorDomain, code: 260))
        == "NSCocoaErrorDomain 260")
    #expect(
      DryRunText.describe(CocoaError(.fileReadNoPermission)) == "NSCocoaErrorDomain 257")
  }

  /// The path the error carries, its file name and its message are never printed.
  @Test func anErrorWithAPathPrintsNoPath() {
    let error = NSError(
      domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
      userInfo: [
        NSFilePathErrorKey: "/Users/owner/secret/finance.sqlite",
        NSLocalizedDescriptionKey: "The file “finance.sqlite” couldn’t be opened.",
        NSUnderlyingErrorKey: NSError(
          domain: NSPOSIXErrorDomain, code: Int(EACCES),
          userInfo: [NSFilePathErrorKey: "/Users/owner/secret/finance.sqlite"]),
      ])
    let words = [DryRunText.describe(error), DryRunText.hint(for: error) ?? ""]
    for text in words {
      #expect(!text.contains("/"))
      #expect(!text.contains("finance"))
      #expect(!text.contains("owner"))
      #expect(!text.contains("couldn"))
    }
  }

  /// `EPERM` anywhere in the chain — or a Cocoa refusal with no POSIX cause — names Full Disk
  /// Access.
  @Test func epermGivesTheFullDiskAccessHint() throws {
    let hint = try #require(DryRunText.hint(for: refusedCopy))
    #expect(hint.contains("Full Disk Access"))
    #expect(hint.contains("Полный доступ к диску"))
    #expect(DryRunText.hint(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == hint)
    #expect(
      DryRunText.hint(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        == hint)
    #expect(DryRunText.hint(for: NSError(domain: NSCocoaErrorDomain, code: 260)) == nil)
  }

  /// `EACCES` is the file's own permissions, not the privacy protection.
  @Test func eaccesGivesThePermissionsHint() throws {
    let error = NSError(
      domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
    let hint = try #require(DryRunText.hint(for: error))
    #expect(hint == "the file's permissions do not let this user read it.")
    #expect(!hint.contains("Full Disk Access"))
  }

  /// SQLite and a stopped update keep the words they had: «SQLite 19», «stopped at … (…)».
  @Test func sqliteStaysAsItWas() {
    let constraint = DatabaseError(resultCode: .SQLITE_CONSTRAINT)
    #expect(DryRunText.describe(constraint) == "SQLite 19")
    let stopped = DatabaseStack.MigrationFailure(
      from: 4, to: 5, migration: "0005_cards", milliseconds: 3, underlying: constraint)
    #expect(DryRunText.describe(stopped) == "stopped at 0005_cards (SQLite 19)")
    #expect(DryRunText.hint(for: stopped) == nil)
    let refused = DatabaseStack.MigrationFailure(
      from: 4, to: 5, migration: nil, milliseconds: 3, underlying: refusedCopy)
    #expect(
      DryRunText.describe(refused)
        == "stopped at ? (NSCocoaErrorDomain 257 (NSPOSIXErrorDomain 1))")
    #expect(DryRunText.hint(for: refused) != nil)
  }
}
