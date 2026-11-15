import AppDatabase
import Foundation

/// The number of migrations the app ships, read from the same bundle folder the database
/// opens, so a new migration never needs a new constant in the upgrade tests.
let expectedSchema: Int = {
  let count = try? BundleSchemaSource(bundle: .main).migrations().count
  return count ?? -1
}()
