import LocalAuthentication
import Observation
import SwiftUI

/// Face ID / passcode lock. Locks at launch and after the chosen delay in the background.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    var lastError: String?
    private var backgroundedAt: Date?

    init() {
        isLocked = UserDefaults.standard.bool(forKey: AppSettings.lockEnabled)
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: AppSettings.lockEnabled) }

    private var delay: TimeInterval {
        TimeInterval(UserDefaults.standard.integer(forKey: AppSettings.autoLockDelay))
    }

    func sceneDidChange(to phase: ScenePhase) {
        guard isEnabled else { return }
        switch phase {
        case .background:
            backgroundedAt = .now
            if delay == 0 { isLocked = true }
        case .active:
            if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) >= delay {
                isLocked = true
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    /// Asks for Face ID, falling back to the device passcode.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await Self.authenticate(reason: String(localized: "Unlock your journal")) {
            isLocked = false
            lastError = nil
        }
    }

    /// Checks that authentication works before turning the lock on, so nobody locks themselves out.
    func confirmEnabling() async -> Bool {
        await Self.authenticate(reason: String(localized: "Turn on the journal lock"))
    }

    /// Whether the device has Face ID, Touch ID or a passcode set up.
    static var canAuthenticate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static var biometryName: LocalizedStringResource {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    private static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
