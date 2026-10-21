import CoreKit
import Foundation

/// Reads the SQL migrations that live in `Schema/` at the repository root. The very same
/// files are shipped inside the app bundle and will be reused by the Windows port, so the
/// schema never exists as generated Swift.
public struct DirectorySchemaSource: SchemaSource {
  private let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public func migrations() throws -> [SchemaMigration] {
    let files = try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension.lowercased() == "sql" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    return try files.map { url in
      SchemaMigration(
        name: url.deletingPathExtension().lastPathComponent,
        sql: try String(contentsOf: url, encoding: .utf8))
    }
  }
}

/// The same migrations, read from the `Schema` folder reference inside the app bundle.
public struct BundleSchemaSource: SchemaSource {
  private let bundle: Bundle
  private let subdirectory: String

  public init(bundle: Bundle = .main, subdirectory: String = "Schema") {
    self.bundle = bundle
    self.subdirectory = subdirectory
  }

  public func migrations() throws -> [SchemaMigration] {
    guard let directory = bundle.url(forResource: subdirectory, withExtension: nil) else {
      throw DatabaseError.schemaMissing
    }
    return try DirectorySchemaSource(directory: directory).migrations()
  }
}

public enum DatabaseError: Error, Equatable, Sendable {
  case schemaMissing
  case migrationMismatch(applied: [String], onDisk: [String])
  case notFound
  case unbalancedParts
}
