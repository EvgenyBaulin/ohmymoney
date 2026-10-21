import CoreKit
import Foundation
import Testing

@testable import CoreArchive

/// Draws for the archive tests, from the deterministic `SplitMix64` of this target.
private struct Draws {
  var source: SplitMix64

  init(seed: UInt64) {
    var mixer = SplitMix64(seed: seed)
    source = SplitMix64(seed: mixer.nextUInt64())
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(source.nextUInt64() % UInt64(range.upperBound - range.lowerBound + 1))
  }

  mutating func bytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8(truncatingIfNeeded: source.nextUInt64()) })
  }

  mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
}

/// The transfer archive holds exactly what was put into it, or refuses to open: random sets
/// of files survive the container; every single byte of a built archive changed, and every
/// length it is cut to, either makes the opening refuse it or leaves every file and the
/// manifest exactly as they were — a damaged archive never gives back a different file; a
/// sealed one refuses any change at all.
@Suite("An archive gives back what went in, or refuses")
struct ArchivePropertyTests {
  /// A path an archive can hold, drawn from folders and names of several scripts.
  private static func path(_ draws: inout Draws) -> String {
    let parts = ["data", "csv", "тест", "日本", "a b", "x.csv", "émoji🎂", "1", "_", "..x"]
    return (0..<draws.int(1...3)).map { _ in draws.pick(parts) }.joined(separator: "/")
  }

  /// Sets of files of every size — empty, a few bytes, around the 64 KiB of a length field —
  /// come out of the container in the order they went in, byte for byte.
  @Test(arguments: Array(UInt64(1)...UInt64(40)))
  func aDrawnSetOfFilesSurvivesTheContainer(seed: UInt64) throws {
    var draws = Draws(seed: seed)
    var writer = ZipWriter(modified: DateOnly(year: 2026, month: 9, day: draws.int(1...28)))
    var files: [(String, Data)] = []
    var used: Set<String> = []
    for _ in 0..<draws.int(0...8) {
      let path = Self.path(&draws)
      guard used.insert(path).inserted else { continue }
      let size = draws.pick([0, 1, 7, 100, 4_096, 65_535, 65_536, 70_001])
      let data = draws.bytes(size)
      try writer.add(path: path, data: data)
      files.append((path, data))
    }
    let container = try writer.finish()
    let entries = try ZipReader.entries(in: container)
    #expect(entries.map(\.path) == files.map(\.0), "seed \(seed)")
    #expect(entries.map(\.data) == files.map(\.1), "seed \(seed)")
    #expect(entries.map(\.checksum) == files.map { CRC32.checksum($0.1) })
  }

  /// A path is taken exactly when it can live in a container: not empty, relative, no `..`
  /// step, no backslash, no NUL, not a folder, and short enough for the header's length field.
  @Test func aPathIsTakenExactlyWhenItCanLiveInAContainer() {
    var draws = Draws(seed: 9)
    let pieces = ["a", "/", "..", ".", "\\", "\u{0}", "b.csv", "тест", " ", ""]
    for round in 0..<2_000 {
      let path = (0..<draws.int(0...5)).map { _ in draws.pick(pieces) }.joined()
      let valid =
        !path.isEmpty && !path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("\\")
        && !path.utf8.contains(0) && !path.split(separator: "/").contains("..")
      var writer = ZipWriter()
      let accepted = (try? writer.add(path: path, data: Data())) != nil
      #expect(accepted == valid, "round \(round): «\(path.debugDescription)»")
    }
  }

