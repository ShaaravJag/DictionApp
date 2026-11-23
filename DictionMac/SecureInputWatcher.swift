import AppKit
import Carbon.HIToolbox
import IOKit
import OSLog

/// Watches macOS Secure Input.
///
/// While any app has Secure Input on (normally only while you type in a password
/// field), macOS hides keypresses from every other app, so the 🎤 key never reaches
/// DictionApp. Browsers sometimes leave it on by mistake, which silently breaks dictation.
@MainActor
final class SecureInputWatcher {
    /// Called with the name of the app holding Secure Input, or nil once it's off.
    var onChange: ((String?) -> Void)?
    private(set) var blockingApp: String?

    private var timer: Timer?
    private let logger = Logger(subsystem: "com.dictionapp.mac", category: "secure-input")

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        var app: String?
        if IsSecureEventInputEnabled() {
            let pid = Self.secureInputPID()
            if pid != ProcessInfo.processInfo.processIdentifier {
                app = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Another app"
            }
        }
        guard app != blockingApp else { return }
        blockingApp = app
        if let app {
            logger.info("Secure Input is on, held by \(app, privacy: .public)")
        } else {
            logger.info("Secure Input is off")
        }
        onChange?(app)
    }

    /// The process holding Secure Input, from the console user's session info in the IORegistry.
    private static func secureInputPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return pid_t(pid) }
        }
        return nil
    }
}
