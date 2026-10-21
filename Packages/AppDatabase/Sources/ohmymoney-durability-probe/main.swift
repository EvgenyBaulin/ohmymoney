import AppCore
import AppDatabase
import CoreKit
import Foundation

// A database, one operation, and then the process kills itself the way nothing can be
// cleaned up after: `SIGKILL` to its own pid. What the test asks afterwards is whether the
// operation survived.
//
// It has to be a process of its own. `kill -9` cannot be survived, so the one being killed
// cannot also be the one checking, and a test cannot kill its own runner and go on.
//
// Arguments: <database path> <note> [--commit-only]
//        or: <database path> --die-in-the-update
//
// The second form opens an older database and kills itself inside the update: after the SQL of
// the migration ran and before its data step wrote anything, inside the one transaction of both
// — when the data step asks for the id of the account it is about to make. What the test asks
// afterwards is whether the file is the older database it was.
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  FileHandle.standardError.write(
    Data("usage: probe <database> <note> [--commit-only] | <database> --die-in-the-update\n".utf8))
  exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let note = arguments[2]
let commitOnly = arguments.contains("--commit-only")

if note == "--die-in-the-update" {
  let dying = MigrationContext(
    mainAccountName: "Main account",
    makeId: {
      FileHandle.standardOutput.write(Data("in the update\n".utf8))
      kill(getpid(), SIGKILL)
      return UUID()
    })
  do {
    _ = try DatabaseStack(
      url: url, schema: DirectorySchemaSource(directory: schemaDirectory()), context: dying)
    // The update had nothing to make an account for: nothing was killed.
    FileHandle.standardOutput.write(Data("updated without dying\n".utf8))
    exit(3)
  } catch {
    FileHandle.standardError.write(Data("probe failed: \(type(of: error))\n".utf8))
    exit(1)
  }
}

do {
  let stack = try DatabaseStack(
    url: url, schema: DirectorySchemaSource(directory: schemaDirectory()))
  let repository = TransactionRepository(writer: stack.writer)
  let id = UUID()
  let entry = TransactionEntry(
    transaction: Transaction(
      id: id, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 100), note: note),
    parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: 100))])
  try repository.save(entry)

  // The write has returned. Everything after this line is what a clean exit would do and a
  // kill never gets to: no close, no checkpoint, no flush of our own.
  if commitOnly {
    FileHandle.standardOutput.write(Data("written\n".utf8))
    kill(getpid(), SIGKILL)
  }
  try stack.close()
  FileHandle.standardOutput.write(Data("written and closed\n".utf8))
} catch {
  FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
  exit(1)
}

/// The migrations, from the repository this package lives in. The probe is a tool of the
/// tests, run outside the sandbox, so a path is the simplest thing that can work.
func schemaDirectory() -> URL {
  if let named = ProcessInfo.processInfo.environment["OHMYMONEY_SCHEMA_DIR"] {
    return URL(fileURLWithPath: named, isDirectory: true)
  }
  return URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // ohmymoney-durability-probe
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // AppDatabase
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("Schema", isDirectory: true)
}