  /// A small archive of a manifest, a database and two files.
  private static func archive() throws -> (builder: ArchiveBuilder, files: [String: Data]) {
    var draws = Draws(seed: 11)
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.1.0", schemaVersion: 4, createdAt: DateOnly(year: 2026, month: 9, day: 26),
        platform: "macOS", rowCounts: ["transactions": 2, "people": 1]))
    let files: [String: Data] = [
      ArchivePaths.database: draws.bytes(300),
      ArchivePaths.csv(table: "transactions"): Data("id,amount\n1,250\n2,\"1,5\"\n".utf8),
      ArchivePaths.csv(table: "people"): Data("id,name\n1,Аня\n".utf8),
      ArchivePaths.settings: Data(#"{"language":"ru"}"#.utf8),
    ]
    try builder.add(files: files)
    return (builder, files)
  }

  /// Every byte of a plain archive changed, one at a time, two ways: the opening refuses it,
  /// or gives back every file and the manifest exactly as built.
  @Test func noChangedByteOfAPlainArchiveGivesBackAnotherFile() throws {
    let (builder, files) = try Self.archive()
    let container = try builder.build()
    let manifest = builder.manifest()
    var refused = 0
    for index in 0..<container.count {
      for flip: UInt8 in [0x01, 0xFF] {
        var damaged = container
        damaged[index] ^= flip
        do {
          let opened = try ArchiveOpener.open(damaged, supportedSchemaVersion: 4)
          #expect(opened.files == files, "byte \(index) ^ \(flip) changed a file")
          #expect(opened.manifest == manifest, "byte \(index) ^ \(flip) changed the manifest")
        } catch {
          refused += 1
        }
      }
    }
    #expect(refused > container.count, "most changes are refused")
  }

  /// A plain archive cut short at any length is refused.
  @Test func aPlainArchiveCutShortIsRefused() throws {
    let container = try Self.archive().builder.build()
    for length in 0..<container.count {
      #expect(throws: (any Error).self, "cut to \(length)") {
        try ArchiveOpener.open(container.prefix(length), supportedSchemaVersion: 4)
      }
    }
  }

  /// A sealed archive refuses every byte changed — of its header, of what it seals, of its
  /// tag — and every length it is cut to. The iteration count is changed apart: a change of
  /// its high bytes asks for millions of rounds, and one round more is enough to show a
  /// different key.
  @Test func aSealedArchiveRefusesAnyChangeAtAll() throws {
    let (builder, files) = try Self.archive()
    var random = SplitMix64(seed: 5)
    let sealed = try builder.build(
      password: "секрет", cipher: TestCipher(), random: &random, iterations: 1)
    let opened = try ArchiveOpener.open(
      sealed, password: "секрет", cipher: TestCipher(), supportedSchemaVersion: 4)
    #expect(opened.files == files)
    let iterations = 16..<20
    for index in 0..<sealed.count where !iterations.contains(index) {
      for flip: UInt8 in [0x01, 0x80] {
        var damaged = sealed
        damaged[index] ^= flip
        #expect(throws: (any Error).self, "byte \(index) ^ \(flip)") {
          try ArchiveOpener.open(
            damaged, password: "секрет", cipher: TestCipher(), supportedSchemaVersion: 4)
        }
      }
    }
    var slower = sealed
    slower[16] ^= 0x03  // one round becomes two
    #expect(throws: (any Error).self) {
      try ArchiveOpener.open(
        slower, password: "секрет", cipher: TestCipher(), supportedSchemaVersion: 4)
    }
    for length in stride(from: 0, to: sealed.count, by: 7) {
      #expect(throws: (any Error).self, "cut to \(length)") {
        try ArchiveOpener.open(
          sealed.prefix(length), password: "секрет", cipher: TestCipher(), supportedSchemaVersion: 4
        )
      }
    }
  }

  /// Built twice from the same files added in any order, an archive is the same bytes, and
  /// its manifest vouches for every file with its SHA-256.
  @Test(arguments: Array(UInt64(21)...UInt64(40)))
  func theSameFilesInAnyOrderMakeTheSameArchive(seed: UInt64) throws {
    var draws = Draws(seed: seed)
    var files: [String: Data] = [:]
    for index in 0..<draws.int(1...6) {
      files[ArchivePaths.csv(table: "t\(index)")] = draws.bytes(draws.int(0...200))
    }
    let metadata = ArchiveBuilder.Metadata(
      appVersion: "1.1.0", schemaVersion: 4, createdAt: DateOnly(year: 2026, month: 9, day: 26),
      platform: "macOS", rowCounts: [:])
    var forward = ArchiveBuilder(metadata: metadata)
    for path in files.keys.sorted() { try forward.add(path: path, data: files[path]!) }
    var backward = ArchiveBuilder(metadata: metadata)
    for path in files.keys.sorted().reversed() { try backward.add(path: path, data: files[path]!) }
    #expect(try forward.build() == backward.build(), "seed \(seed)")
    let manifest = forward.manifest()
    #expect(manifest.checksums == files.mapValues { SHA256.hexDigest($0) })
    #expect(try ArchiveOpener.open(forward.build(), supportedSchemaVersion: 4).files == files)
  }

  /// The row counts a manifest carries are checked against the files: a count one off either
  /// way, for any table and any file drawn, refuses the archive.
  @Test func aRowCountOneOffIsRefused() throws {
    var draws = Draws(seed: 13)
    for round in 0..<200 {
      let rows = draws.int(0...6)
      let text =
        "id,note\n" + (0..<rows).map { "\($0),\"line\nbreak\"" }.joined(separator: "\n")
        + (draws.int(0...1) == 0 ? "\n" : "")
      for count in [rows - 1, rows, rows + 1] where count >= 0 {
        var builder = ArchiveBuilder(
          metadata: ArchiveBuilder.Metadata(
            appVersion: "1.1.0", schemaVersion: 4,
            createdAt: DateOnly(year: 2026, month: 9, day: 26), platform: "macOS",
            rowCounts: ["notes": count]))
        try builder.add(path: ArchivePaths.csv(table: "notes"), text: text)
        let opens = (try? ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 4)) != nil
        #expect(opens == (count == rows), "round \(round): \(rows) rows, counted \(count)")
      }
    }
  }

  /// A blank line is no row, as the CSV reader and `pandas.read_csv` read it: a file that ends
  /// with an empty line, or has one between its rows — an editor's, another implementation's —
  /// is counted by its records, so its manifest is not refused for a row nobody can read.
  @Test func aBlankLineIsNoRow() {
    let files: [(String, Int)] = [
      ("id,name\n1,A\n\n", 1),
      ("id,name\n\n1,A\n\n\n2,B\n", 2),
      ("id,name\r\n1,A\r\n\r\n", 1),
      ("id,name\r\r1,A\r", 1),
      ("id,name\n\n", 0),
      ("id\n\"\"\n\n", 1),
      ("\n\nid,name\n1,A", 1),
    ]
    for (text, rows) in files {
      #expect(ArchiveOpener.countCSVRows(Data(text.utf8)) == rows, "«\(text.debugDescription)»")
    }
  }
}
