import AppCore
import Foundation

/// Cryptographically secure randomness for the salt and the nonce of an encrypted archive.
///
/// `CoreSample.SeededRandom` is deterministic on purpose — it exists so synthetic data can
/// be reproduced — and must never be used here: a predictable salt or nonce would undo the
/// encryption. The system generator is the right source, and it stays in the platform
/// layer, outside the portable core.
struct SecureRandomSource: RandomSource {
  private var generator = SystemRandomNumberGenerator()

  mutating func nextUInt64() -> UInt64 {
    generator.next()
  }
}
