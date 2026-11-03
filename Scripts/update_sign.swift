// Ed25519 keys and signatures for the in-app updater.
//
//   swift Scripts/update_sign.swift keygen <out.pem>
//   swift Scripts/update_sign.swift pubkey <key.pem>
//   swift Scripts/update_sign.swift sign   <key.pem> <file>
//   swift Scripts/update_sign.swift verify <public-key-base64> <file> <signature-base64>
//
// CryptoKit, not openssl: macOS ships LibreSSL as /usr/bin/openssl, whose
// Ed25519 `pkeyutl -rawin` support varies by release, and CryptoKit is exactly
// what the app verifies with, so the two cannot disagree. The key file is a
// standard PKCS#8 PEM, so OpenSSL 3 reads it too (see docs/RELEASE.md).
//
// `pubkey` prints the value for UpdateKeys.publicKeyBase64. The private key
// never belongs in the repository.
import CryptoKit
import Foundation

// PKCS#8 DER header for an Ed25519 private key; the 32-byte seed follows.
let pkcs8Prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03,
                        0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readPrivateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    let body = pem.split(separator: "\n")
        .filter { !$0.hasPrefix("-----") }
        .joined()
    guard let der = Data(base64Encoded: body), der.count == pkcs8Prefix.count + 32,
          der.prefix(pkcs8Prefix.count) == pkcs8Prefix,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
    else { fail("\(path) is not an Ed25519 PKCS#8 PEM private key") }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 2):
    let path = args[1]
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) exists — refusing to overwrite a signing key")
    }
    let key = Curve25519.Signing.PrivateKey()
    let der = pkcs8Prefix + key.rawRepresentation
    let pem = "-----BEGIN PRIVATE KEY-----\n\(der.base64EncodedString())\n-----END PRIVATE KEY-----\n"
    guard FileManager.default.createFile(atPath: path, contents: Data(pem.utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case ("pubkey", 2):
    print(readPrivateKey(args[1]).publicKey.rawRepresentation.base64EncodedString())

case ("sign", 3):
    let key = readPrivateKey(args[1])
    let data = readFile(args[2])
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())

case ("verify", 4):
    guard let raw = Data(base64Encoded: args[1]),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("bad public key") }
    guard let sig = Data(base64Encoded: args[3]) else { fail("bad signature encoding") }
    guard pub.isValidSignature(sig, for: readFile(args[2])) else { fail("signature INVALID") }
    print("signature OK")

default:
    fail("""
    usage:
      swift Scripts/update_sign.swift keygen <out.pem>
      swift Scripts/update_sign.swift pubkey <key.pem>
      swift Scripts/update_sign.swift sign   <key.pem> <file>
      swift Scripts/update_sign.swift verify <public-key-base64> <file> <signature-base64>
    """)
}
