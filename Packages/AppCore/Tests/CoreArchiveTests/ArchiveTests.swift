import CoreKit
import Foundation
import Testing

@testable import CoreArchive

@Suite("A transfer archive survives the round trip and refuses anything else")
struct ArchiveTests {
  private let supported = 7

  @Test func manifestKeysAreSortedAndStable() throws {
    let manifest = try sampleBuilder().manifest()
    let json = String(decoding: try manifest.encoded(), as: UTF8.self)
    let order = [
      "appVersion", "checksums", "createdAt", "formatVersion", "platform", "rowCounts",
      "schemaVersion",
    ]
    var previous = json.startIndex
    for key in order {
      let range = try #require(json.range(of: "\"\(key)\""))
      #expect(range.lowerBound >= previous)
      previous = range.lowerBound
    }
    #expect(try manifest.encoded() == manifest.encoded())
    // Paths keep their slashes instead of turning into \/ escapes.
    #expect(json.contains("data/csv/transactions.csv"))
  }

  @Test func manifestDecodesWhatItEncoded() throws {
    let manifest = try sampleBuilder().manifest()
    #expect(try ArchiveManifest.decode(manifest.encoded()) == manifest)
    #expect(manifest.formatVersion == ArchiveManifest.currentFormatVersion)
    #expect(manifest.createdAt == DateOnly(year: 2026, month: 9, day: 18))
    #expect(manifest.platform == "macOS")
    #expect(manifest.rowCounts == ["transactions": 2, "people": 1])
  }

