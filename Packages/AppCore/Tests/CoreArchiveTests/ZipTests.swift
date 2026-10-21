import CoreKit
import Foundation
import Testing

@testable import CoreArchive

@Suite("Zip containers round-trip and reject damage")
struct ZipTests {
  private func littleEndianUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }

  private func littleEndianUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    let bytes = [UInt8](data)
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  @Test func writesAndReadsOneFile() throws {
    var writer = ZipWriter()
    try writer.add(path: "settings.json", text: "{\"language\":\"ru\"}")
    let container = try writer.finish()

    let entries = try ZipReader.entries(in: container)
    #expect(entries.count == 1)
    #expect(entries[0].path == "settings.json")
    #expect(entries[0].data == Data("{\"language\":\"ru\"}".utf8))
  }

  @Test func roundTripsSeveralFilesInTheOrderTheyWereAdded() throws {
    let payloads: [(String, Data)] = [
      ("manifest.json", Data("{}".utf8)),
      ("data/database.sqlite", Data((0..<4096).map { UInt8($0 % 256) })),
      ("data/csv/transactions.csv", Data("id,amount\n1,250.0000\n".utf8)),
      ("settings.json", Data("{}".utf8)),
    ]
    var writer = ZipWriter()
    for (path, data) in payloads { try writer.add(path: path, data: data) }
    let container = try writer.finish()

    let entries = try ZipReader.entries(in: container)
    #expect(entries.map(\.path) == payloads.map(\.0))
    for (index, payload) in payloads.enumerated() {
      #expect(entries[index].data == payload.1)
    }
    let files = try ZipReader.files(in: container)
    #expect(files.count == payloads.count)
    #expect(files["data/database.sqlite"] == payloads[1].1)
  }

  @Test func storesEmptyFiles() throws {
    var writer = ZipWriter()
    try writer.add(path: "empty.bin", data: Data())
    try writer.add(path: "after-empty.txt", text: "x")
    let files = try ZipReader.files(in: try writer.finish())
    #expect(files["empty.bin"] == Data())
    #expect(files["after-empty.txt"] == Data("x".utf8))
  }

  @Test func keepsNonAsciiPathsAndContents() throws {
    var writer = ZipWriter()
    try writer.add(path: "данные/операции.csv", text: "дата,сумма\n2026-09-18,250\n")
    try writer.add(path: "данные/люди.csv", text: "имя\nКоллега\n")
    let container = try writer.finish()

    // Bit 11 of the general purpose flags declares the name to be UTF-8.
    #expect(littleEndianUInt16(container, 6) & 0x0800 == 0x0800)
    let files = try ZipReader.files(in: container)
    #expect(files["данные/операции.csv"] == Data("дата,сумма\n2026-09-18,250\n".utf8))
    #expect(files["данные/люди.csv"] == Data("имя\nКоллега\n".utf8))
  }

  @Test func headersFollowTheSpecification() throws {
    let payload = Data("id,amount\n1,250.0000\n".utf8)
    var writer = ZipWriter()
    try writer.add(path: "a.csv", data: payload)
    let container = try writer.finish()

    #expect(littleEndianUInt32(container, 0) == 0x0403_4B50)  // local header
    #expect(littleEndianUInt16(container, 4) == 20)  // version needed
    #expect(littleEndianUInt16(container, 8) == 0)  // stored, no compression
    #expect(littleEndianUInt32(container, 14) == CRC32.checksum(payload))
    #expect(littleEndianUInt32(container, 18) == UInt32(payload.count))  // compressed
    #expect(littleEndianUInt32(container, 22) == UInt32(payload.count))  // uncompressed
    #expect(littleEndianUInt16(container, 26) == 5)  // name length
    #expect(littleEndianUInt16(container, 28) == 0)  // no extra field

    let endOffset = container.count - 22
    #expect(littleEndianUInt32(container, endOffset) == 0x0605_4B50)
    #expect(littleEndianUInt16(container, endOffset + 8) == 1)  // entries on this disk
    #expect(littleEndianUInt16(container, endOffset + 10) == 1)  // entries in total
    let directoryOffset = Int(littleEndianUInt32(container, endOffset + 16))
    #expect(littleEndianUInt32(container, directoryOffset) == 0x0201_4B50)
    #expect(littleEndianUInt16(container, endOffset + 20) == 0)  // no comment
  }

  @Test func timestampsAreTheStartOfTheDosEpochByDefault() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "a")
    let container = try writer.finish()
    #expect(littleEndianUInt16(container, 10) == 0)  // midnight
    #expect(littleEndianUInt16(container, 12) == 0x0021)  // 1980-01-01
  }

  @Test func theSameInputAlwaysProducesTheSameBytes() throws {
    func make() throws -> Data {
      var writer = ZipWriter(modified: DateOnly(year: 2026, month: 9, day: 18))
      try writer.add(path: "b.txt", text: "second")
      try writer.add(path: "a.txt", text: "first")
      return try writer.finish()
    }
    #expect(try make() == make())
  }

  @Test func anEmptyContainerIsStillAValidZip() throws {
    let container = try ZipWriter().finish()
    #expect(container.count == 22)
    #expect(try ZipReader.entries(in: container).isEmpty)
  }

  @Test func rejectsPathsThatCannotLiveInAnArchive() throws {
    var writer = ZipWriter()
    #expect(throws: ZipWriterError.invalidPath("")) { try writer.add(path: "", data: Data()) }
    #expect(throws: ZipWriterError.invalidPath("/etc/passwd")) {
      try writer.add(path: "/etc/passwd", data: Data())
    }
    #expect(throws: ZipWriterError.invalidPath("../escape.txt")) {
      try writer.add(path: "../escape.txt", data: Data())
    }
    #expect(throws: ZipWriterError.invalidPath("data\\file.csv")) {
      try writer.add(path: "data\\file.csv", data: Data())
    }
    #expect(throws: ZipWriterError.invalidPath("data/")) {
      try writer.add(path: "data/", data: Data())
    }
  }

  @Test func rejectsTheSamePathTwice() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "first")
    #expect(throws: ZipWriterError.duplicatePath("a.txt")) {
      try writer.add(path: "a.txt", text: "second")
    }
  }

  @Test func sizeLimitsAreStatedInTermsOfPlainZip() {
    // The writer refuses to produce a container it cannot address; zip64 is out of scope.
    #expect(ZipWriter.maximumContainerSize == Int(UInt32.max))
    #expect(ZipWriter.maximumEntryCount == Int(UInt16.max))
    #expect(ZipWriterError.containerTooLarge.message.contains("4 GiB"))
    #expect(ZipWriterError.entryTooLarge(path: "data/database.sqlite").message.contains("4 GiB"))
  }

  @Test func randomBytesAreNotAZipContainer() {
    let noise = Data((0..<200).map { UInt8(($0 &* 37) % 251) })
    #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
      try ZipReader.entries(in: noise)
    }
  }

  @Test func anEmptyFileIsNotAZipContainer() {
    #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
      try ZipReader.entries(in: Data())
    }
  }

  @Test func aContainerWithoutItsTailIsTruncated() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    let container = try writer.finish()
    let cut = container.prefix(container.count - 30)
    #expect(throws: CoreError.invalidArchive(reason: .truncated)) {
      try ZipReader.entries(in: Data(cut))
    }
  }

  @Test func aDirectoryOffsetPastTheEndIsTruncated() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    var container = try writer.finish()
    let endOffset = container.count - 22
    container[container.startIndex + endOffset + 16] = 0xFF
    container[container.startIndex + endOffset + 17] = 0xFF
    #expect(throws: CoreError.invalidArchive(reason: .truncated)) {
      try ZipReader.entries(in: container)
    }
  }

  @Test func aFlippedByteInThePayloadBreaksTheEntryChecksum() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload that is long enough to be found")
    var container = try writer.finish()
    let offset = container.startIndex + 30 + 5 + 10
    container[offset] ^= 0xFF
    #expect(throws: CoreError.invalidArchive(reason: .checksumMismatch)) {
      try ZipReader.entries(in: container)
    }
  }

  @Test func compressedEntriesAreNotSupported() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    var container = try writer.finish()
    let endOffset = container.count - 22
    let directoryOffset = Int(littleEndianUInt32(container, endOffset + 16))
    // Claim method 8 (deflate) in the central directory.
    container[container.startIndex + directoryOffset + 10] = 8
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try ZipReader.entries(in: container)
    }
  }

  /// A zip64 container keeps its counts, sizes and offsets in records of its own and puts -1 in
  /// the classic fields (APPNOTE 4.4.1.4). This reader does not follow them: a zip64 container
  /// from another writer is unsupported, as a compressed one is, not damaged.
  @Test func aZip64ContainerIsUnsupportedNotDamaged() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    let classic = try writer.finish()
    let endOffset = classic.count - 22
    let directorySize = UInt64(littleEndianUInt32(classic, endOffset + 12))
    let directoryOffset = UInt64(littleEndianUInt32(classic, endOffset + 16))

    var container = Data(classic.prefix(endOffset))
    let recordOffset = UInt64(container.count)
    // The zip64 end of central directory record, then its locator.
    append(&container, UInt32(0x0606_4B50))
    append(&container, UInt64(44))
    append(&container, UInt16(45))
    append(&container, UInt16(45))
    append(&container, UInt32(0))
    append(&container, UInt32(0))
    append(&container, UInt64(1))
    append(&container, UInt64(1))
    append(&container, directorySize)
    append(&container, directoryOffset)
    append(&container, UInt32(0x0706_4B50))
    append(&container, UInt32(0))
    append(&container, recordOffset)
    append(&container, UInt32(1))
    // The classic end record, every field that zip64 holds set to -1.
    append(&container, UInt32(0x0605_4B50))
    append(&container, UInt16(0))
    append(&container, UInt16(0))
    append(&container, UInt16.max)
    append(&container, UInt16.max)
    append(&container, UInt32.max)
    append(&container, UInt32.max)
    append(&container, UInt16(0))

    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try ZipReader.entries(in: container)
    }
  }

  /// An entry whose sizes live in its zip64 extra field says -1 in the central directory.
  @Test func anEntryWithZip64SizesIsUnsupportedNotDamaged() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    var container = try writer.finish()
    let endOffset = container.count - 22
    let directoryOffset = Int(littleEndianUInt32(container, endOffset + 16))
    for offset in 20..<28 {  // compressed and uncompressed size
      container[container.startIndex + directoryOffset + offset] = 0xFF
    }
    #expect(throws: CoreError.invalidArchive(reason: .unsupportedFormatVersion)) {
      try ZipReader.entries(in: container)
    }
  }

  private func append<Value: FixedWidthInteger>(_ data: inout Data, _ value: Value) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  @Test func aDamagedCentralDirectorySignatureIsNotAZip() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    var container = try writer.finish()
    let endOffset = container.count - 22
    let directoryOffset = Int(littleEndianUInt32(container, endOffset + 16))
    container[container.startIndex + directoryOffset + 3] = 0x00
    #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
      try ZipReader.entries(in: container)
    }
  }

  /// A container written by Python's `zipfile`: a directory marker, an entry carrying an
  /// extra field the writer here never produces, an empty file and an archive comment
  /// after the end record. Reading it proves the reader follows the specification rather
  /// than its own output.
  private static let foreignContainer = bytes(
    hex:
      "504b03041400000000000000210000000000000000000000000002000000642f504b03041400000800000000"
      + "21000fe95bcd050000000500000010000800d0b4d0b0d0bdd0bdd18bd0b52e63737655540400030000006964"
      + "0a310a504b03041400000000007d0d325d00000000000000000000000009000000656d7074792e62696e504b"
      + "0102140314000000000000002100000000000000000000000000020000000000000000001000ed4100000000"
      + "642f504b01021403140000080000000021000fe95bcd05000000050000001000080000000000000000008001"
      + "20000000d0b4d0b0d0bdd0bdd18bd0b52e6373765554040003000000504b010214031400000000007d0d325d"
      + "00000000000000000000000009000000000000000000000080015b000000656d7074792e62696e504b050600"
      + "00000003000300ad00000082000000050044656d6f21")

  @Test func readsAContainerWrittenByAnotherImplementation() throws {
    let entries = try ZipReader.entries(in: Data(ZipTests.foreignContainer))
    // The directory marker carries no payload and is not an entry of the archive.
    #expect(entries.map(\.path) == ["данные.csv", "empty.bin"])
    #expect(entries[0].data == Data("id\n1\n".utf8))
    #expect(entries[1].data == Data())
  }

  @Test func anArchiveCommentAfterTheEndRecordIsAccepted() throws {
    let container = Data(ZipTests.foreignContainer)
    // The 5-byte comment baked into the fixture.
    #expect(container.suffix(5) == Data("Demo!".utf8))
    #expect(littleEndianUInt16(container, container.count - 5 - 2) == 5)
    #expect(try ZipReader.files(in: container).count == 2)
  }

  @Test func bytesBeforeTheContainerAreNotSilentlyIgnored() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    let container = Data("GARBAGE!".utf8) + (try writer.finish())
    #expect(throws: CoreError.self) { try ZipReader.entries(in: container) }
  }

  @Test func bytesAfterTheEndRecordAreNotSilentlyIgnored() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    let container = (try writer.finish()) + Data("TRAILING".utf8)
    #expect(throws: CoreError.self) { try ZipReader.entries(in: container) }
  }

  @Test func anEndRecordThatPromisesMoreEntriesThanItHoldsIsTruncated() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "payload")
    var container = try writer.finish()
    let endOffset = container.count - 22
    container[container.startIndex + endOffset + 10] = 4  // total entries
    #expect(throws: CoreError.invalidArchive(reason: .truncated)) {
      try ZipReader.entries(in: container)
    }
  }

  @Test func aPathRepeatedInsideOneContainerIsRejected() throws {
    var writer = ZipWriter()
    try writer.add(path: "a.txt", text: "first")
    try writer.add(path: "b.txt", text: "first")
    var container = try writer.finish()
    // Both entries hold the same bytes, so only the names have to be made equal for the
    // CRC-32 of each entry to keep matching.
    while let range = container.range(of: Data("b.txt".utf8)) {
      container.replaceSubrange(range, with: Data("a.txt".utf8))
    }
    #expect(try ZipReader.entries(in: container).count == 2)
    #expect(throws: CoreError.invalidArchive(reason: .notAZipContainer)) {
      try ZipReader.files(in: container)
    }
  }

  @Test func payloadsOnTheUsualBufferBoundariesSurvive() throws {
    let sizes = [0, 1, 4095, 4096, 4097, 65535, 65536, 65537]
    var writer = ZipWriter()
    for size in sizes {
      try writer.add(path: "b\(size).bin", data: Data((0..<size).map { UInt8($0 % 251) }))
    }
    let files = try ZipReader.files(in: try writer.finish())
    for size in sizes {
      #expect(files["b\(size).bin"]?.count == size)
    }
  }

  @Test func aNameOfSixtyFourKilobytesStillRoundTrips() throws {
    // The name length field is 16 bits wide; 65535 bytes is the last name that fits.
    let name = String(repeating: "п", count: 32_000) + ".csv"
    #expect(name.utf8.count <= Int(UInt16.max))
    var writer = ZipWriter()
    try writer.add(path: name, text: "x")
    let files = try ZipReader.files(in: try writer.finish())
    #expect(files[name] == Data("x".utf8))
  }

  @Test func aNameThatDoesNotFitTheHeaderFieldIsRefused() throws {
    var writer = ZipWriter()
    let name = String(repeating: "a", count: Int(UInt16.max) + 1)
    #expect(throws: ZipWriterError.invalidPath(name)) { try writer.add(path: name, data: Data()) }
  }

  @Test func theChecksumOfAnEmptyEntryIsZero() throws {
    var writer = ZipWriter()
    try writer.add(path: "empty.bin", data: Data())
    let container = try writer.finish()
    #expect(littleEndianUInt32(container, 14) == 0)  // local header CRC-32
    #expect(try ZipReader.entries(in: container)[0].checksum == 0)
  }
}
