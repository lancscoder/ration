// Maintainer tool for signing update zips (Ed25519, CryptoKit; no dependencies).
//
//   swift scripts/update-signing.swift generate <private-key-file>   # once; prints the public key
//   swift scripts/update-signing.swift public   <private-key-file>   # prints the public key again
//   swift scripts/update-signing.swift sign     <private-key-file> <file>  # writes <file>.sig
//
// Keep the private key out of the repository and backed up (e.g. in a password
// manager). Losing it means users have to update by hand once, to a build with a new key.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("Couldn't read a signing key from \(path)")
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.count) {
case ("generate", 2):
    let path = (args.last! as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists; not overwriting it.") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 2):
    print(loadKey((args.last! as NSString).expandingTildeInPath).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    let key = loadKey((args[args.startIndex + 1] as NSString).expandingTildeInPath)
    let file = args.last!
    guard let data = FileManager.default.contents(atPath: file) else { fail("Couldn't read \(file)") }
    let signature = try key.signature(for: data).base64EncodedString()
    try Data(signature.utf8).write(to: URL(fileURLWithPath: file + ".sig"))
    print("Signed \(file) -> \(file).sig")
default:
    fail("usage: update-signing.swift generate|public <key-file> | sign <key-file> <file>")
}
