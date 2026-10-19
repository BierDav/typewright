import AppKit
import AuthenticationServices
import CryptoKit
import Observation
import Security

/// The account all of a user's devices share, backed by a passkey. A synced passkey's PRF output is the
/// same on every device, so signing in with it is all a new device needs; the derived secret stays in the keychain.
@MainActor @Observable
final class SyncIdentity: NSObject {
    static let shared = SyncIdentity()

    /// 32 bytes every key of the account derives from.
    private(set) var account: Data?
    /// The name the passkey was created with, as the Passwords app shows it.
    private(set) var name: String?
    private(set) var isWorking = false
    private(set) var error: String?

    /// Relying party for the passkey; needs the associated domain entitlement and the domain's
    /// `apple-app-site-association` listing this app under `webcredentials`.
    /// Nil in builds signed without that entitlement, like ad-hoc development builds.
    static let passkeyDomain: String? = {
        guard let domain = Bundle.main.object(forInfoDictionaryKey: "TypewrightPasskeyDomain") as? String, !domain.isEmpty,
              let task = SecTaskCreateFromSelf(nil),
              let domains = SecTaskCopyValueForEntitlement(task, "com.apple.developer.associated-domains" as CFString, nil) as? [String],
              domains.contains("webcredentials:" + domain) else { return nil }
        return domain
    }()

    /// Short, stable name of the account to compare between devices.
    var fingerprint: String? {
        guard let account else { return nil }
        let hex = SHA256.hash(data: account).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }

    private static let service = "dev.bierdav.Typewright.sync"
    private static let kindKey = "syncIdentityKind"
    private static let nameKey = "syncIdentityName"
    /// Fixed so every device gets the same PRF output from the passkey.
    private static let salt = Data(SHA256.hash(data: Data("typewright account v0".utf8)))

    private var pending: CheckedContinuation<ASAuthorization, Error>?

    override private init() {
        super.init()
        account = Self.loadSecret()
        // Passkeys are the only way in now; accounts from recovery keys sign out once.
        if account != nil, UserDefaults.standard.string(forKey: Self.kindKey) != "passkey" {
            SecItemDelete(Self.query as CFDictionary)
            account = nil
        }
        name = account == nil ? nil : UserDefaults.standard.string(forKey: Self.nameKey)
    }

    /// Creates the account's passkey, named `name` (like an email address) in the Passwords app.
    func createPasskey(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            let provider = try self.provider()
            // The name rides along in the user handle, so signing in on another Mac recovers it.
            let userID = Self.random(16) + Data(name.utf8.prefix(48))
            let request = provider.createCredentialRegistrationRequest(
                challenge: Self.random(32), name: name.isEmpty ? "Typewright" : name, userID: userID)
            request.displayName = name.isEmpty ? "Typewright" : name
            request.prf = .inputValues(.init(saltInput1: Self.salt))
            let result = try await self.perform(request)
            if let registration = result.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
               let key = registration.prf?.first {
                return (key, name)
            }
            // Some authenticators only evaluate the PRF when signing in.
            return try await self.assert(with: provider)
        }
    }

    func signInWithPasskey() async {
        await run { try await self.assert(with: try self.provider()) }
    }

    func signOut() {
        SecItemDelete(Self.query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.kindKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        account = nil
        name = nil
        SyncService.shared.restart()
    }

    // MARK: - Passkeys

    private func run(_ body: @escaping () async throws -> (SymmetricKey, String)) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let (prf, name) = try await body()
            let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: prf, info: Data("typewright account v0".utf8), outputByteCount: 32)
            adopt(secret.withUnsafeBytes { Data($0) }, name: name)
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

    private func assert(with provider: ASAuthorizationPlatformPublicKeyCredentialProvider) async throws -> (SymmetricKey, String) {
        let request = provider.createCredentialAssertionRequest(challenge: Self.random(32))
        request.prf = .inputValues(.init(saltInput1: Self.salt))
        let result = try await perform(request)
        guard let assertion = result.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
              let key = assertion.prf?.first else {
            throw IdentityError("This passkey can't derive keys (no PRF support).")
        }
        let handle = assertion.userID ?? Data()
        return (key, handle.count > 16 ? String(decoding: handle.dropFirst(16), as: UTF8.self) : "")
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

    private func adopt(_ secret: Data, name: String) {
        SecItemDelete(Self.query as CFDictionary)
        var item = Self.query
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        UserDefaults.standard.set("passkey", forKey: Self.kindKey)
        UserDefaults.standard.set(name, forKey: Self.nameKey)
        account = secret
        self.name = name
        error = nil
        SyncService.shared.restart()
    }

    // MARK: - Keychain

    private static var query: [String: Any] {
        // The data protection keychain never prompts, unlike the file keychain after each re-signed build;
        // it needs the signed app's identifier, which builds without passkeys lack anyway.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account",
         kSecUseDataProtectionKeychain as String: true]
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
