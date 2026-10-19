import AppKit
import AuthenticationServices
import CryptoKit
import Observation
import Security

/// The account all of a user's devices share. A synced passkey's PRF output is the same on every
/// device, so signing in with it is all a new device needs; the derived secret stays in the keychain.
@MainActor @Observable
final class SyncIdentity: NSObject {
    static let shared = SyncIdentity()

    enum Kind: String { case passkey, recoveryKey }

    /// 32 bytes every key of the account derives from.
    private(set) var account: Data?
    private(set) var kind: Kind?
    private(set) var isWorking = false
    private(set) var error: String?

    /// Relying party for the passkey; needs the associated domain entitlement and the domain's
    /// `apple-app-site-association` listing this app under `webcredentials`.
    static var passkeyDomain: String? {
        (Bundle.main.object(forInfoDictionaryKey: "TypewrightPasskeyDomain") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Short, stable name of the account to compare between devices.
    var fingerprint: String? {
        guard let account else { return nil }
        let hex = SHA256.hash(data: account).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }

    private static let service = "dev.bierdav.Typewright.sync"
    private static let kindKey = "syncIdentityKind"
    /// Fixed so every device gets the same PRF output from the passkey.
    private static let salt = Data(SHA256.hash(data: Data("typewright account v0".utf8)))

    private var pending: CheckedContinuation<ASAuthorization, Error>?

    override private init() {
        super.init()
        account = Self.loadSecret()
        kind = account == nil ? nil : UserDefaults.standard.string(forKey: Self.kindKey).flatMap(Kind.init)
    }

    func createPasskey() async {
        await run {
            let provider = try self.provider()
            let request = provider.createCredentialRegistrationRequest(
                challenge: Self.random(32), name: "Typewright", userID: Self.random(16))
            request.prf = .inputValues(.init(saltInput1: Self.salt))
            let result = try await self.perform(request)
            if let registration = result.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
               let key = registration.prf?.first {
                return key
            }
            // Some authenticators only evaluate the PRF when signing in.
            return try await self.assert(with: provider)
        }
    }

    func signInWithPasskey() async {
        await run { try await self.assert(with: try self.provider()) }
    }

    /// Without a configured passkey domain: a key to copy to the other devices by hand.
    func generateRecoveryKey() -> String {
        let key = Self.random(32)
        adopt(key, kind: .recoveryKey)
        return Self.hex(key)
    }

    func useRecoveryKey(_ text: String) {
        let hex = text.filter(\.isHexDigit)
        guard hex.count == 64, let key = Self.data(hex: hex) else {
            error = "A recovery key has 64 hexadecimal digits."
            return
        }
        adopt(key, kind: .recoveryKey)
    }

    var recoveryKey: String? { kind == .recoveryKey ? account.map(Self.hex) : nil }

    func signOut() {
        SecItemDelete(Self.query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.kindKey)
        account = nil
        kind = nil
        SyncService.shared.restart()
    }

    // MARK: - Passkeys

    private func run(_ body: @escaping () async throws -> SymmetricKey) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let prf = try await body()
            let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: prf, info: Data("typewright account v0".utf8), outputByteCount: 32)
            adopt(secret.withUnsafeBytes { Data($0) }, kind: .passkey)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // Dismissed by the user.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func provider() throws -> ASAuthorizationPlatformPublicKeyCredentialProvider {
        guard let domain = Self.passkeyDomain else {
            throw IdentityError("Passkeys need an associated domain; set TypewrightPasskeyDomain in Info.plist.")
        }
        return ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: domain)
    }

    private func assert(with provider: ASAuthorizationPlatformPublicKeyCredentialProvider) async throws -> SymmetricKey {
        let request = provider.createCredentialAssertionRequest(challenge: Self.random(32))
        request.prf = .inputValues(.init(saltInput1: Self.salt))
        let result = try await perform(request)
        guard let assertion = result.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
              let key = assertion.prf?.first else {
            throw IdentityError("This passkey can't derive keys (no PRF support).")
        }
        return key
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func adopt(_ secret: Data, kind: Kind) {
        SecItemDelete(Self.query as CFDictionary)
        var item = Self.query
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey)
        account = secret
        self.kind = kind
        error = nil
        SyncService.shared.restart()
    }

    // MARK: - Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account"]
    }

    private static func loadSecret() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              data.count == 32 else { return nil }
        return data
    }

    private static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func hex(_ data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 8)])
        }.joined(separator: "-")
    }

    private static func data(hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

extension SyncIdentity: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            pending?.resume(returning: authorization)
            pending = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            pending?.resume(throwing: error)
            pending = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

private struct IdentityError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
