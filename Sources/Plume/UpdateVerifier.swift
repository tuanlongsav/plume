import CryptoKit
import Foundation

enum UpdateVerifyError: Error, Equatable {
    case badManifest
    case versionMismatch
    case lengthMismatch(expected: Int, actual: Int)
    case digestMismatch
    case badSignatureEncoding
    case signatureInvalid
}

/// The checks that need no AppKit, so they run in `swift test`. The bundle
/// checks after unpacking (identifier, Developer ID team, version) live in
/// `Updater`, because they need the Security framework and a real bundle.
enum UpdateVerifier {
    /// Before downloading: the manifest must describe exactly the asset the
    /// release lists, for exactly the version its tag names.
    static func checkManifest(_ manifest: UpdateManifest, expectedVersion: AppVersion,
                              assetName: String, assetSize: Int) throws {
        guard manifest.format == 1, manifest.asset == assetName else {
            throw UpdateVerifyError.badManifest
        }
        guard AppVersion(manifest.version) == expectedVersion else {
            throw UpdateVerifyError.versionMismatch
        }
        guard manifest.length == assetSize else {
            throw UpdateVerifyError.lengthMismatch(expected: manifest.length, actual: assetSize)
        }
    }

    /// After downloading, before unpacking: length, then SHA-256, then the
    /// Ed25519 signature over every byte. Nothing is unzipped until this passes.
    static func verifyArchive(_ data: Data, manifest: UpdateManifest,
                              publicKey: Curve25519.Signing.PublicKey) throws {
        guard data.count == manifest.length else {
            throw UpdateVerifyError.lengthMismatch(expected: manifest.length, actual: data.count)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else {
            throw UpdateVerifyError.digestMismatch
        }
        guard let signature = Data(base64Encoded: manifest.ed25519), signature.count == 64 else {
            throw UpdateVerifyError.badSignatureEncoding
        }
        guard publicKey.isValidSignature(signature, for: data) else {
            throw UpdateVerifyError.signatureInvalid
        }
    }
}
