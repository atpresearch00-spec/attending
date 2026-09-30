// Signs release zips so the in-app updater can prove an update came from you.
//
//   swift scripts/sign-release.swift <file>     writes <file>.sig
//   swift scripts/sign-release.swift --public   prints the public key (goes in Updater.swift)
//
// The private key lives outside the repo, in ~/.config/attending/release-signing-key
// (created on first use, readable only by you). Back it up: without it, published apps
// can't verify future updates.
import CryptoKit
import Foundation

let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/attending", isDirectory: true)
let keyFile = folder.appendingPathComponent("release-signing-key")
let key: Curve25519.Signing.PrivateKey
if let data = try? Data(contentsOf: keyFile), let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
} else {
    key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    FileHandle.standardError.write(Data("Created a new release signing key at \(keyFile.path). Back it up.\n".utf8))
}
let argument = CommandLine.arguments.dropFirst().first ?? "--public"
if argument == "--public" {
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    let file = URL(fileURLWithPath: argument)
    let signature = try key.signature(for: Data(contentsOf: file))
    try Data(signature.base64EncodedString().utf8).write(to: file.appendingPathExtension("sig"))
    print(file.appendingPathExtension("sig").path)
}
