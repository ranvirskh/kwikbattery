// Signs a release zip for KwikBattery's updater (Ed25519).
//   swift sign-update.swift keygen <private-key-file>        makes a key, prints the public key to put in UpdateChecker.swift
//   swift sign-update.swift sign <private-key-file> <zip>    writes <zip>.sig
import CryptoKit
import Foundation

let a = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
guard a.count >= 3 else { fail("usage: keygen <keyfile> | sign <keyfile> <zip>") }
switch a[1] {
case "keygen":
    guard !FileManager.default.fileExists(atPath: a[2]) else { fail("\(a[2]) already exists; not overwriting") }
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: a[2], contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard a.count == 4, let raw = try? String(contentsOfFile: a[2], encoding: .utf8), let keyData = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData), let zip = FileManager.default.contents(atPath: a[3]) else { fail("cannot read key or zip") }
    let sig = try key.signature(for: zip)
    try Data(sig.base64EncodedString().utf8).write(to: URL(fileURLWithPath: a[3] + ".sig"))
    print("signed \(a[3])")
default: fail("unknown command")
}
