import CryptoKit
import XCTest
@testable import Plume

final class UpdateVerifierTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()
    private let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let v12 = AppVersion("1.2")!

    /// What Scripts/release.sh writes for `data`.
    private func manifest(for data: Data, signedBy signer: Curve25519.Signing.PrivateKey? = nil,
                          version: String = "1.2", format: Int = 1,
                          ed25519: String? = nil, length: Int? = nil) throws -> UpdateManifest {
        let signature = try (signer ?? key).signature(for: data).base64EncodedString()
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return UpdateManifest(format: format, version: version, build: 10200,
                              minimumSystemVersion: "14.0", asset: "Plume-1.2.zip",
                              length: length ?? data.count, sha256: sha,
                              ed25519: ed25519 ?? signature)
    }

    func testAcceptsAGenuineArchive() throws {
        XCTAssertNoThrow(try UpdateVerifier.verifyArchive(
            payload, manifest: try manifest(for: payload), publicKey: key.publicKey))
    }

    func testDecodesTheManifestReleaseShWrites() throws {
        let json = """
        {
          "format": 1,
          "version": "1.2",
          "build": 10200,
          "minimumSystemVersion": "14.0",
          "asset": "Plume-1.2.zip",
          "length": 4096,
          "sha256": "ab",
          "ed25519": "cd"
        }
        """
        let m = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.asset, "Plume-1.2.zip")
        XCTAssertEqual(m.length, 4096)
        XCTAssertEqual(m.build, 10200)
    }

    func testRejectsATamperedArchive() throws {
        let m = try manifest(for: payload)
        var tampered = payload
        tampered[100] ^= 0x01
        XCTAssertThrowsError(try UpdateVerifier.verifyArchive(tampered, manifest: m,
                                                              publicKey: key.publicKey)) {
            XCTAssertEqual($0 as? UpdateVerifyError, .digestMismatch)
        }
    }

    /// The digest matches (an attacker can recompute it); the signature is
    /// what they cannot produce.
    func testRejectsAnArchiveSignedByAnotherKey() throws {
        let m = try manifest(for: payload, signedBy: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try UpdateVerifier.verifyArchive(payload, manifest: m,
                                                              publicKey: key.publicKey)) {
            XCTAssertEqual($0 as? UpdateVerifyError, .signatureInvalid)
        }
    }

    func testRejectsWrongLength() throws {
        let m = try manifest(for: payload, length: payload.count + 1)
        XCTAssertThrowsError(try UpdateVerifier.verifyArchive(payload, manifest: m,
                                                              publicKey: key.publicKey)) {
            XCTAssertEqual($0 as? UpdateVerifyError,
                           .lengthMismatch(expected: payload.count + 1, actual: payload.count))
        }
    }

    func testRejectsGarbageSignatures() throws {
        for junk in ["not base64!", "", Data(repeating: 1, count: 63).base64EncodedString()] {
            let m = try manifest(for: payload, ed25519: junk)
            XCTAssertThrowsError(try UpdateVerifier.verifyArchive(payload, manifest: m,
                                                                  publicKey: key.publicKey)) {
                XCTAssertEqual($0 as? UpdateVerifyError, .badSignatureEncoding, junk)
            }
        }
    }

    func testManifestMustDescribeTheListedAsset() throws {
        let m = try manifest(for: payload)
        XCTAssertNoThrow(try UpdateVerifier.checkManifest(
            m, expectedVersion: v12, assetName: "Plume-1.2.zip", assetSize: payload.count))

        XCTAssertThrowsError(try UpdateVerifier.checkManifest(
            m, expectedVersion: AppVersion("1.3")!, assetName: "Plume-1.2.zip",
            assetSize: payload.count)) {
            XCTAssertEqual($0 as? UpdateVerifyError, .versionMismatch)
        }
        XCTAssertThrowsError(try UpdateVerifier.checkManifest(
            m, expectedVersion: v12, assetName: "Plume-1.3.zip", assetSize: payload.count)) {
            XCTAssertEqual($0 as? UpdateVerifyError, .badManifest)
        }
        XCTAssertThrowsError(try UpdateVerifier.checkManifest(
            try manifest(for: payload, format: 2), expectedVersion: v12,
            assetName: "Plume-1.2.zip", assetSize: payload.count)) {
            XCTAssertEqual($0 as? UpdateVerifyError, .badManifest)
        }
        XCTAssertThrowsError(try UpdateVerifier.checkManifest(
            m, expectedVersion: v12, assetName: "Plume-1.2.zip", assetSize: 1)) {
            XCTAssertEqual($0 as? UpdateVerifyError,
                           .lengthMismatch(expected: payload.count, actual: 1))
        }
    }

    /// An empty or malformed key turns the updater off in every build that
    /// ships it, and those installs could then only be updated by hand.
    func testEmbeddedPublicKeyIsUsable() {
        XCTAssertNotNil(UpdateKeys.publicKey, "UpdateKeys.publicKeyBase64 is not a 32-byte Ed25519 key")
    }
}
