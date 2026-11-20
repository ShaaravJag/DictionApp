import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Accessibility lets us read the dictation key globally and press ⌘V for you.
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system "would like to control this computer" prompt.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
