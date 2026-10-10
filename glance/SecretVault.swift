//
//  SecretVault.swift
//  Face ID for Mac (by PK)
//
//  Holds the 256-bit session key that encrypts the Mac password and the enrolled faces. Glance kept it in a Keychain
//  item with a `userPresence` access control — on macOS that silently means the data-protection keychain, which needs a
//  paid Team ID (errSecMissingEntitlement / -34018). This build is self-signed, so:
//
//  1. Secure Enclave (preferred). A P-256 key-agreement key is created *inside* the Secure Enclave with `.userPresence`;
//     only an opaque handle (`dataRepresentation`, useless on any other Mac) is written to disk. The session key is
//     wrapped ECIES-style: ephemeral P-256 + ECDH with the SE key + HKDF-SHA256 → AES-GCM. Unwrapping needs the SE key
//     to agree, which needs Touch ID or the login password. No entitlement involved.
//  2. Login keychain (fallback, weaker — shown as such in Settings). Plain file-keychain item readable only by this
//     signed app, plus a Touch ID / password check in the app before it is read.
//
//  The backend is chosen once, when the key is first created, and recorded next to it.
//

import Foundation
import CryptoKit
import LocalAuthentication
import Security

nonisolated enum VaultBackend: String {
    case secureEnclave
    case keychain

    var title: String {
        switch self {
        case .secureEnclave: return "Secure Enclave (Touch ID)"
        case .keychain: return "Связка ключей (запасной вариант)"
        }
    }
}

nonisolated enum SecretVaultError: LocalizedError {
    case noKey
    case corrupt
    case authenticationFailed(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Ключ хранилища не найден."
        case .corrupt: return "Файл хранилища повреждён."
        case .authenticationFailed(let m): return "Проверка Touch ID не прошла: \(m)"
        case .keychain(let s): return "Ошибка связки ключей: \(SecCopyErrorMessageString(s, nil) as String? ?? "\(s)")"
        }
    }
}

nonisolated enum SecretVault {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FaceIDforMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()
    private static var backendURL: URL { directory.appendingPathComponent("vault-backend") }
    private static var seKeyURL: URL { directory.appendingPathComponent("vault-se-key") }
    private static var wrappedURL: URL { directory.appendingPathComponent("vault-wrapped") }
    private static let keychainService = "com.pavel.faceidformac"
    private static let keychainAccount = "session-key"
    private static let hkdfSalt = Data("FaceIDforMac.vault.v1".utf8)

    static var backend: VaultBackend? {
        guard let raw = try? String(contentsOf: backendURL, encoding: .utf8) else { return nil }
        return VaultBackend(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var exists: Bool {
        switch backend {
        case .secureEnclave: return FileManager.default.fileExists(atPath: seKeyURL.path)
            && FileManager.default.fileExists(atPath: wrappedURL.path)
        case .keychain: return keychainItemExists()
        case nil: return false
        }
    }

    /// Creates a new session key. Tries the Secure Enclave first. Proves the round trip (one Touch ID prompt) before
    /// returning, so a key that can't be read back is never left behind.
    static func create(reason: String) throws -> SymmetricKey {
        destroy()
        let key = SymmetricKey(size: .bits256)
        if SecureEnclave.isAvailable, (try? createInSecureEnclave(key)) != nil {
            try write(VaultBackend.secureEnclave.rawValue, to: backendURL)
            let readBack = try open(reason: reason)
            guard readBack == key else { destroy(); throw SecretVaultError.corrupt }
            return key
        }
        try createInKeychain(key)
        try write(VaultBackend.keychain.rawValue, to: backendURL)
        let readBack = try open(reason: reason)
        guard readBack == key else { destroy(); throw SecretVaultError.corrupt }
        return key
    }

    /// Unwraps the session key. Always asks for Touch ID (or the login password).
    static func open(reason: String) throws -> SymmetricKey {
        switch backend {
        case .secureEnclave: return try openFromSecureEnclave(reason: reason)
        case .keychain: return try openFromKeychain(reason: reason)
        case nil: throw SecretVaultError.noKey
        }
    }

    static func destroy() {
        for url in [backendURL, seKeyURL, wrappedURL] { try? FileManager.default.removeItem(at: url) }
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    // MARK: - Secure Enclave

    private static func createInSecureEnclave(_ key: SymmetricKey) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw SecretVaultError.authenticationFailed(error?.takeRetainedValue().localizedDescription ?? "access control")
        }
        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: seKey.publicKey)
        let wrapKey = derive(shared, ephemeral: ephemeral.publicKey, recipient: seKey.publicKey)
        let sealed = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrapKey)
        guard let combined = sealed.combined else { throw SecretVaultError.corrupt }
        try write(seKey.dataRepresentation, to: seKeyURL)
        try write(ephemeral.publicKey.x963Representation + combined, to: wrappedURL)
    }

    private static func openFromSecureEnclave(reason: String) throws -> SymmetricKey {
        guard let handle = try? Data(contentsOf: seKeyURL), let blob = try? Data(contentsOf: wrappedURL),
              blob.count > 65 else { throw SecretVaultError.noKey }
        let context = LAContext()
        context.localizedReason = reason
        do {
            let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle,
                                                                       authenticationContext: context)
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
            let shared = try seKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let wrapKey = derive(shared, ephemeral: ephemeral, recipient: seKey.publicKey)
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst(65))
            return SymmetricKey(data: try AES.GCM.open(box, using: wrapKey))
        } catch let e as SecretVaultError {
            throw e
        } catch {
            throw SecretVaultError.authenticationFailed(error.localizedDescription)
        }
    }

    private static func derive(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey,
                               recipient: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: hkdfSalt,
                                       sharedInfo: ephemeral.x963Representation + recipient.x963Representation,
                                       outputByteCount: 32)
    }

    // MARK: - Login keychain fallback

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func keychainItemExists() -> Bool {
        var q = keychainQuery()
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    private static func createInKeychain(_ key: SymmetricKey) throws {
        SecItemDelete(keychainQuery() as CFDictionary)
        var q = keychainQuery()
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
    }

    private static func openFromKeychain(reason: String) throws -> SymmetricKey {
        try requireOwner(reason: reason)
        var q = keychainQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else {
            throw status == errSecSuccess ? SecretVaultError.corrupt : SecretVaultError.keychain(status)
        }
        return SymmetricKey(data: data)
    }

    /// Touch ID or login password. Called only from background threads (never the main thread).
    private static func requireOwner(reason: String) throws {
        let context = LAContext()
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var ok = false; var message = "" }
        let box = Box()
        let reply: @Sendable (Bool, Error?) -> Void = { ok, err in
            box.ok = ok
            box.message = err?.localizedDescription ?? ""
            done.signal()
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason, reply: reply)
        done.wait()
        guard box.ok else { throw SecretVaultError.authenticationFailed(box.message) }
    }

    // MARK: -

    private static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
