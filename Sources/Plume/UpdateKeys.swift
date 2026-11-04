import CryptoKit
import Foundation

/// The public half of the key that signs update archives (Ed25519, 32 raw
/// bytes, base64). Print it with
///
///     swift Scripts/update_sign.swift pubkey <private-key.pem>
///
/// An empty value turns the updater off: a build without a key could
/// verify nothing. Changing it strands every install that embeds the old key
/// unless a release signed with the OLD key first ships the new one — see
/// docs/RELEASE.md before touching this line.
enum UpdateKeys {
    static let publicKeyBase64 = "QeV7o0WsqSCiZQqSfSJjBqY6Vd+LG6gK8kD1gceSsa8="

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}
