// usage: verify-ed <public key base64> <signature base64> <file> — exits 0 when the EdDSA signature is valid.
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard a.count == 4, let pub = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let file = FileManager.default.contents(atPath: a[3]) else { fputs("usage: verify-ed <pub> <sig> <file>\n", stderr); exit(2) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
guard key.isValidSignature(sig, for: file) else { fputs("EdDSA signature does NOT match SUPublicEDKey\n", stderr); exit(1) }
print("EdDSA signature matches SUPublicEDKey")
