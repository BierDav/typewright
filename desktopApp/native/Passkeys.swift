import AppKit
import AuthenticationServices
import CryptoKit
import Security

private typealias Reply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

@_cdecl("tw_desktop_passkeys_available")
func passkeysAvailable() -> Bool {
    guard #available(macOS 15.0, *), let task = SecTaskCreateFromSelf(nil),
          let domains = SecTaskCopyValueForEntitlement(task, "com.apple.developer.associated-domains" as CFString, nil) as? [String]
    else { return false }
    return domains.contains("webcredentials:bierdav.github.io")
}

@_cdecl("tw_desktop_passkey")
func passkey(_ window: UnsafeMutableRawPointer, _ mode: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>,
             _ context: UnsafeMutableRawPointer?, _ reply: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void) {
    let mode = String(cString: mode), name = String(cString: name)
    let anchor = Unmanaged<NSWindow>.fromOpaque(window).takeUnretainedValue()
    DispatchQueue.main.async {
        guard #available(macOS 15.0, *), passkeysAvailable() else {
            "{\"error\":\"Native passkeys need a signed build with an associated domain.\"}".withCString { reply(context, $0) }
            return
        }
        let session = PasskeySession(window: anchor)
        Task { @MainActor in
            let result = await session.run(mode: mode, name: name)
            result.withCString { reply(context, $0) }
        }
    }
}

@available(macOS 15.0, *)
@MainActor private final class PasskeySession: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let window: NSWindow
    private var pending: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?
    private let salt = Data(SHA256.hash(data: Data("typewright account v0".utf8)))

    init(window: NSWindow) { self.window = window }

    func run(mode: String, name: String) async -> String {
        do {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "bierdav.github.io")
            var key: SymmetricKey?
            var accountName = name
            if mode == "create" {
                let user = random(16) + Data(name.utf8.prefix(48))
                let request = provider.createCredentialRegistrationRequest(challenge: random(32), name: name.isEmpty ? "Typewright" : name, userID: user)
                request.displayName = name.isEmpty ? "Typewright" : name
                request.prf = .inputValues(.init(saltInput1: salt))
                key = (try await perform(request).credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration)?.prf?.first
            }
            if key == nil {
                let request = provider.createCredentialAssertionRequest(challenge: random(32))
                request.prf = .inputValues(.init(saltInput1: salt))
                guard let result = try await perform(request).credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
                      let prf = result.prf?.first else { throw NSError(domain: "Typewright", code: 1, userInfo: [NSLocalizedDescriptionKey: "This passkey can't derive keys (no PRF support)."] ) }
                key = prf
                let user = result.userID ?? Data()
                accountName = user.count > 16 ? String(decoding: user.dropFirst(16), as: UTF8.self) : ""
            }
            let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: key!, info: Data("typewright account v0".utf8), outputByteCount: 32)
            let hex = secret.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
            return encode(["secret": hex, "name": accountName])
        } catch let error as ASAuthorizationError where error.code == .canceled { return "null" }
        catch { return encode(["error": error.localizedDescription]) }
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            controller = ASAuthorizationController(authorizationRequests: [request])
            controller?.delegate = self
            controller?.presentationContextProvider = self
            controller?.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        pending?.resume(returning: authorization)
        pending = nil
        self.controller = nil
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        pending?.resume(throwing: error)
        pending = nil
        self.controller = nil
    }
    private func random(_ size: Int) -> Data {
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
        return data
    }
    private func encode(_ value: [String: String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

@_cdecl("tw_desktop_account")
func accountStore(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let request = String(cString: input)
    let service = "dev.bierdav.Typewright.sync"
    let defaults: UserDefaults
    if Bundle.main.bundleIdentifier == "dev.bierdav.Typewright" {
        defaults = .standard
    } else {
        defaults = UserDefaults(suiteName: "dev.bierdav.Typewright") ?? .standard
    }
    func query(_ protected: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "account", kSecUseDataProtectionKeychain as String: protected]
    }
    if request != "load" {
        let value = request.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
        for protected in [true, false] {
            SecItemDelete(query(protected) as CFDictionary)
        }
        if let value, let hex = value["secret"], hex.count == 64 {
            var bytes = Data()
            var at = hex.startIndex
            while at < hex.endIndex {
                let end = hex.index(at, offsetBy: 2)
                guard let byte = UInt8(hex[at..<end], radix: 16) else { return strdup("{\"error\":\"Invalid account key\"}") }
                bytes.append(byte)
                at = end
            }
            var status = errSecMissingEntitlement
            for protected in [true, false] {
                var item = query(protected)
                item[kSecValueData as String] = bytes
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
                if status != errSecMissingEntitlement { break }
            }
            guard status == errSecSuccess else { return strdup("{\"error\":\"The keychain did not store the account\"}") }
            defaults.set(value["name"], forKey: "syncIdentityName")
            defaults.set(value["kind"], forKey: "syncIdentityKind")
        } else {
            defaults.removeObject(forKey: "syncIdentityName")
            defaults.removeObject(forKey: "syncIdentityKind")
        }
        return strdup("null")
    }
    for protected in [true, false] {
        var item = query(protected)
        item[kSecReturnData as String] = true
        var result: AnyObject?
        if SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 {
            if !protected {
                var migrated = query(true)
                migrated[kSecValueData as String] = data
                migrated[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                _ = SecItemAdd(migrated as CFDictionary, nil)
            }
            let value = ["secret": data.map { String(format: "%02x", $0) }.joined(),
                         "name": defaults.string(forKey: "syncIdentityName") ?? "",
                         "kind": defaults.string(forKey: "syncIdentityKind") ?? "passkey"]
            return strdup(String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
    }
    return strdup("null")
}

@_cdecl("tw_desktop_window_control")
func windowControl(_ pointer: UnsafeMutableRawPointer, _ action: UnsafePointer<CChar>) {
    let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
    switch String(cString: action) {
    case "close": window.performClose(nil)
    case "minimize": window.performMiniaturize(nil)
    case "zoom": window.performZoom(nil)
    default: break
    }
}

@MainActor private final class TrafficLightHover: NSResponder {
    static let shared = TrafficLightHover()
    weak var window: NSWindow?
    var tracking: NSTrackingArea?

    func show(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    override func mouseExited(with event: NSEvent) { show(false) }
    override func mouseEntered(with event: NSEvent) { show(true) }

    func update(window: NSWindow, rect: NSRect) {
        if let tracking { self.window?.contentView?.removeTrackingArea(tracking) }
        self.window = window
        tracking = nil
        guard let content = window.contentView, rect.width > 0 else { show(false); return }
        let bounds = NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let target = NSRect(x: bounds.minX + CGFloat(index) * 20, y: bounds.minY, width: 12, height: 12)
            button.frame = parent.convert(target, from: content)
        }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -4, dy: -4), options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self)
        content.addTrackingArea(area)
        tracking = area
        show(true)
    }
}

@_cdecl("tw_desktop_hover_buttons")
@MainActor func hoverButtons(_ pointer: UnsafeMutableRawPointer, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
    let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
    TrafficLightHover.shared.update(window: window, rect: NSRect(x: x, y: y, width: width, height: height))
}