  @Test func builtArchiveHasTheLayoutTheFormatPrescribes() throws {
    let container = try sampleBuilder().build()
    let entries = try ZipReader.entries(in: container)
    #expect(entries.first?.path == ArchivePaths.manifest)
    #expect(
      entries.map(\.path) == [
        "manifest.json", "data/csv/people.csv", "data/csv/transactions.csv",
        "data/database.sqlite", "settings.json",
      ])
  }

  @Test func buildingTwiceProducesTheSameBytes() throws {
    #expect(try sampleBuilder().build() == sampleBuilder().build())
  }

  @Test func openingReturnsEveryFileUnchanged() throws {
    let builder = try sampleBuilder()
    let archive = try ArchiveOpener.open(
      try builder.build(), supportedSchemaVersion: supported)

    #expect(archive.manifest == builder.manifest())
    #expect(archive.files.count == 4)
    #expect(archive.files[ArchivePaths.manifest] == nil)
    #expect(archive.database == Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]))
    #expect(archive.settings == Data("{\"language\":\"ru\"}".utf8))
    #expect(archive.csvTables == ["people", "transactions"])
    #expect(
      archive.csv(table: "transactions")
        == Data("id,date,amount\n1,2026-09-17,250.0000\n2,2026-09-18,-120.0000\n".utf8))
  }

  @Test func everyChecksumInTheManifestIsTheSha256OfItsFile() throws {
    let builder = try sampleBuilder()
    let archive = try ArchiveOpener.open(
      try builder.build(), supportedSchemaVersion: supported)
    #expect(archive.manifest.checksums.count == archive.files.count)
    for (path, data) in archive.files {
      #expect(archive.manifest.checksums[path] == SHA256.hexDigest(data))
    }
  }

  @Test func theManifestCannotBeSuppliedByHand() throws {
    var builder = try sampleBuilder()
    #expect(throws: ZipWriterError.invalidPath(ArchivePaths.manifest)) {
      try builder.add(path: ArchivePaths.manifest, text: "{}")
    }
  }

  @Test func aChangedFileBreaksTheManifestChecksum() throws {
    // The entry is rewritten with a correct CRC-32, so only the digest in the manifest
    // can notice: this is the check that survives an attacker with a zip tool.
    let original = try ZipReader.entries(in: try sampleBuilder().build())
    var writer = ZipWriter()
    for entry in original {
      var data = entry.data
      if entry.path == ArchivePaths.database { data[data.startIndex] ^= 0x01 }
      try writer.add(path: entry.path, data: data)
    }
    #expect(throws: CoreError.invalidArchive(reason: .checksumMismatch)) {
      try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    }
  }

  @Test func aFileNobodyVouchedForIsRejected() throws {
    let original = try ZipReader.entries(in: try sampleBuilder().build())
    var writer = ZipWriter()
    for entry in original { try writer.add(path: entry.path, data: entry.data) }
    try writer.add(path: "data/csv/extra.csv", text: "id\n1\n")
    #expect(throws: CoreError.invalidArchive(reason: .checksumMismatch)) {
      try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    }
  }

  @Test func aMissingFileIsRejected() throws {
    let original = try ZipReader.entries(in: try sampleBuilder().build())
    var writer = ZipWriter()
    for entry in original where entry.path != ArchivePaths.settings {
      try writer.add(path: entry.path, data: entry.data)
    }
    #expect(throws: CoreError.invalidArchive(reason: .checksumMismatch)) {
      try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    }
  }

  @Test func aContainerWithoutAManifestIsRejected() throws {
    var writer = ZipWriter()
    try writer.add(path: ArchivePaths.settings, text: "{}")
    #expect(throws: CoreError.invalidArchive(reason: .manifestMissing)) {
      try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    }
  }

  @Test func anUnreadableManifestIsRejected() throws {
    var writer = ZipWriter()
    try writer.add(path: ArchivePaths.manifest, text: "{ not json at all")
    #expect(throws: ArchiveManifest.Unreadable(field: "manifest", problem: .notJSON)) {
      try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    }
  }

  /// The JSON error was swallowed into one word, so the journal of a refused archive could not
  /// say which field of the manifest was wrong — the one thing another writer needs to know.
  @Test func anUnreadableManifestSaysWhichFieldAndWhatIsWrongWithIt() throws {
    let manifest = try JSONSerialization.jsonObject(with: try sampleBuilder().manifest().encoded())
    let fields = try #require(manifest as? [String: Any])
    let cases: [(String, Any?, ArchiveManifest.Unreadable)] = [
      ("schemaVersion", "three", .init(field: "schemaVersion", problem: .wrongType)),
      ("platform", nil, .init(field: "platform", problem: .missing)),
      ("appVersion", NSNull(), .init(field: "appVersion", problem: .null)),
      ("createdAt", "18.09.2026", .init(field: "createdAt", problem: .malformed)),
      ("rowCounts", ["transactions": "two"], .init(field: "rowCounts", problem: .wrongType)),
    ]
    for (field, value, expected) in cases {
      var edited = fields
      edited[field] = value
      let data = try JSONSerialization.data(withJSONObject: edited)
      #expect(throws: expected, "\(field)") { try ArchiveManifest.decode(data) }
    }
    #expect(throws: ArchiveManifest.Unreadable(field: "manifest", problem: .notJSON)) {
      try ArchiveManifest.decode(Data("[1, 2]".utf8))
    }
  }

  @Test func rowCountsAreCheckedAgainstTheCsvFiles() throws {
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 1,
        createdAt: DateOnly(year: 2026, month: 9, day: 18), platform: "macOS",
        rowCounts: ["transactions": 3]))
    try builder.add(
      path: ArchivePaths.csv(table: "transactions"),
      text: "id,amount\n1,10\n2,20\n")
    #expect(throws: CoreError.invalidArchive(reason: .rowCountMismatch)) {
      try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: supported)
    }
  }

  @Test func rowCountingUnderstandsQuotedLineBreaks() {
    let plain = Data("id,note\n1,a\n2,b\n".utf8)
    #expect(ArchiveOpener.countCSVRows(plain) == 2)
    let withoutTrailingBreak = Data("id,note\n1,a\n2,b".utf8)
    #expect(ArchiveOpener.countCSVRows(withoutTrailingBreak) == 2)
    let windowsBreaks = Data("id,note\r\n1,a\r\n2,b\r\n".utf8)
    #expect(ArchiveOpener.countCSVRows(windowsBreaks) == 2)
    let quoted = Data("id,note\n1,\"line one\nline two\"\n2,b\n".utf8)
    #expect(ArchiveOpener.countCSVRows(quoted) == 2)
    let escapedQuotes = Data("id,note\n1,\"say \"\"hi\"\"\"\n".utf8)
    #expect(ArchiveOpener.countCSVRows(escapedQuotes) == 1)
    let headerOnly = Data("id,note\n".utf8)
    #expect(ArchiveOpener.countCSVRows(headerOnly) == 0)
    #expect(ArchiveOpener.countCSVRows(Data()) == 0)
  }

  @Test func tablesWithoutACsvFileAreLeftToTheImporter() throws {
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 1,
        createdAt: DateOnly(year: 2026, month: 9, day: 18), platform: "macOS",
        rowCounts: ["budgets": 41]))
    try builder.add(path: ArchivePaths.database, data: Data([0x00]))
    let archive = try ArchiveOpener.open(
      try builder.build(), supportedSchemaVersion: supported)
    #expect(archive.manifest.rowCounts["budgets"] == 41)
  }

  @Test func anOlderSchemaIsAcceptedBecauseMigrationHappensOutside() throws {
    let container = try sampleBuilder(schemaVersion: 3).build()
    let archive = try ArchiveOpener.open(container, supportedSchemaVersion: supported)
    #expect(archive.manifest.schemaVersion == 3)
  }

  @Test func aNewerSchemaIsRefusedWithTheVersionsNamed() throws {
    let container = try sampleBuilder(schemaVersion: 99).build()
    #expect(throws: CoreError.unsupportedSchemaVersion(found: 99, supported: supported)) {
      try ArchiveOpener.open(container, supportedSchemaVersion: supported)
    }
  }

  @Test func aNewerArchiveFormatIsRefused() throws {
    let files = [ArchivePaths.settings: Data("{}".utf8)]
    let manifest = ArchiveManifest(
      formatVersion: ArchiveManifest.currentFormatVersion + 1, appVersion: "9.0.0",
      schemaVersion: 1, createdAt: DateOnly(year: 2026, month: 9, day: 18),
      platform: "Windows", rowCounts: [:],
      checksums: [ArchivePaths.settings: SHA256.hexDigest(files[ArchivePaths.settings]!)])
    var writer = ZipWriter()
    try writer.add(path: ArchivePaths.manifest, data: try manifest.encoded())
    for (path, data) in files { try writer.add(path: path, data: data) }
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    }
  }

  @Test func aDamagedContainerNeverLooksLikeAnArchive() throws {
    var container = try sampleBuilder().build()
    container = Data(container.prefix(container.count / 2))
    #expect(throws: CoreError.invalidArchive(reason: .truncated)) {
      try ArchiveOpener.open(container, supportedSchemaVersion: supported)
    }
  }

  @Test func aFieldTheManifestDoesNotKnowIsIgnoredRatherThanFatal() throws {
    // A newer build may add a field to manifest.json without raising the format version;
    // this build has to keep reading the fields it does know.
    let json = """
      {
        "appVersion" : "2.0.0",
        "checksums" : { "settings.json" : "\(SHA256.hexDigest(Data("{}".utf8)))" },
        "createdAt" : "2026-09-18",
        "formatVersion" : 1,
        "futureField" : { "nested" : [1, 2, 3] },
        "platform" : "Windows",
        "rowCounts" : { },
        "schemaVersion" : 1
      }
      """
    var writer = ZipWriter()
    try writer.add(path: ArchivePaths.manifest, text: json)
    try writer.add(path: ArchivePaths.settings, text: "{}")
    let archive = try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    #expect(archive.manifest.appVersion == "2.0.0")
    #expect(archive.manifest.platform == "Windows")
    #expect(archive.settings == Data("{}".utf8))
  }

  @Test func theManifestIsByteStableWhateverOrderTheFilesArrivedIn() throws {
    func make(_ order: [Int]) throws -> ArchiveBuilder {
      var builder = ArchiveBuilder(
        metadata: ArchiveBuilder.Metadata(
          appVersion: "1.0.0", schemaVersion: 1,
          createdAt: DateOnly(year: 2026, month: 9, day: 18), platform: "macOS",
          rowCounts: Dictionary(uniqueKeysWithValues: (0..<40).map { ("t\($0)", $0) })))
      for index in order {
        try builder.add(path: ArchivePaths.csv(table: "t\(index)"), text: "id\n\(index)\n")
      }
      return builder
    }
    let forwards = try make(Array(0..<40))
    let backwards = try make(Array((0..<40).reversed()))
    #expect(try forwards.manifest().encoded() == backwards.manifest().encoded())
    #expect(try forwards.build() == backwards.build())
  }

  @Test func theManifestNamesTheFieldsTheFormatDocumentPrescribes() throws {
    let json = String(decoding: try sampleBuilder().manifest().encoded(), as: UTF8.self)
    for field in [
      "formatVersion", "appVersion", "schemaVersion", "createdAt", "platform", "rowCounts",
      "checksums",
    ] {
      #expect(json.contains("\"\(field)\""), "manifest.json has no \(field)")
    }
    // The day is an ISO string, as the archive format spells it out.
    #expect(json.contains("\"createdAt\" : \"2026-09-18\""))
    // manifest.json never lists itself.
    #expect(!json.contains("\"manifest.json\""))
    // Digests are lower-case hexadecimal.
    let manifest = try sampleBuilder().manifest()
    for digest in manifest.checksums.values {
      #expect(digest.count == 64)
      #expect(digest == digest.lowercased())
    }
  }

  @Test func aDigestInUpperCaseIsStillAccepted() throws {
    let files = [ArchivePaths.settings: Data("{}".utf8)]
    let manifest = ArchiveManifest(
      appVersion: "1.0.0", schemaVersion: 1,
      createdAt: DateOnly(year: 2026, month: 9, day: 18), platform: "Windows",
      rowCounts: [:],
      checksums: [
        ArchivePaths.settings: SHA256.hexDigest(files[ArchivePaths.settings]!).uppercased()
      ])
    var writer = ZipWriter()
    try writer.add(path: ArchivePaths.manifest, data: try manifest.encoded())
    for (path, data) in files { try writer.add(path: path, data: data) }
    let archive = try ArchiveOpener.open(try writer.finish(), supportedSchemaVersion: supported)
    #expect(archive.files.count == 1)
  }

  @Test func rowCountingMatchesTheFilesTheExportWrites() {
    // A note with a Windows line break lives inside a quoted field and must not be
    // mistaken for the end of a record.
    let windowsNote = Data("id,note\n1,\"first\r\nsecond\"\n2,plain\n".utf8)
    #expect(ArchiveOpener.countCSVRows(windowsNote) == 2)
    // A lone carriage return ends a record, the way the reader treats it.
    #expect(ArchiveOpener.countCSVRows(Data("id,note\r1,a\r".utf8)) == 1)
    // A quoted empty value is a record of its own.
    #expect(ArchiveOpener.countCSVRows(Data("note\n\"\"\n".utf8)) == 1)
    #expect(ArchiveOpener.countCSVRows(Data("note\n\"\"".utf8)) == 1)
    // A value made of spaces is content, not an empty file.
    #expect(ArchiveOpener.countCSVRows(Data("note\n   \n".utf8)) == 1)
    // A byte-order mark does not open a record of its own.
    #expect(ArchiveOpener.countCSVRows(Data([0xEF, 0xBB, 0xBF]) + Data("id\n1\n".utf8)) == 1)
  }

  @Test func anArchiveWithoutAnyCsvStillOpens() throws {
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 1,
        createdAt: DateOnly(year: 2026, month: 9, day: 18), platform: "macOS", rowCounts: [:]))
    try builder.add(path: ArchivePaths.settings, text: "{}")
    let archive = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: supported)
    #expect(archive.csvTables.isEmpty)
    #expect(archive.database == nil)
  }

  @Test func anEmptyFileInsideTheArchiveKeepsItsPlace() throws {
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 1,
        createdAt: DateOnly(year: 2026, month: 9, day: 18), platform: "macOS",
        rowCounts: [:]))
    try builder.add(path: ArchivePaths.settings, data: Data())
    let archive = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: supported)
    #expect(archive.settings == Data())
    #expect(
      archive.manifest.checksums[ArchivePaths.settings]
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  @Test func archivePathsAndTableNamesAreEachOthersInverse() {
    for table in ["transactions", "debt_entries", "rates"] {
      #expect(ArchivePaths.table(forCSVPath: ArchivePaths.csv(table: table)) == table)
    }
    #expect(ArchivePaths.table(forCSVPath: "data/csv/.csv") == nil)
    #expect(ArchivePaths.table(forCSVPath: "data/database.sqlite") == nil)
    #expect(ArchivePaths.table(forCSVPath: "settings.json") == nil)
  }

  /// A table is a name, never a path: `data/csv/../x.csv` gave the table `../x`. Nothing writes
  /// a file by that name today; the guard makes it a property instead of a coincidence.
  @Test func aCSVPathThatLeavesItsFolderNamesNoTable() {
    for path in [
      "data/csv/../x.csv", "data/csv/sub/x.csv", "data/csv/..\\x.csv", "data/csv/...csv",
      "data/csv/..csv",
    ] {
      #expect(ArchivePaths.table(forCSVPath: path) == nil, "\(path)")
    }
  }
}
