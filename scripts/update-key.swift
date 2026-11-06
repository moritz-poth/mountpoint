// Signing key for updates (Ed25519). The private key lives only in the login Keychain of the release Mac,
// never in the repo. The app carries the public key and installs only zips signed with this key.
//
//   swift scripts/update-key.swift new          create the key once, print the public key for Updater.swift
//   swift scripts/update-key.swift public       print the public key
//   swift scripts/update-key.swift sign <zip>   write <zip>.sig (base64 signature), used by build-app.sh
//
// Losing the key means existing installs can no longer update themselves – keep a Keychain backup.
import CryptoKit
import Foundation
import Security

let service = "Mountpoint update key"
let account = "moritz-poth"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
          let raw = Data(base64Encoded: data) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "new":
    if storedKey() != nil { fail("A key already exists – not replacing it (installed apps trust the old one).") }
    let key = Curve25519.Signing.PrivateKey()
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                              kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                              kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8)]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Could not save the key in the Keychain (\(status)).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let key = storedKey() else { fail("No key in the Keychain. Run: swift scripts/update-key.swift new") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first else { fail("usage: update-key.swift sign <zip>") }
    guard let key = storedKey() else { fail("No signing key in the Keychain – the zip stays unsigned and the app will not install it.") }
    guard let zip = FileManager.default.contents(atPath: path) else { fail("Cannot read \(path)") }
    let signature = try key.signature(for: zip)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
default:
    fail("usage: update-key.swift new | public | sign <zip>")
}
